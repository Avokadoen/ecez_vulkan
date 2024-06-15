const components = @import("components.zig");
const Scale = components.Scale;
const Rotation = components.Rotation;
const Position = components.Position;

const render = @import("../render.zig");
const InstanceHandle = render.components.InstanceHandle;
const RenderContext = render.Context;

const tracy = @import("ztracy");
const zm = @import("zmath");

// TODO: Doing these things for all enitites in the scene is extremely inefficient
//       since the scene editor is "static". This should only be done for the objects
//       that move
pub const TransformResetSystem = struct {
    /// Reset the transform
    pub fn reset(instance_handle: InstanceHandle, render_context: *RenderContext) void {
        const zone = tracy.ZoneN(@src(), @src().fn_name);
        defer zone.End();
        var _render_context = @as(*RenderContext, @ptrCast(render_context));
        const transform = _render_context.getInstanceTransformPtr(instance_handle);

        transform.* = zm.identity();
    }
};

pub const TransformApplyScaleSystem = struct {
    /// Apply scale to the transform/
    pub fn applyScale(scale: Scale, instance_handle: InstanceHandle, render_context: *RenderContext) void {
        const zone = tracy.ZoneN(@src(), @src().fn_name);
        defer zone.End();
        var transform = render_context.getInstanceTransformPtr(instance_handle);

        transform[0][0] *= scale.vec[0];
        transform[1][1] *= scale.vec[1];
        transform[2][2] *= scale.vec[2];
    }
};

pub const TransformApplyRotationSystem = struct {
    /// Apply rotation to the transform/
    pub fn applyRotation(rotation: Rotation, instance_handle: InstanceHandle, render_context: *RenderContext) void {
        const zone = tracy.ZoneN(@src(), @src().fn_name);
        defer zone.End();
        const transform = render_context.getInstanceTransformPtr(instance_handle);

        transform.* = zm.mul(transform.*, zm.quatToMat(rotation.quat));
    }
};

pub const TransformApplyPositionSystem = struct {
    /// Apply position to the transform
    pub fn applyPosition(position: Position, instance_handle: InstanceHandle, render_context: *RenderContext) void {
        const zone = tracy.ZoneN(@src(), @src().fn_name);
        defer zone.End();
        const transform = render_context.getInstanceTransformPtr(instance_handle);

        transform.* = zm.mul(transform.*, zm.translationV(position.vec));
    }
};
