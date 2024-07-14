const std = @import("std");
const Allocator = std.mem.Allocator;

const ecez = @import("ecez");
const ezby = ecez.ezby;

const zgui = @import("zgui");
const glfw = @import("glfw");
const tracy = @import("ztracy");
const zm = @import("zmath");

const core = @import("../core.zig");

const render = @import("../render.zig");
const InstanceHandle = render.components.InstanceHandle;
const RenderContext = render.Context;
const MeshHandle = RenderContext.MeshHandle;
const MeshInstancehInitializeContex = RenderContext.MeshInstancehInitializeContex;

const game = @import("../game.zig");
const Position = game.components.Position;
const Rotation = game.components.Rotation;
const Scale = game.components.Scale;

const systems = game.systems.SceneGraphSystems(GameStorage);

pub const all_components = game.components.all ++ render.components.all;
pub const all_components_tuple = @import("../core.zig").component_reflect.componentTypeArrayToTuple(&all_components);

const UserPointer = extern struct {
    type: core.glfw_integration.UserPointerType = .game,
    next: ?*UserPointer,
    ptr: *Game,
};

const InputState = struct {
    previous_cursor_xpos: f64 = 0,
    previous_cursor_ypos: f64 = 0,
};

const GameStorage = ecez.CreateStorage(all_components_tuple);

// TODO: convert on_import to simple queries inline
const Scheduler = ecez.CreateScheduler(GameStorage, .{
    // event to apply all transformation and update render buffers as needed
    systems.TransformUpdateEvent,
});

/// Game context
const Game = @This();

allocator: Allocator,

storage: GameStorage,
scheduler: Scheduler,

render_context: RenderContext,
input_state: InputState,

user_pointer: UserPointer,
active_camera: ?ecez.Entity = null,

pub fn init(
    allocator: Allocator,
    window: glfw.Window,
    asset_handler: core.AssetHandler,
    mesh_instance_initalizers: []const MeshInstancehInitializeContex,
) !Game {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    var render_context = try RenderContext.init(
        allocator,
        window,
        asset_handler,
        mesh_instance_initalizers,
        .{ .update_rate = .always },
    );
    errdefer render_context.deinit(allocator);

    // initialize our ecs api
    var storage = try GameStorage.init(allocator);
    errdefer storage.deinit();

    const scheduler = try Scheduler.init(allocator, .{});

    // register input callbacks for the game
    setEditorInput(window);

    // TODO: imgui not present in release build
    // Color scheme
    const StyleCol = zgui.StyleCol;
    const style = zgui.getStyle();
    style.setColor(StyleCol.title_bg, [4]f32{ 0.1, 0.1, 0.1, 0.85 });
    style.setColor(StyleCol.title_bg_active, [4]f32{ 0.15, 0.15, 0.15, 0.9 });
    style.setColor(StyleCol.menu_bar_bg, [4]f32{ 0.1, 0.1, 0.1, 0.8 });
    style.setColor(StyleCol.header, [4]f32{ 0.1, 0.1, 0.1, 0.8 });
    style.setColor(StyleCol.check_mark, [4]f32{ 0, 1, 0, 1 });

    return Game{
        .allocator = allocator,
        .storage = storage,
        .scheduler = scheduler,
        .render_context = render_context,
        .input_state = InputState{},
        .user_pointer = undefined, // assigned by setCameraInput
    };
}

pub fn deinit(self: *Game) void {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    self.scheduler.waitIdle();

    self.render_context.deinit(self.allocator);
    self.storage.deinit();
    self.scheduler.deinit();
}

pub fn importGameSceneFromFile(self: *Game, file_name: []const u8) !void {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    var scene_file = try std.fs.cwd().openFile(file_name, .{});
    defer scene_file.close();

    // prealloc file bytes
    const file_metadata = try scene_file.metadata();
    const file_bytes = try self.allocator.alloc(u8, file_metadata.size());
    defer self.allocator.free(file_bytes);

    // read file bytes
    const read_bytes_count = try scene_file.read(file_bytes);
    std.debug.assert(read_bytes_count == file_bytes.len);

    try self.deserializeAndSyncState(file_bytes);
}

