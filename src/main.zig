const std = @import("std");

const glfw = @import("glfw");
const zm = @import("zmath");

const Editor = @import("Editor.zig");

const RenderContext = @import("RenderContext.zig");

pub fn main() !void {
    // create a gpa with default configuration
    var alloc = if (RenderContext.is_debug_build) std.heap.GeneralPurposeAllocator(.{}){} else std.heap.c_allocator;
    defer {
        if (RenderContext.is_debug_build) {
            if (alloc.deinit() == .leak) {
                std.debug.print("leak detected in gpa!", .{});
            }
        }
    }
    const allocator = if (RenderContext.is_debug_build) alloc.allocator() else alloc;

    // init glfw
    if (glfw.init(.{}) == false) {
        return error.GlfwFailedToInitialize;
    }
    defer glfw.terminate();

    if (glfw.vulkanSupported() == false) {
        @panic("device does not seem to support vulkan");
    }

    // Create our window
    const window = glfw.Window.create(640, 480, "ecez-vulkan", null, null, .{
        .client_api = .no_api,
        .resizable = true,
    }) orelse {
        return error.GlfwCreateWindowFailed;
    };
    defer window.destroy();

    var editor = try Editor.init(allocator, window, &[_]RenderContext.MeshInstancehInitializeContex{
        .{
            .cgltf_path = "models/ScifiHelmet/SciFiHelmet.gltf",
            .instance_count = 100,
        },
        .{
            .cgltf_path = "models/BoxTextured/BoxTextured.gltf",
            .instance_count = 100,
        },
    });
    defer editor.deinit();

    // handle if user resize window
    editor.handleFramebufferResize(window);

    // TODO: make a test scene while file format facilities are not in place
    // load some test stuff while we are missing a file format for scenes
    try editor.createNewVisbleObject("helmet", 0, Editor.FlushAllObjects.no, .{
        .rotation = Editor.Rotation{ .quat = zm.quatFromNormAxisAngle(zm.f32x4(0, 0, 1, 0), std.math.pi) },
        .position = Editor.Position{ .vec = zm.f32x4(-1, 0, 0, 0) },
        .scale = Editor.Scale{ .vec = zm.f32x4(1, 1, 1, 1) },
    });
    try editor.createNewVisbleObject("box", 1, Editor.FlushAllObjects.yes, .{
        .rotation = Editor.Rotation{ .quat = zm.quatFromNormAxisAngle(zm.f32x4(0, 1, 0, 0), std.math.pi * 0.5) },
        .position = Editor.Position{ .vec = zm.f32x4(1, 0, 0, 0) },
    });

    // register input callbacks for the editor
    editor.setEditorInput(window);

    var then = std.time.microTimestamp();
    // Wait for the user to close the window.
    while (!window.shouldClose()) {
        glfw.pollEvents();

        const now = std.time.microTimestamp();
        const delta_time = @max(@as(f32, @floatFromInt(now - then)) / std.time.us_per_s, 0.000001);
        then = now;

        try editor.newFrame(window, delta_time);
    }
}
