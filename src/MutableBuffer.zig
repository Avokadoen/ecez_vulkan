const std = @import("std");

const vk = @import("vulkan");

const vk_dispatch = @import("vk_dispatch.zig");
const InstanceDispatch = vk_dispatch.InstanceDispatch;
const DeviceDispatch = vk_dispatch.DeviceDispatch;

const dmem = @import("device_memory.zig");
const sync = @import("sync.zig");

const MutableBuffer = @This();

const TransferDestination = struct {
    buffer: vk.Buffer,
    offset: vk.DeviceSize,
};

const unset_offset = std.math.maxInt(vk.DeviceSize);

size: vk.DeviceSize,
buffer: vk.Buffer,
memory: vk.DeviceMemory,

// memory still not flushed
incoherent_memory_offset: vk.DeviceSize = unset_offset,
incoherent_memory_size: vk.DeviceSize = 0,

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

    const size = dmem.pow2Align(non_coherent_atom_size, config.size);

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
    const raw_data = std.mem.sliceAsBytes(data);
    if (offset + raw_data.len > self.size) {
        return error.OutOfMemory;
    }

    var data_slice = self.device_data[offset..];
    std.mem.copy(u8, data_slice, raw_data);

    // assign our current flush offset
    self.incoherent_memory_offset = @min(self.incoherent_memory_offset, offset);

    // calculate out current flush size
    const transfer_cursor = offset + @intCast(vk.DeviceSize, raw_data.len);
    const buffer_cursor = self.incoherent_memory_offset + self.incoherent_memory_size;
    const rightmost_cursor = @max(transfer_cursor, buffer_cursor);
    self.incoherent_memory_size = rightmost_cursor - self.incoherent_memory_offset;
}

pub inline fn flush(self: *MutableBuffer, vkd: DeviceDispatch, device: vk.Device) !void {
    if (self.incoherent_memory_offset == 0) {
        return;
    }

    const flush_range = [_]vk.MappedMemoryRange{.{
        .memory = self.memory,
        .offset = self.incoherent_memory_offset,
        .size = dmem.pow2Align(self.non_coherent_atom_size, self.incoherent_memory_size),
    }};
    try vkd.flushMappedMemoryRanges(device, flush_range.len, &flush_range);

    self.incoherent_memory_offset = unset_offset;
    self.incoherent_memory_size = 0;
}
