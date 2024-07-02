const zm = @import("zmath");

// Component based scene graph, Max depth of 7 (8 Levels)
pub const scene_graph = @import("scene_graph.zig");
const camera = @import("camera.zig");

// TODO: compute this
pub const all = [_]type{
    Position,
    Rotation,
    Scale,
    MoveSpeed,
    Velocity,
} ++ camera.all ++ scene_graph.all;

pub const Camera = camera.Camera;

pub const Position = struct {
    vec: zm.Vec,
};

pub const Rotation = struct {
    quat: zm.Quat,
};

pub const Scale = struct {
    vec: zm.Vec,
};

pub const MoveSpeed = struct {
    vec: zm.Vec,
};

pub const Velocity = struct {
    vec: zm.Vec,
};
