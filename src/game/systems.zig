const ecez = @import("ecez");

pub fn CreateTransformUpdateEvent(comptime invoke_name: []const u8, comptime SceneGraph: type) type {
    return ecez.Event(invoke_name, .{
        SceneGraph.TransformResetSystem,
        ecez.DependOn(SceneGraph.TransformApplyScaleSystem, .{SceneGraph.TransformResetSystem}),
        ecez.DependOn(SceneGraph.TransformApplyRotationSystem, .{SceneGraph.TransformApplyScaleSystem}),
        ecez.DependOn(SceneGraph.ApplyCameraRotationSystem, .{SceneGraph.TransformApplyScaleSystem}),
        ecez.DependOn(SceneGraph.TransformApplyPositionSystem, .{ SceneGraph.ApplyCameraRotationSystem, SceneGraph.TransformApplyRotationSystem }),
        ecez.DependOn(SceneGraph.L1PropagateSystem, .{SceneGraph.TransformApplyPositionSystem}),
        ecez.DependOn(SceneGraph.L2PropagateSystem, .{SceneGraph.L1PropagateSystem}),
        ecez.DependOn(SceneGraph.L3PropagateSystem, .{SceneGraph.L2PropagateSystem}),
        ecez.DependOn(SceneGraph.L4PropagateSystem, .{SceneGraph.L3PropagateSystem}),
        ecez.DependOn(SceneGraph.L5PropagateSystem, .{SceneGraph.L4PropagateSystem}),
        ecez.DependOn(SceneGraph.L6PropagateSystem, .{SceneGraph.L5PropagateSystem}),
        ecez.DependOn(SceneGraph.L7PropagateSystem, .{SceneGraph.L6PropagateSystem}),
    }, SceneGraph.EventArgument);
}
