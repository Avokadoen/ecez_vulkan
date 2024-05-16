const std = @import("std");

const vk = @import("vulkan");

const vk_dispatch = @import("vk_dispatch.zig");
const InstanceDispatch = vk_dispatch.InstanceDispatch;
const DeviceDispatch = vk_dispatch.DeviceDispatch;

pub const bytes_in_kilobyte = 1024;
pub const bytes_in_megabyte = bytes_in_kilobyte * kilobyte_in_megabyte;
pub const kilobyte_in_megabyte = 1024;

pub inline fn createBuffer(
    vkd: DeviceDispatch,
    device: vk.Device,
    non_coherent_atom_size: vk.DeviceSize,
    size: vk.DeviceSize,
    usage: vk.BufferUsageFlags,
) !vk.Buffer {
    const buffer_info = vk.BufferCreateInfo{
        .flags = .{},
        .size = pow2Align(non_coherent_atom_size, size),
        .usage = usage,
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    };
    return vkd.createBuffer(device, &buffer_info, null);
}

// TODO: rename createBufferDeviceMemory
pub inline fn createDeviceMemory(
    vkd: DeviceDispatch,
    device: vk.Device,
    vki: InstanceDispatch,
    physical_device: vk.PhysicalDevice,
    buffer: vk.Buffer,
    property_flags: vk.MemoryPropertyFlags,
) !vk.DeviceMemory {
    const memory_requirements = vkd.getBufferMemoryRequirements(device, buffer);
    // TODO: better memory ..
    const memory_type_index = try findMemoryTypeIndex(
        vki,
        physical_device,
        memory_requirements.memory_type_bits,
        property_flags,
    );

    const allocation_info = vk.MemoryAllocateInfo{
        .allocation_size = memory_requirements.size,
        .memory_type_index = memory_type_index,
    };
    return vkd.allocateMemory(device, &allocation_info, null);
}

pub inline fn createDeviceImageMemory(
    vki: InstanceDispatch,
    physical_device: vk.PhysicalDevice,
    vkd: DeviceDispatch,
    device: vk.Device,
    images: []const vk.Image,
) !vk.DeviceMemory {
    var allocation_size: vk.DeviceSize = 0;
    var memory_type_bits: u32 = 0;
    for (images) |image| {
        const memory_requirements = vkd.getImageMemoryRequirements(device, image);
        allocation_size += pow2Align(memory_requirements.alignment, memory_requirements.size);
        memory_type_bits |= memory_requirements.memory_type_bits;
    }

    const allocation_info = vk.MemoryAllocateInfo{
        .allocation_size = allocation_size,
        .memory_type_index = try findMemoryTypeIndex(vki, physical_device, memory_type_bits, .{ .device_local_bit = true }),
    };

    return vkd.allocateMemory(device, &allocation_info, null);
}

pub inline fn findMemoryTypeIndex(vki: InstanceDispatch, physical_device: vk.PhysicalDevice, type_filter: u32, property_flags: vk.MemoryPropertyFlags) !u32 {
    const properties = vki.getPhysicalDeviceMemoryProperties(physical_device);
    for (properties.memory_types[0..properties.memory_type_count], 0..) |memory_type, i| {
        std.debug.assert(i < 32);

        const u5_i = @as(u5, @intCast(i));
        const type_match = (type_filter & (@as(u32, 1) << u5_i)) != 0;
        const property_match = memory_type.property_flags.contains(property_flags);
        if (type_match and property_match) {
            return @as(u32, @intCast(i));
        }
    }

    return error.NotFound;
}

pub fn transferMemoryToDevice(
    vkd: DeviceDispatch,
    device: vk.Device,
    memory: vk.DeviceMemory,
    non_coherent_atom_size: vk.DeviceSize,
    comptime T: type,
    data: []const T,
) !void {
    const raw_data = std.mem.sliceAsBytes(data);

    const aligned_memory_size = pow2Align(non_coherent_atom_size, @as(vk.DeviceSize, @intCast(raw_data.len)));

    const device_data = blk: {
        const raw_device_ptr = try vkd.mapMemory(device, memory, 0, aligned_memory_size, .{});
        break :blk @as([*]u8, @ptrCast(raw_device_ptr))[0..raw_data.len];
    };
    defer vkd.unmapMemory(device, memory);

    @memcpy(device_data, raw_data);

    // TODO: defer flush
    const mapped_range = vk.MappedMemoryRange{
        .memory = memory,
        .offset = 0,
        .size = aligned_memory_size,
    };
    try vkd.flushMappedMemoryRanges(device, 1, @as([*]const vk.MappedMemoryRange, @ptrCast(&mapped_range)));
}

pub inline fn pow2Align(alignment: vk.DeviceSize, size: vk.DeviceSize) vk.DeviceSize {
    return (size + alignment - 1) & ~(alignment - 1);
}

pub inline fn aribtraryAlign(alignment: vk.DeviceSize, size: vk.DeviceSize) vk.DeviceSize {
    const rem = size % alignment;
    return if (rem != 0) size + (alignment - rem) else size;
}
