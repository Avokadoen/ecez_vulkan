const zm = @import("zmath");

// Component based scene graph, Max depth of 7 (8 Levels)
pub const scene_graph = @import("scene_graph.zig");

// TODO: compute this
pub const all = [_]type{
    Position,
    Rotation,
    Scale,
    MoveSpeed,
    Velocity,
    Camera,
} ++ scene_graph.all;

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

pub const Camera = struct {
    turn_rate: f64,
    yaw: f64 = 0,
    pitch: f64 = 0,
    // roll always 0
};
