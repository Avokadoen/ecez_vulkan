const std = @import("std");
const Allocator = std.mem.Allocator;

const ecez = @import("ecez");
const ezby = ecez.ezby;

const zgui = @import("zgui");
const glfw = @import("glfw");

const zm = @import("zmath");

const RenderContext = @import("RenderContext.zig");
const MeshHandle = RenderContext.MeshHandle;
const MeshInstancehInitializeContex = RenderContext.MeshInstancehInitializeContex;

// TODO: controllable scene camera (Icon to toggle camera control)
// TODO: Object list and inspector should have a preferences option in the header to adjust width of the window
// TODO: should be able to change mesh of selected object
// TODO: move transform stuff out
// TODO: configure hiding components fropm component list + widgets
// TODO: ability to override generated component widgets
//       TODO: instance component needs overriding
//       TODO: ObjectMetadata has to be hidden
//       TODO: custom widget for adding a new component

pub const InstanceHandle = RenderContext.InstanceHandle;
pub const Transform = struct {
    mat: zm.Mat,
};
pub const Position = struct {
    vec: zm.Vec,
};
pub const Rotation = struct {
    quat: zm.Quat,
};
pub const Scale = struct {
    vec: zm.Vec,
};
// TODO: rename "EntityMetadata"
pub const ObjectMetadata = struct {
    const buffer_len = 127;
    const hash_len = "##".len + @sizeOf(ecez.Entity);

    id_len: u8,
    id_buffer: [buffer_len]u8,

    fn init(name: []const u8, entity: ecez.Entity) ObjectMetadata {
        const id_len = name.len + hash_len;
        std.debug.assert(id_len < buffer_len);

        const hash_fluff = "##" ++ std.mem.asBytes(&entity.id);
        var id_buffer: [buffer_len]u8 = undefined;

        @memcpy(id_buffer[0..name.len], name);
        @memcpy(id_buffer[name.len .. name.len + hash_fluff.len], hash_fluff);
        id_buffer[id_len] = 0;

        return ObjectMetadata{
            .id_len = @intCast(id_len),
            .id_buffer = id_buffer,
        };
    }

    fn rename(self: *ObjectMetadata, name: []const u8) void {
        const id_len = name.len + hash_len;
        std.debug.assert(id_len < buffer_len);

        // move the hash to its new postion
        // we could use mem.rotate here for better efficiency, but KISS
        const hash_start_pos = name.len;
        var tmp_hash_buffer: [hash_len]u8 = undefined;
        @memcpy(&tmp_hash_buffer, self.id_buffer[hash_start_pos .. hash_start_pos + id_len]);
        @memcpy(self.id_buffer[name.len .. name.len + hash_len], &tmp_hash_buffer);

        // copy new name over
        @memcpy(self.id_buffer[0..name.len], name);
        self.id_buffer[id_len] = 0;
        self.id_len = @intCast(id_len);
    }

    pub inline fn getId(self: ObjectMetadata) [:0]const u8 {
        return self.id_buffer[0..self.id_len :0];
    }

    pub inline fn getDisplayName(self: ObjectMetadata) []const u8 {
        // name - "##xyzw"
        return self.id_buffer[0 .. self.id_len - hash_len];
    }
};

const fake_components = [_]type{
    ObjectMetadata,
    Transform,
    Position,
    Rotation,
    Scale,
    InstanceHandle,
};

const object_metadata_index = blk: {
    inline for (fake_components, 0..) |Component, component_index| {
        if (Component == ObjectMetadata) {
            break :blk component_index;
        }
    }
};

const biggest_component_size = blk: {
    comptime var size = 0;
    inline for (fake_components) |Component| {
        if (Component == ObjectMetadata) continue;

        if (@sizeOf(Component) > size) {
            size = @sizeOf(Component);
        }
    }
    break :blk size;
};

fn overrideWidgetGenerator(comptime Component: type) ?type {
    return switch (Component) {
        InstanceHandle => struct {
            pub fn widget(editor: *Editor, instance_handle: *InstanceHandle) bool {
                const persistent_state = editor.getPersitentState();
                var render_context = editor.getRenderContext();

                const mesh_handle = instance_handle.*.mesh_handle;
                const preview_value = persistent_state.mesh_names.get(mesh_handle).?;

                if (zgui.beginCombo("Mesh", .{ .preview_value = preview_value })) {
                    defer zgui.endCombo();

                    var mesh_name_iter = persistent_state.mesh_names.iterator();
                    while (mesh_name_iter.next()) |mesh_entry| {
                        if (zgui.selectable(mesh_entry.value_ptr.*, .{
                            .selected = mesh_handle == mesh_entry.key_ptr.*,
                        })) {
                            // If we are in the processing of adding a instance handle, then we do not want to
                            // destroy none existing handle in the renderer, only set the in flight handle
                            if (persistent_state.add_component_modal.is_active) {
                                instance_handle.mesh_handle = mesh_entry.key_ptr.*;
                            } else if (mesh_handle != mesh_entry.key_ptr.*) {
                                // TODO: handle errors here and report to user
                                const new_instance_handle = render_context.getNewInstance(mesh_entry.key_ptr.*) catch unreachable;
                                editor.storage.setComponent(persistent_state.selected_entity.?, new_instance_handle) catch unreachable;

                                // destroy old instance handle
                                render_context.destroyInstanceHandle(instance_handle.*);

                                instance_handle.* = new_instance_handle;
                                editor.forceFlush() catch unreachable;
                            }
                        }
                    }
                }
                zgui.sameLine(.{});
                marker("You also need a transform for object to be visible", .hint);

                return false;
            }
        },
        Rotation => struct {
            pub fn widget(editor: *Editor, rotation: *Rotation) bool {
                _ = editor;

                var euler_angles = blk: {
                    const angles = quaternionToEuler(rotation.quat);
                    break :blk [_]f32{
                        std.math.radiansToDegrees(f32, angles[0]),
                        std.math.radiansToDegrees(f32, angles[1]),
                        std.math.radiansToDegrees(f32, angles[2]),
                    };
                };

                zgui.text("Angles: ", .{});
                zgui.sameLine(.{});
                if (zgui.dragFloat3("##euler_angles", .{ .v = &euler_angles })) {
                    const x_axis = zm.f32x4(1, 0, 0, 0);
                    const x_rad = std.math.degreesToRadians(f32, euler_angles[0]);
                    const x_rot = zm.quatFromAxisAngle(x_axis, x_rad);

                    const y_axis = zm.f32x4(0, 1, 0, 0);
                    const y_rad = std.math.degreesToRadians(f32, euler_angles[1]);
                    const y_rot = zm.quatFromAxisAngle(y_axis, y_rad);

                    const z_axis = zm.f32x4(0, 0, 1, 0);
                    const z_rad = std.math.degreesToRadians(f32, euler_angles[2]);
                    const z_rot = zm.quatFromAxisAngle(z_axis, z_rad);

                    rotation.quat = zm.qmul(zm.qmul(x_rot, y_rot), z_rot);
                    return true;
                }
                zgui.sameLine(.{});
                // TODO: fix rotation in y axis: http://www.euclideanspace.com/maths/geometry/rotations/conversions/quaternionToEuler/
                marker("The rotation in Y axis is currently bugged ... ", .warning);

                return false;
            }
        },
        else => null,
    };
}

