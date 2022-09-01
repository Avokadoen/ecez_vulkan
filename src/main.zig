const std = @import("std");
const ecez = @import("ecez");
const glfw = @import("glfw");

const RenderContext = @import("RenderContext.zig");

const PositionComp = struct {
    xyz: [3]f32,
};

const VelocityComp = struct {
    xyz: [3]f32,
};

const MovableArch = struct {
    pos: PositionComp,
    vel: VelocityComp,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit()) {
            std.log.err("leak detected", .{});
        }
    }
    const allocator = gpa.allocator();

    var world = try ecez.WorldBuilder().WithArchetypes(.{MovableArch}).init(allocator, .{});
    defer world.deinit();

    // init glfw
    try glfw.init(.{});
    defer glfw.terminate();

    // Create our window
    const window = try glfw.Window.create(640, 480, "ecez-vulkan", null, null, .{
        .client_api = .no_api,
        .resizable = false,
    });
    defer window.destroy();

    const context = try RenderContext.init(allocator);
    defer context.deinit();

    // Wait for the user to close the window.
    while (!window.shouldClose()) {
        try glfw.pollEvents();

        try world.dispatch();
    }
}
