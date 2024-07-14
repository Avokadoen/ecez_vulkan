const std = @import("std");

const tracy = @import("ztracy");
const glfw = @import("glfw");

const core = @import("core.zig");

const config_options = @import("config_options");

pub fn main() !void {
    tracy.SetThreadName("main thread");

    // create a gpa with default configuration
    var alloc = if (core.build_info.is_debug_build) std.heap.GeneralPurposeAllocator(.{}){} else std.heap.c_allocator;
    defer {
        if (core.build_info.is_debug_build) {
            if (alloc.deinit() == .leak) {
                std.debug.print("leak detected in gpa!", .{});
            }
        }
    }
    const allocator = if (core.build_info.is_debug_build) alloc.allocator() else alloc;

    // init glfw
    if (glfw.init(.{}) == false) {
        return error.GlfwFailedToInitialize;
    }
    defer glfw.terminate();

    if (glfw.vulkanSupported() == false) {
        @panic("device does not seem to support vulkan");
    }

    const primary_monitor = null; // glfw.Monitor.getPrimary();

    // Create our window
    const window = glfw.Window.create(640, 480, "ecez-vulkan", primary_monitor, null, .{
        .client_api = .no_api,
        .resizable = true,
    }) orelse {
        return error.GlfwCreateWindowFailed;
    };
    defer window.destroy();

    const asset_handler = try core.AssetHandler.init(allocator);
    defer asset_handler.deinit(allocator);

    switch (config_options.editor_or_game) {
        .editor => try @import("editor.zig").main(allocator, asset_handler, window),
        .game => try @import("game.zig").main(allocator, asset_handler, window),
    }
}