fn deserializeAndSyncState(self: *Game, bytes: []const u8) !void {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    // deserialize bytes into the ecs storage
    try ezby.deserialize(GameStorage, &self.storage, bytes);

    // restart the render context to make sure all required instances has and appropriate handle
    self.render_context.clearInstancesRetainingCapacity();

    const RenderInstanceHandleQuery = GameStorage.Query(struct {
        instance_handle: *InstanceHandle,
    }, .{});

    var instance_handle_iter = RenderInstanceHandleQuery.submit(&self.storage);

    // Synchronize the state of instance handles so that they have a valid handle according to the running render context
    while (instance_handle_iter.next()) |item| {
        item.instance_handle.* = try self.render_context.getNewInstance(item.instance_handle.mesh_handle);
    }
}

pub fn update(self: *Game, delta_time: f32) void {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    {
        const camera_zone = tracy.ZoneN(@src(), @src().fn_name ++ " camera control");
        defer camera_zone.End();
        // TODO: convert to system?
        if (self.validCameraEntity(self.active_camera)) {
            const active_camera = self.active_camera.?; // validCameraEntity only true when set

            // calculate the current camera orientation
            const orientation = orientation_calc_blk: {
                const camera_state = self.storage.getComponent(active_camera, game.components.Camera) catch unreachable;
                break :orientation_calc_blk camera_state.toQuat();
            };

            // fetch the camera position pointer and calculate the position delta
            const camera_position_ptr = self.storage.getComponent(active_camera, *game.components.Position) catch unreachable;
            camera_position_ptr.vec += calc_position_delta_blk: {
                const camera_velocity = self.storage.getComponent(active_camera, game.components.Velocity) catch unreachable;
                const camera_movespeed = self.storage.getComponent(active_camera, game.components.MoveSpeed) catch unreachable;
                const is_movement_vector_set = @reduce(.Min, camera_velocity.vec) != 0 or @reduce(.Max, camera_velocity.vec) != 0;
                if (is_movement_vector_set) {
                    const movement_dir = zm.normalize3(zm.rotate(zm.conjugate(orientation), zm.normalize3(camera_velocity.vec)));
                    const actionable_movement = movement_dir * camera_movespeed.vec;

                    const delta_time_vec = @as(zm.Vec, @splat(delta_time));

                    break :calc_position_delta_blk actionable_movement * delta_time_vec;
                }

                break :calc_position_delta_blk @splat(0);
            };

            // apply update render camera with game camera
            self.render_context.camera.view = RenderContext.Camera.calcView(orientation, camera_position_ptr.vec);
        }
    }
}

pub fn newFrame(self: *Game, window: glfw.Window, delta_time: f32) !void {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    // TODO: Move out of newFrame, into update function instead ...
    if (false == self.ui_state.camera_control_active) {
        // If we are not controlling the camera, then we should update cursor if needed
        // NOTE: getting cursor must be done before calling zgui.newFrame
        window.setInputModeCursor(.normal);
        switch (zgui.getMouseCursor()) {
            .none => window.setInputModeCursor(.hidden),
            .arrow => window.setCursor(self.arrow),
            .text_input => window.setCursor(self.ibeam),
            .resize_all => window.setCursor(self.crosshair),
            .resize_ns => window.setCursor(self.resize_ns),
            .resize_ew => window.setCursor(self.resize_ew),
            .resize_nesw => window.setCursor(self.resize_nesw),
            .resize_nwse => window.setCursor(self.resize_nwse),
            .hand => window.setCursor(self.pointing_hand),
            .not_allowed => window.setCursor(self.not_allowed),
            .count => window.setCursor(self.ibeam),
        }
    }

    const frame_size = window.getFramebufferSize();
    zgui.io.setDisplaySize(@as(f32, @floatFromInt(frame_size.width)), @as(f32, @floatFromInt(frame_size.height)));
    zgui.io.setDisplayFramebufferScale(1.0, 1.0);

    zgui.newFrame();
    { // imgui render block
        defer zgui.render();

        zgui.io.setDeltaTime(delta_time);

        var b = true;
        _ = zgui.showDemoWindow(&b);
    }

    try self.render_context.drawFrame(window);
    try self.forceFlush();
}

