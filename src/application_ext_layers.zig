const std = @import("std");
const Allocator = std.mem.Allocator;
const BaseDispatch = @import("vk_dispatch.zig").BaseDispatch;
const is_debug_build = @import("builtin").mode == .Debug;

const vk = @import("vulkan");

pub const required_extensions = [_][:0]const u8{
    vk.extension_info.khr_swapchain.name,
    // At the time of writing, descriptor indexing is supported by 48% of hardware
    // This is not as bad as it sounds. As an example Nvidias 600 series support this extension.
    vk.extension_info.khr_maintenance_3.name,
    vk.extension_info.ext_descriptor_indexing.name,
};

pub const required_extensions_cstr = [_][*:0]const u8{
    vk.extension_info.khr_swapchain.name,
    // At the time of writing, descriptor indexing is supported by 48% of hardware
    // This is not as bad as it sounds. As an example Nvidias 600 series support this extension.
    vk.extension_info.khr_maintenance_3.name,
    vk.extension_info.ext_descriptor_indexing.name,
};

const desired_layers = [_][*:0]const u8{
    "VK_LAYER_KHRONOS_validation",
    "VK_LAYER_KHRONOS_synchronization2",
};

pub inline fn getValidationLayers(allocator: Allocator, vkb: BaseDispatch) ![]const [*:0]const u8 {
    if (comptime (is_debug_build == false)) {
        return &[0][*:0]const u8{};
    }

    var layer_count: u32 = undefined;
    _ = try vkb.enumerateInstanceLayerProperties(&layer_count, null);

    const existing_layers = try allocator.alloc(vk.LayerProperties, layer_count);
    defer allocator.free(existing_layers);

    _ = try vkb.enumerateInstanceLayerProperties(&layer_count, existing_layers.ptr);

    inline for (desired_layers) |desired_layer| {
        var found: bool = false;

        inner: for (existing_layers) |existing_layer| {
            if (std.mem.orderZ(u8, desired_layer, @as([*:0]const u8, @ptrCast(&existing_layer.layer_name))) == .eq) {
                found = true;
                break :inner;
            }
        }

        if (found == false) {
            return error.MissingValidationLayer;
        }
    }

    return &desired_layers;
}
