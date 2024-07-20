const std = @import("std");
const Allocator = std.mem.Allocator;

const ecez = @import("ecez");
const ezby = ecez.ezby;

const zgui = @import("zgui");
const glfw = @import("glfw");
const tracy = @import("ztracy");
const zm = @import("zmath");

const core = @import("../core.zig");
const marker = core.zgui_integration.marker;

const config_options = @import("config_options");

const EditorIcons = @import("EditorIcons.zig");
const Icons = EditorIcons.Icon;

const GlfwCursors = @import("GlfwCursors.zig");

const undo_redo_stack = @import("undo_redo_stack.zig");
const UndoRedoStack = undo_redo_stack.CreateType(&all_components);

const render = @import("../render.zig");
const InstanceHandle = render.components.InstanceHandle;
const RenderContext = render.Context;
const MeshHandle = RenderContext.MeshHandle;
const MeshInstancehInitializeContex = RenderContext.MeshInstancehInitializeContex;

const editor_components = @import("components.zig");
const EntityMetadata = editor_components.EntityMetadata;

const game = @import("../game.zig");
const Position = game.components.Position;
const Rotation = game.components.Rotation;
const Scale = game.components.Scale;
const SceneGraph = game.scene_graph.SceneGraphSystems(EditorStorage);

const component_reflect = @import("component_reflect.zig");
const all_components = component_reflect.all_components;
const biggest_component_size = component_reflect.biggest_component_size;

pub const UserPointer = extern struct {
    type: core.glfw_integration.UserPointerType = .editor,
    next: ?*UserPointer,
    ptr: *Editor,
};

const UiState = struct {
    const ObjectList = struct {
        renaming_buffer: [127:0]u8,
        first_rename_draw: bool,
        renaming_entity: bool,
    };

    const ObjectInspector = struct {
        name_buffer: [127:0]u8,
        selected_component_index: usize,
    };

    const AddComponentModal = struct {
        selected_component_index: usize = all_components.len,
        component_bytes: [biggest_component_size * biggest_component_size]u8 = undefined,
        is_active: bool = false,
    };

    // common state
    selected_entity: ?ecez.Entity,

    export_editor_file_modal_popen: bool,
    import_editor_file_modal_popen: bool,
    export_game_file_modal_popen: bool,
    export_import_file_name: [127:0]u8,

    object_list_active: bool = true,
    object_list: ObjectList,

    object_inspector_active: bool = true,
    object_inspector: ObjectInspector,

    add_component_modal: AddComponentModal,

    camera_control_active: bool = false,

    pub fn setExportImportFileName(ui: *UiState, file_name: []const u8) void {
        @memcpy(ui.export_import_file_name[0..file_name.len], file_name);
        ui.export_import_file_name[file_name.len] = 0;
    }
};

const InputState = struct {
    previous_cursor_xpos: f64 = 0,
    previous_cursor_ypos: f64 = 0,
};

const EditorStorage = ecez.CreateStorage(component_reflect.all_components_tuple);
const GameSystems = game.systems.SceneGraphSystems(EditorStorage);

// TODO: convert on_import to simple queries inline
const Scheduler = ecez.CreateScheduler(EditorStorage, .{
    // event to apply all transformation and update render buffers as needed
    GameSystems.TransformUpdateEvent,
});

// TODO: editor should not be part of renderer

/// Editor for making scenes
const Editor = @This();

allocator: Allocator,

cursors: GlfwCursors,

storage: EditorStorage,
scheduler: Scheduler,

render_context: RenderContext,

active_camera: ?ecez.Entity = null,
ui_state: UiState,
input_state: InputState = InputState{},
icons: EditorIcons,

user_pointer: UserPointer = undefined, // assigned by setCameraInput

undo_stack: UndoRedoStack,

pub fn init(
    allocator: Allocator,
    window: glfw.Window,
    asset_handler: core.AssetHandler,
    mesh_instance_initalizers: []const MeshInstancehInitializeContex,
) !Editor {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    // initialize our ecs api
    var storage = try EditorStorage.init(allocator);
    errdefer storage.deinit();

    const scheduler = try Scheduler.init(allocator, .{});

    var render_context = try RenderContext.init(
        allocator,
        window,
        asset_handler,
        mesh_instance_initalizers,
        .{ .update_rate = .always },
    );
    errdefer render_context.deinit(allocator);

    const ui_state = ui_state_init_blk: {
        var ui = UiState{
            .selected_entity = null,
            .object_list = .{
                .renaming_buffer = undefined,
                .first_rename_draw = false,
                .renaming_entity = false,
            },
            .object_inspector = .{
                .name_buffer = undefined,
                .selected_component_index = all_components.len,
            },
            .export_editor_file_modal_popen = false,
            .import_editor_file_modal_popen = false,
            .export_game_file_modal_popen = false,
            .export_import_file_name = undefined,
            .add_component_modal = .{},
        };

        ui.setExportImportFileName("test.ezby");

        break :ui_state_init_blk ui;
    };

    // Color scheme
    const StyleCol = zgui.StyleCol;
    const style = zgui.getStyle();
    style.setColor(StyleCol.title_bg, [4]f32{ 0.1, 0.1, 0.1, 0.85 });
    style.setColor(StyleCol.title_bg_active, [4]f32{ 0.15, 0.15, 0.15, 0.9 });
    style.setColor(StyleCol.menu_bar_bg, [4]f32{ 0.1, 0.1, 0.1, 0.8 });
    style.setColor(StyleCol.header, [4]f32{ 0.1, 0.1, 0.1, 0.8 });
    style.setColor(StyleCol.check_mark, [4]f32{ 0, 1, 0, 1 });

    const cursors = try GlfwCursors.init();
    errdefer cursors.deinit();

    // register input callbacks for the editor
    setEditorInput(window);

    var undo_stack = UndoRedoStack{};
    try undo_stack.resize(allocator, 128);
    errdefer undo_stack.deinit(allocator);

    return Editor{
        .allocator = allocator,
        .storage = storage,
        .scheduler = scheduler,
        .render_context = render_context,
        .ui_state = ui_state,
        .icons = EditorIcons.init(render_context.imgui_pipeline.texture_indices),
        .cursors = cursors,
        .undo_stack = undo_stack,
    };
}

