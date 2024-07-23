const zm = @import("zmath");
const ecez = @import("ecez");

// Component based scene graph, Max depth of 7 (8 Levels)
const camera = @import("camera.zig");

// TODO: compute this
pub const all = [_]type{
    MoveSpeed,
    PlayerTag,
} ++ camera.all ++ SceneGraph.all;

pub const Camera = camera.Camera;

pub const MoveSpeed = struct {
    vec: zm.Vec,
};

pub const PlayerTag = struct {};

pub const SceneGraph = struct {
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
};
