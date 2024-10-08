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

const physics = @import("../physics.zig");

const systems = game.systems.SceneGraphSystems(GameStorage);

pub const all_components = game.components.all ++ physics.components.all ++ render.components.all;
pub const all_components_tuple = @import("../core.zig").component_reflect.componentTypeArrayToTuple(&all_components);

pub const UserPointer = extern struct {
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

player_entity: ecez.Entity,

pub fn init(
    allocator: Allocator,
    window: *glfw.Window,
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
    setCameraInput(window);

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
        .player_entity = undefined, // assigned by importGameSceneFromFile
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

    {
        const RenderInstanceHandleQuery = GameStorage.Query(struct {
            instance_handle: *InstanceHandle,
        }, .{});

        // Synchronize the state of instance handles so that they have a valid handle according to the running render context
        var instance_handle_iter = RenderInstanceHandleQuery.submit(&self.storage);
        while (instance_handle_iter.next()) |item| {
            item.instance_handle.* = try self.render_context.getNewInstance(item.instance_handle.mesh_handle);
        }
    }

    {
        const PlayerQuery = GameStorage.Query(struct {
            entity: ecez.Entity,
            player_tag: game.components.PlayerTag,
        }, .{});

        var iter_count: u32 = 0;
        var player_iter = PlayerQuery.submit(&self.storage);
        while (player_iter.next()) |item| {
            // Expect only one player tag
            std.debug.assert(0 == iter_count);

            self.player_entity = item.entity;
            iter_count += 1;
        }
    }
}

pub fn update(self: *Game, delta_time: f32) void {
    std.debug.assert(self.validPlayerEntity());

    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    {
        const player_zone = tracy.ZoneN(@src(), @src().fn_name ++ " player control");
        defer player_zone.End();

        // TODO: convert to system?
        // calculate the current camera orientation
        const orientation = orientation_calc_blk: {
            const camera_state = self.storage.getComponent(self.player_entity, game.components.Camera) catch unreachable;
            break :orientation_calc_blk camera_state.toQuat();
        };

        // fetch the camera position pointer and calculate the position delta
        const camera_position_ptr = self.storage.getComponent(self.player_entity, *game.components.Position) catch unreachable;
        camera_position_ptr.vec += calc_position_delta_blk: {
            const camera_velocity = self.storage.getComponent(self.player_entity, game.components.Velocity) catch unreachable;
            const camera_movespeed = self.storage.getComponent(self.player_entity, game.components.MoveSpeed) catch unreachable;
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

pub fn newFrame(self: *Game, window: *glfw.Window, delta_time: f32) !void {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    // TODO: needed for dev ui
    // // TODO: Move out of newFrame, into update function instead ...
    // if (false == self.ui_state.camera_control_active) {
    //     // If we are not controlling the camera, then we should update cursor if needed
    //     // NOTE: getting cursor must be done before calling zgui.newFrame
    //     window.setInputMode(.cursor, .normal);
    //     switch (zgui.getMouseCursor()) {
    //         .none => window.setInputMode(.cursor, .hidden),
    //         .arrow => window.setCursor(self.arrow),
    //         .text_input => window.setCursor(self.ibeam),
    //         .resize_all => window.setCursor(self.crosshair),
    //         .resize_ns => window.setCursor(self.resize_ns),
    //         .resize_ew => window.setCursor(self.resize_ew),
    //         .resize_nesw => window.setCursor(self.resize_nesw),
    //         .resize_nwse => window.setCursor(self.resize_nwse),
    //         .hand => window.setCursor(self.pointing_hand),
    //         .not_allowed => window.setCursor(self.not_allowed),
    //         .count => window.setCursor(self.ibeam),
    //     }
    // }

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

fn validPlayerEntity(self: *Game) bool {
    const expected_camera_components = [_]type{
        game.components.Position,
        game.components.MoveSpeed,
        game.components.Velocity,
        game.components.Camera,
    };

    inline for (expected_camera_components) |Component| {
        if (false == self.storage.hasComponent(self.player_entity, Component)) {
            return false;
        }
    }

    return true;
}

/// register input so camera handles glfw input
pub fn setCameraInput(window: *glfw.Window) void {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    const CameraCallbacks = struct {
        pub fn key(_window: *glfw.Window, input_key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) void {
            _ = mods;
            _ = scancode;

            const user_pointer = core.glfw_integration.findUserPointer(
                UserPointer,
                _window,
            ) orelse return;

            const game_ptr = user_pointer.ptr;
            std.debug.assert(game_ptr.validPlayerEntity());

            const axist_value: f32 = switch (action) {
                .press => 1,
                .release => -1,
                .repeat => return,
            };

            const camera_velocity_ptr = game_ptr.storage.getComponent(game_ptr.player_entity, *game.components.Velocity) catch unreachable;

            switch (input_key) {
                .w => camera_velocity_ptr.vec[2] += axist_value,
                .a => camera_velocity_ptr.vec[0] -= axist_value,
                .s => camera_velocity_ptr.vec[2] -= axist_value,
                .d => camera_velocity_ptr.vec[0] += axist_value,
                .space => camera_velocity_ptr.vec[1] += axist_value,
                .left_control => camera_velocity_ptr.vec[1] -= axist_value,
                .escape => {
                    // TODO: shutdown for now
                },
                else => {},
            }
        }

        pub fn char(_window: *glfw.Window, codepoint: u21) void {
            _ = codepoint;
            _ = _window;
        }

        pub fn mouseButton(_window: *glfw.Window, button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) void {
            _ = mods;
            _ = action;
            _ = button;
            _ = _window;
        }

        pub fn cursorPos(_window: *glfw.Window, xpos: f64, ypos: f64) void {
            const user_pointer = core.glfw_integration.findUserPointer(
                UserPointer,
                _window,
            ) orelse return;

            const game_ptr = user_pointer.ptr;
            std.debug.assert(game_ptr.validPlayerEntity());

            defer {
                game_ptr.input_state.previous_cursor_xpos = xpos;
                game_ptr.input_state.previous_cursor_ypos = ypos;
            }

            const x_delta = xpos - game_ptr.input_state.previous_cursor_xpos;
            const y_delta = ypos - game_ptr.input_state.previous_cursor_ypos;

            const camera_ptr = game_ptr.storage.getComponent(game_ptr.player_entity, *game.components.Camera) catch unreachable;
            camera_ptr.yaw -= x_delta * camera_ptr.turn_rate;
            camera_ptr.pitch -= y_delta * camera_ptr.turn_rate;
        }

        pub fn scroll(_window: *glfw.Window, xoffset: f64, yoffset: f64) void {
            _ = yoffset;
            _ = xoffset;
            _ = _window;
        }
    };

    // disable cursor, lock it to center
    window.setInputMode(.cursor, .disabled);

    _ = window.setKeyCallback(CameraCallbacks.key);
    _ = window.setCharCallback(CameraCallbacks.char);
    _ = window.setMouseButtonCallback(CameraCallbacks.mouseButton);
    _ = window.setCursorPosCallback(CameraCallbacks.cursorPos);
    _ = window.setScrollCallback(CameraCallbacks.scroll);
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
    // self.render_context.signalUpdate();
}
