const vk = @import("vulkan");

const DeviceDispatch = @import("vk_dispatch.zig").DeviceDispatch;

pub inline fn createSemaphore(vkd: DeviceDispatch, device: vk.Device) !vk.Semaphore {
    const semaphore_create_info = vk.SemaphoreCreateInfo{ .flags = .{} };
    return vkd.createSemaphore(device, &semaphore_create_info, null);
}

pub inline fn createFence(vkd: DeviceDispatch, device: vk.Device, signaled: bool) !vk.Fence {
    const fence_create_info = vk.FenceCreateInfo{
        .flags = .{ .signaled_bit = signaled },
    };
    return vkd.createFence(device, &fence_create_info, null);
}
