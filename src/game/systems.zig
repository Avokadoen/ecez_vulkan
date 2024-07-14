const components = @import("components.zig");
const Scale = components.Scale;
const Rotation = components.Rotation;
const Position = components.Position;

const Camera = @import("camera.zig").Camera;

const render = @import("../render.zig");
const InstanceHandle = render.components.InstanceHandle;
const RenderContext = render.Context;

const tracy = @import("ztracy");
const zm = @import("zmath");
const ecez = @import("ecez");

pub fn SceneGraphSystems(StorageType: type) type {
    return struct {
        pub const EventArgument = struct {
            render_context: *RenderContext,
            read_storage: StorageType,
        };

        pub const TransformUpdateEvent = ecez.Event("transform_update", .{
            TransformResetSystem,
            ecez.DependOn(TransformApplyScaleSystem, .{TransformResetSystem}),
            ecez.DependOn(TransformApplyRotationSystem, .{TransformApplyScaleSystem}),
            ecez.DependOn(ApplyCameraRotationSystem, .{TransformApplyScaleSystem}),
            ecez.DependOn(TransformApplyPositionSystem, .{ ApplyCameraRotationSystem, TransformApplyRotationSystem }),
            ecez.DependOn(L1PropagateSystem, .{TransformApplyPositionSystem}),
            ecez.DependOn(L2PropagateSystem, .{L1PropagateSystem}),
            ecez.DependOn(L3PropagateSystem, .{L2PropagateSystem}),
            ecez.DependOn(L4PropagateSystem, .{L3PropagateSystem}),
            ecez.DependOn(L5PropagateSystem, .{L4PropagateSystem}),
            ecez.DependOn(L6PropagateSystem, .{L5PropagateSystem}),
            ecez.DependOn(L7PropagateSystem, .{L6PropagateSystem}),
        }, EventArgument);

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
            pub fn applyRotation(
                rotation: Rotation,
                instance_handle: InstanceHandle,
                event_argument: EventArgument,
                exclude: ecez.ExcludeEntityWith(.{Camera}),
            ) void {
                _ = exclude;

                const zone = tracy.ZoneN(@src(), @src().fn_name);
                defer zone.End();

                const transform = event_argument.render_context.getInstanceTransformPtr(instance_handle);

                transform.* = zm.mul(transform.*, zm.quatToMat(rotation.quat));
            }
        };

        pub const ApplyCameraRotationSystem = struct {
            pub fn applyCameraRotationSystem(rotation: *components.Rotation, camera: Camera, instance_handle: InstanceHandle, event_argument: EventArgument) void {
                const zone = tracy.ZoneN(@src(), @src().fn_name);
                defer zone.End();

                const transform = event_argument.render_context.getInstanceTransformPtr(instance_handle);

                const full_rotation = zm.inverse(zm.qmul(camera.toQuat(), rotation.quat));
                transform.* = zm.mul(transform.*, zm.quatToMat(full_rotation));
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
            pub fn l1Propagate(l: components.SceneGraph.L1, instance_handle: InstanceHandle, event_argument: EventArgument) void {
                propagate(l, instance_handle, event_argument);
            }
        };

        pub const L2PropagateSystem = struct {
            pub fn l2Propagate(l: components.SceneGraph.L2, instance_handle: InstanceHandle, event_argument: EventArgument) void {
                propagate(l, instance_handle, event_argument);
            }
        };

        pub const L3PropagateSystem = struct {
            pub fn l3Propagate(l: components.SceneGraph.L3, instance_handle: InstanceHandle, event_argument: EventArgument) void {
                propagate(l, instance_handle, event_argument);
            }
        };

        pub const L4PropagateSystem = struct {
            pub fn l4Propagate(l: components.SceneGraph.L4, instance_handle: InstanceHandle, event_argument: EventArgument) void {
                propagate(l, instance_handle, event_argument);
            }
        };

        pub const L5PropagateSystem = struct {
            pub fn l5Propagate(l: components.SceneGraph.L5, instance_handle: InstanceHandle, event_argument: EventArgument) void {
                propagate(l, instance_handle, event_argument);
            }
        };

        pub const L6PropagateSystem = struct {
            pub fn l6Propagate(l: components.SceneGraph.L6, instance_handle: InstanceHandle, event_argument: EventArgument) void {
                propagate(l, instance_handle, event_argument);
            }
        };

        pub const L7PropagateSystem = struct {
            pub fn l7Propagate(l: components.SceneGraph.L7, instance_handle: InstanceHandle, event_argument: EventArgument) void {
                propagate(l, instance_handle, event_argument);
            }
        };
    };
}
