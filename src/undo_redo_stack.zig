const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const ecez = @import("ecez");
const Entity = ecez.Entity;

pub fn CreateType(comptime components: []const type) type {
    return struct {
        pub const ComponentEnum = gen_enum_type_blk: {
            var enum_fields: [components.len]std.builtin.Type.EnumField = undefined;
            for (&enum_fields, 0..) |*enum_field, iter| {
                const name = std.fmt.comptimePrint("{d}", .{iter});
                enum_field.* = .{
                    .name = name,
                    .value = iter,
                };
            }

            const type_info = std.builtin.Type{ .Enum = .{
                .tag_type = u32,
                .fields = &enum_fields,
                .decls = &[0]std.builtin.Type.Declaration{},
                .is_exhaustive = true,
            } };
            break :gen_enum_type_blk @Type(type_info);
        };

        const biggest_byte_size = biggest_comp_byte_size_blk: {
            var biggest_size: usize = 0;
            for (components) |Component| {
                biggest_size = @max(@sizeOf(Component), biggest_size);
            }

            break :biggest_comp_byte_size_blk biggest_size;
        };

        pub const ActionTypeEnum = enum {
            set_component,
            remove_component,
            // TODO:
            // create_entity,
        };

        pub const ActionType = union(ActionTypeEnum) {
            set_component: Entity,
            remove_component: Entity,
        };

        pub const Action = struct {
            action_type: ActionType,
            component_type: ComponentEnum,
            component_bytes: [biggest_byte_size]u8,
        };

        pub const UndoRedoStack = @This();

        action_ring_len: u32 = 0,
        action_ring_cursor: i32 = 0,
        action_ring_buffer: ArrayListUnmanaged(Action) = .{},

        pub fn resize(self: *UndoRedoStack, allocator: Allocator, new_size: usize) Allocator.Error!void {
            try self.action_ring_buffer.resize(allocator, new_size);
        }

        pub fn deinit(self: *UndoRedoStack, allocator: Allocator) void {
            self.action_ring_buffer.deinit(allocator);
            self.action_ring_cursor = undefined;
        }

        pub fn pushSetComponent(self: *UndoRedoStack, entity: Entity, component: anytype) void {
            const index = comptime indexOfComponent(@TypeOf(component));
            var action = Action{
                .action_type = ActionType{ .set_component = entity },
                .component_type = @enumFromInt(index),
                .component_bytes = undefined,
            };
            const component_bytes = std.mem.asBytes(&component);
            @memcpy(action.component_bytes[0..component_bytes.len], component_bytes);
            self.pushAction(action);
        }

        pub fn pushRemoveComponent(self: *UndoRedoStack, entity: Entity, Component: type) void {
            const index = comptime indexOfComponent(Component);
            const action = Action{
                .action_type = ActionType{ .remove_component = entity },
                .component_type = @enumFromInt(index),
                .component_bytes = undefined,
            };
            self.pushAction(action);
        }

        pub fn pushAction(self: *UndoRedoStack, action: Action) void {
            self.action_ring_buffer.items[@intCast(self.action_ring_cursor)] = action;
            self.action_ring_cursor = @rem((self.action_ring_cursor + 1), @as(i32, @intCast(self.action_ring_buffer.items.len)));
            self.action_ring_len = @min(self.action_ring_len + 1, self.action_ring_buffer.items.len - 1);
        }

        pub fn popAction(self: *UndoRedoStack, ecez_storage: anytype) !void {
            if (0 == self.action_ring_len) return;

            self.action_ring_cursor = if (self.action_ring_cursor == 0)
                @as(i32, @intCast(self.action_ring_buffer.items.len - 1))
            else
                self.action_ring_cursor - 1;

            self.action_ring_len = self.action_ring_len - 1;

            const ring_cursor: usize = @intCast(self.action_ring_cursor);
            const action = self.action_ring_buffer.items[ring_cursor];
            self.action_ring_buffer.items[ring_cursor] = undefined;

            switch (@intFromEnum(action.component_type)) {
                inline 0...components.len - 1 => |comp_index| {
                    const Component = components[comp_index];

                    switch (action.action_type) {
                        .set_component => |entity| {
                            const component = std.mem.bytesToValue(Component, action.component_bytes[0..@sizeOf(Component)]);
                            try ecez_storage.setComponent(entity, component);
                        },
                        .remove_component => |entity| try ecez_storage.removeComponent(entity, Component),
                    }
                },
                else => |invalid_value| std.debug.panic("invalid type {d}", .{invalid_value}),
            }
        }

        fn indexOfComponent(ComponentType: type) comptime_int {
            inline for (components, 0..) |Component, index| {
                if (ComponentType == Component) {
                    return index;
                }
            }

            @compileError("failed to find component " ++ @typeName(ComponentType));
        }
    };
}
