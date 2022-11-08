const std = @import("std");
const Allocator = std.mem.Allocator;

const builtin = @import("builtin");

const vk = @import("vulkan");
const glfw = @import("glfw");

const max_queue_families = 16;

const RenderContext = @This();

// TODO: reduce debug assert, replace with errors

const is_debug_build = builtin.mode == .Debug;

vkb: BaseDispatch,
vki: InstanceDispatch,
vkd: DeviceDispatch,

// in debug builds this will be something, but in release this is null
debug_messenger: ?vk.DebugUtilsMessengerEXT,

instance: vk.Instance,
physical_device: vk.PhysicalDevice,
device: vk.Device,

surface: vk.SurfaceKHR,
swapchain_support_details: SwapchainSupportDetails,
swapchain: vk.SwapchainKHR,
swapchain_images: []vk.Image,

queue_family_indices: QueueFamilyIndices,
graphics_queue: vk.Queue,

pub fn init(allocator: Allocator, window: glfw.Window) !RenderContext {
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

    errdefer vki.destroyInstance(instance, null);

    const surface = blk: {
        var s: vk.SurfaceKHR = undefined;
        const result = try glfw.createWindowSurface(instance, window, null, &s);
        if (@intToEnum(vk.Result, result) != vk.Result.success) {
            return error.FailedToCreateSurface;
        }
        break :blk s;
    };
    errdefer vki.destroySurfaceKHR(instance, surface, null);

    // register message callback in debug
    const debug_messenger = try setupDebugMessenger(vki, instance);
    errdefer {
        if (is_debug_build) {
            vki.destroyDebugUtilsMessengerEXT(instance, debug_messenger.?, null);
        }
    }

    const physical_device = try selectPhysicalDevice(allocator, instance, vki, surface);
    const swapchain_support_details = try SwapchainSupportDetails.init(allocator, vki, physical_device, surface);
    const queue_family_indices = try QueueFamilyIndices.init(vki, physical_device, surface);
    const device = try createLogicalDevice(vki, physical_device, queue_family_indices);
    const vkd = try DeviceDispatch.load(device, vki.dispatch.vkGetDeviceProcAddr);
    errdefer vkd.destroyDevice(device, null);

    const graphics_queue = vkd.getDeviceQueue(device, queue_family_indices.graphics.?.index, 0);

    const swapchain = try createSwapchain(vkd, swapchain_support_details, surface, device, window);
    errdefer vkd.destroySwapchainKHR(device, swapchain, null);

    const swapchain_images = blk: {
        var image_count: u32 = undefined;
        _ = try vkd.getSwapchainImagesKHR(device, swapchain, &image_count, null);

        var images = try allocator.alloc(vk.Image, image_count);
        errdefer allocator.free(images);

        _ = try vkd.getSwapchainImagesKHR(device, swapchain, &image_count, images.ptr);

        break :blk images;
    };
    errdefer allocator.free(swapchain_images);

    return RenderContext{
        .vkb = vkb,
        .vki = vki,
        .vkd = vkd,
        .debug_messenger = debug_messenger,
        .instance = instance,
        .surface = surface,
        .physical_device = physical_device,
        .device = device,
        .swapchain_support_details = swapchain_support_details,
        .swapchain = swapchain,
        .swapchain_images = swapchain_images,
        .queue_family_indices = queue_family_indices,
        .graphics_queue = graphics_queue,
    };
}

pub fn deinit(self: RenderContext, allocator: Allocator) void {
    allocator.free(self.swapchain_images);
    self.swapchain_support_details.deinit(allocator);

    self.vkd.destroySwapchainKHR(self.device, self.swapchain, null);
    self.vki.destroySurfaceKHR(self.instance, self.surface, null);
    self.vkd.destroyDevice(self.device, null);

    if (is_debug_build) {
        // this is never null in debug builds so we can "safely" unwrap the value
        const debug_messenger = self.debug_messenger.?;
        self.vki.destroyDebugUtilsMessengerEXT(self.instance, debug_messenger, null);
    }

    self.vki.destroyInstance(self.instance, null);
}

