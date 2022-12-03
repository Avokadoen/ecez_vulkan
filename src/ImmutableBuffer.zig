const std = @import("std");

const vk = @import("vulkan");

const vk_dispatch = @import("vk_dispatch.zig");
const InstanceDispatch = vk_dispatch.InstanceDispatch;
const DeviceDispatch = vk_dispatch.DeviceDispatch;

const command = @import("command.zig");
const dmem = @import("device_memory.zig");
const sync = @import("sync.zig");

const ImmutableBuffer = @This();

const max_transfers_scheduled = 32;

size: vk.DeviceSize,
buffer: vk.Buffer,
memory: vk.DeviceMemory,
non_coherent_atom_size: vk.DeviceSize,

pub const Config = struct {
    size: vk.DeviceSize = 64 * dmem.bytes_in_megabyte, // default of 64 megabyte
};
pub inline fn init(
    vki: InstanceDispatch,
    physical_device: vk.PhysicalDevice,
    vkd: DeviceDispatch,
    device: vk.Device,
    non_coherent_atom_size: vk.DeviceSize,
    buffer_usage: vk.BufferUsageFlags,
    config: Config,
) !ImmutableBuffer {
    std.debug.assert(config.size != 0);

    const size = dmem.getAlignedDeviceSize(non_coherent_atom_size, config.size);

    // create device memory and transfer vertices to host
    const buffer = try dmem.createBuffer(
        vkd,
        device,
        non_coherent_atom_size,
        size,
        buffer_usage.merge(vk.BufferUsageFlags{ .transfer_dst_bit = true }),
    );
    errdefer vkd.destroyBuffer(device, buffer, null);
    const memory = try dmem.createDeviceMemory(
        vkd,
        device,
        vki,
        physical_device,
        buffer,
        .{ .device_local_bit = true },
    );
    errdefer vkd.freeMemory(device, memory, null);
    try vkd.bindBufferMemory(device, buffer, memory, 0);

    return ImmutableBuffer{
        .size = size,
        .buffer = buffer,
        .memory = memory,
        .non_coherent_atom_size = non_coherent_atom_size,
    };
}

pub inline fn deinit(self: ImmutableBuffer, vkd: DeviceDispatch, device: vk.Device) void {
    vkd.freeMemory(device, self.memory, null);
    vkd.destroyBuffer(device, self.buffer, null);
}
