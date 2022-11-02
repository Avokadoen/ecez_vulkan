const std = @import("std");
const Allocator = std.mem.Allocator;

const builtin = @import("builtin");

const vk = @import("vulkan");
const glfw = @import("glfw");

const RenderContext = @This();

const is_debug_build = builtin.mode == .Debug;

vkb: BaseDispatch,
vki: InstanceDispatch,

// in debug builds this will be something, but in release this is null
debug_messenger: ?vk.DebugUtilsMessengerEXT,

instance: vk.Instance,
physical_device: vk.PhysicalDevice,

queue_family_indices: QueueFamilyIndices,

// device: vk.Device,

pub fn init(allocator: Allocator) !RenderContext {
    // bind the glfw instance proc pointer
    const vk_proc = @ptrCast(fn (instance: vk.Instance, procname: [*:0]const u8) callconv(.C) vk.PfnVoidFunction, glfw.getInstanceProcAddress);
    const vkb = try BaseDispatch.load(vk_proc);

    // create the vk instance
    const instance = blk: {
        const application_info = vk.ApplicationInfo{
            .p_application_name = "ecez-vulkan",
            .application_version = vk.makeApiVersion(0, 1, 0, 0),
            .p_engine_name = "ecez-vulkan",
            .engine_version = vk.makeApiVersion(0, 1, 0, 0),
            .api_version = vk.API_VERSION_1_3,
        };

        // initialize extension list
        var extensions = std.ArrayList([*:0]const u8).init(allocator);
        defer extensions.deinit();

        // append glfw extensions
        const glfw_extensions = try glfw.getRequiredInstanceExtensions();
        try extensions.appendSlice(glfw_extensions);

        // add the debug utils extension
        try extensions.append(vk.extension_info.ext_debug_utils.name);

        // get validation layers if we are in debug mode
        const validation_layers = try getValidationLayers(allocator, vkb);

        const instance_info = vk.InstanceCreateInfo{
            .flags = .{},
            .p_next = if (is_debug_build) null else &debug_message_info,
            .p_application_info = &application_info,
            .enabled_layer_count = @intCast(u32, validation_layers.len),
            .pp_enabled_layer_names = validation_layers.ptr,
            .enabled_extension_count = @intCast(u32, extensions.items.len),
            .pp_enabled_extension_names = extensions.items.ptr,
        };
        break :blk (try vkb.createInstance(&instance_info, null));
    };

    const vki = try InstanceDispatch.load(instance, vk_proc);

    // register message callback in debug
    const debug_messenger = try setupDebugMessenger(vki, instance);
    const physical_device = try selectPhysicalDevice(allocator, instance, vki);
    const queue_family_indices = try QueueFamilyIndices.init(allocator, vki, physical_device);

    return RenderContext{
        .vkb = vkb,
        .vki = vki,
        .debug_messenger = debug_messenger,
        .instance = instance,
        .physical_device = physical_device,
        .queue_family_indices = queue_family_indices,
    };
}

pub fn deinit(self: RenderContext) void {
    if (is_debug_build) {
        // this is never null in debug builds so we can "safely" unwrap the value
        const debug_messenger = self.debug_messenger.?;
        self.vki.destroyDebugUtilsMessengerEXT(self.instance, debug_messenger, null);
    }

    self.vki.destroyInstance(self.instance, null);
}

