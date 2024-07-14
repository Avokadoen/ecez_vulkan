const std = @import("std");

const core = @import("../core.zig");

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

const Editor = @import("Editor.zig");

const tracy = @import("ztracy");
const zgui = @import("zgui");
const zm = @import("zmath");
const ecez = @import("ecez");

pub const all_components = editor_components.all ++ game.components.all ++ render.components.all;
pub const all_components_tuple = @import("../core.zig").component_reflect.componentTypeArrayToTuple(&all_components);

pub const object_metadata_index = blk: {
    for (all_components, 0..) |Component, component_index| {
        if (Component == EntityMetadata) {
            break :blk component_index;
        }
    }
};

pub const biggest_component_size = blk: {
    var size = 0;
    for (all_components) |Component| {
        if (Component == EntityMetadata) continue;

        if (@sizeOf(Component) > size) {
            size = @sizeOf(Component);
        }
    }
    break :blk size;
};

pub fn overrideWidgetGenerator(comptime Component: type) ?type {
    return switch (Component) {
        InstanceHandle => struct {
            pub fn widget(editor: *Editor, instance_handle: *InstanceHandle) bool {
                const zone = tracy.ZoneN(@src(), @src().fn_name);
                defer zone.End();

                const mesh_handle = instance_handle.*.mesh_handle;
                const mesh_name = editor.render_context.getNameFromMeshHandle(mesh_handle).?;
                const preview_value: *[:0]const u8 = @ptrCast(mesh_name);

                if (zgui.beginCombo("Mesh", .{ .preview_value = preview_value.* })) {
                    defer zgui.endCombo();

                    var mesh_name_iter = editor.render_context.mesh_name_handle_map.iterator();
                    while (mesh_name_iter.next()) |mesh_name_entry| {
                        const c_name: *[:0]const u8 = @ptrCast(mesh_name_entry.key_ptr);

                        if (zgui.selectable(c_name.*, .{
                            .selected = mesh_handle == mesh_name_entry.value_ptr.*,
                        })) {
                            // If we are in the processing of adding a instance handle, then we do not want to
                            // destroy none existing handle in the renderer, only set the in flight handle
                            if (editor.ui_state.add_component_modal.is_active) {
                                instance_handle.mesh_handle = mesh_name_entry.value_ptr.*;
                            } else if (mesh_handle != mesh_name_entry.value_ptr.*) {
                                // destroy old instance handle
                                editor.render_context.destroyInstanceHandle(instance_handle.*) catch unreachable;

                                // TODO: handle errors here and report to user
                                const new_instance_handle = editor.render_context.getNewInstance(mesh_name_entry.value_ptr.*) catch unreachable;
                                editor.storage.setComponent(editor.ui_state.selected_entity.?, new_instance_handle) catch unreachable;

                                instance_handle.* = new_instance_handle;
                                editor.forceFlush() catch unreachable;
                            }
                        }
                    }
                }

                const transform = editor.render_context.getInstanceTransform(instance_handle.*);
                zgui.text("Transform (readonly): ", .{});
                {
                    zgui.beginDisabled(.{ .disabled = true });
                    defer zgui.endDisabled();

                    var row_0: [4]f32 = transform[0];
                    _ = zgui.inputFloat4("##transform_row_0", .{
                        .v = &row_0,
                        .flags = .{ .read_only = true },
                    });

                    var row_1: [4]f32 = transform[1];
                    _ = zgui.inputFloat4("##transform_row_1", .{
                        .v = &row_1,
                        .flags = .{ .read_only = true },
                    });

                    var row_2: [4]f32 = transform[2];
                    _ = zgui.inputFloat4("##transform_row_2", .{
                        .v = &row_2,
                        .flags = .{ .read_only = true },
                    });

                    var row_3: [4]f32 = transform[3];
                    _ = zgui.inputFloat4("##transform_row_3", .{
                        .v = &row_3,
                        .flags = .{ .read_only = true },
                    });
                }

                return false;
            }
        },
        Rotation => struct {
            pub fn widget(editor: *Editor, rotation: *Rotation) bool {
                const zone = tracy.ZoneN(@src(), @src().fn_name);
                defer zone.End();
                _ = editor;

                var euler_angles = blk: {
                    const angles = zm.quatToRollPitchYaw(rotation.quat);
                    break :blk [_]f32{
                        std.math.radiansToDegrees(angles[0]),
                        std.math.radiansToDegrees(angles[1]),
                        std.math.radiansToDegrees(angles[2]),
                    };
                };

                zgui.text("Angles: ", .{});
                zgui.sameLine(.{});
                if (zgui.dragFloat3("##euler_angles", .{ .v = &euler_angles })) {
                    const x_rad = std.math.degreesToRadians(euler_angles[0]);
                    const y_rad = std.math.degreesToRadians(euler_angles[1]);
                    const z_rad = std.math.degreesToRadians(euler_angles[2]);

                    rotation.quat = zm.quatFromRollPitchYaw(x_rad, y_rad, z_rad);
                    return true;
                }

                return false;
            }
        },
        game.components.SceneGraph.Level => struct {
            pub fn widget(editor: *Editor, level: *game.components.SceneGraph.Level) bool {
                _ = editor;
                const zone = tracy.ZoneN(@src(), @src().fn_name);
                defer zone.End();

                if (zgui.beginCombo("Level", .{ .preview_value = @tagName(level.value) })) {
                    defer zgui.endCombo();

                    inline for (@typeInfo(game.components.SceneGraph.LevelValue).Enum.fields) |enum_field| {
                        if (zgui.selectable(std.fmt.comptimePrint("{s}", .{enum_field.name}), .{
                            .selected = @intFromEnum(level.value) == enum_field.value,
                        })) {
                            level.value = @enumFromInt(enum_field.value);
                        }
                    }
                }

                return false;
            }
        },
        else => null,
    };
}

