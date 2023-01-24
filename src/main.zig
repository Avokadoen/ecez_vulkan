const std = @import("std");
// const ecez = @import("ecez");
const glfw = @import("glfw");
const zm = @import("zmath");

const Editor = @import("Editor.zig");

const RenderContext = @import("RenderContext.zig");

const PositionComp = struct {
    xyz: [3]f32,
};

const VelocityComp = struct {
    xyz: [3]f32,
};

pub fn main() !void {
    // create a gpa with default configuration
    var alloc = if (RenderContext.is_debug_build) std.heap.GeneralPurposeAllocator(.{}){} else std.heap.c_allocator;
    defer {
        if (RenderContext.is_debug_build) {
            const leak = alloc.deinit();
            if (leak) {
                std.debug.print("leak detected in gpa!", .{});
            }
        }
    }
    const allocator = if (RenderContext.is_debug_build) alloc.allocator() else alloc;

    // init glfw
    try glfw.init(.{});
    defer glfw.terminate();

    // Create our window
    const window = try glfw.Window.create(640, 480, "ecez-vulkan", null, null, .{
        .client_api = .no_api,
        .resizable = true,
    });
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
    {
        const helmet = try editor.newSceneEntity("helmet");
        const helmet_mesh_handle = editor.getNthMeshHandle(0);
        try editor.assignEntityMeshInstance(helmet, helmet_mesh_handle);

        try editor.ecs.setComponent(helmet, Editor.Rotation{ .quat = zm.quatFromNormAxisAngle(zm.f32x4(0, 0, 1, 0), std.math.pi) });
        try editor.ecs.setComponent(helmet, Editor.Position{ .vec = zm.f32x4(-1, 0, 0, 0) });
        try editor.ecs.setComponent(helmet, Editor.Transform{ .mat = undefined });
    }
    {
        const box = try editor.newSceneEntity("box");
        const box_mesh_handle = editor.getNthMeshHandle(1);
        try editor.assignEntityMeshInstance(box, box_mesh_handle);

        try editor.ecs.setComponent(box, Editor.Rotation{ .quat = zm.quatFromNormAxisAngle(zm.f32x4(0, 1, 0, 0), std.math.pi * 0.5) });
        try editor.ecs.setComponent(box, Editor.Position{ .vec = zm.f32x4(1, 0, 0, 0) });
        try editor.ecs.setComponent(box, Editor.Transform{ .mat = undefined });
    }

    // make sure editor updates renderer after we have set some render state programatically (helmet and box)
    try editor.ecs.triggerEvent(.transform_update, .{});
    editor.ecs.waitEvent(.transform_update);
    editor.signalRenderUpdate();

    // register input callbacks for the editor
    editor.setEditorInput(window);

    var then = std.time.microTimestamp();
    // Wait for the user to close the window.
    while (!window.shouldClose()) {
        try glfw.pollEvents();

        const now = std.time.microTimestamp();
        const delta_time = @max(@intToFloat(f32, now - then) / std.time.us_per_s, 0.000001);
        then = now;

        try editor.newFrame(window, delta_time);
    }
}
