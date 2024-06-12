const std = @import("std");
const Allocator = std.mem.Allocator;

const tracy = @import("ztracy");

const vk = @import("vulkan");
const vk_dispatch = @import("vk_dispatch.zig");
const DeviceDispatch = vk_dispatch.DeviceDispatch;

pub inline fn createShaderModule(vkd: DeviceDispatch, device: vk.Device, shader_code: []const u8) !vk.ShaderModule {
    const zone = tracy.ZoneN(@src(), @src().fn_name);
    defer zone.End();

    std.debug.assert(@mod(shader_code.len, 4) == 0);
    const create_info = vk.ShaderModuleCreateInfo{
        .flags = .{},
        .code_size = shader_code.len,
        .p_code = @as([*]const u32, @ptrCast(@alignCast(shader_code.ptr))),
    };
    return vkd.createShaderModule(device, &create_info, null);
}
