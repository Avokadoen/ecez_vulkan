const std = @import("std");
const fs = std.fs;

const LibExeObjStep = std.build.LibExeObjStep;
const Build = std.Build;
const Step = std.build.Step;
const ArrayList = std.ArrayList;

// ecez is needed by the Editor
const ecez = @import("deps/ecez/build.zig");

const zmath = @import("deps/zmath/build.zig");
const zmesh = @import("deps/zmesh/build.zig");
const zgui = @import("deps/zgui/build.zig");
const glfw = @import("deps/mach-glfw/build.zig");

const vkgen = @import("deps/vulkan-zig/generator/index.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ecez-vulkan",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = mode,
    });

    // let user enable/disable tracy
    const ztracy_enable = b.option(bool, "enable-tracy", "Enable Tracy profiler") orelse false;
    // link ecez and ztracy
    ecez.link(b, exe, true, ztracy_enable);

    // link glfw
    const glfw_module = glfw.module(b);
    glfw.link(b, exe, .{}) catch @panic("failed to link glfw");
    exe.addModule("glfw", glfw_module);

    // link zmath
    const zmath_pkg = zmath.package(b, target, mode, .{});
    zmath_pkg.link(exe);

    // link zigimg
    exe.addModule("zigimg", b.createModule(.{
        .source_file = .{ .path = "deps/zigimg/zigimg.zig" },
    }));

    // link zmesh
    const zmesh_pkg = zmesh.package(b, target, mode, .{
        .options = .{ .shape_use_32bit_indices = true },
    });
    zmesh_pkg.link(exe);

    // link zgui
    const zgui_pkg = zgui.package(b, target, mode, .{
        .options = .{ .backend = .no_backend },
    });
    zgui_pkg.link(exe);

    // Create a step that generates vk.zig (stored in zig-cache) from the provided vulkan registry.
    const gen = vkgen.VkGenerateStep.create(b, thisDir() ++ "/deps/vk.xml");
    // Add the generated file as package to the final executable
    exe.addModule("vulkan", gen.getModule());

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
    shader_comp.add("mesh.vert.spv", "assets/shaders/mesh.vert", .{});
    shader_comp.add("mesh.frag.spv", "assets/shaders/mesh.frag", .{});

    // compile the ui shaders
    shader_comp.add("ui.vert.spv", "assets/shaders/ui.vert", .{});
    shader_comp.add("ui.frag.spv", "assets/shaders/ui.frag", .{});

    var asset_move_step = AssetMoveStep.init(b) catch unreachable;
    exe.step.dependOn(&asset_move_step.step);
    asset_move_step.step.dependOn(&shader_comp.step);

    var shader_move_step = ShaderMoveStep.init(b, shader_comp) catch unreachable;
    exe.step.dependOn(&shader_move_step.step);
    shader_move_step.step.dependOn(&asset_move_step.step);

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
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = mode,
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