fn specializedAddHandle(comptime Component: type) ?type {
    return switch (Component) {
        InstanceHandle => struct {
            pub fn add(editor: *Editor, instance_handle: *InstanceHandle) !void {
                const persistent_state = editor.getPersitentState();

                try editor.assignEntityMeshInstance(
                    persistent_state.selected_entity.?,
                    instance_handle.mesh_handle,
                );
            }
        },
        else => null,
    };
}

fn specializedRemoveHandle(comptime Component: type) ?type {
    return switch (Component) {
        InstanceHandle => struct {
            pub fn remove(editor: *Editor) !void {
                const selected_entity = editor.getPersitentState().selected_entity.?;
                const instance_handle = blk: {
                    const handle = try editor.storage.getComponent(selected_entity, InstanceHandle);
                    break :blk handle;
                };
                var render_context = editor.getRenderContext();

                // destroy old instance handle
                render_context.destroyInstanceHandle(instance_handle);

                // In the event a remove failed, then the select index is in a inconsistent state
                // and we do not really have to do anything
                editor.storage.removeComponent(selected_entity, Component) catch {
                    // TODO: log here in debug builds
                };

                try editor.forceFlush();
            }
        },
        else => null,
    };
}

/// Synchronize the state of instance handles so that they have a valid handle according to the running render context
pub fn importInstanceHandlesSystem(instance_handle: *InstanceHandle, shared_render_context: *ecez.SharedState(RenderContext)) void {
    var render_context = @as(*RenderContext, @ptrCast(shared_render_context));
    // TODO: handle error
    instance_handle.* = render_context.getNewInstance(instance_handle.mesh_handle) catch unreachable;
}

// TODO: Doing these things for all enitites in the scene is extremely inefficient
//       since the scene editor is "static". This should only be done for the object
const TransformSystems = struct {
    /// Reset the transform
    pub fn reset(transform: *Transform) void {
        transform.mat = zm.identity();
    }

    /// Apply scale to the transform/
    pub fn applyScale(transform: *Transform, scale: Scale) void {
        transform.mat[0][0] *= scale.vec[0];
        transform.mat[1][1] *= scale.vec[1];
        transform.mat[2][2] *= scale.vec[2];
    }

    /// Apply rotation to the transform/
    pub fn applyRotation(transform: *Transform, rotation: Rotation) void {
        transform.mat = zm.mul(transform.mat, zm.quatToMat(rotation.quat));
    }

    /// Apply position to the transform
    pub fn applyPosition(transform: *Transform, position: Position) void {
        transform.mat = zm.mul(transform.mat, zm.translationV(position.vec));
    }

    /// This system takes each instance handle and transform pair and send the transform to the renderer storage to be rendered
    pub fn propagateToRenderer(transform: Transform, instance_handle: InstanceHandle, render_context: *ecez.SharedState(RenderContext)) void {
        var _render_context = @as(*RenderContext, @ptrCast(render_context));
        _render_context.setInstanceTransform(instance_handle, transform.mat);
    }
};

fn componentWidget(comptime T: type, component: *T) bool {
    var component_changed = false;

    const component_info = switch (@typeInfo(T)) {
        .Struct => |info| info,
        else => @compileError("invalid component type"),
    };

    inline for (component_info.fields, 0..) |field, i| {
        zgui.text(" {s}:", .{field.name});

        component_changed = fieldWidget(T, field.type, i, &@field(component, field.name)) or component_changed;
    }

    return component_changed;
}

fn fieldWidget(comptime Component: type, comptime T: type, comptime id_mod: usize, field: *T) bool {
    var input_id_buf: [2 + @typeName(Component).len + @typeName(T).len + 16]u8 = undefined;
    const id = std.fmt.bufPrint(&input_id_buf, "##{s}{s}{d}", .{ @typeName(Component), @typeName(T), id_mod }) catch unreachable;
    input_id_buf[id.len] = 0;

    var field_changed = false;
    const c_id = input_id_buf[0..id.len :0];
    switch (@typeInfo(T)) {
        .Int => {
            var value = @as(i32, @intCast(field.*));
            if (zgui.inputInt(c_id, .{ .v = &value })) {
                field.* = @as(T, @intCast(value));
                field_changed = true;
            }
        },
        .Float => {
            var value = @as(f32, @intCast(field.*));
            if (zgui.inputFloat(c_id, .{ .v = &value })) {
                field.* = @as(T, @intCast(value));
                field_changed = true;
            }
        },
        .Array => |array_info| {
            switch (@typeInfo(array_info.child)) {
                .Float => {
                    var values: [array_info.len]f32 = undefined;
                    for (&values, 0..) |*value, j| {
                        value.* = @as(f32, @floatCast(field.*[j]));
                    }

                    var array_input = false;
                    switch (array_info.len) {
                        1 => {
                            var value = @as(f32, @intCast(field.*));
                            if (zgui.inputFloat(c_id, .{ .v = &value })) {
                                array_input = true;
                            }
                        },
                        2 => {
                            if (zgui.dragFloat2(c_id, .{ .v = &values })) {
                                array_input = true;
                            }
                        },
                        3 => {
                            if (zgui.dragFloat3(c_id, .{ .v = &values })) {
                                array_input = true;
                            }
                        },
                        4 => {
                            if (zgui.dragFloat4(c_id, .{ .v = &values })) {
                                array_input = true;
                            }
                        },
                        else => std.debug.panic("unimplemented array length of {d}", .{array_info.len}),
                    }
                    if (array_input) {
                        field_changed = true;
                        for (values, 0..) |value, j| {
                            field.*[j] = @as(array_info.child, @floatCast(value));
                        }
                    }
                },
                .Int => {
                    if (array_info.child == u8) {
                        if (zgui.inputText(c_id, .{ .buf = field })) {
                            field_changed = true;
                        }
                    } else {
                        var values: [array_info.len]i32 = undefined;
                        for (values, 0..) |*value, j| {
                            value.* = @as(i32, @floatCast(field.*[j]));
                        }

                        var array_input = false;
                        switch (array_info.len) {
                            1 => {
                                var value = @as(i32, @intCast(field.*));
                                if (zgui.inputFloat(c_id, .{ .v = &value })) {
                                    array_input = true;
                                }
                            },
                            2 => {
                                if (zgui.inputFloat2(c_id, .{ .v = &values })) {
                                    array_input = true;
                                }
                            },
                            3 => {
                                if (zgui.inputFloat3(c_id, .{ .v = &values })) {
                                    array_input = true;
                                }
                            },
                            4 => {
                                if (zgui.inputFloat4(c_id, .{ .v = &values })) {
                                    array_input = true;
                                }
                            },
                            else => std.debug.panic("unimplemented array length of {d}", .{array_info.len}),
                        }
                        if (array_input) {
                            field_changed = true;
                            for (values, 0..) |value, j| {
                                field.*[j] = @as(array_info.child, @floatCast(value));
                            }
                        }
                    }
                },
                .Vector => |vec_info| {
                    comptime var index: usize = 0;
                    inline while (index < vec_info.len) : (index += 1) {
                        field_changed = field_changed or fieldWidget(Component, @TypeOf(field[index]), (id_mod + index) << 1, &field[index]);
                    }
                },
                else => std.debug.panic("unimplemented array type of {s}", .{@typeName(array_info.child)}),
            }
        },
        .Vector => |vec_info| {
            switch (@typeInfo(vec_info.child)) {
                .Float => {
                    var values: [vec_info.len]f32 = undefined;
                    for (&values, 0..) |*value, j| {
                        value.* = @as(f32, @floatCast(field.*[j]));
                    }

                    if (fieldWidget(Component, @TypeOf(values), id_mod << 1, &values)) {
                        for (values, 0..) |value, j| {
                            field.*[j] = value;
                        }

                        field_changed = true;
                    }
                },
                .Int => {
                    var values: [vec_info.len]i32 = undefined;
                    for (&values, 0..) |*value, j| {
                        value.* = @as(i32, @floatCast(field.*[j]));
                    }

                    if (fieldWidget(Component, @TypeOf(values), id_mod << 1, &values)) {
                        for (values, 0..) |value, j| {
                            field.*[j] = value;
                        }

                        field_changed = true;
                    }
                },
                else => std.debug.panic("unimplemented vector type of {s}", .{@typeName(vec_info.child)}),
            }
        },
        .Pointer => |ptr_info| {
            _ = ptr_info;
            std.debug.panic("todo", .{});
        },
        else => std.debug.panic("unimplemented type of {s}", .{@typeName(field.type)}),
    }

    return field_changed;
}