pub fn deinit(self: *Editor) void {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    self.scheduler.waitIdle();
    self.cursors.deinit();
    self.render_context.deinit(self.allocator);
    self.storage.deinit();
    self.scheduler.deinit();
    self.undo_stack.deinit(self.allocator);
}

pub fn popUndoStack(self: *Editor) void {
    self.undo_stack.popAction(&self.storage) catch {
        // TODO: log in debug
    };
}

pub fn exportEditorSceneToFile(self: *Editor, file_name: []const u8) !void {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    const ezby_stream = try ezby.serialize(EditorStorage, self.allocator, self.storage, .{}, .{});
    defer self.allocator.free(ezby_stream);

    // TODO: this is an horrible idea since we don't know if the write will be sucessfull
    // delete file if it exist already
    std.fs.cwd().deleteFile(file_name) catch |err| switch (err) {
        error.FileNotFound => {}, // ok
        else => return err,
    };

    try std.fs.cwd().writeFile(.{ .sub_path = file_name, .data = ezby_stream });
}

pub fn exportGameSceneToFile(self: *Editor, file_name: []const u8) !void {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    // Serialize current state
    const ezby_stream = try ezby.serialize(EditorStorage, self.allocator, self.storage, .{}, .{});
    // On function exit, restore previous state
    defer {
        // TODO: make sure this can't fail, or progress can be lost
        // Alternative: serialzie, deserialzie a temp local storage
        self.deserializeAndSyncState(ezby_stream) catch |err| std.debug.panic("failed to restore scene stated: {s}", .{@errorName(err)});
        self.allocator.free(ezby_stream);
    }

    // Query all entities with EntityMetadata (should be all entities)
    var enity_metadata_query = EditorStorage.Query(
        struct {
            entity: ecez.Entity,
            metadata: EntityMetadata,
        },
        .{},
    ).submit(&self.storage);
    while (enity_metadata_query.next()) |result| {
        // Queue removal of EntityMetadata
        try self.storage.queueRemoveComponent(result.entity, EntityMetadata);
    }

    // Submit edit queue
    try self.storage.flushStorageQueue();

    const game_stream = try ezby.serialize(EditorStorage, self.allocator, self.storage, .{}, .{ .culled_component_types = &editor_components.all });
    defer self.allocator.free(game_stream);

    // TODO: this is an horrible idea since we don't know if the write will be sucessfull
    // delete file if it exist already
    std.fs.cwd().deleteFile(file_name) catch |err| switch (err) {
        error.FileNotFound => {}, // ok
        else => return err,
    };

    try std.fs.cwd().writeFile(.{ .sub_path = file_name, .data = game_stream });
}

pub fn importEditorSceneFromFile(self: *Editor, file_name: []const u8) !void {
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

fn deserializeAndSyncState(self: *Editor, bytes: []const u8) !void {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    // deserialize bytes into the ecs storage
    try ezby.deserialize(EditorStorage, &self.storage, bytes);

    // restart the render context to make sure all required instances has and appropriate handle
    self.render_context.clearInstancesRetainingCapacity();

    const RenderInstanceHandleQuery = EditorStorage.Query(struct {
        instance_handle: *InstanceHandle,
    }, .{});

    var instance_handle_iter = RenderInstanceHandleQuery.submit(&self.storage);

    // Synchronize the state of instance handles so that they have a valid handle according to the running render context
    while (instance_handle_iter.next()) |item| {
        item.instance_handle.* = try self.render_context.getNewInstance(item.instance_handle.mesh_handle);
    }
}

pub fn update(self: *Editor, delta_time: f32) void {
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

            // apply update render camera with editor camera
            self.render_context.camera.view = RenderContext.Camera.calcView(orientation, camera_position_ptr.vec);
        }
    }
}

