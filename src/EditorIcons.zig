const std = @import("std");

const zgui = @import("zgui");
const ImguiPipeline = @import("ImguiPipeline.zig");

const EditorIcons = @This();

pub const Icon = enum(u32) {
    folder_file_load,
    folder_file_save,
    @"3d_model_load",
    pluss,
    minus,
    camera_off,
    camera_on,
    cursor,
    object_list_off,
    object_list_on,
    object_inspector_off,
    object_inspector_on,
    debug_log_off,
    debug_log_on,
    new_object,
    play,
    debug_play,
};

pub const icon_size = 18;
texture_indices: *ImguiPipeline.TextureIndices,

pub fn init(texture_indices: *ImguiPipeline.TextureIndices) EditorIcons {
    return EditorIcons{
        .texture_indices = texture_indices,
    };
}

pub const ButtonConfig = struct {
    bg_col: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 },
    tint_col: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
};
/// draw an image button for a specific icon
pub fn button(
    self: EditorIcons,
    icon: Icon,
    str_id: [:0]const u8,
    hint_str: [:0]const u8,
    width: f32,
    height: f32,
    config: ButtonConfig,
) bool {
    const icon_stride = ImguiPipeline.atlas_dimension / icon_size;

    const icon_value: f32 = @floatFromInt(@intFromEnum(icon));
    const x = @mod(icon_value, icon_stride);
    const y = @divFloor(icon_value, icon_stride);

    const uv1: [2]f32 = .{
        (x + 1) * ImguiPipeline.uv_stride,
        (y + 1) * ImguiPipeline.uv_stride,
    };
    const uv0: [2]f32 = .{
        uv1[0] - ImguiPipeline.uv_stride,
        uv1[1] - ImguiPipeline.uv_stride,
    };

    const press = zgui.imageButton(str_id, &self.texture_indices.icon, .{
        .w = width,
        .h = height,
        .uv0 = uv0,
        .uv1 = uv1,
        .bg_col = config.bg_col,
        .tint_col = config.tint_col,
    });

    if (zgui.isItemHovered(.{})) {
        if (zgui.beginTooltip()) {
            defer zgui.endTooltip();

            zgui.pushTextWrapPos(zgui.getFontSize() * 35);
            zgui.textUnformatted(hint_str);
            zgui.popTextWrapPos();
        }
    }

    return press;
}
