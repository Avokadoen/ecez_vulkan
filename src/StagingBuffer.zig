const std = @import("std");

const vk = @import("vulkan");

const vk_dispatch = @import("vk_dispatch.zig");
const InstanceDispatch = vk_dispatch.InstanceDispatch;
const DeviceDispatch = vk_dispatch.DeviceDispatch;

const command = @import("command.zig");
const dmem = @import("device_memory.zig");
const sync = @import("sync.zig");

const StagingBuffer = @This();

const TransferDestination = struct {
    buffer: vk.Buffer,
    offset: vk.DeviceSize,
};

const max_transfers_scheduled = 32;

buffer: vk.Buffer,
memory: vk.DeviceMemory,

// memory still not flushed
transfer_destinations: [max_transfers_scheduled]TransferDestination = undefined,
incoherent_memory_ranges: [max_transfers_scheduled]vk.MappedMemoryRange = undefined,
incoherent_memory_count: u32 = 0,
incoherent_memory_bytes: vk.DeviceSize = 0,
// TODO: reduce duplicate memory

non_coherent_atom_size: vk.DeviceSize,

transfer_queue: vk.Queue,
command_pool: vk.CommandPool,
command_buffer: vk.CommandBuffer,
transfer_fence: vk.Fence,

pub const Config = struct {
    size: vk.DeviceSize = 64 * dmem.bytes_in_megabyte, // default of 64 megabyte for staging
};
pub fn init(
    vki: InstanceDispatch,
    physical_device: vk.PhysicalDevice,
    vkd: DeviceDispatch,
    device: vk.Device,
    non_coherent_atom_size: vk.DeviceSize,
    transfer_family_index: u32,
    transfer_queue: vk.Queue,
    config: Config,
) !StagingBuffer {
    // create device memory and transfer vertices to host
    const buffer = try dmem.createBuffer(
        vkd,
        device,
        non_coherent_atom_size,
        config.size,
        .{ .transfer_src_bit = true },
    );
    errdefer vkd.destroyBuffer(device, buffer, null);
    const memory = try dmem.createDeviceMemory(
        vkd,
        device,
        vki,
        physical_device,
        buffer,
        .{ .host_visible_bit = true },
    );
    errdefer vkd.freeMemory(device, memory, null);
    try vkd.bindBufferMemory(device, buffer, memory, 0);

    const command_pool = try command.createPool(vkd, device, transfer_family_index);
    errdefer vkd.destroyCommandPool(device, command_pool, null);

    const command_buffer = try command.createBuffer(vkd, device, command_pool);

    const transfer_fence = try sync.createFence(vkd, device, false);
    errdefer vkd.destroyFence(device, transfer_fence, null);

    return StagingBuffer{
        .buffer = buffer,
        .memory = memory,
        .non_coherent_atom_size = non_coherent_atom_size,
        .command_pool = command_pool,
        .command_buffer = command_buffer,
        .transfer_queue = transfer_queue,
        .transfer_fence = transfer_fence,
    };
}

pub fn deinit(self: StagingBuffer, vkd: DeviceDispatch, device: vk.Device) void {
    _ = vkd.waitForFences(device, 1, @ptrCast([*]const vk.Fence, &self.transfer_fence), vk.TRUE, std.time.ns_per_s) catch {};
    vkd.destroyFence(device, self.transfer_fence, null);
    vkd.destroyCommandPool(device, self.command_pool, null);
    vkd.freeMemory(device, self.memory, null);
    vkd.destroyBuffer(device, self.buffer, null);
}

pub fn scheduleTransfer(
    self: *StagingBuffer,
    vkd: DeviceDispatch,
    device: vk.Device,
    destination_buffer: vk.Buffer,
    destination_offset: vk.DeviceSize,
    comptime T: type,
    data: []const T,
) !void {
    if (self.incoherent_memory_count >= max_transfers_scheduled) return;

    const raw_data = std.mem.sliceAsBytes(data);

    const aligned_memory_size = dmem.getAlignedDeviceSize(self.non_coherent_atom_size, @intCast(vk.DeviceSize, raw_data.len));

    var device_data = blk: {
        var raw_device_ptr = try vkd.mapMemory(device, self.memory, self.incoherent_memory_bytes, aligned_memory_size, .{});
        break :blk @ptrCast([*]u8, raw_device_ptr)[0..raw_data.len];
    };
    defer vkd.unmapMemory(device, self.memory);

    std.mem.copy(u8, device_data, raw_data);

    self.incoherent_memory_ranges[self.incoherent_memory_count] = vk.MappedMemoryRange{
        .memory = self.memory,
        .offset = self.incoherent_memory_bytes,
        .size = aligned_memory_size,
    };
    self.transfer_destinations[self.incoherent_memory_count] = TransferDestination{
        .buffer = destination_buffer,
        .offset = destination_offset,
    };

    self.incoherent_memory_count += 1;
    self.incoherent_memory_bytes += aligned_memory_size;
}

pub fn flushAndCopyToDestination(self: *StagingBuffer, vkd: DeviceDispatch, device: vk.Device) !void {
    if (self.incoherent_memory_count == 0) return;

    _ = try vkd.mapMemory(device, self.memory, 0, self.incoherent_memory_bytes, .{});
    try vkd.flushMappedMemoryRanges(device, self.incoherent_memory_count, &self.incoherent_memory_ranges);
    vkd.unmapMemory(device, self.memory);

    const begin_info = vk.CommandBufferBeginInfo{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    };
    try vkd.beginCommandBuffer(self.command_buffer, &begin_info);

    // TODO: reduce buffers, only have one of each dst buffer
    var copy_regions: [max_transfers_scheduled]vk.BufferCopy = undefined;
    for (self.incoherent_memory_ranges[0..self.incoherent_memory_count]) |memory_ranges, i| {
        copy_regions[i] = vk.BufferCopy{
            .src_offset = memory_ranges.offset,
            .dst_offset = self.transfer_destinations[i].offset,
            .size = memory_ranges.size,
        };
        vkd.cmdCopyBuffer(self.command_buffer, self.buffer, self.transfer_destinations[i].buffer, 1, copy_regions[i..].ptr);
    }

    try vkd.endCommandBuffer(self.command_buffer);

    // TODO: semaphores
    const submit_into = vk.SubmitInfo{
        .wait_semaphore_count = 0,
        .p_wait_semaphores = undefined,
        .p_wait_dst_stage_mask = undefined,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast([*]vk.CommandBuffer, &self.command_buffer),
        .signal_semaphore_count = 0,
        .p_signal_semaphores = undefined,
    };
    try vkd.queueSubmit(self.transfer_queue, 1, @ptrCast([*]const vk.SubmitInfo, &submit_into), self.transfer_fence);

    _ = vkd.waitForFences(device, 1, @ptrCast([*]const vk.Fence, &self.transfer_fence), vk.TRUE, std.time.ns_per_s) catch {};
    try vkd.resetFences(device, 1, @ptrCast([*]const vk.Fence, &self.transfer_fence));

    self.incoherent_memory_count = 0;
    self.incoherent_memory_bytes = 0;
    try vkd.resetCommandPool(device, self.command_pool, .{});
}