pub fn createTestScene(self: *Game) !void {
    // load some test stuff while we are missing a file format for scenes
    const box_mesh_handle = self.getMeshHandleFromName("BoxTextured").?;
    try self.createNewVisbleObject("box", box_mesh_handle, .{
        .rotation = game.components.Rotation{ .quat = zm.quatFromNormAxisAngle(zm.f32x4(0, 0, 1, 0), std.math.pi) },
        .position = game.components.Position{ .vec = zm.f32x4(-1, 0, 0, 0) },
        .scale = game.components.Scale{ .vec = zm.f32x4(1, 1, 1, 1) },
    });

    const helmet_mesh_handle = self.getMeshHandleFromName("SciFiHelmet").?;
    try self.createNewVisbleObject("helmet", helmet_mesh_handle, .{
        .rotation = game.components.Rotation{ .quat = zm.quatFromNormAxisAngle(zm.f32x4(0, 1, 0, 0), std.math.pi * 0.5) },
        .position = game.components.Position{ .vec = zm.f32x4(1, 0, 0, 0) },
    });

    // camera init
    {
        const CameraArch = struct {
            b: game.components.Position = .{ .vec = zm.f32x4(0, 0, -4, 0) },
            c: game.components.MoveSpeed = .{ .vec = @splat(20) },
            d: game.components.Velocity = .{ .vec = @splat(0) },
            e: game.components.Camera = .{ .turn_rate = 0.0005 },
        };

        const active_camera = try self.newSceneEntity("default_camera");
        try self.storage.setComponents(active_camera, CameraArch{});
        self.active_camera = active_camera;
    }
}

pub fn validCameraEntity(self: *Game, entity: ?ecez.Entity) bool {
    const camera_entity = entity orelse return false;

    const expected_camera_components = [_]type{
        game.components.Position,
        game.components.MoveSpeed,
        game.components.Velocity,
        game.components.Camera,
    };

    inline for (expected_camera_components) |Component| {
        if (false == self.storage.hasComponent(camera_entity, Component)) {
            return false;
        }
    }

    return true;
}

pub fn handleFramebufferResize(self: *Game, window: glfw.Window) void {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    self.render_context.handleFramebufferResize(window, false);

    self.user_pointer = UserPointer{
        .ptr = self,
        .next = @ptrCast(&self.render_context.user_pointer),
    };

    window.setUserPointer(&self.user_pointer);
}

