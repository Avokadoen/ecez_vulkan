const std = @import("std");
const fs = std.fs;

const LibExeObjStep = std.build.LibExeObjStep;
const Builder = std.build.Builder;
const Step = std.build.Step;
const ArrayList = std.ArrayList;

// const ecez = @import("deps/ecez/build.zig");
const glfw = @import("deps/mach-glfw/build.zig");
const zmath = @import("deps/zmath/build.zig");
const zmesh = @import("deps/zmesh/build.zig");

const vkgen = @import("deps/vulkan-zig/generator/index.zig");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("ecez-vulkan", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);

    // let user enable/disable tracy
    // const ztracy_enable = b.option(bool, "enable-tracy", "Enable Tracy profiler") orelse false;
    // link ecez and ztracy
    // // ecez.link(b, exe, ztracy_enable);

    // link glfw
    exe.addPackage(glfw.pkg);
    glfw.link(b, exe, .{}) catch unreachable;

    // link zmath
    exe.addPackage(zmath.pkg);

    // link zigimg
    exe.addPackagePath("zigimg", "deps/zigimg/zigimg.zig");

    // link zmesh
    const zmesh_options = zmesh.BuildOptionsStep.init(b, .{});
    const zmesh_pkg = zmesh.getPkg(&.{zmesh_options.getPkg()});
    exe.addPackage(zmesh_pkg);
    zmesh.link(exe, zmesh_options);

    // Create a step that generates vk.zig (stored in zig-cache) from the provided vulkan registry.
    const gen = vkgen.VkGenerateStep.init(b, thisDir() ++ "/deps/vk.xml", "vk.zig");
    // Add the generated file as package to the final executable
    exe.addPackage(gen.package);

    var asset_move_step = AssetMoveStep.init(b) catch unreachable;

    // TODO: -O (optimize), -I (includes)
    //  !always have -g as last entry! (see glslc_len definition)
    const include_shader_debug = b.option(bool, "shader-debug-info", "include shader debug info, default is false") orelse false;
    const glslc_flags = [_][]const u8{ "glslc", "--target-env=vulkan1.3", "-g" };
    const glslc_len = if (include_shader_debug) glslc_flags.len else glslc_flags.len - 1;
    const shader_comp = vkgen.ShaderCompileStep.init(
        b,
        glslc_flags[0..glslc_len],
        "assets/shaders",
    );
    _ = shader_comp.add("assets/shaders/shader.vert", .{
        .entry_point = null,
        .stage = .vertex,
        .output_filename = null,
    });
    _ = shader_comp.add("assets/shaders/shader.frag", .{
        .entry_point = null,
        .stage = .fragment,
        .output_filename = null,
    });

    exe.step.dependOn(&asset_move_step.step);
    asset_move_step.step.dependOn(&shader_comp.step);

    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
    run_step.dependOn(&asset_move_step.step);

    const exe_tests = b.addTest("src/main.zig");
    exe_tests.setTarget(target);
    exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}

inline fn thisDir() []const u8 {
    return comptime std.fs.path.dirname(@src().file) orelse ".";
}

const MoveDirError = error{NotFound};

/// Holds the path to a file where parent directory and file name is separated
const SplitPath = struct {
    dir: []const u8,
    file_name: []const u8,
};

inline fn pathAndFile(file_path: []const u8) MoveDirError!SplitPath {
    var i = file_path.len - 1;
    while (i > 0) : (i -= 1) {
        if (file_path[i] == '/') {
            return SplitPath{
                .dir = file_path[0..i],
                .file_name = file_path[i + 1 .. file_path.len],
            };
        }
    }
    return MoveDirError.NotFound;
}

const AssetMoveStep = struct {
    step: Step,
    builder: *Builder,

    fn init(b: *Builder) !*AssetMoveStep {
        var step = Step.init(.custom, "assets", b.allocator, make);

        const self = try b.allocator.create(AssetMoveStep);
        self.* = .{
            .step = step,
            .builder = b,
        };

        return self;
    }

    fn make(step: *Step) anyerror!void {
        const self: *AssetMoveStep = @fieldParentPtr(AssetMoveStep, "step", step);

        try createFolder(self.builder.install_prefix);

        const dst_asset_path = blk: {
            const dst_asset_path_arr = [_][]const u8{ self.builder.install_prefix, "assets" };
            break :blk try std.fs.path.join(self.builder.allocator, dst_asset_path_arr[0..]);
        };
        try createFolder(dst_asset_path);
        var dst_assets_dir = try fs.openIterableDirAbsolute(dst_asset_path, .{});
        defer dst_assets_dir.close();

        {
            var src_raw_assets_dir = try fs.cwd().openIterableDir("assets/", .{
                .access_sub_paths = true,
            });
            defer src_raw_assets_dir.close();

            copyDir(src_raw_assets_dir, dst_assets_dir);
        }

        {
            var src_shader_assets_dir = try fs.cwd().openIterableDir("zig-cache/assets/", .{
                .access_sub_paths = true,
            });
            defer src_shader_assets_dir.close();

            copyDir(src_shader_assets_dir, dst_assets_dir);
        }
    }
};

// TODO: HACK: catch unreachable to avoid error hell from recursion
fn copyDir(src_dir: fs.IterableDir, dst_parent_dir: fs.IterableDir) void {
    const Kind = fs.File.Kind;

    var iter = src_dir.iterate();
    search: while (iter.next() catch unreachable) |asset| {
        switch (asset.kind) {
            Kind.Directory => {
                var src_child_dir = src_dir.dir.openIterableDir(asset.name, .{
                    .access_sub_paths = true,
                }) catch unreachable;
                defer src_child_dir.close();

                dst_parent_dir.dir.makeDir(asset.name) catch |err| switch (err) {
                    std.os.MakeDirError.PathAlreadyExists => {}, // ok
                    else => unreachable,
                };

                var dst_child_dir = dst_parent_dir.dir.openIterableDir(asset.name, .{}) catch unreachable;
                defer dst_child_dir.close();

                copyDir(src_child_dir, dst_child_dir);
            },
            Kind.File => {
                for ([_][]const u8{
                    ".frag",
                    ".vert",
                    ".comp",
                }) |shader_ending| {
                    if (std.mem.endsWith(u8, asset.name, shader_ending)) {
                        continue :search; // skip shader folder which will be compiled by glslc before being moved
                    }
                }

                std.fs.Dir.copyFile(src_dir.dir, asset.name, dst_parent_dir.dir, asset.name, .{}) catch unreachable;
            },
            else => {}, // don't care
        }
    }
}

inline fn createFolder(path: []const u8) std.os.MakeDirError!void {
    if (fs.makeDirAbsolute(path)) |_| {
        // ok
    } else |err| switch (err) {
        std.os.MakeDirError.PathAlreadyExists => {
            // ok
        },
        else => |e| return e,
    }
}
