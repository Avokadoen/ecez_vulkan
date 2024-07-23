const zm = @import("zmath");

pub const all = [_]type{
    Position,
    Rotation,
    Scale,
    Velocity,
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

pub const Velocity = struct {
    vec: zm.Vec,
};

// pub const Cube = struct {

// }