pub fn specializedAddHandle(comptime Component: type) ?type {
    return switch (Component) {
        InstanceHandle => struct {
            pub fn add(editor: *Editor, instance_handle: *InstanceHandle) !void {
                // TODO: move add/remove handle into decls on struct, handle in the undo/redo stack as well
                try editor.assignEntityMeshInstance(
                    editor.ui_state.selected_entity.?,
                    instance_handle.mesh_handle,
                );
            }
        },
        else => null,
    };
}

pub fn specializedRemoveHandle(comptime Component: type) ?type {
    return switch (Component) {
        InstanceHandle => struct {
            pub fn remove(editor: *Editor) !void {
                const zone = tracy.ZoneN(@src(), @src().fn_name);
                defer zone.End();

                const selected_entity = editor.ui_state.selected_entity.?;
                const instance_handle = blk: {
                    const handle = try editor.storage.getComponent(selected_entity, InstanceHandle);
                    break :blk handle;
                };

                // destroy old instance handle
                try editor.render_context.destroyInstanceHandle(instance_handle);

                // TODO: move add/remove handle into decls on struct, handle in the undo/redo stack as well
                // undo_blk: {
                //     const prev_component = editor.storage.getComponent(selected_entity, Component) catch {
                //         break :undo_blk;
                //     };
                //     editor.undo_stack.pushSetComponent(selected_entity, prev_component);
                // }

                // In the event a remove failed, then the select index is in a inconsistent state
                // and we do not really have to do anything
                editor.storage.removeComponent(selected_entity, Component) catch {
                    // TODO: log here in debug builds
                };

                try editor.forceFlush();
            }
        },
        Position, Rotation, Scale => struct {
            pub fn remove(editor: *Editor) !void {
                const selected_entity = editor.ui_state.selected_entity.?;

                editor.storage.removeComponent(selected_entity, Component) catch {
                    // TODO: log here in debug builds
                };

                try editor.forceFlush();
            }
        },
        else => null,
    };
}

pub fn componentWidget(comptime T: type, component: *T) bool {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();
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

pub fn fieldWidget(comptime Component: type, comptime T: type, comptime id_mod: usize, field: *T) bool {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

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
            var value = @as(f32, @floatCast(field.*));
            if (zgui.inputFloat(c_id, .{ .v = &value })) {
                field.* = @as(T, @floatCast(value));
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
                            var value = @as(f32, @floatCast(field.*));
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
        else => {
            if (ecez.Entity == T) {
                const IdType = @typeInfo(T).Struct.fields[0].type;

                var value = @as(i32, @intCast(field.id));
                if (zgui.inputInt(c_id, .{ .v = &value })) {
                    field.id = @as(IdType, @intCast(value));
                    field_changed = true;
                }
            } else {
                std.debug.panic("unimplemented type of {s}", .{@typeName(T)});
            }
        },
    }

    return field_changed;
}
