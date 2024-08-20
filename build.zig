const std = @import("std");
const fs = std.fs;

const Build = std.Build;
const Step = Build.Step;
const ArrayList = std.ArrayList;

const vkgen = @import("vulkan_zig");
const ShaderCompileStep = vkgen.ShaderCompileStep;

const BuildProduct = enum {
    editor,
    game,
};

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_product = b.option(BuildProduct, "bin_type", "Whether the build is a game executable, or the scene editor") orelse .editor;
    const config_options = build_options_blk: {
        const opts = b.addOptions();
        opts.addOption(BuildProduct, "bin_type", build_product);
        opts.addOption([]const u8, "build_script_path", thisDir());

        break :build_options_blk opts;
    };

    const main_path = b.path("src/main.zig");
    const exe = b.addExecutable(.{
        .name = if (build_product == .editor) "editor" else "game",
        .root_source_file = main_path,
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addOptions("config_options", config_options);

    // link ecez and ztracy
    {
        // let user enable/disable tracy
        const enable_tracy = b.option(bool, "enable-tracy", "Enable Tracy profiler") orelse false;

        // link ecez
        {
            const ecez = b.dependency("ecez", .{ .enable_tracy = enable_tracy });
            exe.root_module.addImport("ecez", ecez.module("ecez"));

            const ztracy_dep = b.dependency("ztracy", .{
                .enable_ztracy = enable_tracy,
            });

            exe.root_module.addImport("ztracy", ztracy_dep.module("root"));

            if (enable_tracy)
                exe.linkLibrary(ztracy_dep.artifact("tracy"));
        }
    }

    // Use zglfw
    {
        const zglfw = b.dependency("zglfw", .{});
        exe.root_module.addImport("zglfw", zglfw.module("root"));
        exe.linkLibrary(zglfw.artifact("glfw"));

        @import("system_sdk").addLibraryPathsTo(exe);
    }

    // link zmath
    {
        const zmath = b.dependency("zmath", .{});
        exe.root_module.addImport("zmath", zmath.module("root"));
    }

    // link zmesh
    {
        const zmesh = b.dependency("zmesh", .{});
        exe.root_module.addImport("zmesh", zmesh.module("root"));
        exe.linkLibrary(zmesh.artifact("zmesh"));
    }

    // link zgui
    {
        const zgui = b.dependency("zgui", .{
            .shared = false,
            .with_implot = true,
        });
        exe.root_module.addImport("zgui", zgui.module("root"));
        exe.linkLibrary(zgui.artifact("imgui"));
    }

    // link zigimg
    {
        const zigimg = b.dependency("zigimg", .{});
        exe.root_module.addImport("zigimg", zigimg.module("zigimg"));
    }

    // generate vulkan bindings, link vulkan and generate shaders
    const shader_comp_step = vulkan_blk: {
        // Get the (lazy) path to vk.xml:
        const registry = b.dependency("vulkan_headers", .{}).path("deps/vk.xml");
        // Get generator executable reference
        const vk_gen = b.dependency("vulkan_zig", .{}).artifact("vulkan-zig-generator");
        // Set up a run step to generate the bindings
        const vk_generate_cmd = b.addRunArtifact(vk_gen);
        // Pass the registry to the generator
        vk_generate_cmd.addArg(registry.dependency.sub_path);
        // Create a module from the generator's output...
        const vulkan_zig = b.addModule("vulkan-zig", .{
            .root_source_file = vk_generate_cmd.addOutputFileArg("vk.zig"),
        });
        // ... and pass it as a module to your executable's build command
        exe.root_module.addImport("vulkan", vulkan_zig);

        // link shaders
        {
            // TODO: -O (optimize), -I (includes)
            //  !always have -g as last entry! (see glslc_len definition)
            const include_shader_debug = b.option(bool, "shader-debug-info", "include shader debug info, default is false") orelse false;
            const glslc_flags = [_][]const u8{ "glslc", "--target-env=vulkan1.2", "-g" };
            const glslc_len = if (include_shader_debug) glslc_flags.len else glslc_flags.len - 1;
            const shader_comp = vkgen.ShaderCompileStep.create(
                b,
                glslc_flags[0..glslc_len],
                "-o",
            );

            // compile the mesh shaders
            shader_comp.add("mesh_vert_spv", "assets/shaders/mesh.vert", .{});
            shader_comp.add("mesh_frag_spv", "assets/shaders/mesh.frag", .{});

            // compile the ui shaders
            shader_comp.add("ui_vert_spv", "assets/shaders/ui.vert", .{});
            shader_comp.add("ui_frag_spv", "assets/shaders/ui.frag", .{});

            exe.step.dependOn(&shader_comp.step);
            exe.root_module.addImport("shaders", shader_comp.getModule());

            break :vulkan_blk shader_comp;
        }
    };

    var asset_move_step = AssetMoveStep.init(b) catch unreachable;
    exe.step.dependOn(&asset_move_step.step);
    asset_move_step.step.dependOn(&shader_comp_step.step);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
    run_step.dependOn(&asset_move_step.step);

    const exe_tests = b.addTest(.{
        .root_source_file = main_path,
        .target = target,
        .optimize = optimize,
    });

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
    builder: *Build,

    fn init(b: *Build) !*AssetMoveStep {
        const step = Step.init(.{ .id = .custom, .name = "assets", .owner = b, .makeFn = make });

        const self = try b.allocator.create(AssetMoveStep);
        self.* = .{
            .step = step,
            .builder = b,
        };

        return self;
    }

    fn make(step: *Step, prog_node: std.Progress.Node) anyerror!void {
        const self: *AssetMoveStep = @fieldParentPtr("step", step);

        try createFolder(self.builder.install_prefix);

        const dst_asset_path = blk: {
            const dst_asset_path_arr = [_][]const u8{ self.builder.install_prefix, "assets" };
            break :blk try std.fs.path.join(self.builder.allocator, dst_asset_path_arr[0..]);
        };
        try createFolder(dst_asset_path);
        var dst_assets_dir = try fs.openDirAbsolute(dst_asset_path, .{});
        defer dst_assets_dir.close();

        var src_assets_dir = try fs.openDirAbsolute(thisDir() ++ "/assets", .{
            .iterate = true,
            .access_sub_paths = true,
        });
        defer src_assets_dir.close();

        copyDir(self.builder, src_assets_dir, dst_assets_dir);

        prog_node.completeOne();
    }
};

// TODO: HACK: catch unreachable to avoid error hell from recursion
fn copyDir(b: *Build, src_dir: fs.Dir, dst_parent_dir: fs.Dir) void {
    const Kind = fs.File.Kind;

    var walker = src_dir.walk(b.allocator) catch unreachable;
    defer walker.deinit();
    while (walker.next() catch unreachable) |asset| {
        switch (asset.kind) {
            Kind.directory => {
                var src_child_dir = src_dir.openDir(asset.path, .{
                    .iterate = true,
                    .access_sub_paths = true,
                }) catch unreachable;
                defer src_child_dir.close();

                dst_parent_dir.makeDir(asset.path) catch |err| switch (err) {
                    error.PathAlreadyExists => {}, // ok
                    else => unreachable,
                };
                var dst_child_dir = dst_parent_dir.openDir(asset.path, .{}) catch unreachable;
                defer dst_child_dir.close();
            },
            Kind.file => {
                if (std.mem.eql(u8, asset.path[0..7], "shaders")) {
                    continue; // skip shader folder which will be compiled by glslc before being moved
                }
                src_dir.copyFile(asset.path, dst_parent_dir, asset.path, .{}) catch unreachable;
            },
            else => {}, // don't care
        }
    }
}

inline fn createFolder(path: []const u8) !void {
    if (fs.makeDirAbsolute(path)) |_| {
        // ok
    } else |err| switch (err) {
        error.PathAlreadyExists => {
            // ok
        },
        else => |e| return e,
    }
}

fn glfwLink(b: *std.Build, step: *std.build.CompileStep) void {
    const glfw_dep = b.dependency("mach_glfw", .{
        .target = step.target,
        .optimize = step.optimize,
    });
    step.linkLibrary(glfw_dep.artifact("mach-glfw"));
    step.addModule("glfw", glfw_dep.module("mach-glfw"));

    // TODO(build-system): Zig package manager currently can't handle transitive deps like this, so we need to use
    // these explicitly here:
    @import("glfw").addPaths(step);
    step.linkLibrary(b.dependency("vulkan_headers", .{
        .target = step.target,
        .optimize = step.optimize,
    }).artifact("vulkan-headers"));
    step.linkLibrary(b.dependency("x11_headers", .{
        .target = step.target,
        .optimize = step.optimize,
    }).artifact("x11-headers"));
    step.linkLibrary(b.dependency("wayland_headers", .{
        .target = step.target,
        .optimize = step.optimize,
    }).artifact("wayland-headers"));
}