// TODO: verify that it's sane to panic instead of error return
inline fn selectPhysicalDevice(allocator: Allocator, instance: vk.Instance, vki: InstanceDispatch) !vk.PhysicalDevice {
    var device_count: u32 = undefined;
    _ = try vki.enumeratePhysicalDevices(instance, &device_count, null);

    if (device_count == 0) {
        std.debug.panic("failed to find any GPU with vulkan support", .{});
    }

    const devices = try allocator.alloc(vk.PhysicalDevice, device_count);
    defer allocator.free(devices);

    _ = try vki.enumeratePhysicalDevices(instance, &device_count, devices.ptr);

    var selected_index: usize = 0;
    var selected_device = devices[selected_index];
    var selected_queue_families = try QueueFamilyIndices.init(allocator, vki, selected_device);
    while (selected_queue_families.is_complete() == false) {
        selected_index += 1;
        if (selected_index >= devices.len) {
            std.debug.panic("failed to find GPU with required queues", .{});
        }

        selected_device = devices[selected_index];
        selected_queue_families = try QueueFamilyIndices.init(allocator, vki, selected_device);
    }

    var selected_device_properties: vk.PhysicalDeviceProperties = vki.getPhysicalDeviceProperties(selected_device);
    var selected_device_features: vk.PhysicalDeviceFeatures = vki.getPhysicalDeviceFeatures(selected_device);

    device_search: for (devices[1..]) |current_device| {
        var current_queue_families = try QueueFamilyIndices.init(allocator, vki, current_device);
        if (current_queue_families.is_complete() == false) {
            continue :device_search;
        }

        var current_device_properties: vk.PhysicalDeviceProperties = vki.getPhysicalDeviceProperties(current_device);
        // if we have a discrete GPU and other GPU is not discrete then we do not select it
        if (selected_device_properties.device_type == .discrete_gpu and current_device_properties.device_type != .discrete_gpu) {
            continue :device_search;
        }

        {
            var selected_limit_score: u32 = 0;
            var current_limit_score: u32 = 0;

            const limits_info = @typeInfo(vk.PhysicalDeviceLimits).Struct;
            limit_grading: inline for (limits_info.fields) |field| {
                // TODO: check arrays and flags as well
                if (field.field_type != u32 and field.field_type != f32) {
                    continue :limit_grading;
                }

                const selected_limit_field = @field(selected_device_properties.limits, field.name);
                const current_limit_field = @field(current_device_properties.limits, field.name);

                selected_limit_score += @intCast(u32, @boolToInt(selected_limit_field > current_limit_field));
                current_limit_score += @intCast(u32, @boolToInt(selected_limit_field < current_limit_field));
            }

            if (current_limit_score < selected_limit_score) {
                continue :device_search;
            }
        }

        var current_device_features: vk.PhysicalDeviceFeatures = vki.getPhysicalDeviceFeatures(current_device);
        var selected_feature_sum: u32 = 0;
        var current_feature_sum: u32 = 0;
        const feature_info = @typeInfo(vk.PhysicalDeviceFeatures).Struct;
        inline for (feature_info.fields) |field| {
            if (field.field_type != vk.Bool32) {
                @compileError("unexpected field type"); // something has changed in vk wrapper
            }

            selected_feature_sum += @intCast(u32, @field(selected_device_features, field.name));
            current_feature_sum += @intCast(u32, @field(current_device_features, field.name));
        }

        // if current should be selected
        if (selected_feature_sum < current_feature_sum) {
            selected_device = current_device;
            selected_device_properties = current_device_properties;
            selected_device_features = current_device_features;
            selected_queue_families = current_queue_families;
        }
    }

    if (is_debug_build) {
        std.debug.print("\nselected gpu: {s}\n", .{selected_device_properties.device_name});
    }

    return selected_device;
}

pub const QueueFamilyIndices = struct {
    graphics_family: ?u32,

    pub fn init(allocator: Allocator, vki: InstanceDispatch, physical_device: vk.PhysicalDevice) !QueueFamilyIndices {
        const queue_families_properties = blk: {
            var family_count: u32 = undefined;
            vki.getPhysicalDeviceQueueFamilyProperties(physical_device, &family_count, null);
            if (family_count == 0) {
                return error.FailedToRetrieveQueueFamilies;
            }

            // TODO: use inline switch here to avoid alloc and used stack memory instead :)
            //       we need stage 2 to do this ...
            //       we can then remove allocator from signature and error return!
            const families = try allocator.alloc(vk.QueueFamilyProperties, family_count);
            vki.getPhysicalDeviceQueueFamilyProperties(physical_device, &family_count, families.ptr);

            break :blk families;
        };
        defer allocator.free(queue_families_properties);

        var queues: QueueFamilyIndices = QueueFamilyIndices{
            .graphics_family = null,
        };

        const graphics_bit = vk.QueueFlags{ .graphics_bit = true };
        for (queue_families_properties) |property, i| {
            if ((property.queue_flags.contains(graphics_bit))) {
                queues.graphics_family = @intCast(u32, i);

                if (queues.is_complete()) break;
            }
        }

        return queues;
    }

    pub inline fn is_complete(self: QueueFamilyIndices) bool {
        return self.graphics_family != null;
    }
};

