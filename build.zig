const std = @import("std");
const ecez = @import("deps/ecez/build.zig");
const glfw = @import("deps/mach-glfw/build.zig");

const vkgen = @import("deps/vulkan-zig/generator/index.zig");

pub fn build(b: *std.build.Builder) void {
    // we force stage 1 until certain issues have been resolved
    // see issue: https://github.com/ziglang/zig/issues/12521
    b.use_stage1 = true;

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("ecez-vulkan", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);

    // let user enable/disable tracy
    const ztracy_enable = b.option(bool, "enable-tracy", "Enable Tracy profiler") orelse false;
    // link ecez and ztracy
    ecez.link(b, exe, ztracy_enable);

    // link glfw
    exe.addPackage(glfw.pkg);
    glfw.link(b, exe, .{});

    // Create a step that generates vk.zig (stored in zig-cache) from the provided vulkan registry.
    const gen = vkgen.VkGenerateStep.init(b, thisDir() ++ "/deps/vk.xml", "vk.zig");
    // Add the generated file as package to the final executable
    exe.addPackage(gen.package);

    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest("src/main.zig");
    exe_tests.setTarget(target);
    exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}

inline fn thisDir() []const u8 {
    return comptime std.fs.path.dirname(@src().file) orelse ".";
}
