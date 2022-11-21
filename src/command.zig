const vk = @import("vulkan");

const DeviceDispatch = @import("vk_dispatch.zig").DeviceDispatch;

pub inline fn createPool(vkd: DeviceDispatch, device: vk.Device, queue_family_index: u32) !vk.CommandPool {
    const pool_info = vk.CommandPoolCreateInfo{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = queue_family_index,
    };

    return vkd.createCommandPool(device, &pool_info, null);
}

pub inline fn createBuffer(vkd: DeviceDispatch, device: vk.Device, command_pool: vk.CommandPool) !vk.CommandBuffer {
    const cmd_buffer_info = vk.CommandBufferAllocateInfo{
        .command_pool = command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    };
    var command_buffer: vk.CommandBuffer = undefined;
    try vkd.allocateCommandBuffers(device, &cmd_buffer_info, @ptrCast([*]vk.CommandBuffer, &command_buffer));
    return command_buffer;
}