const PersistentState = struct {
    const ObjectList = struct {
        renaming_buffer: [128]u8,
        first_rename_draw: bool,
        renaming_entity: bool,
    };

    const ObjectInspector = struct {
        name_buffer: [128]u8,
        selected_component_index: usize,
    };

    const AddComponentModal = struct {
        selected_component_index: usize = fake_components.len,
        component_bytes: [biggest_component_size]u8 = undefined,
        is_active: bool = false,
    };

    // common state
    selected_entity: ?ecez.Entity,
    mesh_names: std.AutoArrayHashMap(MeshHandle, [:0]const u8),

    export_file_modal_popen: bool,
    import_file_modal_popen: bool,
    export_import_file_name: [128]u8,

    object_list: ObjectList,
    object_inspector: ObjectInspector,
    add_component_modal: AddComponentModal,
};

const Storage = ecez.CreateStorage(.{
    // TODO: generate this!
    fake_components[0],
    fake_components[1],
    fake_components[2],
    fake_components[3],
    fake_components[4],
    fake_components[5],
}, .{
    PersistentState,
    RenderContext,
});

// TODO: convert on_import to simple queries inline
const Scheduler = ecez.CreateScheduler(Storage, .{
    // event to apply all transformation and update render buffers as needed
    ecez.Event("transform_update", .{
        TransformSystems.reset,
        ecez.DependOn(TransformSystems.applyScale, .{TransformSystems.reset}),
        ecez.DependOn(TransformSystems.applyRotation, .{TransformSystems.applyScale}),
        ecez.DependOn(TransformSystems.applyPosition, .{TransformSystems.applyRotation}),
        ecez.DependOn(TransformSystems.propagateToRenderer, .{TransformSystems.applyPosition}),
    }, .{}),
    ecez.Event("on_import", .{
        importInstanceHandlesSystem,
    }, .{}),
});

// TODO: editor should not be part of renderer

/// Editor for making scenes
const Editor = @This();

allocator: Allocator,

pointing_hand: glfw.Cursor,
arrow: glfw.Cursor,
ibeam: glfw.Cursor,
crosshair: glfw.Cursor,
resize_ns: glfw.Cursor,
resize_ew: glfw.Cursor,
resize_nesw: glfw.Cursor,
resize_nwse: glfw.Cursor,
not_allowed: glfw.Cursor,

storage: Storage,
scheduler: Scheduler,

