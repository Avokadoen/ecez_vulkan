const std = @import("std");
// const ecez = @import("ecez");
const glfw = @import("glfw");

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

    var context = try RenderContext.init(allocator, window);
    defer context.deinit(allocator);

    context.handleFramebufferResize(window);

    // Wait for the user to close the window.
    while (!window.shouldClose()) {
        try glfw.pollEvents();

        try context.drawFrame(window);
    }
}