const ShaderMoveStep = struct {
    step: Step,
    shader_compile_step: *vkgen.ShaderCompileStep,

    fn init(b: *Build, shader_compile_step: *vkgen.ShaderCompileStep) !*ShaderMoveStep {
        const self = try b.allocator.create(ShaderMoveStep);
        self.* = .{
            .step = Build.Step.init(.{
                .id = .custom,
                .name = "shaders_move",
                .owner = b,
                .makeFn = make,
            }),
            .shader_compile_step = shader_compile_step,
        };

        return self;
    }

    fn make(step: *Build.Step, progress: *std.Progress.Node) !void {
        progress.setEstimatedTotalItems(4);
        progress.activate();
        defer progress.end();

        const self: *ShaderMoveStep = @fieldParentPtr(ShaderMoveStep, "step", step);
        var b: *Build = self.step.owner;

        const dst_shader_directory_path = blk: {
            const dst_asset_path_arr = [_][]const u8{ b.install_prefix, "assets", "shaders" };
            break :blk try std.fs.path.join(b.allocator, dst_asset_path_arr[0..]);
        };
        var dst_shader_dir = try fs.openDirAbsolute(dst_shader_directory_path, .{});
        defer dst_shader_dir.close();
        progress.setCompletedItems(1);

        const shaders_dir_path = try b.cache_root.join(
            b.allocator,
            &.{vkgen.ShaderCompileStep.cache_dir},
        );
        var src_shader_dir = try fs.openIterableDirAbsolute(shaders_dir_path, .{
            .access_sub_paths = true,
        });
        defer src_shader_dir.close();
        progress.setCompletedItems(2);

        copyDir(b, src_shader_dir, dst_shader_dir);
        progress.setCompletedItems(3);

        var iter_dst_shader_dir = try fs.openIterableDirAbsolute(dst_shader_directory_path, .{});
        defer iter_dst_shader_dir.close();
        var walker = iter_dst_shader_dir.walk(b.allocator) catch unreachable;
        defer walker.deinit();
        walk_loop: while (walker.next() catch unreachable) |asset| {
            switch (asset.kind) {
                fs.File.Kind.File => {
                    const actual_shader_name = blk: {
                        for (self.shader_compile_step.shaders.items) |shader| {
                            if (std.mem.eql(u8, asset.basename, &shader.hash)) {
                                break :blk shader.name;
                            }
                        }
                        continue :walk_loop;
                    };

                    const dst_shader_path = blk: {
                        const dst_asset_path_arr = [_][]const u8{ dst_shader_directory_path, actual_shader_name };
                        break :blk try std.fs.path.join(b.allocator, &dst_asset_path_arr);
                    };

                    asset.dir.rename(asset.path, dst_shader_path) catch unreachable;
                },
                else => {}, // don't care
            }
        }
        progress.setCompletedItems(4);
    }
};

const AssetMoveStep = struct {
    step: Step,
    builder: *Build,

    fn init(b: *Build) !*AssetMoveStep {
        var step = Step.init(.{ .id = .custom, .name = "assets", .owner = b, .makeFn = make });

        const self = try b.allocator.create(AssetMoveStep);
        self.* = .{
            .step = step,
            .builder = b,
        };

        return self;
    }

    fn make(step: *Step, prog_node: *std.Progress.Node) anyerror!void {
        const self: *AssetMoveStep = @fieldParentPtr(AssetMoveStep, "step", step);

        try createFolder(self.builder.install_prefix);

        const dst_asset_path = blk: {
            const dst_asset_path_arr = [_][]const u8{ self.builder.install_prefix, "assets" };
            break :blk try std.fs.path.join(self.builder.allocator, dst_asset_path_arr[0..]);
        };
        try createFolder(dst_asset_path);
        var dst_assets_dir = try fs.openDirAbsolute(dst_asset_path, .{});
        defer dst_assets_dir.close();

        var src_assets_dir = try fs.openIterableDirAbsolute(thisDir() ++ "/assets", .{
            .access_sub_paths = true,
        });
        defer src_assets_dir.close();

        copyDir(self.builder, src_assets_dir, dst_assets_dir);

        prog_node.completeOne();
    }
};

// TODO: HACK: catch unreachable to avoid error hell from recursion
fn copyDir(b: *Build, src_dir: fs.IterableDir, dst_parent_dir: fs.Dir) void {
    const Kind = fs.File.Kind;

    var walker = src_dir.walk(b.allocator) catch unreachable;
    defer walker.deinit();
    while (walker.next() catch unreachable) |asset| {
        switch (asset.kind) {
            Kind.Directory => {
                var src_child_dir = src_dir.dir.openIterableDir(asset.path, .{
                    .access_sub_paths = true,
                }) catch unreachable;
                defer src_child_dir.close();

                dst_parent_dir.makeDir(asset.path) catch |err| switch (err) {
                    std.os.MakeDirError.PathAlreadyExists => {}, // ok
                    else => unreachable,
                };
                var dst_child_dir = dst_parent_dir.openDir(asset.path, .{}) catch unreachable;
                defer dst_child_dir.close();
            },
            Kind.File => {
                if (std.mem.eql(u8, asset.path[0..7], "shaders")) {
                    continue; // skip shader folder which will be compiled by glslc before being moved
                }
                src_dir.dir.copyFile(asset.path, dst_parent_dir, asset.path, .{}) catch unreachable;
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