pub fn init(allocator: Allocator, window: glfw.Window, mesh_instance_initalizers: []const MeshInstancehInitializeContex) !Editor {
    var render_context = try RenderContext.init(allocator, window, mesh_instance_initalizers, .{
        .update_rate = .manually,
    });
    errdefer render_context.deinit(allocator);

    var persistent_state = PersistentState{
        .selected_entity = null,
        .mesh_names = std.AutoArrayHashMap(MeshHandle, [:0]const u8).init(allocator),
        .object_list = .{
            .renaming_buffer = undefined,
            .first_rename_draw = false,
            .renaming_entity = false,
        },
        .object_inspector = .{
            .name_buffer = undefined,
            .selected_component_index = fake_components.len,
        },
        .export_file_modal_popen = false,
        .import_file_modal_popen = false,
        .export_import_file_name = undefined,
        .add_component_modal = .{},
    };
    std.mem.copy(u8, &persistent_state.export_import_file_name, "test.ezby");
    persistent_state.export_import_file_name["test.ezby".len] = 0;

    try persistent_state.mesh_names.ensureTotalCapacity(mesh_instance_initalizers.len);

    errdefer {
        const mesh_name_value = persistent_state.mesh_names.values();
        for (mesh_name_value) |name_str| {
            allocator.free(name_str);
        }
        persistent_state.mesh_names.deinit();
    }

    for (mesh_instance_initalizers, 0..) |mesh_instance_initalizer, nth| {
        var path_iter = std.mem.splitBackwards(u8, mesh_instance_initalizer.cgltf_path, "/");
        const file_name = path_iter.first();
        var mesh_name_iter = std.mem.split(u8, file_name, ".");
        const only_file_name = mesh_name_iter.first();

        var mesh_name_mem = try allocator.alloc(u8, only_file_name.len + 1);
        std.mem.copy(u8, mesh_name_mem, only_file_name);
        mesh_name_mem[only_file_name.len] = 0;

        const mesh_handle = render_context.getNthMeshHandle(nth);
        persistent_state.mesh_names.putAssumeCapacity(mesh_handle, mesh_name_mem[0..only_file_name.len :0]);
    }

    // Color scheme
    const StyleCol = zgui.StyleCol;
    const style = zgui.getStyle();
    style.setColor(StyleCol.title_bg, [4]f32{ 0.1, 0.1, 0.1, 0.85 });
    style.setColor(StyleCol.title_bg_active, [4]f32{ 0.15, 0.15, 0.15, 0.9 });
    style.setColor(StyleCol.menu_bar_bg, [4]f32{ 0.1, 0.1, 0.1, 0.8 });
    style.setColor(StyleCol.header, [4]f32{ 0.1, 0.1, 0.1, 0.8 });
    style.setColor(StyleCol.check_mark, [4]f32{ 0, 1, 0, 1 });

    const pointing_hand = glfw.Cursor.createStandard(.pointing_hand) orelse return error.CreateCursorFailed;
    errdefer pointing_hand.destroy();
    const arrow = glfw.Cursor.createStandard(.arrow) orelse return error.CreateCursorFailed;
    errdefer arrow.destroy();
    const ibeam = glfw.Cursor.createStandard(.ibeam) orelse return error.CreateCursorFailed;
    errdefer ibeam.destroy();
    const crosshair = glfw.Cursor.createStandard(.crosshair) orelse return error.CreateCursorFailed;
    errdefer crosshair.destroy();
    const resize_ns = glfw.Cursor.createStandard(.resize_ns) orelse return error.CreateCursorFailed;
    errdefer resize_ns.destroy();
    const resize_ew = glfw.Cursor.createStandard(.resize_ew) orelse return error.CreateCursorFailed;
    errdefer resize_ew.destroy();
    const resize_nesw = glfw.Cursor.createStandard(.resize_nesw) orelse return error.CreateCursorFailed;
    errdefer resize_nesw.destroy();
    const resize_nwse = glfw.Cursor.createStandard(.resize_nwse) orelse return error.CreateCursorFailed;
    errdefer resize_nwse.destroy();
    const not_allowed = glfw.Cursor.createStandard(.not_allowed) orelse return error.CreateCursorFailed;
    errdefer not_allowed.destroy();

    // initialize our ecs api
    var storage = try Storage.init(allocator, .{ persistent_state, render_context });
    const scheduler = Scheduler.init();

    return Editor{
        .allocator = allocator,
        .pointing_hand = pointing_hand,
        .arrow = arrow,
        .ibeam = ibeam,
        .crosshair = crosshair,
        .resize_ns = resize_ns,
        .resize_ew = resize_ew,
        .resize_nesw = resize_nesw,
        .resize_nwse = resize_nwse,
        .not_allowed = not_allowed,
        .storage = storage,
        .scheduler = scheduler,
    };
}

pub fn exportToFile(self: *Editor, file_name: []const u8) !void {
    const ezby_stream = try ezby.serialize(Storage, self.allocator, self.storage, .{});
    defer self.allocator.free(ezby_stream);

    // TODO: this is an horrible idea since we don't know if the write will be sucessfull
    // delete file if it exist already
    std.fs.cwd().deleteFile(file_name) catch |err| switch (err) {
        error.FileNotFound => {}, // ok
        else => return err,
    };

    try std.fs.cwd().writeFile(file_name, ezby_stream);
}

pub fn importFromFile(self: *Editor, file_name: []const u8) !void {
    var scene_file = try std.fs.cwd().openFile(file_name, .{});
    defer scene_file.close();

    // prealloc file bytes
    const file_metadata = try scene_file.metadata();
    const file_bytes = try self.allocator.alloc(u8, file_metadata.size());
    defer self.allocator.free(file_bytes);

    // read file bytes
    const read_bytes_count = try scene_file.read(file_bytes);
    std.debug.assert(read_bytes_count == file_bytes.len);

    // deserialize bytes into the ecs storage
    try ezby.deserialize(Storage, &self.storage, file_bytes);

    // restart the render context to make sure all required instances has and appropriate handle
    var render_context = self.getRenderContext();
    render_context.clearInstancesRetainingCapacity();

    // this will make each render instance component get a new handle from the renderer
    self.scheduler.dispatchEvent(&self.storage, .on_import, .{}, .{});
    self.scheduler.waitEvent(.on_import);

    // propagate all the changes to the GPU
    try self.forceFlush();
}

