const std = @import("std");
const Allocator = std.mem.Allocator;

const ecez = @import("ecez");

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
    entity: ecez.Entity,

    id_len: u8,
    buffer: [64]u8,

    inline fn init(name: []const u8, entity: ecez.Entity) ObjectMetadata {
        const hash_fluff = "##" ++ [_]u8{
            @intCast(u8, (entity.id) & 0xFF),
            @intCast(u8, ((entity.id) >> 8) & 0xFF),
            @intCast(u8, ((entity.id) >> 16) & 0xFF),
            @intCast(u8, ((entity.id) >> 24) & 0xFF),
        };
        var buffer: [64]u8 = undefined;
        const id_len = name.len + hash_fluff.len;
        std.debug.assert(buffer.len > id_len);

        std.mem.copy(u8, buffer[0..], name);
        std.mem.copy(u8, buffer[name.len..], hash_fluff);
        buffer[id_len] = 0;

        return ObjectMetadata{
            .entity = entity,
            .id_len = @intCast(u8, id_len),
            .buffer = buffer,
        };
    }

    inline fn rename(self: *ObjectMetadata, name: []const u8) void {
        const hash_fluff = "##" ++ [_]u8{
            @intCast(u8, (self.entity.id) & 0xFF),
            @intCast(u8, ((self.entity.id) >> 8) & 0xFF),
            @intCast(u8, ((self.entity.id) >> 16) & 0xFF),
            @intCast(u8, ((self.entity.id) >> 24) & 0xFF),
        };
        const id_len = name.len + hash_fluff.len;
        std.debug.assert(self.buffer.len > id_len);

        std.mem.copy(u8, self.buffer[0..], name);
        std.mem.copy(u8, self.buffer[name.len..], hash_fluff);
        self.buffer[id_len] = 0;
        self.id_len = @intCast(u8, id_len);
    }

    pub inline fn getId(self: ObjectMetadata) [:0]const u8 {
        return self.buffer[0..self.id_len :0];
    }

    pub inline fn getDisplayName(self: ObjectMetadata) []const u8 {
        // name - "##xyzw"
        return self.buffer[0 .. self.id_len - 6];
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
    inline for (fake_components) |Component, component_index| {
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

                if (zgui.beginCombo("Mesh", .{ .preview_value = persistent_state.mesh_names[persistent_state.instance_handle_widget.selected_mesh_index] })) {
                    defer zgui.endCombo();

                    for (persistent_state.mesh_names[0..persistent_state.mesh_names_len]) |mesh_name, mesh_index| {
                        if (zgui.selectable(mesh_name, .{
                            .selected = persistent_state.instance_handle_widget.selected_mesh_index == mesh_index,
                        })) {
                            persistent_state.instance_handle_widget.selected_mesh_index = mesh_index;
                            instance_handle.mesh_handle = editor.getNthMeshHandle(mesh_index);
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

                try editor.assignEntityMeshInstance(persistent_state.selected_entity.?, instance_handle.mesh_handle);
            }
        },
        else => null,
    };
}

// TODO: it would be nicer here to use PeristentState as event data because it is easier to see when it is changed by systems
/// Generate the entries of the object list depending on objects in the scene
pub fn objectListSystem(metadata: *ObjectMetadata, persistent_state: *ecez.SharedState(PersistentState)) void {
    const selected_entity_id = blk: {
        // selected entity is either our persistent user selction, or an invalid/unlikely InstanceHandle.
        if (persistent_state.selected_entity) |entity| {
            break :blk entity.id;
        } else {
            const invalid_entity_id: ecez.EntityId = std.math.maxInt(ecez.EntityId);
            break :blk @bitCast(ecez.EntityId, invalid_entity_id);
        }
    };
    // if user is renaming the selectable
    if (persistent_state.object_list.renaming_entity and metadata.entity.id == selected_entity_id) {

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
                metadata.rename(persistent_state.object_list.renaming_buffer[0..new_len]);

                // set object name field to current selection
                const display_name = metadata.getDisplayName();
                std.mem.copy(u8, &persistent_state.object_inspector.name_buffer, display_name);
                persistent_state.object_inspector.name_buffer[display_name.len] = 0;

                persistent_state.object_list.renaming_entity = false;
                std.mem.set(u8, &persistent_state.object_list.renaming_buffer, 0);
            }
        }
    } else {
        if (zgui.selectable(metadata.getId(), .{
            .selected = metadata.entity.id == selected_entity_id,
            .flags = .{ .allow_double_click = true },
        })) {
            // set object name field to current selection
            const display_name = metadata.getDisplayName();
            std.mem.copy(u8, &persistent_state.object_inspector.name_buffer, display_name);

            // Set index to a non existing index. This makes no object selected
            persistent_state.object_inspector.selected_component_index = fake_components.len;
            persistent_state.object_inspector.name_buffer[display_name.len] = 0;

            persistent_state.object_list.first_rename_draw = true;
            persistent_state.object_list.renaming_entity = zgui.isItemHovered(.{}) and zgui.isMouseDoubleClicked(zgui.MouseButton.left);
            persistent_state.selected_entity = metadata.entity;
        }
    }
}

