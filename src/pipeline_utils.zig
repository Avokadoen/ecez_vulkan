const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");
const vk_dispatch = @import("vk_dispatch.zig");
const BaseDispatch = vk_dispatch.BaseDispatch;
const InstanceDispatch = vk_dispatch.InstanceDispatch;
const DeviceDispatch = vk_dispatch.DeviceDispatch;

/// caller must deinit returned memory
pub fn readFile(allocator: Allocator, absolute_path: []const u8) ![]u8 {
    const file = try std.fs.openFileAbsolute(absolute_path, .{ .mode = .read_only });
    defer file.close();

    var reader = file.reader();
    const file_size = (try reader.context.stat()).size;

    var buffer = try allocator.alloc(u8, file_size);
    errdefer allocator.free(buffer);

    const read = try reader.readAll(buffer);
    std.debug.assert(read == file_size);

    return buffer;
}

pub inline fn createShaderModule(vkd: DeviceDispatch, device: vk.Device, shader_code: []const u8) !vk.ShaderModule {
    std.debug.assert(@mod(shader_code.len, 4) == 0);
    const create_info = vk.ShaderModuleCreateInfo{
        .flags = .{},
        .code_size = shader_code.len,
        .p_code = @ptrCast([*]const u32, @alignCast(@alignOf(u32), shader_code.ptr)),
    };
    return vkd.createShaderModule(device, &create_info, null);
}