pub fn newFrame(self: *Editor, window: glfw.Window, delta_time: f32) !void {
    const frame_size = window.getFramebufferSize();
    zgui.io.setDisplaySize(@as(f32, @floatFromInt(frame_size.width)), @as(f32, @floatFromInt(frame_size.height)));
    zgui.io.setDisplayFramebufferScale(1.0, 1.0);

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

    zgui.newFrame();
    { // imgui render block
        defer zgui.render();

        zgui.io.setDeltaTime(delta_time);

        // var b = true;
        // _ = zgui.showDemoWindow(&b);

        // define editor header
        const header_height = blk1: {
            if (zgui.beginMainMenuBar() == false) {
                break :blk1 0;
            }
            defer zgui.endMainMenuBar();

            if (zgui.beginMenu("File", true)) {
                defer zgui.endMenu();

                if (zgui.menuItem("Export", .{})) {
                    var persistent_state = self.getPersitentState();
                    persistent_state.export_file_modal_popen = true;
                }

                if (zgui.menuItem("Import", .{})) {
                    var persistent_state = self.getPersitentState();
                    persistent_state.import_file_modal_popen = true;
                }

                if (zgui.menuItem("Load new model", .{})) {
                    std.debug.print("load new model", .{}); // TODO: load new model
                }
            }

            if (zgui.beginMenu("Window", true)) {
                defer zgui.endMenu();

                // TODO: array that defines each window, loop them here to make them toggleable
                if (zgui.menuItem("Object list", .{})) {
                    std.debug.print("object list", .{}); // TODO: toggle object list window
                }

                if (zgui.menuItem("Debug log", .{})) {
                    std.debug.print("debug log", .{}); // TODO: toggle debug log window
                }
            }

            if (zgui.beginMenu("Objects", true)) {
                defer zgui.endMenu();

                try self.createNewEntityMenu();
            }

            break :blk1 zgui.getWindowHeight();
        };

        // export scene to file modal
        {
            var persistent_state = self.getPersitentState();
            if (persistent_state.export_file_modal_popen) {
                zgui.openPopup("Export Modal", .{});
            }

            if (zgui.beginPopupModal("Export Modal", .{ .flags = .{ .always_auto_resize = true } })) {
                defer zgui.endPopup();

                zgui.text("File name: ", .{});
                if (zgui.inputText("##export_file_name", .{
                    .buf = &persistent_state.export_import_file_name,
                    .flags = .{},
                })) {}
                zgui.sameLine(.{});
                marker("File name should have the extension '.ezby',\nbut it is not required", .hint);

                zgui.setItemDefaultFocus();
                if (zgui.button("Export scene", .{})) {
                    const file_name_len = std.mem.indexOf(u8, &persistent_state.export_import_file_name, &[_]u8{0}).?;
                    // TODO: show error as a modal
                    try self.exportToFile(persistent_state.export_import_file_name[0..file_name_len]);
                    persistent_state.export_file_modal_popen = false;
                    zgui.closeCurrentPopup();
                }
                zgui.sameLine(.{});
                if (zgui.button("Cancel##export_modal", .{ .w = 120, .h = 0 })) {
                    persistent_state.export_file_modal_popen = false;
                    zgui.closeCurrentPopup();
                }
            }
        }

        // import scene to file modal
        {
            var persistent_state = self.getPersitentState();
            if (persistent_state.import_file_modal_popen) {
                zgui.openPopup("Import Modal", .{});
            }

            if (zgui.beginPopupModal("Import Modal", .{ .flags = .{ .always_auto_resize = true } })) {
                defer zgui.endPopup();

                zgui.text("File name: ", .{});
                if (zgui.inputText("##import_file_name", .{
                    .buf = &persistent_state.export_import_file_name,
                    .flags = .{},
                })) {}

                zgui.setItemDefaultFocus();
                if (zgui.button("Import scene", .{})) {
                    const file_name_len = std.mem.indexOf(u8, &persistent_state.export_import_file_name, &[_]u8{0}).?;
                    // TODO: show error as a modal
                    try self.importFromFile(persistent_state.export_import_file_name[0..file_name_len]);
                    persistent_state.import_file_modal_popen = false;
                    zgui.closeCurrentPopup();
                }
                zgui.sameLine(.{});
                if (zgui.button("Cancel##import_modal", .{ .w = 120, .h = 0 })) {
                    persistent_state.import_file_modal_popen = false;
                    zgui.closeCurrentPopup();
                }
            }
        }

        // define Object List
        {
            const width = @as(f32, @floatFromInt(frame_size.width)) / 6;

            zgui.setNextWindowSize(.{ .w = width, .h = @as(f32, @floatFromInt(frame_size.height)), .cond = .always });
            zgui.setNextWindowPos(.{ .x = 0, .y = header_height, .cond = .always });
            _ = zgui.begin("Object List", .{ .popen = null, .flags = .{
                .menu_bar = false,
                .no_move = true,
                .no_resize = false,
                .no_scrollbar = false,
                .no_scroll_with_mouse = false,
                .no_collapse = true,
            } });
            defer zgui.end();

            {
                // TODO: only have this if none of the selectables are hovered
                //       also have object related popup with actions: delete, copy, more? ... ?
                if (zgui.beginPopupContextWindow()) {
                    defer zgui.endPopup();

                    try self.createNewEntityMenu();
                }

                const ObjectListQuery = Storage.Query(
                    struct {
                        entity: ecez.Entity,
                        metadata: *ObjectMetadata,
                    },
                    .{},
                );

                var list_item_iter = ObjectListQuery.submit(&self.storage);

                var persistent_state = self.getPersitentState();
                while (list_item_iter.next()) |list_item| {
                    const selected_entity_id = blk: {
                        // selected entity is either our persistent user selction, or an invalid/unlikely InstanceHandle.
                        if (persistent_state.selected_entity) |selected_entity| {
                            break :blk selected_entity.id;
                        } else {
                            const invalid_entity_id: ecez.EntityId = std.math.maxInt(ecez.EntityId);
                            break :blk @as(ecez.EntityId, @bitCast(invalid_entity_id));
                        }
                    };

                    // if user is renaming the selectable
                    if (persistent_state.object_list.renaming_entity and list_item.entity.id == selected_entity_id) {

                        // make sure the user can start typing as soon as they initiate renaming
                        if (persistent_state.object_list.first_rename_draw) {
                            zgui.setKeyboardFocusHere(0);
                            persistent_state.object_list.first_rename_draw = false;
                        }

                        if (zgui.inputText("##object_list_rename", .{
                            .buf = &persistent_state.object_list.renaming_buffer,
                            .flags = .{ .enter_returns_true = true },
                        })) {
                            const new_len = std.mem.indexOf(u8, &persistent_state.object_list.renaming_buffer, &[_]u8{0}).?;

                            if (new_len > 0) {
                                list_item.metadata.rename(persistent_state.object_list.renaming_buffer[0..new_len]);

                                // set object name field to current selection
                                const display_name = list_item.metadata.getDisplayName();
                                std.mem.copy(u8, &persistent_state.object_inspector.name_buffer, display_name);
                                persistent_state.object_inspector.name_buffer[display_name.len] = 0;

                                persistent_state.object_list.renaming_entity = false;
                                @memset(&persistent_state.object_list.renaming_buffer, 0);
                            }
                        }
                    } else {
                        if (zgui.selectable(list_item.metadata.getId(), .{
                            .selected = list_item.entity.id == selected_entity_id,
                            .flags = .{ .allow_double_click = true },
                        })) {
                            // set object name field to current selection
                            const display_name = list_item.metadata.getDisplayName();
                            std.mem.copy(u8, &persistent_state.object_inspector.name_buffer, display_name);

                            // Set index to a non existing index. This makes no object selected
                            persistent_state.object_inspector.selected_component_index = fake_components.len;
                            persistent_state.object_inspector.name_buffer[display_name.len] = 0;

                            persistent_state.object_list.first_rename_draw = true;
                            persistent_state.object_list.renaming_entity = zgui.isItemHovered(.{}) and zgui.isMouseDoubleClicked(zgui.MouseButton.left);
                            persistent_state.selected_entity = list_item.entity;
                        }
                    }
                }
            }
        }

        // define Object Inspector
        {
            const width = @as(f32, @floatFromInt(frame_size.width)) / 6;

            zgui.setNextWindowSize(.{ .w = width, .h = @as(f32, @floatFromInt(frame_size.height)), .cond = .always });
            zgui.setNextWindowPos(.{ .x = @as(f32, @floatFromInt(frame_size.width)) - width, .y = header_height, .cond = .always });
            _ = zgui.begin("Object Inspector", .{ .popen = null, .flags = .{
                .menu_bar = false,
                .no_move = true,
                .no_resize = false,
                .no_scrollbar = false,
                .no_scroll_with_mouse = false,
                .no_collapse = true,
            } });
            defer zgui.end();

            var persistent_state = self.getPersitentState();
            if (persistent_state.selected_entity) |selected_entity| {
                zgui.text("Name: ", .{});
                zgui.sameLine(.{});
                if (zgui.inputText("##object_inspector_rename", .{
                    .buf = &persistent_state.object_inspector.name_buffer,
                    .flags = .{ .enter_returns_true = true },
                })) {
                    const new_len = std.mem.indexOf(u8, &persistent_state.object_inspector.name_buffer, &[_]u8{0}).?;

                    if (new_len > 0) {
                        var metadata = try self.storage.getComponent(selected_entity, ObjectMetadata);
                        metadata.rename(persistent_state.object_inspector.name_buffer[0..new_len]);
                        try self.storage.setComponent(selected_entity, metadata);
                    }
                }

                zgui.separator();

                zgui.text("Component list: ", .{});
                if (zgui.beginListBox("##component list", .{ .w = -std.math.floatMin(f32), .h = 0 })) {
                    defer zgui.endListBox();

                    inline for (fake_components, 0..) |Component, comp_index| {
                        if (self.storage.hasComponent(selected_entity, Component)) {
                            if (zgui.selectable(@typeName(Component), .{ .selected = comp_index == persistent_state.object_inspector.selected_component_index })) {
                                persistent_state.object_inspector.selected_component_index = comp_index;
                            }
                        }
                    }
                }

                // add component UI
                {
                    if (zgui.button("Add", .{})) {
                        persistent_state.add_component_modal.is_active = true;
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
                        inline for (fake_components, 0..) |Component, comp_index| {
                            // you can never add a ObjectMetadata
                            if (Component == ObjectMetadata) continue;

                            if (self.storage.hasComponent(selected_entity, Component) == false) {
                                // if the component index is not set, then we set it to current component index
                                if (persistent_state.add_component_modal.selected_component_index == fake_components.len) {
                                    persistent_state.add_component_modal.selected_component_index = comp_index;
                                }

                                if (zgui.selectable(@typeName(Component), .{
                                    .selected = comp_index == persistent_state.add_component_modal.selected_component_index,
                                    .flags = .{ .dont_close_popups = true },
                                })) {
                                    persistent_state.add_component_modal.selected_component_index = comp_index;
                                    @memset(&persistent_state.add_component_modal.component_bytes, 0);
                                }
                            }
                        }

                        // Menu to set the initial value of selected component
                        {
                            zgui.separator();

                            // List of components that you can add
                            inline for (fake_components, 0..) |Component, comp_index| {
                                if (Component == ObjectMetadata) continue;

                                if (comp_index == persistent_state.add_component_modal.selected_component_index) {
                                    zgui.text("{s}:", .{@typeName(Component)});

                                    const component_ptr: *Component = blk: {
                                        // @setRuntimeSafety(false);
                                        const ptr = std.mem.bytesAsValue(Component, persistent_state.add_component_modal.component_bytes[0..@sizeOf(Component)]);
                                        break :blk @alignCast(ptr);
                                    };

                                    // if component has specialized widget
                                    if (overrideWidgetGenerator(Component)) |Override| {
                                        // call manually implemented widget
                                        _ = Override.widget(self, component_ptr);
                                    } else {
                                        // .. or generated widget
                                        _ = componentWidget(Component, component_ptr);
                                    }
                                }
                            }
                            zgui.separator();
                        }

                        if (zgui.button("Add component", .{ .w = 120, .h = 0 })) {
                            // Add component to entity
                            inline for (fake_components, 0..) |Component, comp_index| {
                                if (Component == ObjectMetadata) continue;

                                if (comp_index == persistent_state.add_component_modal.selected_component_index) {
                                    const component = @as(
                                        *Component,
                                        @ptrCast(@alignCast(&persistent_state.add_component_modal.component_bytes)),
                                    );

                                    if (specializedAddHandle(Component)) |add_handle| {
                                        try add_handle.add(self, component);
                                    } else {
                                        try self.storage.setComponent(selected_entity, component.*);
                                    }

                                    try self.forceFlush();
                                }
                            }

                            persistent_state.add_component_modal.selected_component_index = fake_components.len;
                            persistent_state.add_component_modal.is_active = false;
                            zgui.closeCurrentPopup();
                        }
                        zgui.sameLine(.{});
                        marker("Remember to set ALL values to something valid", .warning);

                        zgui.setItemDefaultFocus();
                        zgui.sameLine(.{});
                        if (zgui.button("Cancel", .{ .w = 120, .h = 0 })) {
                            persistent_state.add_component_modal.selected_component_index = fake_components.len;
                            persistent_state.add_component_modal.is_active = false;
                            zgui.closeCurrentPopup();
                        }
                    }
                }
                zgui.sameLine(.{});

                {
                    const object_metadata_selected = object_metadata_index == persistent_state.object_inspector.selected_component_index;
                    const nothing_selected = persistent_state.object_inspector.selected_component_index == fake_components.len;
                    zgui.beginDisabled(.{
                        .disabled = object_metadata_selected or nothing_selected,
                    });
                    defer zgui.endDisabled();

                    if (zgui.button("Remove", .{})) {
                        inline for (fake_components, 0..) |Component, comp_index| {
                            // deleting the metadata of an entity is illegal
                            if (Component != ObjectMetadata and comp_index == persistent_state.object_inspector.selected_component_index) {
                                if (specializedRemoveHandle(Component)) |remove_handle| {
                                    try remove_handle.remove(self);
                                } else {
                                    // In the event a remove failed, then the select index is in a inconsistent state
                                    // and we do not really have to do anything
                                    self.storage.removeComponent(selected_entity, Component) catch {
                                        // TODO: log here in debug builds
                                    };
                                }

                                // assign selection an invalid index
                                // TODO: Selection should be persistent when removing current component
                                persistent_state.object_inspector.selected_component_index = fake_components.len;
                            }
                        }
                    }
                }

                zgui.separator();
                zgui.text("Component widgets:", .{});
                comp_iter: inline for (fake_components) |Component| {
                    if (Component == ObjectMetadata) {
                        continue :comp_iter;
                    }

                    if (self.storage.hasComponent(selected_entity, Component)) {
                        zgui.separator();
                        zgui.text("{s}:", .{@typeName(Component)});

                        var component = self.storage.getComponent(selected_entity, Component) catch unreachable;
                        var changed = false;
                        // if component has specialized widget
                        if (overrideWidgetGenerator(Component)) |Override| {
                            // call manually implemented widget
                            changed = Override.widget(self, &component);
                        } else {
                            // .. or generated widget
                            changed = componentWidget(Component, &component);
                        }

                        if (changed) {
                            try self.storage.setComponent(selected_entity, component);
                            try self.forceFlush();
                        }

                        zgui.separator();
                    }
                }
            }
        }
    }

    var render_context = self.getRenderContext();
    try render_context.drawFrame(window, delta_time);
}