pub fn newFrame(self: *Editor, window: glfw.Window, delta_time: f32) !void {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    // TODO: Move out of newFrame, into update function instead ...
    if (false == self.ui_state.camera_control_active) {
        // If we are not controlling the camera, then we should update cursor if needed
        // NOTE: getting cursor must be done before calling zgui.newFrame
        window.setInputModeCursor(.normal);
        self.cursors.handleZguiCursor(window);
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

        // define editor header
        const header_height = blk1: {
            const header_zone = tracy.ZoneN(@src(), @src().fn_name ++ " header height");
            defer header_zone.End();

            {
                zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = [2]f32{ -1, 8 } });
                defer zgui.popStyleVar(.{});

                if (zgui.beginMainMenuBar() == false) {
                    break :blk1 0;
                }
            }
            defer zgui.endMainMenuBar();

            // file operations
            {
                if (self.icons.button(.folder_file_load, "folder_load_button##00", "load scene from file", EditorIcons.icon_size, EditorIcons.icon_size, .{})) {
                    self.ui_state.import_editor_file_modal_popen = true;
                }
                zgui.sameLine(.{});
                if (self.icons.button(.folder_file_save, "folder_save_button##00", "save current scene to file", EditorIcons.icon_size, EditorIcons.icon_size, .{})) {
                    self.ui_state.export_editor_file_modal_popen = true;
                }
                zgui.sameLine(.{});
                if (self.icons.button(.@"3d_model_load", "model_load_button##00", "load new 3d model", EditorIcons.icon_size, EditorIcons.icon_size, .{})) {
                    std.debug.print("load new model", .{}); // TODO: load new model
                }
                zgui.sameLine(.{});
            }

            zgui.separator();
            zgui.sameLine(.{});

            // window toggles
            {
                const object_list_icon = if (self.ui_state.object_list_active) Icons.object_list_on else Icons.object_list_off;
                if (self.icons.button(object_list_icon, "object_list_button##00", "toggle object list window", EditorIcons.icon_size, EditorIcons.icon_size, .{})) {
                    self.ui_state.object_list_active = !self.ui_state.object_list_active;
                }
                zgui.sameLine(.{});
                const object_inspector_icon = if (self.ui_state.object_inspector_active) Icons.object_inspector_on else Icons.object_inspector_off;
                if (self.icons.button(object_inspector_icon, "object_inspector_button##00", "toggle object inspector window", EditorIcons.icon_size, EditorIcons.icon_size, .{})) {
                    self.ui_state.object_inspector_active = !self.ui_state.object_inspector_active;
                }
                zgui.sameLine(.{});
                if (self.icons.button(.debug_log_off, "debug_log_button##00", "toggle debug log window", EditorIcons.icon_size, EditorIcons.icon_size, .{})) {
                    std.debug.print("debug log", .{}); // TODO: toggle debug log window
                }
                zgui.sameLine(.{});
            }

            zgui.separator();
            zgui.sameLine(.{});

            // scene related
            {
                if (self.icons.button(.new_object, "new_object_button##00", "spawn new entity in the scene", EditorIcons.icon_size, EditorIcons.icon_size, .{})) {
                    try self.createNewEntityMenu();
                }

                // camera control button
                {
                    zgui.beginDisabled(.{
                        .disabled = false == self.validCameraEntity(self.active_camera),
                    });
                    defer zgui.endDisabled();

                    const camera_icon = if (self.ui_state.camera_control_active) Icons.camera_on else Icons.camera_off;
                    if (self.icons.button(camera_icon, "camera_control_button##00", "control camera with key and mouse (esc to exit)", EditorIcons.icon_size, EditorIcons.icon_size, .{})) {
                        if (self.ui_state.camera_control_active == false) {
                            self.ui_state.camera_control_active = true;
                            setCameraInput(window);
                        } else {
                            self.ui_state.camera_control_active = false;
                            setEditorInput(window);
                        }
                    }
                }
            }

            zgui.separator();
            zgui.sameLine(.{});

            // game related
            {
                const game_button_size = 18 * 3;
                const available_x = (zgui.getContentRegionAvail()[0] * 0.5) + zgui.getCursorPosX();
                zgui.setCursorPos([2]f32{ available_x - game_button_size, 0 });

                if (self.icons.button(.folder_file_save, "game_scene_save##00", "export scene as a game scene", EditorIcons.icon_size, EditorIcons.icon_size, .{})) {
                    self.ui_state.export_game_file_modal_popen = true;
                    self.ui_state.setExportImportFileName("scene.game.ezby");
                }

                if (self.icons.button(.play, "play_game_scene##00", "builds release game exe, game scene and runs", EditorIcons.icon_size, EditorIcons.icon_size, .{})) {
                    std.debug.print("unimplemented", .{});
                }

                if (self.icons.button(.debug_play, "debug_play_game_scene##00", "builds debug game exe, game scene and runs", EditorIcons.icon_size, EditorIcons.icon_size, .{})) {
                    const play_game_config = PlayGameSettings{
                        .project_src_path = config_options.build_script_path,
                        .game_compile_flags = &[0][]const u8{},
                    };
                    try self.playGame(self.allocator, play_game_config);
                }
            }

            break :blk1 zgui.getWindowHeight();
        };

        const export_import_file_name_len = std.mem.indexOf(u8, &self.ui_state.export_import_file_name, &[_]u8{0}).?;

        // export editor scene to file modal
        {
            if (self.ui_state.export_editor_file_modal_popen) {
                zgui.openPopup("Export Modal", .{});
            }

            if (zgui.beginPopupModal("Export Modal", .{ .flags = .{ .always_auto_resize = true } })) {
                defer zgui.endPopup();

                zgui.text("File name: ", .{});
                if (zgui.inputText("##export_file_name", .{
                    .buf = &self.ui_state.export_import_file_name,
                    .flags = .{},
                })) {}
                zgui.sameLine(.{});

                // TODO: make it required, validate in code
                marker("File name should have the extension '.ezby',\nbut it is not required", .hint);

                zgui.setItemDefaultFocus();
                if (zgui.button("Export scene", .{})) {
                    // TODO: show error as a modal
                    try self.exportEditorSceneToFile(self.ui_state.export_import_file_name[0..export_import_file_name_len]);
                    self.ui_state.export_editor_file_modal_popen = false;
                    zgui.closeCurrentPopup();
                }
                zgui.sameLine(.{});
                if (zgui.button("Cancel##export_modal", .{ .w = 120, .h = 0 })) {
                    self.ui_state.export_editor_file_modal_popen = false;
                    zgui.closeCurrentPopup();
                }
            }
        }

        // import editor scene to file modal
        {
            if (self.ui_state.import_editor_file_modal_popen) {
                zgui.openPopup("Import Modal", .{});
            }

            if (zgui.beginPopupModal("Import Modal", .{ .flags = .{ .always_auto_resize = true } })) {
                defer zgui.endPopup();

                zgui.text("File name: ", .{});
                if (zgui.inputText("##import_file_name", .{
                    .buf = &self.ui_state.export_import_file_name,
                    .flags = .{},
                })) {}

                zgui.setItemDefaultFocus();
                if (zgui.button("Import scene", .{})) {
                    // TODO: show error as a modal
                    try self.importEditorSceneFromFile(self.ui_state.export_import_file_name[0..export_import_file_name_len]);
                    self.ui_state.import_editor_file_modal_popen = false;
                    zgui.closeCurrentPopup();
                }
                zgui.sameLine(.{});
                if (zgui.button("Cancel##import_modal", .{ .w = 120, .h = 0 })) {
                    self.ui_state.import_editor_file_modal_popen = false;
                    zgui.closeCurrentPopup();
                }
            }
        }

        // export editor scene as game scene to file modal
        {
            if (self.ui_state.export_game_file_modal_popen) {
                zgui.openPopup("Export Modal##game", .{});
            }

            if (zgui.beginPopupModal("Export Modal##game", .{ .flags = .{ .always_auto_resize = true } })) {
                defer zgui.endPopup();

                zgui.text("File name: ", .{});
                if (zgui.inputText("##export_game_file_name", .{
                    .buf = &self.ui_state.export_import_file_name,
                    .flags = .{},
                })) {}
                zgui.sameLine(.{});

                // TODO: make it required, validate in code
                marker("File name should have the extension '.game.ezby',\nbut it is not required", .hint);

                zgui.setItemDefaultFocus();
                if (zgui.button("Export game scene", .{})) {
                    // TODO: show error as a modal
                    try self.exportGameSceneToFile(self.ui_state.export_import_file_name[0..export_import_file_name_len]);
                    self.ui_state.export_game_file_modal_popen = false;
                    zgui.closeCurrentPopup();
                }
                zgui.sameLine(.{});
                if (zgui.button("Cancel##export_modal", .{ .w = 120, .h = 0 })) {
                    self.ui_state.export_game_file_modal_popen = false;
                    zgui.closeCurrentPopup();
                }
            }
        }

        // define Object List
        object_list_blk: {
            const object_list_zone = tracy.ZoneN(@src(), @src().fn_name ++ " object list");
            defer object_list_zone.End();

            if (self.ui_state.object_list_active == false) {
                break :object_list_blk;
            }

            const width = @as(f32, @floatFromInt(frame_size.width)) / 6;

            zgui.setNextWindowSize(.{ .w = width, .h = @as(f32, @floatFromInt(frame_size.height)), .cond = .always });
            zgui.setNextWindowPos(.{ .x = 0, .y = header_height, .cond = .always });

            if (zgui.begin("Object List", .{ .popen = null, .flags = .{
                .menu_bar = false,
                .no_move = true,
                .no_resize = false,
                .no_scrollbar = false,
                .no_scroll_with_mouse = false,
                .no_collapse = true,
            } }) == false) {
                break :object_list_blk;
            }

            defer zgui.end();

            {
                if (self.icons.button(.new_object, "new_object_button##01", "create a new entity", EditorIcons.icon_size, EditorIcons.icon_size, .{})) {
                    _ = try self.newSceneEntity("empty entity");
                }
                zgui.sameLine(.{});
                if (self.icons.button(.copy_object, "copy_object_button##00", "copy selected entity", EditorIcons.icon_size, EditorIcons.icon_size, .{})) {
                    if (self.ui_state.selected_entity) |*selected_entity| {
                        const new_entity = try self.storage.cloneEntity(selected_entity.*);
                        defer selected_entity.* = new_entity;

                        // EntityMetadata
                        {
                            const metadata = self.storage.getComponent(new_entity, *EntityMetadata) catch unreachable;
                            // TODO postfix with _copy, (N) ... ?
                            metadata.* = EntityMetadata.init(metadata.getDisplayName(), new_entity);
                        }

                        // TODO: this is probably logic we want for undo/redo as well?
                        // InstanceHandle
                        if (self.storage.hasComponent(new_entity, InstanceHandle)) {
                            const instance_handle = self.storage.getComponent(new_entity, InstanceHandle) catch unreachable;
                            self.storage.removeComponent(new_entity, InstanceHandle) catch unreachable;
                            try self.assignEntityMeshInstance(new_entity, instance_handle.mesh_handle);
                        }
                    }
                }

                const ObjectListQuery = EditorStorage.Query(
                    struct {
                        entity: ecez.Entity,
                        metadata: *EntityMetadata,
                    },
                    .{},
                );

                var list_item_iter = ObjectListQuery.submit(&self.storage);
                while (list_item_iter.next()) |list_item| {
                    const selected_entity_id = blk: {
                        // selected entity is either our persistent user selction, or an invalid/unlikely InstanceHandle.
                        if (self.ui_state.selected_entity) |selected_entity| {
                            break :blk selected_entity.id;
                        } else {
                            const invalid_entity_id: ecez.EntityId = std.math.maxInt(ecez.EntityId);
                            break :blk @as(ecez.EntityId, @bitCast(invalid_entity_id));
                        }
                    };

                    // if user is renaming the selectable
                    if (self.ui_state.object_list.renaming_entity and list_item.entity.id == selected_entity_id) {

                        // make sure the user can start typing as soon as they initiate renaming
                        if (self.ui_state.object_list.first_rename_draw) {
                            zgui.setKeyboardFocusHere(0);
                            self.ui_state.object_list.first_rename_draw = false;
                        }

                        if (zgui.inputText("##object_list_rename", .{
                            .buf = &self.ui_state.object_list.renaming_buffer,
                            .flags = .{ .enter_returns_true = true },
                        })) {
                            const new_len = std.mem.indexOf(u8, &self.ui_state.object_list.renaming_buffer, &[_]u8{0}).?;

                            if (new_len > 0) {
                                list_item.metadata.rename(self.ui_state.object_list.renaming_buffer[0..new_len]);

                                // set object name field to current selection
                                const display_name = list_item.metadata.getDisplayName();
                                @memcpy(self.ui_state.object_inspector.name_buffer[0..display_name.len], display_name);
                                self.ui_state.object_inspector.name_buffer[display_name.len] = 0;

                                self.ui_state.object_list.renaming_entity = false;
                                @memset(&self.ui_state.object_list.renaming_buffer, 0);
                            }
                        }
                    } else {
                        if (zgui.selectable(list_item.metadata.getId(), .{
                            .selected = list_item.entity.id == selected_entity_id,
                            .flags = .{ .allow_double_click = true },
                        })) {
                            // set object name field to current selection
                            const display_name = list_item.metadata.getDisplayName();
                            @memcpy(self.ui_state.object_inspector.name_buffer[0..display_name.len], display_name);

                            // Set index to a non existing index. This makes no object selected
                            self.ui_state.object_inspector.selected_component_index = all_components.len;
                            self.ui_state.object_inspector.name_buffer[display_name.len] = 0;

                            self.ui_state.object_list.first_rename_draw = true;
                            self.ui_state.object_list.renaming_entity = zgui.isItemHovered(.{}) and zgui.isMouseDoubleClicked(zgui.MouseButton.left);
                            self.ui_state.selected_entity = list_item.entity;
                        }
                    }
                }
            }
        }

        // define Object Inspector
        object_inspector_blk: {
            const object_inspector_zone = tracy.ZoneN(@src(), @src().fn_name ++ " object inspector");
            defer object_inspector_zone.End();

            if (self.ui_state.object_inspector_active == false) {
                break :object_inspector_blk;
            }

            const width = @as(f32, @floatFromInt(frame_size.width)) / 6;

            zgui.setNextWindowSize(.{ .w = width, .h = @as(f32, @floatFromInt(frame_size.height)), .cond = .always });
            zgui.setNextWindowPos(.{ .x = @as(f32, @floatFromInt(frame_size.width)) - width, .y = header_height, .cond = .always });
            if (zgui.begin("Object Inspector", .{ .popen = null, .flags = .{
                .menu_bar = false,
                .no_move = true,
                .no_resize = false,
                .no_scrollbar = false,
                .no_scroll_with_mouse = false,
                .no_collapse = true,
            } }) == false) {
                break :object_inspector_blk;
            }
            defer zgui.end();

            if (self.ui_state.selected_entity) |selected_entity| {
                // entity metadata
                {
                    zgui.text("Id: {d}", selected_entity);
                    zgui.text("Name: ", .{});
                    zgui.sameLine(.{});
                    if (zgui.inputText("##object_inspector_rename", .{
                        .buf = &self.ui_state.object_inspector.name_buffer,
                        .flags = .{ .enter_returns_true = true },
                    })) {
                        const new_len = std.mem.indexOf(u8, &self.ui_state.object_inspector.name_buffer, &[_]u8{0}).?;

                        if (new_len > 0) {
                            var metadata = try self.storage.getComponent(selected_entity, EntityMetadata);
                            metadata.rename(self.ui_state.object_inspector.name_buffer[0..new_len]);

                            // Undo logic
                            undo_blk: {
                                const prev_component = self.storage.getComponent(selected_entity, EntityMetadata) catch |err| {
                                    std.debug.assert(err == error.ComponentMissing);
                                    self.undo_stack.pushRemoveComponent(selected_entity, EntityMetadata);
                                    // if get failed, dont store in undo stack
                                    break :undo_blk;
                                };
                                self.undo_stack.pushSetComponent(selected_entity, prev_component);
                            }

                            try self.storage.setComponent(selected_entity, metadata);
                        }
                    }
                }

                // entity buttons
                {
                    const needs_dummy_space = entity_icons_blk: {
                        if (self.active_camera) |camera_entity| {
                            if (selected_entity.id != camera_entity.id and self.validCameraEntity(selected_entity)) {
                                if (self.icons.button(.camera_off, "Set active camera##00", "make current entity the active scene camera", EditorIcons.icon_size, EditorIcons.icon_size, .{})) {
                                    self.active_camera = selected_entity;
                                }

                                break :entity_icons_blk false;
                            }
                        }
                        break :entity_icons_blk true;
                    };

                    // TODO: this does not match icon height for some reason (buttons has padding on image)
                    if (needs_dummy_space) {
                        zgui.dummy(.{ .w = EditorIcons.icon_size, .h = EditorIcons.icon_size + 2 });
                    }
                }

                zgui.separator();

                zgui.text("Component list: ", .{});
                if (zgui.beginListBox("##component list", .{ .w = -std.math.floatMin(f32), .h = 0 })) {
                    defer zgui.endListBox();

                    inline for (all_components, 0..) |Component, comp_index| {
                        if (self.storage.hasComponent(selected_entity, Component)) {
                            if (zgui.selectable(@typeName(Component), .{ .selected = comp_index == self.ui_state.object_inspector.selected_component_index })) {
                                self.ui_state.object_inspector.selected_component_index = comp_index;
                            }
                        }
                    }
                }

                // add component UI
                {
                    if (zgui.button("Add", .{})) {
                        self.ui_state.add_component_modal.is_active = true;
                        zgui.openPopup("Add component", .{});
                    }

                    // Place add modal at the center of the screen
                    const center = zgui.getMainViewport().getCenter();
                    zgui.setNextWindowPos(.{
                        .x = center[0],
                        .y = center[1],
                        .cond = .appearing,
                        .pivot_x = 0.5,
                        .pivot_y = 0.5,
                    });

                    if (zgui.beginPopupModal("Add component", .{ .flags = .{ .always_auto_resize = true } })) {
                        defer zgui.endPopup();

                        // List of components that you can add
                        inline for (all_components, 0..) |Component, comp_index| {
                            // you can never add a EntityMetadata
                            if (Component == EntityMetadata) continue;

                            if (self.storage.hasComponent(selected_entity, Component) == false) {
                                // if the component index is not set, then we set it to current component index
                                if (self.ui_state.add_component_modal.selected_component_index == all_components.len) {
                                    self.ui_state.add_component_modal.selected_component_index = comp_index;
                                }

                                if (zgui.selectable(@typeName(Component), .{
                                    .selected = comp_index == self.ui_state.add_component_modal.selected_component_index,
                                    .flags = .{ .dont_close_popups = true },
                                })) {
                                    self.ui_state.add_component_modal.selected_component_index = comp_index;

                                    @memset(&self.ui_state.add_component_modal.component_bytes, 0);
                                }
                            }
                        }

                        // Menu to set the initial value of selected component
                        {
                            zgui.separator();

                            // List of components that you can add
                            inline for (all_components, 0..) |Component, comp_index| {
                                if (Component == EntityMetadata) continue;

                                if (comp_index == self.ui_state.add_component_modal.selected_component_index) {
                                    zgui.text("{s}:", .{@typeName(Component)});

                                    const component_ptr: *Component = blk: {
                                        const aligned_ptr = std.mem.alignPointer(self.ui_state.add_component_modal.component_bytes[0..].ptr, @alignOf(Component));
                                        const ptr_value = std.mem.bytesAsValue(Component, aligned_ptr.?);
                                        break :blk @alignCast(ptr_value);
                                    };

                                    // if component has specialized widget
                                    if (component_reflect.overrideWidgetGenerator(Component)) |Override| {
                                        // call manually implemented widget
                                        _ = Override.widget(self, component_ptr);
                                    } else {
                                        // .. or generated widget
                                        _ = component_reflect.componentWidget(Component, component_ptr);
                                    }
                                }
                            }
                            zgui.separator();
                        }

                        if (zgui.button("Add component", .{ .w = 120, .h = 0 })) {
                            // Add component to entity
                            inline for (all_components, 0..) |Component, comp_index| {
                                if (Component == EntityMetadata) continue;

                                if (comp_index == self.ui_state.add_component_modal.selected_component_index) {
                                    const component_ptr: *Component = blk: {
                                        const aligned_ptr = std.mem.alignPointer(self.ui_state.add_component_modal.component_bytes[0..].ptr, @alignOf(Component));
                                        const ptr_value = std.mem.bytesAsValue(Component, aligned_ptr.?);
                                        break :blk @alignCast(ptr_value);
                                    };

                                    if (component_reflect.specializedAddHandle(Component)) |add_handle| {
                                        try add_handle.add(self, component_ptr);
                                    } else {

                                        // Undo logic
                                        undo_blk: {
                                            const prev_component = self.storage.getComponent(selected_entity, Component) catch |err| {
                                                std.debug.assert(err == error.ComponentMissing);
                                                self.undo_stack.pushRemoveComponent(selected_entity, Component);
                                                // if get failed, dont store in undo stack
                                                break :undo_blk;
                                            };
                                            self.undo_stack.pushSetComponent(selected_entity, prev_component);
                                        }

                                        try self.storage.setComponent(selected_entity, component_ptr.*);
                                    }
                                }
                            }

                            self.ui_state.add_component_modal.selected_component_index = all_components.len;
                            self.ui_state.add_component_modal.is_active = false;
                            zgui.closeCurrentPopup();
                        }
                        zgui.sameLine(.{});
                        marker("Remember to set ALL values to something valid", .warning);

                        zgui.setItemDefaultFocus();
                        zgui.sameLine(.{});
                        if (zgui.button("Cancel", .{ .w = 120, .h = 0 })) {
                            self.ui_state.add_component_modal.selected_component_index = all_components.len;
                            self.ui_state.add_component_modal.is_active = false;
                            zgui.closeCurrentPopup();
                        }
                    }
                }
                zgui.sameLine(.{});

                {
                    const object_metadata_selected = component_reflect.object_metadata_index == self.ui_state.object_inspector.selected_component_index;
                    const nothing_selected = self.ui_state.object_inspector.selected_component_index == all_components.len;
                    zgui.beginDisabled(.{
                        .disabled = object_metadata_selected or nothing_selected,
                    });
                    defer zgui.endDisabled();

                    if (zgui.button("Remove", .{})) {
                        inline for (all_components, 0..) |Component, comp_index| {
                            // deleting the metadata of an entity is illegal
                            if (Component != EntityMetadata and comp_index == self.ui_state.object_inspector.selected_component_index) {
                                if (component_reflect.specializedRemoveHandle(Component)) |remove_handle| {
                                    try remove_handle.remove(self);
                                } else {
                                    undo_blk: {
                                        const prev_component = self.storage.getComponent(selected_entity, Component) catch {
                                            break :undo_blk;
                                        };
                                        self.undo_stack.pushSetComponent(selected_entity, prev_component);
                                    }

                                    // In the event a remove failed, then the select index is in a inconsistent state
                                    // and we do not really have to do anything
                                    self.storage.removeComponent(selected_entity, Component) catch {
                                        // TODO: log here in debug builds
                                    };
                                }

                                // assign selection an invalid index
                                // TODO: Selection should be persistent when removing current component
                                self.ui_state.object_inspector.selected_component_index = all_components.len;
                            }
                        }
                    }
                }

                zgui.separator();
                zgui.text("Component widgets:", .{});
                comp_iter: inline for (all_components) |Component| {
                    if (Component == EntityMetadata) {
                        continue :comp_iter;
                    }

                    if (self.storage.hasComponent(selected_entity, Component)) {
                        zgui.separator();
                        zgui.text("{s}:", .{@typeName(Component)});

                        var component = self.storage.getComponent(selected_entity, Component) catch unreachable;
                        var changed = false;
                        // if component has specialized widget
                        if (component_reflect.overrideWidgetGenerator(Component)) |Override| {
                            // call manually implemented widget
                            changed = Override.widget(self, &component);
                        } else {
                            // .. or generated widget
                            changed = component_reflect.componentWidget(Component, &component);
                        }

                        if (changed) {

                            // Undo set logic, TODO: only do this on mouse release
                            undo_blk: {
                                const prev_component = self.storage.getComponent(selected_entity, Component) catch |err| {
                                    std.debug.assert(err == error.ComponentMissing);
                                    self.undo_stack.pushRemoveComponent(selected_entity, Component);
                                    // if get failed, dont store in undo stack
                                    break :undo_blk;
                                };
                                self.undo_stack.pushSetComponent(selected_entity, prev_component);
                            }

                            try self.storage.setComponent(selected_entity, component);
                        }

                        zgui.separator();
                    }
                }
            }
        }
    }

    try self.render_context.drawFrame(window);
    try self.forceFlush();
}

