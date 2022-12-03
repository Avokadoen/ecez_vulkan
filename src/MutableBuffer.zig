const std = @import("std");

const vk = @import("vulkan");

const vk_dispatch = @import("vk_dispatch.zig");
const InstanceDispatch = vk_dispatch.InstanceDispatch;
const DeviceDispatch = vk_dispatch.DeviceDispatch;

const command = @import("command.zig");
const dmem = @import("device_memory.zig");
const sync = @import("sync.zig");

const MutableBuffer = @This();

const TransferDestination = struct {
    buffer: vk.Buffer,
    offset: vk.DeviceSize,
};

const max_transfers_scheduled = 32;

size: vk.DeviceSize,
buffer: vk.Buffer,
memory: vk.DeviceMemory,

// memory still not flushed
incoherent_memory_ranges: [max_transfers_scheduled]vk.MappedMemoryRange = undefined,
incoherent_memory_count: u32 = 0,

non_coherent_atom_size: vk.DeviceSize,

device_data: []u8,

pub const Config = struct {
    size: vk.DeviceSize = 64 * dmem.bytes_in_megabyte, // default of 64 megabyte for staging
};
pub inline fn init(
    vki: InstanceDispatch,
    physical_device: vk.PhysicalDevice,
    vkd: DeviceDispatch,
    device: vk.Device,
    non_coherent_atom_size: vk.DeviceSize,
    buffer_usage: vk.BufferUsageFlags,
    config: Config,
) !MutableBuffer {
    std.debug.assert(config.size != 0);

    const size = dmem.getAlignedDeviceSize(non_coherent_atom_size, config.size);

    // create device memory and transfer vertices to host
    const buffer = try dmem.createBuffer(
        vkd,
        device,
        non_coherent_atom_size,
        size,
        buffer_usage,
    );
    errdefer vkd.destroyBuffer(device, buffer, null);
    const memory = try dmem.createDeviceMemory(
        vkd,
        device,
        vki,
        physical_device,
        buffer,
        .{ .host_visible_bit = true, .device_local_bit = true },
    );
    errdefer vkd.freeMemory(device, memory, null);
    try vkd.bindBufferMemory(device, buffer, memory, 0);

    const device_data: []u8 = blk: {
        var raw_device_ptr = try vkd.mapMemory(device, memory, 0, size, .{});
        break :blk @ptrCast([*]u8, raw_device_ptr)[0..size];
    };

    return MutableBuffer{
        .size = size,
        .buffer = buffer,
        .memory = memory,
        .non_coherent_atom_size = non_coherent_atom_size,
        .device_data = device_data,
    };
}

pub inline fn deinit(self: MutableBuffer, vkd: DeviceDispatch, device: vk.Device) void {
    vkd.unmapMemory(device, self.memory);
    vkd.freeMemory(device, self.memory, null);
    vkd.destroyBuffer(device, self.buffer, null);
}

pub inline fn scheduleTransfer(
    self: *MutableBuffer,
    offset: vk.DeviceSize,
    comptime T: type,
    data: []const T,
) !void {
    if (self.incoherent_memory_count >= max_transfers_scheduled) {
        return error.OutOfTransferSlots;
    }

    const raw_data = std.mem.sliceAsBytes(data);
    if (offset + raw_data.len > self.size) {
        return error.OutOfMemory;
    }

    var data_slice = self.device_data[offset..];
    std.mem.copy(u8, data_slice, raw_data);

    const aligned_memory_size = dmem.getAlignedDeviceSize(self.non_coherent_atom_size, @intCast(vk.DeviceSize, raw_data.len));

    self.incoherent_memory_ranges[self.incoherent_memory_count] = vk.MappedMemoryRange{
        .memory = self.memory,
        .offset = offset,
        .size = aligned_memory_size,
    };

    self.incoherent_memory_count += 1;
}

pub inline fn flush(self: *MutableBuffer, vkd: DeviceDispatch, device: vk.Device) !void {
    if (self.incoherent_memory_count == 0) return;
    try vkd.flushMappedMemoryRanges(device, self.incoherent_memory_count, &self.incoherent_memory_ranges);
    self.incoherent_memory_count = 0;
}