pub fn deinit(self: *Editor) void {
    self.scheduler.waitIdle();

    const persistent_state = self.getPersitentState();
    for (persistent_state.mesh_names.values()) |mesh_name| {
        self.allocator.free(mesh_name);
    }
    persistent_state.mesh_names.deinit();

    self.pointing_hand.destroy();
    self.arrow.destroy();
    self.ibeam.destroy();
    self.crosshair.destroy();
    self.resize_ns.destroy();
    self.resize_ew.destroy();
    self.resize_nesw.destroy();
    self.resize_nwse.destroy();
    self.not_allowed.destroy();

    self.getRenderContext().deinit(self.allocator);
    self.storage.deinit();
}

pub fn handleFramebufferResize(self: *Editor, window: glfw.Window) void {
    var render_context = self.getRenderContext();
    render_context.handleFramebufferResize(window);
}

/// register input so only editor handles glfw input
pub fn setEditorInput(self: Editor, window: glfw.Window) void {
    _ = self;
    _ = window.setKeyCallback(keyCallback);
    _ = window.setCharCallback(charCallback);
    _ = window.setMouseButtonCallback(mouseButtonCallback);
    _ = window.setCursorPosCallback(cursorPosCallback);
    _ = window.setScrollCallback(scrollCallback);
}

