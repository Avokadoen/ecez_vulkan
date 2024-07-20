const zm = @import("zmath");

const components = @import("components.zig");

pub const all = [_]type{
    Camera,
};

pub const Camera = struct {
    turn_rate: f64,
    yaw: f64 = 0,
    pitch: f64 = 0,
    // roll always 0

    pub fn toQuat(camera: Camera) zm.Quat {
        const yaw_quat = zm.quatFromAxisAngle(zm.f32x4(0.0, 1.0, 0.0, 0.0), @floatCast(camera.yaw));
        const pitch_quat = zm.quatFromAxisAngle(zm.f32x4(1.0, 0.0, 0.0, 0.0), @floatCast(camera.pitch));
        return zm.qmul(yaw_quat, pitch_quat);
    }
};
