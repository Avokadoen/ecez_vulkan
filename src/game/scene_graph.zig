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

// TODO: benchmark 1 type for scenegraph with runtime skips in system i.e first call if (level != 0) ...
//       vs current unique type impl

pub fn updateEntityLevel(entity: ecez.Entity, new_parent: ecez.Entity, storage: anytype) !void {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    const level_component_ptr = try storage.getComponent(entity, *components.SceneGraph.Level);

    const CurrentLevel = switch (level_component_ptr) {
        inline 0...components.SceneGraph.level_types.len - 1 => |current_level| components.SceneGraph.level_types[current_level],
    };

    // remove previous level type
    try storage.removeComponent(entity, CurrentLevel);

    // add new level type
    const parent_level = try storage.getComponent(new_parent, components.SceneGraph.Level);
    const new_level_value = parent_level.value + 1;

    const NewLevel = switch (new_level_value) {
        inline 0...components.SceneGraph.level_types.len - 1 => |new_level| components.SceneGraph.level_types[new_level],
    };

    level_component_ptr.value = @enumFromInt(parent_level.value + 1);
    try storage.setComponent(entity, NewLevel{ .parent = new_parent });
}
