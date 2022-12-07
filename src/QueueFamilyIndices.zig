const std = @import("std");

const vk = @import("vulkan");

const application_ext_layers = @import("application_ext_layers.zig");

const vk_dispatch = @import("vk_dispatch.zig");
const InstanceDispatch = vk_dispatch.InstanceDispatch;
const DeviceDispatch = vk_dispatch.DeviceDispatch;

const QueueFamilyIndices = @This();

const max_queue_families = 16;

pub const FamilyEntry = struct {
    index: u32,
    support_present: bool,
};

graphics: ?FamilyEntry,
graphics_queue_count: u32,

compute: ?FamilyEntry,
compute_queue_count: u32,

transfer: ?FamilyEntry,
transfer_queue_count: u32,

pub fn init(vki: InstanceDispatch, physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !QueueFamilyIndices {
    var queues: QueueFamilyIndices = QueueFamilyIndices{
        .graphics = null,
        .graphics_queue_count = 0,
        .compute = null,
        .compute_queue_count = 0,
        .transfer = null,
        .transfer_queue_count = 0,
    };

    if ((try checkDeviceExtensionSupport(vki, physical_device)) == false) {
        return queues;
    }

    var queue_arr: [max_queue_families]vk.QueueFamilyProperties = undefined;
    const queue_families_properties = blk: {
        var family_count: u32 = undefined;
        vki.getPhysicalDeviceQueueFamilyProperties(physical_device, &family_count, null);
        std.debug.assert(family_count <= max_queue_families);

        if (family_count == 0) {
            return queues;
        }

        // TODO: use inline switch here. We need stage 2 to do this ...
        vki.getPhysicalDeviceQueueFamilyProperties(physical_device, &family_count, &queue_arr);

        break :blk queue_arr[0..family_count];
    };

    // TODO: account for timestamp_valid_bits
    for (queue_families_properties) |property, i| {
        const flags = property.queue_flags;

        // graphics queue is usually the first and only one with this bit
        if ((flags.contains(vk.QueueFlags{ .graphics_bit = true }))) {
            const index = @intCast(u32, i);
            const support_present = (try vki.getPhysicalDeviceSurfaceSupportKHR(physical_device, index, surface)) != 0;
            queues.graphics = FamilyEntry{ .index = index, .support_present = support_present };
            queues.graphics_queue_count = property.queue_count;
        }

        // grab dedicated compute family index if any
        const is_dedicated_compute = !flags.graphics_bit and flags.compute_bit;
        if (is_dedicated_compute or (queues.compute == null and flags.contains(vk.QueueFlags{ .compute_bit = true }))) {
            const index = @intCast(u32, i);
            const support_present = (try vki.getPhysicalDeviceSurfaceSupportKHR(physical_device, index, surface)) != 0;
            queues.compute = FamilyEntry{ .index = index, .support_present = support_present };
            queues.compute_queue_count = property.queue_count;
        }

        // grab dedicated transfer family index if any
        const is_dedicated_transfer = !flags.graphics_bit and !flags.compute_bit and flags.transfer_bit;
        if (is_dedicated_transfer or (queues.transfer == null and flags.contains(vk.QueueFlags{ .transfer_bit = true }))) {
            const index = @intCast(u32, i);
            const support_present = (try vki.getPhysicalDeviceSurfaceSupportKHR(physical_device, index, surface)) != 0;
            queues.transfer = FamilyEntry{ .index = index, .support_present = support_present };
            queues.transfer_queue_count = property.queue_count;
        }
    }

    return queues;
}

pub inline fn graphicsIndex(self: QueueFamilyIndices) u32 {
    return self.graphics.?.index;
}

pub inline fn transferIndex(self: QueueFamilyIndices) u32 {
    return self.transfer.?.index;
}

pub inline fn isComplete(self: QueueFamilyIndices) bool {
    if (self.graphics == null or self.compute == null or self.transfer == null) {
        return false;
    }

    return self.graphics.?.support_present;
}

inline fn checkDeviceExtensionSupport(vki: InstanceDispatch, physical_device: vk.PhysicalDevice) !bool {
    var available_extensions: [1024]vk.ExtensionProperties = undefined;

    const extension_count: u32 = blk: {
        var count: u32 = undefined;
        var result = try vki.enumerateDeviceExtensionProperties(physical_device, null, &count, null);
        std.debug.assert(count < available_extensions.len);
        std.debug.assert(result == .success);

        result = try vki.enumerateDeviceExtensionProperties(physical_device, null, &count, &available_extensions);
        std.debug.assert(result == .success);

        break :blk count;
    };

    var matched_extensions: u8 = 0;
    for (application_ext_layers.required_extensions) |required_extension| {
        for (available_extensions[0..extension_count]) |available_extension| {
            if (std.cstr.cmp(required_extension, @ptrCast([*:0]const u8, &available_extension.extension_name)) == 0) {
                matched_extensions += 1;
                break;
            }
        }
    }

    return matched_extensions == application_ext_layers.required_extensions.len;
}