// TODO: verify that it's sane to panic instead of error return
inline fn selectPhysicalDevice(allocator: Allocator, instance: vk.Instance, vki: InstanceDispatch, surface: vk.SurfaceKHR) !vk.PhysicalDevice {
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
    var selected_queue_families = try QueueFamilyIndices.init(vki, selected_device, surface);
    while (selected_queue_families.is_complete() == false) {
        selected_index += 1;
        if (selected_index >= devices.len) {
            std.debug.panic("failed to find GPU with required queues", .{});
        }

        selected_device = devices[selected_index];
        selected_queue_families = try QueueFamilyIndices.init(vki, selected_device, surface);
    }

    var selected_device_properties: vk.PhysicalDeviceProperties = vki.getPhysicalDeviceProperties(selected_device);
    var selected_device_features: vk.PhysicalDeviceFeatures = vki.getPhysicalDeviceFeatures(selected_device);

    device_search: for (devices[1..]) |current_device| {
        var current_queue_families = try QueueFamilyIndices.init(vki, current_device, surface);
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
    pub const FamilyEntry = struct {
        index: u32,
        support_present: bool,
    };

    graphics: ?FamilyEntry,
    compute: ?FamilyEntry,
    transfer: ?FamilyEntry,

    pub fn init(vki: InstanceDispatch, physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !QueueFamilyIndices {
        var queues: QueueFamilyIndices = QueueFamilyIndices{
            .graphics = null,
            .compute = null,
            .transfer = null,
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
            }

            // grab dedicated compute family index if any
            const is_dedicated_compute = !flags.graphics_bit and flags.compute_bit;
            if (is_dedicated_compute or (queues.compute == null and flags.contains(vk.QueueFlags{ .compute_bit = true }))) {
                const index = @intCast(u32, i);
                const support_present = (try vki.getPhysicalDeviceSurfaceSupportKHR(physical_device, index, surface)) != 0;
                queues.compute = FamilyEntry{ .index = index, .support_present = support_present };
            }

            // grab dedicated transfer family index if any
            const is_dedicated_transfer = !flags.graphics_bit and !flags.compute_bit and flags.transfer_bit;
            if (is_dedicated_transfer or (queues.transfer == null and flags.contains(vk.QueueFlags{ .transfer_bit = true }))) {
                const index = @intCast(u32, i);
                const support_present = (try vki.getPhysicalDeviceSurfaceSupportKHR(physical_device, index, surface)) != 0;
                queues.transfer = FamilyEntry{ .index = index, .support_present = support_present };
            }
        }

        return queues;
    }

    pub inline fn is_complete(self: QueueFamilyIndices) bool {
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
        for (required_extensions) |required_extension| {
            for (available_extensions[0..extension_count]) |available_extension| {
                if (std.cstr.cmp(required_extension, @ptrCast([*:0]const u8, &available_extension.extension_name)) == 0) {
                    matched_extensions += 1;
                    break;
                }
            }
        }

        return matched_extensions == required_extensions.len;
    }
};

pub const SwapchainSupportDetails = struct {
    capabilities: vk.SurfaceCapabilitiesKHR,
    formats: []vk.SurfaceFormatKHR,
    present_modes: []vk.PresentModeKHR,

    pub fn init(allocator: Allocator, vki: InstanceDispatch, physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !SwapchainSupportDetails {
        const capabilities = try vki.getPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface);

        const formats = blk: {
            var format_count: u32 = undefined;
            _ = try vki.getPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, null);

            if (format_count == 0) {
                return error.DeviceSurfaceMissingFormats;
            }

            var f = try allocator.alloc(vk.SurfaceFormatKHR, format_count);
            errdefer allocator.free(f);

            _ = try vki.getPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, f.ptr);
            break :blk f;
        };
        errdefer allocator.free(formats);

        const present_modes = blk: {
            var present_count: u32 = undefined;
            _ = try vki.getPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &present_count, null);

            if (present_count == 0) {
                return error.DeviceSurfaceMissingPresentModes;
            }

            var p = try allocator.alloc(vk.PresentModeKHR, present_count);
            errdefer allocator.free(p);

            _ = try vki.getPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &present_count, p.ptr);
            break :blk p;
        };
        errdefer allocator.free(present_modes);

        return SwapchainSupportDetails{
            .capabilities = capabilities,
            .formats = formats,
            .present_modes = present_modes,
        };
    }

    pub fn deinit(self: SwapchainSupportDetails, allocator: Allocator) void {
        allocator.free(self.formats);
        allocator.free(self.present_modes);
    }

    pub inline fn chooseSurfaceFormat(self: SwapchainSupportDetails) vk.SurfaceFormatKHR {
        for (self.formats) |format| {
            if (format.format == .r8g8b8a8_srgb and format.color_space == .srgb_nonlinear_khr) {
                return format;
            }
        }
        return self.formats[0];
    }

    pub inline fn choosePresentMode(self: SwapchainSupportDetails) vk.PresentModeKHR {
        for (self.present_modes) |present_mode| {
            if (present_mode == .mailbox_khr) {
                return present_mode;
            }
        }
        return .fifo_khr;
    }

    pub inline fn chooseExtent(self: SwapchainSupportDetails, window: glfw.Window) !vk.Extent2D {
        if (self.capabilities.current_extent.width != std.math.maxInt(u32)) {
            return self.capabilities.current_extent;
        }

        const frame_buffer_size = try window.getFramebufferSize();

        var actual_extent = vk.Extent2D{
            .width = frame_buffer_size.width,
            .height = frame_buffer_size.height,
        };

        actual_extent.width = std.math.clamp(
            actual_extent.width,
            self.capabilities.min_image_extent.width,
            self.capabilities.max_image_extent.width,
        );
        actual_extent.height = std.math.clamp(
            actual_extent.height,
            self.capabilities.min_image_extent.height,
            self.capabilities.max_image_extent.height,
        );

        return actual_extent;
    }
};