/// register input so only game handles glfw input
pub fn setEditorInput(window: glfw.Window) void {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    const EditorCallbacks = struct {
        pub fn key(_window: glfw.Window, input_key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) void {
            _ = scancode;

            // apply modifiers
            zgui.io.addKeyEvent(zgui.Key.mod_shift, mods.shift);
            zgui.io.addKeyEvent(zgui.Key.mod_ctrl, mods.control);
            zgui.io.addKeyEvent(zgui.Key.mod_alt, mods.alt);
            zgui.io.addKeyEvent(zgui.Key.mod_super, mods.super);
            // zgui.addKeyEvent(zgui.Key.mod_caps_lock, mod.caps_lock);
            // zgui.addKeyEvent(zgui.Key.mod_num_lock, mod.num_lock);

            zgui.io.addKeyEvent(core.zgui_integration.mapGlfwKeyToImgui(input_key), action == .press);

            const user_pointer = core.glfw_integration.findUserPointer(
                UserPointer,
                _window,
            ) orelse return;

            const undo_action = input_key == .z and (action == .press) and mods.control;
            if (undo_action) {
                user_pointer.ptr.popUndoStack();
            }
        }

        pub fn char(_window: glfw.Window, codepoint: u21) void {
            _ = _window;

            var buffer: [8]u8 = undefined;
            const len = std.unicode.utf8Encode(codepoint, buffer[0..]) catch return;
            const cstr = buffer[0 .. len + 1];
            cstr[len] = 0; // null terminator
            zgui.io.addInputCharactersUTF8(@as([*:0]const u8, @ptrCast(cstr.ptr)));
        }

        pub fn mouseButton(_window: glfw.Window, button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) void {
            _ = _window;

            if (switch (button) {
                .left => zgui.MouseButton.left,
                .right => zgui.MouseButton.right,
                .middle => zgui.MouseButton.middle,
                .four, .five, .six, .seven, .eight => null,
            }) |zgui_button| {
                // apply modifiers
                zgui.io.addKeyEvent(zgui.Key.mod_shift, mods.shift);
                zgui.io.addKeyEvent(zgui.Key.mod_ctrl, mods.control);
                zgui.io.addKeyEvent(zgui.Key.mod_alt, mods.alt);
                zgui.io.addKeyEvent(zgui.Key.mod_super, mods.super);

                zgui.io.addMouseButtonEvent(zgui_button, action == .press);
            }
        }

        pub fn cursorPos(_window: glfw.Window, xpos: f64, ypos: f64) void {
            const user_pointer = core.glfw_integration.findUserPointer(
                UserPointer,
                _window,
            ) orelse return;

            defer {
                user_pointer.ptr.input_state.previous_cursor_xpos = xpos;
                user_pointer.ptr.input_state.previous_cursor_ypos = ypos;
            }

            zgui.io.addMousePositionEvent(@as(f32, @floatCast(xpos)), @as(f32, @floatCast(ypos)));
        }

        pub fn scroll(_window: glfw.Window, xoffset: f64, yoffset: f64) void {
            _ = _window;

            zgui.io.addMouseWheelEvent(@as(f32, @floatCast(xoffset)), @as(f32, @floatCast(yoffset)));
        }
    };

    // enable normal system cursor behaviour
    window.setInputModeCursor(.normal);

    _ = window.setKeyCallback(EditorCallbacks.key);
    _ = window.setCharCallback(EditorCallbacks.char);
    _ = window.setMouseButtonCallback(EditorCallbacks.mouseButton);
    _ = window.setCursorPosCallback(EditorCallbacks.cursorPos);
    _ = window.setScrollCallback(EditorCallbacks.scroll);
}

/// register input so camera handles glfw input
pub fn setCameraInput(window: glfw.Window) void {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    const CameraCallbacks = struct {
        pub fn key(_window: glfw.Window, input_key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) void {
            _ = mods;
            _ = scancode;

            const user_pointer = core.glfw_integration.findUserPointer(
                UserPointer,
                _window,
            ) orelse return;

            const game_ptr = user_pointer.ptr;

            const axist_value: f32 = switch (action) {
                .press => 1,
                .release => -1,
                .repeat => return,
            };

            if (game_ptr.validCameraEntity(game_ptr.active_camera)) {
                const camera_entity = game_ptr.active_camera.?;
                const camera_velocity_ptr = game_ptr.storage.getComponent(camera_entity, *game.components.Velocity) catch unreachable;

                switch (input_key) {
                    .w => camera_velocity_ptr.vec[2] += axist_value,
                    .a => camera_velocity_ptr.vec[0] -= axist_value,
                    .s => camera_velocity_ptr.vec[2] -= axist_value,
                    .d => camera_velocity_ptr.vec[0] += axist_value,
                    .space => camera_velocity_ptr.vec[1] += axist_value,
                    .left_control => camera_velocity_ptr.vec[1] -= axist_value,
                    // exit camera mode
                    .escape => {
                        camera_velocity_ptr.vec = @splat(0);
                        game_ptr.ui_state.camera_control_active = false;
                        setEditorInput(_window);
                    },
                    else => {},
                }
            }
        }

        pub fn char(_window: glfw.Window, codepoint: u21) void {
            _ = codepoint;
            _ = _window;
        }

        pub fn mouseButton(_window: glfw.Window, button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) void {
            _ = mods;
            _ = action;
            _ = button;
            _ = _window;
        }

        pub fn cursorPos(_window: glfw.Window, xpos: f64, ypos: f64) void {
            const user_pointer = core.glfw_integration.findUserPointer(
                UserPointer,
                _window,
            ) orelse return;

            const game_ptr = user_pointer.ptr;

            defer {
                game_ptr.input_state.previous_cursor_xpos = xpos;
                game_ptr.input_state.previous_cursor_ypos = ypos;
            }

            const x_delta = xpos - game_ptr.input_state.previous_cursor_xpos;
            const y_delta = ypos - game_ptr.input_state.previous_cursor_ypos;

            camera_update_blk: {
                if (game_ptr.active_camera) |camera_entity| {
                    const camera_ptr = game_ptr.storage.getComponent(camera_entity, *game.components.Camera) catch {
                        break :camera_update_blk;
                    };
                    camera_ptr.yaw -= x_delta * camera_ptr.turn_rate;
                    camera_ptr.pitch -= y_delta * camera_ptr.turn_rate;
                }
            }
        }

        pub fn scroll(_window: glfw.Window, xoffset: f64, yoffset: f64) void {
            _ = yoffset;
            _ = xoffset;
            _ = _window;
        }
    };

    // disable cursor, lock it to center
    window.setInputModeCursor(.disabled);

    _ = window.setKeyCallback(CameraCallbacks.key);
    _ = window.setCharCallback(CameraCallbacks.char);
    _ = window.setMouseButtonCallback(CameraCallbacks.mouseButton);
    _ = window.setCursorPosCallback(CameraCallbacks.cursorPos);
    _ = window.setScrollCallback(CameraCallbacks.scroll);
}

