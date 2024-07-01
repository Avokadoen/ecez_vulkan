const components = @import("components.zig");
const Scale = components.Scale;
const Rotation = components.Rotation;
const Position = components.Position;

const render = @import("../render.zig");
const InstanceHandle = render.components.InstanceHandle;
const RenderContext = render.Context;

const tracy = @import("ztracy");
const zm = @import("zmath");
const ecez = @import("ecez");

// TODO: benchmark 1 type for scenegraph with runtime skips in system i.e first call if (level != 0) ...
//       vs current unique type impl

pub const all = [_]type{
    Level,
} ++ level_types;

pub const LevelValue = enum(u32) {
    L0,
    L1,
    L2,
    L3,
    L4,
    L5,
    L6,
    L7,
};

pub const Level = struct {
    value: LevelValue,
};

pub const L0 = struct {};
pub const L1 = struct { parent: ecez.Entity };
pub const L2 = struct { parent: ecez.Entity };
pub const L3 = struct { parent: ecez.Entity };
pub const L4 = struct { parent: ecez.Entity };
pub const L5 = struct { parent: ecez.Entity };
pub const L6 = struct { parent: ecez.Entity };
pub const L7 = struct { parent: ecez.Entity };

pub const level_types = [_]type{
    L0,
    L1,
    L2,
    L3,
    L4,
    L5,
    L6,
    L7,
};

pub fn updateEntityLevel(entity: ecez.Entity, new_parent: ecez.Entity, storage: anytype) !void {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    const level_component_ptr = try storage.getComponent(entity, *Level);

    const CurrentLevel = switch (level_component_ptr) {
        inline 0...level_types.len - 1 => |current_level| level_types[current_level],
    };

    // remove previous level type
    try storage.removeComponent(entity, CurrentLevel);

    // add new level type
    const parent_level = try storage.getComponent(new_parent, Level);
    const new_level_value = parent_level.value + 1;

    const NewLevel = switch (new_level_value) {
        inline 0...level_types.len - 1 => |new_level| level_types[new_level],
    };

    level_component_ptr.value = @enumFromInt(parent_level.value + 1);
    try storage.setComponent(entity, NewLevel{ .parent = new_parent });
}

pub fn SceneGraphSystems(StorageType: type) type {
    return struct {
        pub const EventArgument = struct {
            render_context: *RenderContext,
            read_storage: StorageType,
        };

        // TODO: Doing these things for all enitites in the scene is extremely inefficient
        //       since the scene editor is "static". This should only be done for the objects
        //       that move
        pub const TransformResetSystem = struct {
            /// Reset the transform
            pub fn reset(instance_handle: InstanceHandle, event_argument: EventArgument) void {
                const zone = tracy.ZoneN(@src(), @src().fn_name);
                defer zone.End();

                var _render_context = @as(*RenderContext, @ptrCast(event_argument.render_context));
                const transform = _render_context.getInstanceTransformPtr(instance_handle);

                transform.* = zm.identity();
            }
        };

        pub const TransformApplyScaleSystem = struct {
            /// Apply scale to the transform/
            pub fn applyScale(scale: Scale, instance_handle: InstanceHandle, event_argument: EventArgument) void {
                const zone = tracy.ZoneN(@src(), @src().fn_name);
                defer zone.End();

                var transform = event_argument.render_context.getInstanceTransformPtr(instance_handle);

                transform[0][0] *= scale.vec[0];
                transform[1][1] *= scale.vec[1];
                transform[2][2] *= scale.vec[2];
            }
        };

        pub const TransformApplyRotationSystem = struct {
            /// Apply rotation to the transform/
            pub fn applyRotation(rotation: Rotation, instance_handle: InstanceHandle, event_argument: EventArgument) void {
                const zone = tracy.ZoneN(@src(), @src().fn_name);
                defer zone.End();

                const transform = event_argument.render_context.getInstanceTransformPtr(instance_handle);

                transform.* = zm.mul(transform.*, zm.quatToMat(rotation.quat));
            }
        };

        pub const TransformApplyPositionSystem = struct {
            /// Apply position to the transform
            pub fn applyPosition(position: Position, instance_handle: InstanceHandle, event_argument: EventArgument) void {
                const zone = tracy.ZoneN(@src(), @src().fn_name);
                defer zone.End();

                const transform = event_argument.render_context.getInstanceTransformPtr(instance_handle);

                transform.* = zm.mul(transform.*, zm.translationV(position.vec));
            }
        };

        fn propagate(l: anytype, instance_handle: InstanceHandle, event_argument: EventArgument) void {
            const zone = tracy.ZoneN(@src(), @typeName(@TypeOf(l)) ++ @src().fn_name);
            defer zone.End();

            const parent_transform = fetch_parent_blk: {
                const parent_instance = event_argument.read_storage.getComponent(l.parent, InstanceHandle) catch {
                    // parent does not have tranform in renderer
                    // TODO: fallback to position, rotation, scale
                    return;
                };

                break :fetch_parent_blk event_argument.render_context.getInstanceTransform(parent_instance);
            };

            const transform = event_argument.render_context.getInstanceTransformPtr(instance_handle);
            transform.* = zm.mul(transform.*, parent_transform);
        }

        pub const L1PropagateSystem = struct {
            pub fn l1Propagate(l: L1, instance_handle: InstanceHandle, event_argument: EventArgument) void {
                propagate(l, instance_handle, event_argument);
            }
        };

        pub const L2PropagateSystem = struct {
            pub fn l2Propagate(l: L2, instance_handle: InstanceHandle, event_argument: EventArgument) void {
                propagate(l, instance_handle, event_argument);
            }
        };

        pub const L3PropagateSystem = struct {
            pub fn l3Propagate(l: L3, instance_handle: InstanceHandle, event_argument: EventArgument) void {
                propagate(l, instance_handle, event_argument);
            }
        };

        pub const L4PropagateSystem = struct {
            pub fn l4Propagate(l: L4, instance_handle: InstanceHandle, event_argument: EventArgument) void {
                propagate(l, instance_handle, event_argument);
            }
        };

        pub const L5PropagateSystem = struct {
            pub fn l5Propagate(l: L5, instance_handle: InstanceHandle, event_argument: EventArgument) void {
                propagate(l, instance_handle, event_argument);
            }
        };

        pub const L6PropagateSystem = struct {
            pub fn l6Propagate(l: L6, instance_handle: InstanceHandle, event_argument: EventArgument) void {
                propagate(l, instance_handle, event_argument);
            }
        };

        pub const L7PropagateSystem = struct {
            pub fn l7Propagate(l: L7, instance_handle: InstanceHandle, event_argument: EventArgument) void {
                propagate(l, instance_handle, event_argument);
            }
        };
    };
}