inline fn createSwapchain(
    vkd: DeviceDispatch,
    swapchain_support_details: SwapchainSupportDetails,
    surface: vk.SurfaceKHR,
    device: vk.Device,
    window: glfw.Window,
) !vk.SwapchainKHR {
    const surface_format = swapchain_support_details.chooseSurfaceFormat();
    const present_mode = swapchain_support_details.choosePresentMode();
    const extent = try swapchain_support_details.chooseExtent(window);

    const image_count = blk: {
        if (swapchain_support_details.capabilities.max_image_count > 0 and
            swapchain_support_details.capabilities.min_image_count + 1 > swapchain_support_details.capabilities.max_image_count)
        {
            break :blk swapchain_support_details.capabilities.max_image_count;
        }

        break :blk swapchain_support_details.capabilities.min_image_count + 1;
    };

    const create_info = vk.SwapchainCreateInfoKHR{
        .flags = .{},
        .surface = surface,
        .min_image_count = image_count,
        .image_format = surface_format.format,
        .image_color_space = surface_format.color_space,
        .image_extent = extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true },
        .image_sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .pre_transform = swapchain_support_details.capabilities.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = present_mode,
        .clipped = vk.TRUE,
        .old_swapchain = .null_handle,
    };
    return vkd.createSwapchainKHR(device, &create_info, null);
}

inline fn createLogicalDevice(
    vki: InstanceDispatch,
    physical_device: vk.PhysicalDevice,
    queue_families: QueueFamilyIndices,
) InstanceDispatch.CreateDeviceError!vk.Device {
    const queue_priorities = [_]f32{1};
    const queue_create_info = [1]vk.DeviceQueueCreateInfo{.{
        .flags = .{},
        .queue_family_index = queue_families.graphics.?.index,
        .queue_count = 1,
        .p_queue_priorities = &queue_priorities,
    }};

    const device_features = vk.PhysicalDeviceFeatures{};
    const create_info = vk.DeviceCreateInfo{
        .flags = .{},
        .queue_create_info_count = queue_create_info.len,
        .p_queue_create_infos = &queue_create_info,
        .enabled_layer_count = if (is_debug_build) desired_layers.len else 0,
        .pp_enabled_layer_names = &desired_layers,
        .enabled_extension_count = required_extensions_cstr.len,
        .pp_enabled_extension_names = &required_extensions_cstr,
        .p_enabled_features = &device_features,
    };
    return vki.createDevice(physical_device, &create_info, null);
}

const BaseDispatch = vk.BaseWrapper(.{
    .createInstance = true,
    .enumerateInstanceLayerProperties = true,
});

const InstanceDispatch = vk.InstanceWrapper(.{
    .createDevice = true,
    .destroyInstance = true,
    .enumeratePhysicalDevices = true,
    .enumerateDeviceExtensionProperties = true,
    .getPhysicalDeviceProperties = true,
    .getPhysicalDeviceFeatures = true,
    .getPhysicalDeviceQueueFamilyProperties = true,
    .getPhysicalDeviceSurfaceSupportKHR = true,
    .getPhysicalDeviceSurfaceCapabilitiesKHR = true,
    .getPhysicalDeviceSurfaceFormatsKHR = true,
    .getPhysicalDeviceSurfacePresentModesKHR = true,
    .getDeviceProcAddr = true,
    .createDebugUtilsMessengerEXT = is_debug_build,
    .destroyDebugUtilsMessengerEXT = is_debug_build,
    .destroySurfaceKHR = true,
});

const DeviceDispatch = vk.DeviceWrapper(.{
    .createSwapchainKHR = true,
    .destroyDevice = true,
    .destroySwapchainKHR = true,
    .getDeviceQueue = true,
    .getSwapchainImagesKHR = true,
});

const debug_message_info = vk.DebugUtilsMessengerCreateInfoEXT{
    .flags = .{},
    .message_severity = .{
        .verbose_bit_ext = false,
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

const required_extensions = [_][:0]const u8{
    vk.extension_info.khr_swapchain.name,
    vk.extension_info.khr_synchronization_2.name,
};

const required_extensions_cstr = [_][*:0]const u8{
    vk.extension_info.khr_swapchain.name,
    vk.extension_info.khr_synchronization_2.name,
};

const desired_layers = [_][*:0]const u8{
    "VK_LAYER_KHRONOS_validation",
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