const BaseDispatch = vk.BaseWrapper(.{
    .createInstance = true,
    .enumerateInstanceLayerProperties = true,
});

const InstanceDispatch = vk.InstanceWrapper(.{
    .destroyInstance = true,
    .enumeratePhysicalDevices = true,
    .getPhysicalDeviceProperties = true,
    .getPhysicalDeviceFeatures = true,
    .getPhysicalDeviceQueueFamilyProperties = true,
    .createDebugUtilsMessengerEXT = is_debug_build,
    .destroyDebugUtilsMessengerEXT = is_debug_build,
});

const debug_message_info = vk.DebugUtilsMessengerCreateInfoEXT{
    .flags = .{},
    .message_severity = .{
        .verbose_bit_ext = true,
        .warning_bit_ext = true,
        .error_bit_ext = true,
    },
    .message_type = .{
        .general_bit_ext = true,
        .validation_bit_ext = true,
        .performance_bit_ext = true,
    },
    .pfn_user_callback = messageCallback,
    .p_user_data = null,
};

/// set up debug messenger if we are in a debug build
inline fn setupDebugMessenger(vki: InstanceDispatch, instance: vk.Instance) !?vk.DebugUtilsMessengerEXT {
    if (comptime (is_debug_build == false)) {
        return null;
    }

    return (try vki.createDebugUtilsMessengerEXT(instance, &debug_message_info, null));
}

inline fn getValidationLayers(allocator: Allocator, vkb: BaseDispatch) ![]const [*:0]const u8 {
    if (comptime (is_debug_build == false)) {
        return &[0][*:0]const u8{};
    }

    const desired_layers = [_][*:0]const u8{
        "VK_LAYER_KHRONOS_validation",
    };

    var layer_count: u32 = undefined;
    _ = try vkb.enumerateInstanceLayerProperties(&layer_count, null);

    var existing_layers = try allocator.alloc(vk.LayerProperties, layer_count);
    defer allocator.free(existing_layers);

    _ = try vkb.enumerateInstanceLayerProperties(&layer_count, existing_layers.ptr);

    inline for (desired_layers) |desired_layer| {
        var found: bool = false;

        inner: for (existing_layers) |existing_layer| {
            if (std.cstr.cmp(desired_layer, @ptrCast([*:0]const u8, &existing_layer.layer_name)) == 0) {
                found = true;
                break :inner;
            }
        }

        if (found == false) {
            return error.MissingValidationLayer;
        }
    }

    return &desired_layers;
}

fn messageCallback(
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT.IntType,
    message_types: vk.DebugUtilsMessageTypeFlagsEXT.IntType,
    p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    p_user_data: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    _ = p_user_data;
    _ = message_types;

    const error_mask = comptime blk: {
        break :blk vk.DebugUtilsMessageSeverityFlagsEXT{
            .warning_bit_ext = true,
            .error_bit_ext = true,
        };
    };
    const is_severe = (error_mask.toInt() & message_severity) > 0;
    const writer = if (is_severe) std.io.getStdErr().writer() else std.io.getStdOut().writer();

    if (p_callback_data) |data| {
        writer.print("validation layer: {s}\n", .{data.p_message}) catch {
            std.debug.print("error from stdout print in message callback", .{});
        };
    }

    return vk.FALSE;
}