// TODO: Doing these things for all enitites in the scene is extremely inneficient
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
    pub fn propagateToRenderer(instance_handle: InstanceHandle, transform: Transform, render_context: *ecez.SharedState(RenderContext)) void {
        var _render_context = @ptrCast(*RenderContext, render_context);
        _render_context.setInstanceTransform(instance_handle, transform.mat);
    }
};

fn componentWidget(comptime T: type, component: *T) bool {
    var component_changed = false;

    const component_info = switch (@typeInfo(T)) {
        .Struct => |info| info,
        else => @compileError("invalid component type"),
    };

    inline for (component_info.fields) |field, i| {
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
            var value = @intCast(i32, field.*);
            if (zgui.inputInt(c_id, .{ .v = &value })) {
                field.* = @intCast(T, value);
                field_changed = true;
            }
        },
        .Float => {
            var value = @intCast(f32, field.*);
            if (zgui.inputFloat(c_id, .{ .v = &value })) {
                field.* = @intCast(T, value);
                field_changed = true;
            }
        },
        .Array => |array_info| {
            switch (@typeInfo(array_info.child)) {
                .Float => {
                    var values: [array_info.len]f32 = undefined;
                    for (values) |*value, j| {
                        value.* = @floatCast(f32, field.*[j]);
                    }

                    var array_input = false;
                    switch (array_info.len) {
                        1 => {
                            var value = @intCast(f32, field.*);
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
                        for (values) |value, j| {
                            field.*[j] = @floatCast(array_info.child, value);
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
                        for (values) |*value, j| {
                            value.* = @floatCast(i32, field.*[j]);
                        }

                        var array_input = false;
                        switch (array_info.len) {
                            1 => {
                                var value = @intCast(i32, field.*);
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
                            for (values) |value, j| {
                                field.*[j] = @floatCast(array_info.child, value);
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
                    for (values) |*value, j| {
                        value.* = @floatCast(f32, field.*[j]);
                    }

                    if (fieldWidget(Component, @TypeOf(values), id_mod << 1, &values)) {
                        for (values) |value, j| {
                            field.*[j] = value;
                        }

                        field_changed = true;
                    }
                },
                .Int => {
                    var values: [vec_info.len]i32 = undefined;
                    for (values) |*value, j| {
                        value.* = @floatCast(i32, field.*[j]);
                    }

                    if (fieldWidget(Component, @TypeOf(values), id_mod << 1, &values)) {
                        for (values) |value, j| {
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
        renaming_buffer: [64]u8,
        first_rename_draw: bool,
        renaming_entity: bool,
    };

    const ObjectInspector = struct {
        name_buffer: [64]u8,
        selected_component_index: usize,
    };

    const AddComponentModal = struct {
        selected_component_index: usize = fake_components.len,
        component_bytes: [biggest_component_size]u8 = undefined,
    };

    const InstanceHandleWidget = struct {
        // add component: InstanceHandle state
        selected_mesh_index: usize,
    };

    // common state
    selected_entity: ?ecez.Entity,
    mesh_names_len: usize,
    mesh_names: [128][:0]const u8,
    selected_mesh_index: usize,

    object_list: ObjectList,
    object_inspector: ObjectInspector,
    add_component_modal: AddComponentModal,
    instance_handle_widget: InstanceHandleWidget,
};

const World = ecez.WorldBuilder().WithComponents(.{
    // TODO: generate this!
    fake_components[0],
    fake_components[1],
    fake_components[2],
    fake_components[3],
    fake_components[4],
    fake_components[5],
}).WithSharedState(.{
    PersistentState,
    RenderContext,
}).WithEvents(.{
    // event to draw all objects in the scene as an item in a list
    ecez.Event("draw_object_list", .{objectListSystem}, .{}),
    // event to apply all transformation and update render buffers as needed
    ecez.Event("transform_update", .{
        TransformSystems.reset,
        ecez.DependOn(TransformSystems.applyScale, .{TransformSystems.reset}),
        ecez.DependOn(TransformSystems.applyRotation, .{TransformSystems.applyScale}),
        ecez.DependOn(TransformSystems.applyPosition, .{TransformSystems.applyRotation}),
        ecez.DependOn(TransformSystems.propagateToRenderer, .{TransformSystems.applyPosition}),
    }, .{}),
}).Build();

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

ecs: World,

pub fn init(allocator: Allocator, window: glfw.Window, mesh_instance_initalizers: []const MeshInstancehInitializeContex) !Editor {
    var render_context = try RenderContext.init(allocator, window, mesh_instance_initalizers, .{
        .update_rate = .manually,
    });
    errdefer render_context.deinit(allocator);

    var persistent_state = PersistentState{
        .selected_entity = null,
        .mesh_names_len = 0,
        .mesh_names = undefined,
        .selected_mesh_index = 0,
        .object_list = .{
            .renaming_buffer = undefined,
            .first_rename_draw = false,
            .renaming_entity = false,
        },
        .object_inspector = .{
            .name_buffer = undefined,
            .selected_component_index = fake_components.len,
        },
        .add_component_modal = .{},
        .instance_handle_widget = .{ .selected_mesh_index = 0 },
    };

    var initialized_mesh_names: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < initialized_mesh_names) : (i += 1) {
            allocator.free(persistent_state.mesh_names[i]);
        }
    }
    persistent_state.mesh_names_len = mesh_instance_initalizers.len;
    for (persistent_state.mesh_names[0..persistent_state.mesh_names_len]) |*mesh_name, i| {
        var path_iter = std.mem.splitBackwards(u8, mesh_instance_initalizers[i].cgltf_path, "/");
        const file_name = path_iter.first();
        var mesh_name_iter = std.mem.split(u8, file_name, ".");
        const only_file_name = mesh_name_iter.first();

        var mesh_name_mem = try allocator.alloc(u8, only_file_name.len + 1);
        std.mem.copy(u8, mesh_name_mem, only_file_name);
        mesh_name_mem[only_file_name.len] = 0;

        mesh_name.* = mesh_name_mem[0..only_file_name.len :0];
    }

    const ecs = try World.init(allocator, .{ persistent_state, render_context });

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
        .ecs = ecs,
    };
}

pub fn newFrame(self: *Editor, window: glfw.Window, delta_time: f32) !void {
    const frame_size = window.getFramebufferSize();
    zgui.io.setDisplaySize(@intToFloat(f32, frame_size.width), @intToFloat(f32, frame_size.height));
    zgui.io.setDisplayFramebufferScale(1.0, 1.0);

    // NOTE: getting cursor must be done before calling zgui.newFrame
    switch (zgui.getMouseCursor()) {
        .none => window.setCursor(self.pointing_hand),
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

        var b = true;
        _ = zgui.showDemoWindow(&b);

        // define editor header
        const header_height = blk1: {
            if (zgui.beginMainMenuBar() == false) {
                break :blk1 0;
            }
            defer zgui.endMainMenuBar();

            if (zgui.beginMenu("File", true)) {
                defer zgui.endMenu();

                if (zgui.menuItem("Export", .{})) {
                    std.debug.print("export", .{}); // TODO: export scene
                }

                if (zgui.menuItem("Import", .{})) {
                    std.debug.print("import", .{}); // TODO: import scene
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

        // define Object List
        {
            const width = @intToFloat(f32, frame_size.width) / 6;

            zgui.setNextWindowSize(.{ .w = width, .h = @intToFloat(f32, frame_size.height), .cond = .always });
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

                try self.ecs.triggerEvent(.draw_object_list, .{});
                self.ecs.waitEvent(.draw_object_list);
            }
        }

        // define Object Inspector
        {
            const width = @intToFloat(f32, frame_size.width) / 6;

            zgui.setNextWindowSize(.{ .w = width, .h = @intToFloat(f32, frame_size.height), .cond = .always });
            zgui.setNextWindowPos(.{ .x = @intToFloat(f32, frame_size.width) - width, .y = header_height, .cond = .always });
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
                        var metadata = try self.ecs.getComponent(selected_entity, ObjectMetadata);
                        metadata.rename(persistent_state.object_inspector.name_buffer[0..new_len]);
                        try self.ecs.setComponent(selected_entity, metadata);
                    }
                }

                zgui.separator();

                zgui.text("Component list: ", .{});
                if (zgui.beginListBox("##component list", .{ .w = -std.math.floatMin(f32), .h = 0 })) {
                    defer zgui.endListBox();

                    inline for (fake_components) |Component, comp_index| {
                        if (self.ecs.hasComponent(selected_entity, Component)) {
                            if (zgui.selectable(@typeName(Component), .{ .selected = comp_index == persistent_state.object_inspector.selected_component_index })) {
                                persistent_state.object_inspector.selected_component_index = comp_index;
                            }
                        }
                    }
                }

                // add component UI
                {
                    if (zgui.button("Add", .{})) {
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
                        inline for (fake_components) |Component, comp_index| {
                            // you can never add a ObjectMetadata
                            if (Component == ObjectMetadata) continue;

                            if (self.ecs.hasComponent(selected_entity, Component) == false) {
                                // if the component index is not set, then we set it to current component index
                                if (persistent_state.add_component_modal.selected_component_index == fake_components.len) {
                                    persistent_state.add_component_modal.selected_component_index = comp_index;
                                }

                                if (zgui.selectable(@typeName(Component), .{
                                    .selected = comp_index == persistent_state.add_component_modal.selected_component_index,
                                    .flags = .{ .dont_close_popups = true },
                                })) {
                                    persistent_state.add_component_modal.selected_component_index = comp_index;
                                    std.mem.set(u8, &persistent_state.add_component_modal.component_bytes, 0);
                                }
                            }
                        }

                        // Menu to set the initial value of selected component
                        {
                            zgui.separator();

                            // List of components that you can add
                            inline for (fake_components) |Component, comp_index| {
                                if (Component == ObjectMetadata) continue;

                                if (comp_index == persistent_state.add_component_modal.selected_component_index) {
                                    zgui.text("{s}:", .{@typeName(Component)});

                                    const component_ptr = blk: {
                                        // @setRuntimeSafety(false);
                                        const ptr = std.mem.bytesAsValue(Component, persistent_state.add_component_modal.component_bytes[0..@sizeOf(Component)]);
                                        break :blk @alignCast(@alignOf(Component), ptr);
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
                            inline for (fake_components) |Component, comp_index| {
                                if (Component == ObjectMetadata) continue;

                                if (comp_index == persistent_state.add_component_modal.selected_component_index) {
                                    const component = @ptrCast(
                                        *Component,
                                        @alignCast(@alignOf(Component), &persistent_state.add_component_modal.component_bytes),
                                    );

                                    if (specializedAddHandle(Component)) |add_handle| {
                                        try add_handle.add(self, component);
                                    } else {
                                        try self.ecs.setComponent(selected_entity, component.*);
                                    }

                                    try self.forceFLush();
                                }
                            }

                            persistent_state.add_component_modal.selected_component_index = fake_components.len;
                            zgui.closeCurrentPopup();
                        }
                        zgui.sameLine(.{});
                        marker("Remember to set ALL values to something valid", .warning);

                        zgui.setItemDefaultFocus();
                        zgui.sameLine(.{});
                        if (zgui.button("Cancel", .{ .w = 120, .h = 0 })) {
                            persistent_state.add_component_modal.selected_component_index = fake_components.len;
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
                        inline for (fake_components) |Component, comp_index| {
                            // deleting the metadata of an entity is illegal
                            if (Component != ObjectMetadata and comp_index == persistent_state.object_inspector.selected_component_index) {
                                // In the event a remove failed, then the select index is in a inconsistent state
                                // and we do not really have to do anything
                                self.ecs.removeComponent(selected_entity, Component) catch {
                                    // TODO: log here in debug builds
                                };

                                try self.forceFLush();

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

                    if (self.ecs.hasComponent(selected_entity, Component)) {
                        zgui.separator();
                        zgui.text("{s}:", .{@typeName(Component)});

                        var component = self.ecs.getComponent(selected_entity, Component) catch unreachable;
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
                            try self.ecs.setComponent(selected_entity, component);
                            try self.forceFLush();
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
    const persistent_state = self.getPersitentState();
    for (persistent_state.mesh_names[0..persistent_state.mesh_names_len]) |mesh_name| {
        self.allocator.free(mesh_name);
    }

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
    self.ecs.deinit();
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
    zgui.io.addInputCharactersUTF8(@ptrCast([*:0]const u8, cstr.ptr));
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

    zgui.io.addMousePositionEvent(@floatCast(f32, xpos), @floatCast(f32, ypos));
}

pub fn scrollCallback(window: glfw.Window, xoffset: f64, yoffset: f64) void {
    _ = window;

    zgui.io.addMouseWheelEvent(@floatCast(f32, xoffset), @floatCast(f32, yoffset));
}

pub fn getNthMeshHandle(self: *Editor, nth: usize) MeshHandle {
    return self.getRenderContext().getNthMeshHandle(nth);
}

pub fn newSceneEntity(self: *Editor, name: []const u8) !ecez.Entity {
    const entity = try self.ecs.createEntity(.{});
    var metadata = ObjectMetadata.init(name, entity);
    try self.ecs.setComponent(entity, metadata);

    return entity;
}

/// This function retrieves a instance handle from the renderer and assigns it to the argument entity
pub fn assignEntityMeshInstance(self: *Editor, entity: ecez.Entity, mesh_handle: MeshHandle) !void {
    if (self.ecs.hasComponent(entity, InstanceHandle)) {
        return error.EntityAlreadyHasInstance;
    }

    var render_context = self.getRenderContext();
    const new_instance = render_context.getNewInstance(mesh_handle) catch |err| {
        // if this fails we will end in an inconsistent state!
        std.debug.panic("attemped to get new instance {d} failed with error {any}", .{ mesh_handle, err });
    };

    try self.ecs.setComponent(entity, new_instance);
}

pub fn renameEntity(self: *Editor, entity: ecez.Entity, name: []const u8) !void {
    var metadata = try self.ecs.getComponent(entity, ObjectMetadata);
    metadata.rename(name);
    try self.ecs.setComponent(entity, metadata);
}

pub fn getMeshNames(self: *Editor) []const [:0]const u8 {
    const persistent_state = self.getPersitentState();
    return persistent_state.mesh_names[0..persistent_state.mesh_names_len];
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
        try self.ecs.setComponent(new_entity, position);
    }
    if (config.rotation) |rotation| {
        try self.ecs.setComponent(new_entity, rotation);
    }
    if (config.scale) |scale| {
        try self.ecs.setComponent(new_entity, scale);
    }
    // new visible object must have a transform component to be visible in the scene
    try self.ecs.setComponent(new_entity, Editor.Transform{ .mat = undefined });

    // Make sure editor updates renderer after we have set some render state programatically.
    // This is highly sub-optimal and should not be done in any hot loop
    if (flush_all_objects == .yes) {
        try self.forceFLush();
    }
}

inline fn forceFLush(self: *Editor) !void {
    try self.ecs.triggerEvent(.transform_update, .{});
    self.ecs.waitEvent(.transform_update);
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
        for (mesh_names) |mesh_name, nth_mesh| {
            if (zgui.menuItem(mesh_name, .{})) {
                try self.createNewVisbleObject(mesh_name, nth_mesh, .yes, .{});
            }
        }
    }
}

inline fn getRenderContext(self: *Editor) *RenderContext {
    return @ptrCast(*RenderContext, self.ecs.getSharedStatePtrWithSharedStateType(*ecez.SharedState(RenderContext)));
}

inline fn getPersitentState(self: *Editor) *PersistentState {
    return @ptrCast(*PersistentState, self.ecs.getSharedStatePtrWithSharedStateType(*ecez.SharedState(PersistentState)));
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
        zgui.beginTooltip();
        defer zgui.endTooltip();

        zgui.pushTextWrapPos(zgui.getFontSize() * 35);
        zgui.textUnformatted(message);
        zgui.popTextWrapPos();
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
