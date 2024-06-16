const std = @import("std");

const tracy = @import("ztracy");
const glfw = @import("glfw");
const zm = @import("zmath");

const Editor = @import("editor.zig").Editor;

const RenderContext = @import("render.zig").Context;

const core = @import("core.zig");

const game = @import("game.zig");

const config_options = @import("config_options");

pub fn main() !void {
    tracy.SetThreadName("main thread");

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
        .editor => try editorMain(allocator, asset_handler, window),
        .game => try gameMain(allocator, asset_handler, window),
    }
}

fn editorMain(allocator: std.mem.Allocator, asset_handler: core.AssetHandler, window: glfw.Window) !void {
    var editor: Editor = editor_init_blk: {
        var mesh_initializers = std.ArrayList(RenderContext.MeshInstancehInitializeContex).init(allocator);
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
                    try mesh_initializers.append(RenderContext.MeshInstancehInitializeContex{
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

    // TODO: make a test scene while file format facilities are not in place
    // load some test stuff while we are missing a file format for scenes
    const box_mesh_handle = editor.getMeshHandleFromName("BoxTextured").?;
    try editor.createNewVisbleObject("box", box_mesh_handle, Editor.FlushAllObjects.no, .{
        .rotation = game.components.Rotation{ .quat = zm.quatFromNormAxisAngle(zm.f32x4(0, 0, 1, 0), std.math.pi) },
        .position = game.components.Position{ .vec = zm.f32x4(-1, 0, 0, 0) },
        .scale = game.components.Scale{ .vec = zm.f32x4(1, 1, 1, 1) },
    });

    const helmet_mesh_handle = editor.getMeshHandleFromName("SciFiHelmet").?;
    try editor.createNewVisbleObject("helmet", helmet_mesh_handle, Editor.FlushAllObjects.yes, .{
        .rotation = game.components.Rotation{ .quat = zm.quatFromNormAxisAngle(zm.f32x4(0, 1, 0, 0), std.math.pi * 0.5) },
        .position = game.components.Position{ .vec = zm.f32x4(1, 0, 0, 0) },
    });

    var then = std.time.microTimestamp();
    // Wait for the user to close the window.
    while (!window.shouldClose()) {
        tracy.FrameMark();

        glfw.pollEvents();

        const now = std.time.microTimestamp();
        const delta_time = @max(@as(f32, @floatFromInt(now - then)) / std.time.us_per_s, 0.000001);
        then = now;

        try editor.newFrame(window, delta_time);
    }
}

fn gameMain(allocator: std.mem.Allocator, asset_handler: core.AssetHandler, window: glfw.Window) !void {
    _ = allocator;
    _ = asset_handler;
    _ = window;

    return error.Unimplemented;
}
