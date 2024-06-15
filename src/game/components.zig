const zm = @import("zmath");

// TODO: compute this
pub const all = [_]type{
    Position,
    Rotation,
    Scale,
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