pub fn createTestScene(self: *Editor) !void {
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

pub fn validCameraEntity(self: *Editor, entity: ?ecez.Entity) bool {
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

/// register input so only editor handles glfw input
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

            const editor_ptr = user_pointer.ptr;

            const axist_value: f32 = switch (action) {
                .press => 1,
                .release => -1,
                .repeat => return,
            };

            if (editor_ptr.validCameraEntity(editor_ptr.active_camera)) {
                const camera_entity = editor_ptr.active_camera.?;
                const camera_velocity_ptr = editor_ptr.storage.getComponent(camera_entity, *game.components.Velocity) catch unreachable;

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
                        editor_ptr.ui_state.camera_control_active = false;
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

            const editor_ptr = user_pointer.ptr;

            defer {
                editor_ptr.input_state.previous_cursor_xpos = xpos;
                editor_ptr.input_state.previous_cursor_ypos = ypos;
            }

            const x_delta = xpos - editor_ptr.input_state.previous_cursor_xpos;
            const y_delta = ypos - editor_ptr.input_state.previous_cursor_ypos;

            camera_update_blk: {
                if (editor_ptr.active_camera) |camera_entity| {
                    const camera_ptr = editor_ptr.storage.getComponent(camera_entity, *game.components.Camera) catch {
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

pub fn getMeshHandleFromName(self: *Editor, name: []const u8) ?MeshHandle {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    return self.render_context.getMeshHandleFromName(name);
}

pub fn newSceneEntity(self: *Editor, name: []const u8) !ecez.Entity {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    const entity = try self.storage.createEntity(.{});
    const metadata = EntityMetadata.init(name, entity);
    try self.storage.setComponent(entity, metadata);

    return entity;
}

/// This function retrieves a instance handle from the renderer and assigns it to the argument entity
pub fn assignEntityMeshInstance(self: *Editor, entity: ecez.Entity, mesh_handle: MeshHandle) !void {
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

pub const VisibleObjectConfig = struct {
    position: ?Editor.Position = null,
    rotation: ?Editor.Rotation = null,
    scale: ?Editor.Scale = null,
};
/// Create a new entity that should also have a renderable mesh instance tied to the entity.
/// The function will also send this to the GPU in the event of flush_all_objects = .yes
pub fn createNewVisbleObject(
    self: *Editor,
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

    try self.storage.setComponent(new_entity, game.components.SceneGraph.Level{ .value = .L0 });
    try self.storage.setComponent(new_entity, game.components.SceneGraph.L0{});
}

pub fn forceFlush(self: *Editor) !void {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    self.scheduler.dispatchEvent(
        &self.storage,
        .transform_update,
        GameSystems.EventArgument{ .read_storage = self.storage, .render_context = &self.render_context },
    );
    self.scheduler.waitEvent(.transform_update);

    // Currently the renderer is configured to always flush
    // self.render_context.signalUpdate();
}

/// Display imgui menu with a list of options for a new entity
/// The new entity can either be a empty entity (only contain editor metadata)
/// or be a visible object in the scene by selecting the desired mesh for the new entity
inline fn createNewEntityMenu(self: *Editor) !void {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    if (zgui.beginMenu("Create new", true)) {
        defer zgui.endMenu();

        if (zgui.menuItem("empty entity", .{})) {
            _ = try self.newSceneEntity("empty entity");
        }

        var mesh_name_iter = self.render_context.mesh_name_handle_map.keyIterator();
        while (mesh_name_iter.next()) |mesh_name_entry| {
            const c_name: *[:0]const u8 = @ptrCast(mesh_name_entry);
            if (zgui.menuItem(c_name.*, .{})) {
                const mesh_handle = self.getMeshHandleFromName(c_name.*).?;
                try self.createNewVisbleObject(c_name.*, mesh_handle, .{});
            }
        }
    }
}

const PlayGameSettings = struct {
    project_src_path: []const u8,
    game_compile_flags: []const []const u8,
};

fn playGame(self: *Editor, allocator: Allocator, settings: PlayGameSettings) !void {
    {
        const argv = [_][]const u8{ "zig", "build", "-Dbin_type=game" };

        // Spawn zig compiler and begin compiling game
        var compile_game_process = std.process.Child.init(&argv, allocator);
        compile_game_process.cwd = settings.project_src_path;
        try compile_game_process.spawn();

        // Export current scene as scene to play
        try self.exportGameSceneToFile("scene.game.ezby");

        // wait
        switch (try compile_game_process.wait()) {
            .Exited => |exit_code| {
                if (0 != exit_code) {
                    std.debug.print("failed to compile game", .{});
                    return;
                }
            },
            else => {
                // TODO: unreachable?
                std.debug.print("failed to compile game", .{});
            },
        }
    }

    {
        const argv = [_][]const u8{"zig-out/bin/game"};
        var run_game_process = std.process.Child.init(&argv, allocator);
        run_game_process.cwd = settings.project_src_path;
        try run_game_process.spawn();

        _ = try run_game_process.wait();
    }
}