pub fn keyCallback(window: glfw.Window, key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) void {
    _ = window;
    _ = scancode;

    // apply modifiers
    zgui.io.addKeyEvent(zgui.Key.mod_shift, mods.shift);
    zgui.io.addKeyEvent(zgui.Key.mod_ctrl, mods.control);
    zgui.io.addKeyEvent(zgui.Key.mod_alt, mods.alt);
    zgui.io.addKeyEvent(zgui.Key.mod_super, mods.super);
    // zgui.addKeyEvent(zgui.Key.mod_caps_lock, mod.caps_lock);
    // zgui.addKeyEvent(zgui.Key.mod_num_lock, mod.num_lock);

    zgui.io.addKeyEvent(mapGlfwKeyToImgui(key), action == .press);
}

pub fn charCallback(window: glfw.Window, codepoint: u21) void {
    _ = window;

    var buffer: [8]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, buffer[0..]) catch return;
    const cstr = buffer[0 .. len + 1];
    cstr[len] = 0; // null terminator
    zgui.io.addInputCharactersUTF8(@as([*:0]const u8, @ptrCast(cstr.ptr)));
}

pub fn mouseButtonCallback(window: glfw.Window, button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) void {
    _ = window;

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

pub fn cursorPosCallback(window: glfw.Window, xpos: f64, ypos: f64) void {
    _ = window;

    zgui.io.addMousePositionEvent(@as(f32, @floatCast(xpos)), @as(f32, @floatCast(ypos)));
}

pub fn scrollCallback(window: glfw.Window, xoffset: f64, yoffset: f64) void {
    _ = window;

    zgui.io.addMouseWheelEvent(@as(f32, @floatCast(xoffset)), @as(f32, @floatCast(yoffset)));
}

pub fn getNthMeshHandle(self: *Editor, nth: usize) MeshHandle {
    return self.getRenderContext().getNthMeshHandle(nth);
}

pub fn newSceneEntity(self: *Editor, name: []const u8) !ecez.Entity {
    const entity = try self.storage.createEntity(.{});
    var metadata = ObjectMetadata.init(name, entity);
    try self.storage.setComponent(entity, metadata);

    return entity;
}

/// This function retrieves a instance handle from the renderer and assigns it to the argument entity
pub fn assignEntityMeshInstance(self: *Editor, entity: ecez.Entity, mesh_handle: MeshHandle) !void {
    if (self.storage.hasComponent(entity, InstanceHandle)) {
        return error.EntityAlreadyHasInstance;
    }

    var render_context = self.getRenderContext();
    const new_instance = render_context.getNewInstance(mesh_handle) catch |err| {
        // if this fails we will end in an inconsistent state!
        std.debug.panic("attemped to get new instance {d} failed with error {any}", .{ mesh_handle, err });
    };

    try self.storage.setComponent(entity, new_instance);
}

pub fn renameEntity(self: *Editor, entity: ecez.Entity, name: []const u8) !void {
    var metadata = try self.storage.getComponent(entity, ObjectMetadata);
    metadata.rename(name);
    try self.storage.setComponent(entity, metadata);
}

pub fn getMeshNames(self: *Editor) []const [:0]const u8 {
    const persistent_state = self.getPersitentState();
    return persistent_state.mesh_names.values();
}

pub fn signalRenderUpdate(self: *Editor) void {
    var render_context = self.getRenderContext();
    render_context.signalUpdate();
}

/// Wether createNewVisbleObject should update all transforms and submit all scene object
/// state to the GPU
pub const FlushAllObjects = enum(u1) {
    yes,
    no,
};
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
    nth_mesh: usize,
    comptime flush_all_objects: FlushAllObjects,
    config: VisibleObjectConfig,
) !void {
    const new_entity = try self.newSceneEntity(object_name);
    const mesh_handle = self.getNthMeshHandle(nth_mesh);
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
    // new visible object must have a transform component to be visible in the scene
    try self.storage.setComponent(new_entity, Editor.Transform{ .mat = undefined });

    // Make sure editor updates renderer after we have set some render state programatically.
    // This is highly sub-optimal and should not be done in any hot loop
    if (flush_all_objects == .yes) {
        try self.forceFlush();
    }
}

fn forceFlush(self: *Editor) !void {
    self.scheduler.dispatchEvent(&self.storage, .transform_update, .{}, .{});
    self.scheduler.waitEvent(.transform_update);
    self.signalRenderUpdate();
}

/// Display imgui menu with a list of options for a new entity
/// The new entity can either be a empty entity (only contain editor metadata)
/// or be a visible object in the scene by selecting the desired mesh for the new entity
inline fn createNewEntityMenu(self: *Editor) !void {
    if (zgui.beginMenu("Create new", true)) {
        defer zgui.endMenu();

        if (zgui.menuItem("empty entity", .{})) {
            _ = try self.newSceneEntity("empty entity");
        }

        const mesh_names = self.getMeshNames();
        for (mesh_names, 0..) |mesh_name, nth_mesh| {
            if (zgui.menuItem(mesh_name, .{})) {
                try self.createNewVisbleObject(mesh_name, nth_mesh, .yes, .{});
            }
        }
    }
}

inline fn getRenderContext(self: *Editor) *RenderContext {
    return @ptrCast(self.storage.getSharedStatePtrWithSharedStateType(*ecez.SharedState(RenderContext)));
}

inline fn getPersitentState(self: *Editor) *PersistentState {
    return @ptrCast(self.storage.getSharedStatePtrWithSharedStateType(*ecez.SharedState(PersistentState)));
}

const MarkerType = enum {
    warning,
    hint,
};
inline fn marker(message: []const u8, marker_type: MarkerType) void {
    const marker_txt = switch (marker_type) {
        .warning => "(!)",
        .hint => "(?)",
    };
    zgui.textDisabled(marker_txt, .{});
    if (zgui.isItemHovered(.{})) {
        if (zgui.beginTooltip()) {
            defer zgui.endTooltip();

            zgui.pushTextWrapPos(zgui.getFontSize() * 35);
            zgui.textUnformatted(message);
            zgui.popTextWrapPos();
        }
    }
}

