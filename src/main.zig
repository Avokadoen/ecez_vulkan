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

    // var world = try ecez.WorldBuilder().WithComponents(.{ PositionComp, VelocityComp }).init(allocator, .{});
    // defer world.deinit();

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
    editor.render_context.handleFramebufferResize(window);

    // TODO: make a test scene while file format facilities are not in place
    {
        const helmet_rotation = zm.rotationZ(std.math.pi);
        const helmet_mesh_handle = editor.getNthMeshHandle(0);

        const helmet_instance1 = editor.getNewInstance(helmet_mesh_handle) catch unreachable;
        editor.setInstanceTransform(helmet_instance1, zm.mul(helmet_rotation, zm.translation(-1, 0, 0)));

        var test_transform = zm.mul(helmet_rotation, zm.translation(0, 0, 0));
        const helmet_instance2 = editor.getNewInstance(helmet_mesh_handle) catch unreachable;
        editor.setInstanceTransform(helmet_instance2, test_transform);

        const box_mesh_handle = editor.getNthMeshHandle(1);
        var box_instances: [100]RenderContext.InstanceHandle = undefined;
        for (box_instances) |*box| {
            box.* = editor.getNewInstance(box_mesh_handle) catch unreachable;
            editor.setInstanceTransform(box.*, zm.translation(1, 0, 0));
        }
    }

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

        // TODO: proper input handling? (out of project scope)
        if (window.getKey(.escape) == .press) {
            window.setShouldClose(true);
        }
    }
}
