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
        .size = getAlignedDeviceSize(non_coherent_atom_size, size),
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
        allocation_size += getAlignedDeviceSize(memory_requirements.alignment, memory_requirements.size);
        memory_type_bits |= memory_requirements.memory_type_bits;
    }

    const allocation_info = vk.MemoryAllocateInfo{
        .allocation_size = allocation_size,
        .memory_type_index = try findMemoryTypeIndex(vki, physical_device, memory_type_bits, .{ .device_local_bit = true }),
    };

    return vkd.allocateMemory(device, &allocation_info, null);
}

inline fn findMemoryTypeIndex(vki: InstanceDispatch, physical_device: vk.PhysicalDevice, type_filter: u32, property_flags: vk.MemoryPropertyFlags) !u32 {
    const properties = vki.getPhysicalDeviceMemoryProperties(physical_device);
    for (properties.memory_types[0..properties.memory_type_count]) |memory_type, i| {
        std.debug.assert(i < 32);

        const u5_i = @intCast(u5, i);
        const type_match = (type_filter & (@as(u32, 1) << u5_i)) != 0;
        const property_match = memory_type.property_flags.contains(property_flags);
        if (type_match and property_match) {
            return @intCast(u32, i);
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

    const aligned_memory_size = getAlignedDeviceSize(non_coherent_atom_size, @intCast(vk.DeviceSize, raw_data.len));

    var device_data = blk: {
        var raw_device_ptr = try vkd.mapMemory(device, memory, 0, aligned_memory_size, .{});
        break :blk @ptrCast([*]u8, raw_device_ptr)[0..raw_data.len];
    };
    defer vkd.unmapMemory(device, memory);

    std.mem.copy(u8, device_data, raw_data);

    // TODO: defer flush
    const mapped_range = vk.MappedMemoryRange{
        .memory = memory,
        .offset = 0,
        .size = aligned_memory_size,
    };
    try vkd.flushMappedMemoryRanges(device, 1, @ptrCast([*]const vk.MappedMemoryRange, &mapped_range));
}

pub inline fn getAlignedDeviceSize(non_coherent_atom_size: vk.DeviceSize, size: vk.DeviceSize) vk.DeviceSize {
    return (size + non_coherent_atom_size - 1) & ~(non_coherent_atom_size - 1);
}