pub fn getMeshHandleFromName(self: *Game, name: []const u8) ?MeshHandle {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    return self.render_context.getMeshHandleFromName(name);
}

/// This function retrieves a instance handle from the renderer and assigns it to the argument entity
pub fn assignEntityMeshInstance(self: *Game, entity: ecez.Entity, mesh_handle: MeshHandle) !void {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    if (self.storage.hasComponent(entity, InstanceHandle)) {
        return error.EntityAlreadyHasInstance;
    }

    const new_instance = self.render_context.getNewInstance(mesh_handle) catch |err| {
        // if this fails we will end in an inconsistent state!
        std.debug.panic("attemped to get new instance {d} failed with error {any}", .{ mesh_handle, err });
    };

    try self.storage.setComponent(entity, new_instance);
}

pub fn signalRenderUpdate(self: *Game) void {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    self.render_context.signalUpdate();
}

pub const VisibleObjectConfig = struct {
    position: ?Game.Position = null,
    rotation: ?Game.Rotation = null,
    scale: ?Game.Scale = null,
};
/// Create a new entity that should also have a renderable mesh instance tied to the entity.
/// The function will also send this to the GPU in the event of flush_all_objects = .yes
pub fn createNewVisbleObject(
    self: *Game,
    object_name: []const u8,
    mesh_handle: RenderContext.MeshHandle,
    config: VisibleObjectConfig,
) !void {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    const new_entity = try self.newSceneEntity(object_name);
    try self.assignEntityMeshInstance(new_entity, mesh_handle);

    if (config.position) |position| {
        try self.storage.setComponent(new_entity, position);
    }
    if (config.rotation) |rotation| {
        try self.storage.setComponent(new_entity, rotation);
    }
    if (config.scale) |scale| {
        try self.storage.setComponent(new_entity, scale);
    }

    try self.storage.setComponent(new_entity, game.scene_graph.Level{ .value = .L0 });
    try self.storage.setComponent(new_entity, game.scene_graph.L0{});
}

pub fn forceFlush(self: *Game) !void {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    self.scheduler.dispatchEvent(
        &self.storage,
        .transform_update,
        systems.EventArgument{ .read_storage = self.storage, .render_context = &self.render_context },
    );
    self.scheduler.waitEvent(.transform_update);

    // Currently the renderer is configured to always flush
    // self.signalRenderUpdate();
}
