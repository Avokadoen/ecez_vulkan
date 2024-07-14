const std = @import("std");
const glfw = @import("glfw");
const tracy = @import("ztracy");

const core = @import("../core.zig");

const render = @import("../render.zig");

pub fn main(allocator: std.mem.Allocator, asset_handler: core.AssetHandler, window: glfw.Window) !void {
    _ = allocator;
    _ = asset_handler;
    _ = window;

    return error.Unimplemented;
}