inline fn mapGlfwKeyToImgui(key: glfw.Key) zgui.Key {
    return switch (key) {
        .unknown => zgui.Key.none,
        .space => zgui.Key.space,
        .apostrophe => zgui.Key.apostrophe,
        .comma => zgui.Key.comma,
        .minus => zgui.Key.minus,
        .period => zgui.Key.period,
        .slash => zgui.Key.slash,
        .zero => zgui.Key.zero,
        .one => zgui.Key.one,
        .two => zgui.Key.two,
        .three => zgui.Key.three,
        .four => zgui.Key.four,
        .five => zgui.Key.five,
        .six => zgui.Key.six,
        .seven => zgui.Key.seven,
        .eight => zgui.Key.eight,
        .nine => zgui.Key.nine,
        .semicolon => zgui.Key.semicolon,
        .equal => zgui.Key.equal,
        .a => zgui.Key.a,
        .b => zgui.Key.b,
        .c => zgui.Key.c,
        .d => zgui.Key.d,
        .e => zgui.Key.e,
        .f => zgui.Key.f,
        .g => zgui.Key.g,
        .h => zgui.Key.h,
        .i => zgui.Key.i,
        .j => zgui.Key.j,
        .k => zgui.Key.k,
        .l => zgui.Key.l,
        .m => zgui.Key.m,
        .n => zgui.Key.n,
        .o => zgui.Key.o,
        .p => zgui.Key.p,
        .q => zgui.Key.q,
        .r => zgui.Key.r,
        .s => zgui.Key.s,
        .t => zgui.Key.t,
        .u => zgui.Key.u,
        .v => zgui.Key.v,
        .w => zgui.Key.w,
        .x => zgui.Key.x,
        .y => zgui.Key.y,
        .z => zgui.Key.z,
        .left_bracket => zgui.Key.left_bracket,
        .backslash => zgui.Key.back_slash,
        .right_bracket => zgui.Key.right_bracket,
        .grave_accent => zgui.Key.grave_accent,
        .world_1 => zgui.Key.none, // ????
        .world_2 => zgui.Key.none, // ????
        .escape => zgui.Key.escape,
        .enter => zgui.Key.enter,
        .tab => zgui.Key.tab,
        .backspace => zgui.Key.back_space,
        .insert => zgui.Key.insert,
        .delete => zgui.Key.delete,
        .right => zgui.Key.right_arrow,
        .left => zgui.Key.left_arrow,
        .down => zgui.Key.down_arrow,
        .up => zgui.Key.up_arrow,
        .page_up => zgui.Key.page_up,
        .page_down => zgui.Key.page_down,
        .home => zgui.Key.home,
        .end => zgui.Key.end,
        .caps_lock => zgui.Key.caps_lock,
        .scroll_lock => zgui.Key.scroll_lock,
        .num_lock => zgui.Key.num_lock,
        .print_screen => zgui.Key.print_screen,
        .pause => zgui.Key.pause,
        .F1 => zgui.Key.f1,
        .F2 => zgui.Key.f2,
        .F3 => zgui.Key.f3,
        .F4 => zgui.Key.f4,
        .F5 => zgui.Key.f5,
        .F6 => zgui.Key.f6,
        .F7 => zgui.Key.f7,
        .F8 => zgui.Key.f8,
        .F9 => zgui.Key.f9,
        .F10 => zgui.Key.f10,
        .F11 => zgui.Key.f11,
        .F12 => zgui.Key.f12,
        .F13,
        .F14,
        .F15,
        .F16,
        .F17,
        .F18,
        .F19,
        .F20,
        .F21,
        .F22,
        .F23,
        .F24,
        .F25,
        => zgui.Key.none,
        .kp_0 => zgui.Key.keypad_0,
        .kp_1 => zgui.Key.keypad_1,
        .kp_2 => zgui.Key.keypad_2,
        .kp_3 => zgui.Key.keypad_3,
        .kp_4 => zgui.Key.keypad_4,
        .kp_5 => zgui.Key.keypad_5,
        .kp_6 => zgui.Key.keypad_6,
        .kp_7 => zgui.Key.keypad_7,
        .kp_8 => zgui.Key.keypad_8,
        .kp_9 => zgui.Key.keypad_9,
        .kp_decimal => zgui.Key.keypad_decimal,
        .kp_divide => zgui.Key.keypad_divide,
        .kp_multiply => zgui.Key.keypad_multiply,
        .kp_subtract => zgui.Key.keypad_subtract,
        .kp_add => zgui.Key.keypad_add,
        .kp_enter => zgui.Key.keypad_enter,
        .kp_equal => zgui.Key.keypad_equal,
        .left_shift => zgui.Key.left_shift,
        .left_control => zgui.Key.left_ctrl,
        .left_alt => zgui.Key.left_alt,
        .left_super => zgui.Key.left_super,
        .right_shift => zgui.Key.right_shift,
        .right_control => zgui.Key.right_ctrl,
        .right_alt => zgui.Key.right_alt,
        .right_super => zgui.Key.right_super,
        .menu => zgui.Key.menu,
    };
}

// source: https://en.wikipedia.org/wiki/Conversion_between_quaternions_and_Euler_angles
inline fn quaternionToEuler(q: zm.Quat) zm.F32x4 {
    // double sinr_cosp = 2 * (q.w * q.x + q.y * q.z);
    const sinr_cosp = 2 * (q[3] * q[0] + q[1] * q[2]);
    // double cosr_cosp = 1 - 2 * (q.x * q.x + q.y * q.y);
    const cosr_cosp = 1 - 2 * (q[0] * q[0] + q[1] * q[1]);

    // double sinp = std::sqrt(1 + 2 * (q.w * q.y - q.x * q.z))
    const sinp = @sqrt(1 + 2 * (q[3] * q[1] - q[0] * q[2]));
    // double cosp = std::sqrt(1 - 2 * (q.w * q.y - q.x * q.z))
    const cosp = @sqrt(1 - 2 * (q[3] * q[1] - q[0] * q[2]));

    // double siny_cosp = 2 * (q.w * q.z + q.x * q.y);
    const siny_cosp = 2 * (q[3] * q[2] + q[0] * q[1]);
    // double cosy_cosp = 1 - 2 * (q.y * q.y + q.z * q.z);
    const cosy_cosp = 1 - 2 * (q[1] * q[1] + q[2] * q[2]);

    // return angles;
    return zm.f32x4(
        // angles.roll = std::atan2(sinr_cosp, cosr_cosp);
        std.math.atan2(f32, sinr_cosp, cosr_cosp), // x rotation
        // angles.pitch = 2 * std::atan2(sinp, cosp) - M_PI / 2;
        (-std.math.pi / 2.0) + 2 * std.math.atan2(f32, sinp, cosp), // y rotation
        // angles.yaw = std::atan2(siny_cosp, cosy_cosp);
        std.math.atan2(f32, siny_cosp, cosy_cosp), // z rotation
        0,
    );
}
