const std = @import("std");
const glfw = @import("glfw");
const tracy = @import("ztracy");

const core = @import("../core.zig");

const render = @import("../render.zig");

const Editor = @import("Editor.zig");

pub fn main(allocator: std.mem.Allocator, asset_handler: core.AssetHandler, window: glfw.Window) !void {
    var editor: Editor = editor_init_blk: {
        var mesh_initializers = std.ArrayList(render.Context.MeshInstancehInitializeContex).init(allocator);
        defer {
            for (mesh_initializers.items) |mesh_initializer| {
                allocator.free(mesh_initializer.cgltf_path);
            }
            mesh_initializers.deinit();
        }

        {
            const model_path = try asset_handler.getPath(allocator, "models");
            defer allocator.free(model_path);

            var model_dir = try std.fs.openDirAbsolute(model_path, .{ .iterate = true });
            defer model_dir.close();

            var model_walker = try model_dir.walk(allocator);
            defer model_walker.deinit();

            while ((try model_walker.next())) |entry| {
                if (std.mem.endsWith(u8, entry.basename, ".gltf")) {
                    const path = try std.fs.path.join(allocator, &[_][]const u8{ "models", entry.path });
                    try mesh_initializers.append(render.Context.MeshInstancehInitializeContex{
                        .cgltf_path = path,
                        .instance_count = 10_000,
                    });
                }
            }
        }

        break :editor_init_blk try Editor.init(
            allocator,
            window,
            asset_handler,
            mesh_initializers.items,
        );
    };
    defer editor.deinit();

    // handle if user resize window
    editor.handleFramebufferResize(window);

    // create default test scene
    try editor.createTestScene();

    var then = std.time.microTimestamp();
    // Wait for the user to close the window.
    while (!window.shouldClose()) {
        tracy.FrameMark();

        glfw.pollEvents();

        const now = std.time.microTimestamp();
        const delta_time = @max(@as(f32, @floatFromInt(now - then)) / std.time.us_per_s, 0.000001);
        then = now;

        editor.update(delta_time);
        try editor.newFrame(window, delta_time);
    }
}
