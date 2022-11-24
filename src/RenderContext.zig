const std = @import("std");
const Allocator = std.mem.Allocator;

const builtin = @import("builtin");

const vk = @import("vulkan");
const glfw = @import("glfw");
const zm = @import("zmath");

const vk_dispatch = @import("vk_dispatch.zig");
const BaseDispatch = vk_dispatch.BaseDispatch;
const InstanceDispatch = vk_dispatch.InstanceDispatch;
const DeviceDispatch = vk_dispatch.DeviceDispatch;

const StagingBuffer = @import("StagingBuffer.zig");
const QueueFamilyIndices = @import("QueueFamilyIndices.zig");

const command = @import("command.zig");
const sync = @import("sync.zig");
const dmem = @import("device_memory.zig");
const application_ext_layers = @import("application_ext_layers.zig");

const is_debug_build = builtin.mode == .Debug;
const max_frames_in_flight = 2;

const RenderContext = @This();

// TODO: reduce debug assert, replace with errors
// TODO: use sync2

// TODO: placeholder
const Vertex = struct {
    pos: [2]f32,
    color: [3]f32,

    pub fn getBindingDescription() vk.VertexInputBindingDescription {
        return vk.VertexInputBindingDescription{
            .binding = 0,
            .stride = @sizeOf(Vertex),
            .input_rate = .vertex,
        };
    }

    pub fn getAttributeDescriptions() [2]vk.VertexInputAttributeDescription {
        return [2]vk.VertexInputAttributeDescription{
            .{
                .location = 0,
                .binding = 0,
                .format = .r32g32_sfloat,
                .offset = @offsetOf(Vertex, "pos"),
            },
            .{
                .location = 1,
                .binding = 0,
                .format = .r32g32b32_sfloat,
                .offset = @offsetOf(Vertex, "color"),
            },
        };
    }
};

const vertices = [_]Vertex{
    // zig fmt: off
    .{ .pos = .{ -0.5, -0.5 }, .color = .{ 1, 0, 0 } },
    .{ .pos = .{  0.5, -0.5 }, .color = .{ 0, 1, 0 } },
    .{ .pos = .{  0.5,  0.5 }, .color = .{ 0, 0, 1 } },
    .{ .pos = .{ -0.5,  0.5 }, .color = .{ 1, 1, 1 } },
    // zig fmt: on
};
const vertex_size: comptime_int = vertices.len * @sizeOf(Vertex);

const indices = [_]u16{ 
    0, 1, 2, 2, 3, 0
};

vkb: BaseDispatch,
vki: InstanceDispatch,
vkd: DeviceDispatch,

// in debug builds this will be something, but in release this is null
debug_messenger: ?vk.DebugUtilsMessengerEXT,

instance: vk.Instance,
physical_device: vk.PhysicalDevice,
device_properties: vk.PhysicalDeviceProperties,
device: vk.Device,

// TODO: abstraction: a "frame"? (all types that are slices here)

surface: vk.SurfaceKHR,
swapchain_support_details: SwapchainSupportDetails,
swapchain_extent: vk.Extent2D,
swapchain: vk.SwapchainKHR,
swapchain_images: []vk.Image,
swapchain_image_views: []vk.ImageView,

render_pass: vk.RenderPass,
framebuffers: []vk.Framebuffer,
pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,

command_pools: []vk.CommandPool,
command_buffers: []vk.CommandBuffer,

// used solely for memory management
all_semaphores: []vk.Semaphore,
image_available_semaphores: []vk.Semaphore,
render_finished_semaphores: []vk.Semaphore,
in_flight_fences: []vk.Fence,

current_frame: usize,

staging_buffer: StagingBuffer,

vertex_buffer_size: vk.DeviceSize,
index_buffer_size: vk.DeviceSize,
vertex_index_buffer: vk.Buffer,
vertex_index_memory: vk.DeviceMemory,

queue_family_indices: QueueFamilyIndices,
graphics_queue: vk.Queue,
transfer_queue: vk.Queue,

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

        if (is_debug_build) {
            // add the debug utils extension
            try extensions.append(vk.extension_info.ext_debug_utils.name);
        }

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
    const device_properties = vki.getPhysicalDeviceProperties(physical_device);

    const swapchain_support_details = try SwapchainSupportDetails.init(allocator, vki, physical_device, surface);
    errdefer swapchain_support_details.deinit(allocator);

    const queue_family_indices = try QueueFamilyIndices.init(vki, physical_device, surface);
    const device = try createLogicalDevice(vki, physical_device, queue_family_indices);
    const vkd = try DeviceDispatch.load(device, vki.dispatch.vkGetDeviceProcAddr);
    errdefer vkd.destroyDevice(device, null);

    const graphics_queue = vkd.getDeviceQueue(device, queue_family_indices.graphicsIndex(), 0);
    const transfer_queue = vkd.getDeviceQueue(device, queue_family_indices.transferIndex(), 0);

    const swapchain = try createSwapchain(
        vkd,
        swapchain_support_details,
        surface,
        device,
        window,
        null,
    );
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

    const swapchain_image_views = try allocator.alloc(vk.ImageView, swapchain_images.len);
    errdefer allocator.free(swapchain_image_views);
    try instantiateImageViews(
        swapchain_image_views,
        vkd,
        device,
        swapchain_images,
        swapchain_support_details.preferredFormat().format,
    );
    errdefer {
        for (swapchain_image_views) |image_view| {
            vkd.destroyImageView(device, image_view, null);
        }
    }

    const render_pass = try createRenderPass(vkd, device, swapchain_support_details.preferredFormat().format);
    errdefer vkd.destroyRenderPass(device, render_pass, null);

    const swapchain_extent = try swapchain_support_details.chooseExtent(window);

    var framebuffers = try allocator.alloc(vk.Framebuffer, swapchain_images.len);
    errdefer allocator.free(framebuffers);

    try instantiateFramebuffer(framebuffers, vkd, device, render_pass, swapchain_extent, swapchain_image_views);
    errdefer {
        for (framebuffers) |framebuffer| {
            vkd.destroyFramebuffer(device, framebuffer, null);
        }
    }

    const pipeline_layout = blk: {
        const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
            .flags = .{},
            .set_layout_count = 0,
            .p_set_layouts = undefined,
            .push_constant_range_count = 0,
            .p_push_constant_ranges = undefined,
        };
        break :blk try vkd.createPipelineLayout(device, &pipeline_layout_info, null);
    };
    errdefer vkd.destroyPipelineLayout(device, pipeline_layout, null);

    const pipeline = try createGraphicsPipeline(allocator, vkd, device, swapchain_extent, render_pass, pipeline_layout);
    errdefer vkd.destroyPipeline(device, pipeline, null);

    // TODO: spawn pools according to how many threads we have
    const command_pools = blk: {
        var pools = try allocator.alloc(vk.CommandPool, max_frames_in_flight);
        errdefer allocator.free(pools);

        var pools_initiated: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < pools_initiated) : (i += 1) {
                vkd.destroyCommandPool(device, pools[i], null);
            }
        }

        for (pools) |*pool| {
            pool.* = try command.createPool(vkd, device, queue_family_indices.graphicsIndex());
        }
        break :blk pools;
    };
    errdefer {
        for (command_pools) |pool| {
            vkd.destroyCommandPool(device, pool, null);
        }
        allocator.free(command_pools);
    }

    const command_buffers = blk: {
        var buffers = try allocator.alloc(vk.CommandBuffer, max_frames_in_flight);
        errdefer allocator.free(buffers);

        for (buffers) |*cmd_buffer, i| {
            cmd_buffer.* = try command.createBuffer(vkd, device, command_pools[i]);
        }
        break :blk buffers;
    };
    errdefer allocator.free(command_buffers);

    // create all sempahores we need which we can slice later
    const all_semaphores = blk: {
        var semaphores = try allocator.alloc(vk.Semaphore, max_frames_in_flight * 2);

        var initialized_semaphores: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < initialized_semaphores) : (i += 1) {
                vkd.destroySemaphore(device, semaphores[i], null);
            }
            allocator.free(semaphores);
        }

        for (semaphores) |*semaphore| {
            semaphore.* = try sync.createSemaphore(vkd, device);
            initialized_semaphores += 1;
        }

        break :blk semaphores;
    };
    errdefer {
        for (all_semaphores) |semaphore| {
            vkd.destroySemaphore(device, semaphore, null);
        }
        allocator.free(all_semaphores);
    }
    const image_available_semaphores = all_semaphores[0..max_frames_in_flight];
    const render_finished_semaphores = all_semaphores[max_frames_in_flight .. max_frames_in_flight * 2];

    const in_flight_fences = blk: {
        var fences = try allocator.alloc(vk.Fence, max_frames_in_flight);

        var initialized_fences: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < initialized_fences) : (i += 1) {
                vkd.destroyFence(device, fences[i], null);
            }
            allocator.free(fences);
        }

        for (fences) |*fence| {
            fence.* = try sync.createFence(vkd, device, true);
            initialized_fences += 1;
        }

        break :blk fences;
    };
    errdefer {
        for (in_flight_fences) |fence| {
            vkd.destroyFence(device, fence, null);
        }
        allocator.free(in_flight_fences);
    }

    const non_coherent_atom_size = device_properties.limits.non_coherent_atom_size;

    var staging_buffer = try StagingBuffer.init(
        vki,
        physical_device,
        vkd,
        device,
        non_coherent_atom_size,
        queue_family_indices.transferIndex(),
        transfer_queue,
        .{ .size = 64 * dmem.bytes_in_kilobyte },
    );
    errdefer staging_buffer.deinit(vkd, device);

    // TODO: simplfiy buffer aligned creation (createBuffer accept size array and do this internally)
    const vertex_buffer_size = dmem.getAlignedDeviceSize(non_coherent_atom_size, vertex_size);
    const index_buffer_size = dmem.getAlignedDeviceSize(non_coherent_atom_size, indices.len * @sizeOf(u16));
    // create device memory and transfer vertices to host
    const vertex_index_buffer = try dmem.createBuffer(
        vkd,
        device,
        non_coherent_atom_size,
        dmem.getAlignedDeviceSize(non_coherent_atom_size, vertex_buffer_size + index_buffer_size),
        .{ .transfer_dst_bit = true, .vertex_buffer_bit = true, .index_buffer_bit = true, },
    );
    errdefer vkd.destroyBuffer(device, vertex_index_buffer, null);
    const vertex_index_memory = try dmem.createDeviceMemory(
        vkd,
        device,
        vki,
        physical_device,
        vertex_index_buffer,
        .{ .device_local_bit = true },
    );
    errdefer vkd.freeMemory(device, vertex_index_memory, null);
    try vkd.bindBufferMemory(device, vertex_index_buffer, vertex_index_memory, 0);

    // TODO: scheduling transfer of data that is not atom aligned is problematic. How should this be communicated or enforced?
    try staging_buffer.scheduleTransfer(vkd, device, vertex_index_buffer, 0, Vertex, &vertices);
    try staging_buffer.scheduleTransfer(
        vkd, 
        device, 
        vertex_index_buffer, 
        vertex_buffer_size, 
        u16, 
        &indices,
    );
    try staging_buffer.flushAndCopyToDestination(vkd, device);

    return RenderContext{
        .vkb = vkb,
        .vki = vki,
        .vkd = vkd,
        .debug_messenger = debug_messenger,
        .instance = instance,
        .surface = surface,
        .physical_device = physical_device,
        .device_properties = device_properties,
        .device = device,
        .swapchain_support_details = swapchain_support_details,
        .swapchain_extent = swapchain_extent,
        .swapchain = swapchain,
        .swapchain_images = swapchain_images,
        .swapchain_image_views = swapchain_image_views,
        .render_pass = render_pass,
        .framebuffers = framebuffers,
        .pipeline_layout = pipeline_layout,
        .pipeline = pipeline,
        .command_pools = command_pools,
        .command_buffers = command_buffers,
        .all_semaphores = all_semaphores,
        .image_available_semaphores = image_available_semaphores,
        .render_finished_semaphores = render_finished_semaphores,
        .in_flight_fences = in_flight_fences,
        .current_frame = 0,
        .staging_buffer = staging_buffer,
        .vertex_buffer_size = vertex_buffer_size,
        .index_buffer_size = index_buffer_size,
        .vertex_index_buffer = vertex_index_buffer,
        .vertex_index_memory = vertex_index_memory,
        .queue_family_indices = queue_family_indices,
        .graphics_queue = graphics_queue,
        .transfer_queue = transfer_queue,
    };
}

pub fn recreatePresentResources(self: *RenderContext, window: glfw.Window) !void {
    { // destroy resource
        try self.vkd.deviceWaitIdle(self.device);

        // destroy outdated resources
        for (self.framebuffers) |framebuffer| {
            self.vkd.destroyFramebuffer(self.device, framebuffer, null);
        }
        for (self.swapchain_image_views) |image_view| {
            self.vkd.destroyImageView(self.device, image_view, null);
        }
    }

    try self.swapchain_support_details.reinit(self.vki, self.physical_device, self.surface);
    self.swapchain_extent = try self.swapchain_support_details.chooseExtent(window);

    const old_swapchain = self.swapchain;
    self.swapchain = try createSwapchain(
        self.vkd,
        self.swapchain_support_details,
        self.surface,
        self.device,
        window,
        old_swapchain,
    );
    self.vkd.destroySwapchainKHR(self.device, old_swapchain, null);

    var image_count = @intCast(u32, self.swapchain_images.len);
    _ = try self.vkd.getSwapchainImagesKHR(
        self.device,
        self.swapchain,
        &image_count,
        self.swapchain_images.ptr,
    );

    try instantiateImageViews(
        self.swapchain_image_views,
        self.vkd,
        self.device,
        self.swapchain_images,
        self.swapchain_support_details.preferredFormat().format,
    );
    try instantiateFramebuffer(
        self.framebuffers,
        self.vkd,
        self.device,
        self.render_pass,
        self.swapchain_extent,
        self.swapchain_image_views,
    );
}

pub fn deinit(self: RenderContext, allocator: Allocator) void {
    for (self.in_flight_fences) |fence| {
        // try to wait for fences, continue if it fails for any reason
        _ = self.vkd.waitForFences(self.device, 1, @ptrCast([*]const vk.Fence, &fence), vk.TRUE, std.time.ns_per_s) catch {};
    }

    self.staging_buffer.deinit(self.vkd, self.device);
    self.vkd.freeMemory(self.device, self.vertex_index_memory, null);
    self.vkd.destroyBuffer(self.device, self.vertex_index_buffer, null);

    for (self.framebuffers) |framebuffer| {
        self.vkd.destroyFramebuffer(self.device, framebuffer, null);
    }
    for (self.swapchain_image_views) |image_view| {
        self.vkd.destroyImageView(self.device, image_view, null);
    }
    self.vkd.destroySwapchainKHR(self.device, self.swapchain, null);

    for (self.in_flight_fences) |fence| {
        self.vkd.destroyFence(self.device, fence, null);
    }
    allocator.free(self.in_flight_fences);

    for (self.all_semaphores) |semaphore| {
        self.vkd.destroySemaphore(self.device, semaphore, null);
    }
    allocator.free(self.all_semaphores);

    for (self.command_pools) |pool| {
        self.vkd.destroyCommandPool(self.device, pool, null);
    }
    allocator.free(self.command_pools);
    allocator.free(self.command_buffers);

    self.vkd.destroyPipeline(self.device, self.pipeline, null);
    self.vkd.destroyPipelineLayout(self.device, self.pipeline_layout, null);

    self.vkd.destroyRenderPass(self.device, self.render_pass, null);

    allocator.free(self.framebuffers);
    allocator.free(self.swapchain_image_views);
    allocator.free(self.swapchain_images);
    self.swapchain_support_details.deinit(allocator);

    self.vki.destroySurfaceKHR(self.instance, self.surface, null);
    self.vkd.destroyDevice(self.device, null);

    if (is_debug_build) {
        // this is never null in debug builds so we can "safely" unwrap the value
        const debug_messenger = self.debug_messenger.?;
        self.vki.destroyDebugUtilsMessengerEXT(self.instance, debug_messenger, null);
    }

    self.vki.destroyInstance(self.instance, null);
}

pub fn drawFrame(self: *RenderContext, window: glfw.Window) !void {
    _ = try self.vkd.waitForFences(self.device, 1, @ptrCast([*]const vk.Fence, &self.in_flight_fences[self.current_frame]), vk.TRUE, std.math.maxInt(u64));

    var image_index: u32 = blk: {
        const result = self.vkd.acquireNextImageKHR(self.device, self.swapchain, std.math.maxInt(u64), self.image_available_semaphores[self.current_frame], .null_handle) catch |err| {
            switch (err) {
                error.OutOfDateKHR => {
                    try self.recreatePresentResources(window);
                    return;
                },
                else => return err,
            }
        };
        break :blk result.image_index;
    };

    try self.vkd.resetFences(self.device, 1, @ptrCast([*]const vk.Fence, &self.in_flight_fences[self.current_frame]));

    try self.vkd.resetCommandPool(self.device, self.command_pools[self.current_frame], .{});
    try recordGraphicsCommandBuffer(
        self.vkd,
        self.command_buffers[self.current_frame],
        self.render_pass,
        self.framebuffers[image_index],
        self.swapchain_extent,
        self.pipeline,
        self.vertex_buffer_size,
        self.vertex_index_buffer,
    );

    const wait_dst_stage_mask = vk.PipelineStageFlags{ .color_attachment_output_bit = true };
    const render_finish_semaphore = @ptrCast([*]const vk.Semaphore, &self.render_finished_semaphores[self.current_frame]);
    const submit_info = vk.SubmitInfo{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast([*]const vk.Semaphore, &self.image_available_semaphores[self.current_frame]),
        .p_wait_dst_stage_mask = @ptrCast([*]const vk.PipelineStageFlags, &wait_dst_stage_mask),
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast([*]const vk.CommandBuffer, &self.command_buffers[self.current_frame]),
        .signal_semaphore_count = 1,
        .p_signal_semaphores = render_finish_semaphore,
    };
    try self.vkd.queueSubmit(self.graphics_queue, 1, @ptrCast([*]const vk.SubmitInfo, &submit_info), self.in_flight_fences[self.current_frame]);

    const recreate_present_resources = blk: {
        const present_info = vk.PresentInfoKHR{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = render_finish_semaphore,
            .swapchain_count = 1,
            .p_swapchains = @ptrCast([*]const vk.SwapchainKHR, &self.swapchain),
            .p_image_indices = @ptrCast([*]const u32, &image_index),
            .p_results = null,
        };
        const result = self.vkd.queuePresentKHR(self.graphics_queue, &present_info) catch |err| {
            switch (err) {
                error.OutOfDateKHR => break :blk true,
                else => return err,
            }
        };

        break :blk result == vk.Result.suboptimal_khr;
    };

    self.current_frame = (self.current_frame + 1) % max_frames_in_flight;

    if (recreate_present_resources) {
        try self.recreatePresentResources(window);
    }
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
    while (selected_queue_families.isComplete() == false) {
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
        if (current_queue_families.isComplete() == false) {
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

pub fn handleFramebufferResize(self: *RenderContext, window: glfw.Window) void {
    const callback = struct {
        pub fn func(_window: glfw.Window, width: u32, height: u32) void {
            _ = width;
            _ = height;

            const ctx_self = _window.getUserPointer(RenderContext) orelse return;
            ctx_self.recreatePresentResources(_window) catch {};
        }
    }.func;
    window.setUserPointer(self);
    window.setFramebufferSizeCallback(callback);
}

pub const SwapchainSupportDetails = struct {
    capabilities: vk.SurfaceCapabilitiesKHR,

    preferred_format_index: usize,
    formats: []vk.SurfaceFormatKHR,

    preferred_present_mode: vk.PresentModeKHR,
    present_modes: []vk.PresentModeKHR,

    pub fn init(allocator: Allocator, vki: InstanceDispatch, physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !SwapchainSupportDetails {
        const capabilities = try vki.getPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface);

        const formats = blk: {
            var format_count: u32 = undefined;
            _ = try vki.getPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, null);

            if (format_count == 0) {
                return error.DeviceSurfaceMissingFormats;
            }

            break :blk try allocator.alloc(vk.SurfaceFormatKHR, format_count);
        };
        errdefer allocator.free(formats);
        var format_len: u32 = @intCast(u32, formats.len);
        _ = try vki.getPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_len, formats.ptr);

        const preferred_format_index = blk: {
            for (formats) |format, i| {
                if (format.format == .r8g8b8a8_srgb and format.color_space == .srgb_nonlinear_khr) {
                    break :blk i;
                }
            }
            break :blk 0;
        };

        const present_modes = blk: {
            var present_count: u32 = undefined;
            _ = try vki.getPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &present_count, null);
            if (present_count == 0) {
                return error.DeviceSurfaceMissingPresentModes;
            }

            break :blk try allocator.alloc(vk.PresentModeKHR, present_count);
        };
        errdefer allocator.free(present_modes);
        var present_modes_len: u32 = @intCast(u32, present_modes.len);
        _ = try vki.getPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &present_modes_len, present_modes.ptr);

        const preferred_present_mode = blk: {
            for (present_modes) |present_mode| {
                if (present_mode == .mailbox_khr) {
                    break :blk present_mode;
                }
            }
            break :blk .fifo_khr;
        };

        return SwapchainSupportDetails{
            .capabilities = capabilities,
            .formats = formats,
            .preferred_format_index = preferred_format_index,
            .present_modes = present_modes,
            .preferred_present_mode = preferred_present_mode,
        };
    }

    pub fn reinit(self: *SwapchainSupportDetails, vki: InstanceDispatch, physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !void {
        self.capabilities = try vki.getPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface);

        self.preferred_format_index = blk: {
            for (self.formats) |format, i| {
                if (format.format == .r8g8b8a8_srgb and format.color_space == .srgb_nonlinear_khr) {
                    break :blk i;
                }
            }
            break :blk 0;
        };

        self.preferred_present_mode = blk: {
            for (self.present_modes) |present_mode| {
                if (present_mode == .mailbox_khr) {
                    break :blk present_mode;
                }
            }
            break :blk .fifo_khr;
        };
    }

    pub fn deinit(self: SwapchainSupportDetails, allocator: Allocator) void {
        allocator.free(self.formats);
        allocator.free(self.present_modes);
    }

    pub inline fn preferredFormat(self: SwapchainSupportDetails) vk.SurfaceFormatKHR {
        return self.formats[self.preferred_format_index];
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
    old_swapchain: ?vk.SwapchainKHR,
) !vk.SwapchainKHR {
    const surface_format = swapchain_support_details.formats[swapchain_support_details.preferred_format_index];
    const present_mode = swapchain_support_details.preferred_present_mode;
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
        .old_swapchain = old_swapchain orelse .null_handle,
    };
    return vkd.createSwapchainKHR(device, &create_info, null);
}

inline fn createLogicalDevice(
    vki: InstanceDispatch,
    physical_device: vk.PhysicalDevice,
    queue_families: QueueFamilyIndices,
) InstanceDispatch.CreateDeviceError!vk.Device {
    const one_index = queue_families.graphicsIndex() == queue_families.transferIndex();
    const queue_priorities = [_]f32{1};
    const queue_create_info = [_]vk.DeviceQueueCreateInfo{
        .{
            .flags = .{},
            .queue_family_index = queue_families.graphicsIndex(),
            .queue_count = 1,
            .p_queue_priorities = &queue_priorities,
        },
        .{
            .flags = .{},
            .queue_family_index = queue_families.transferIndex(),
            .queue_count = 1,
            .p_queue_priorities = &queue_priorities,
        },
    };

    const device_features = vk.PhysicalDeviceFeatures{};
    const create_info = vk.DeviceCreateInfo{
        .flags = .{},
        .queue_create_info_count = if (one_index) 1 else queue_create_info.len,
        .p_queue_create_infos = &queue_create_info,
        .enabled_layer_count = if (is_debug_build) application_ext_layers.desired_layers.len else 0,
        .pp_enabled_layer_names = &application_ext_layers.desired_layers,
        .enabled_extension_count = application_ext_layers.required_extensions_cstr.len,
        .pp_enabled_extension_names = &application_ext_layers.required_extensions_cstr,
        .p_enabled_features = &device_features,
    };
    return vki.createDevice(physical_device, &create_info, null);
}

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

    inline for (application_ext_layers.desired_layers) |desired_layer| {
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

    return &application_ext_layers.desired_layers;
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

inline fn createRenderPass(vkd: DeviceDispatch, device: vk.Device, swapchain_format: vk.Format) !vk.RenderPass {
    const color_attachment = vk.AttachmentDescription{
        .flags = .{},
        .format = swapchain_format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .dont_care,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .@"undefined",
        .final_layout = .present_src_khr,
    };
    const color_attachment_ref = vk.AttachmentReference{
        .attachment = 0,
        .layout = .color_attachment_optimal,
    };
    const subpass = vk.SubpassDescription{
        .flags = .{},
        .pipeline_bind_point = .graphics,
        .input_attachment_count = 0,
        .p_input_attachments = undefined,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast([*]const vk.AttachmentReference, &color_attachment_ref),
        .p_resolve_attachments = null,
        .p_depth_stencil_attachment = null,
        .preserve_attachment_count = 0,
        .p_preserve_attachments = undefined,
    };

    const subpass_dependency = vk.SubpassDependency{
        .src_subpass = vk.SUBPASS_EXTERNAL,
        .dst_subpass = 0,
        .src_stage_mask = .{ .color_attachment_output_bit = true },
        .dst_stage_mask = .{ .color_attachment_output_bit = true },
        .src_access_mask = .{},
        .dst_access_mask = .{ .color_attachment_write_bit = true },
        .dependency_flags = .{},
    };

    const render_pass_info = vk.RenderPassCreateInfo{
        .flags = .{},
        .attachment_count = 1,
        .p_attachments = @ptrCast([*]const vk.AttachmentDescription, &color_attachment),
        .subpass_count = 1,
        .p_subpasses = @ptrCast([*]const vk.SubpassDescription, &subpass),
        .dependency_count = 1,
        .p_dependencies = @ptrCast([*]const vk.SubpassDependency, &subpass_dependency),
    };
    return vkd.createRenderPass(device, &render_pass_info, null);
}

const AssetHandler = struct {
    exe_path: []const u8,

    pub fn init(allocator: Allocator) !AssetHandler {
        const exe_path = try std.fs.selfExePathAlloc(allocator);
        return AssetHandler{
            .exe_path = exe_path,
        };
    }

    pub fn deinit(self: AssetHandler, allocator: Allocator) void {
        allocator.free(self.exe_path);
    }

    pub inline fn getShaderPath(self: AssetHandler, allocator: Allocator, shader_name: []const u8) ![]const u8 {
        const join_path = [_][]const u8{ self.exe_path, "../../", shader_name };
        return std.fs.path.resolve(allocator, join_path[0..]);
    }
};

/// caller must deinit returned memory
pub fn readFile(allocator: Allocator, absolute_path: []const u8) ![]u8 {
    const file = try std.fs.openFileAbsolute(absolute_path, .{ .mode = .read_only });
    defer file.close();

    var reader = file.reader();
    const file_size = (try reader.context.stat()).size;

    var buffer = try allocator.alloc(u8, file_size);
    errdefer allocator.free(buffer);

    const read = try reader.readAll(buffer);
    std.debug.assert(read == file_size);

    return buffer;
}

inline fn createGraphicsPipeline(
    allocator: Allocator,
    vkd: DeviceDispatch,
    device: vk.Device,
    swapchain_extent: vk.Extent2D,
    render_pass: vk.RenderPass,
    pipeline_layout: vk.PipelineLayout,
) !vk.Pipeline {
    const asset_handler = try AssetHandler.init(allocator);
    defer asset_handler.deinit(allocator);

    const vert_bytes = blk: {
        const path = try asset_handler.getShaderPath(allocator, "shader.vert.spv");
        defer allocator.free(path);
        const bytes = try readFile(allocator, path);
        break :blk bytes;
    };
    defer allocator.free(vert_bytes);

    const vert_module = try createShaderModule(vkd, device, vert_bytes);
    defer vkd.destroyShaderModule(device, vert_module, null);

    const vert_stage_info = vk.PipelineShaderStageCreateInfo{
        .flags = .{},
        .stage = .{ .vertex_bit = true },
        .module = vert_module,
        .p_name = "main",
        .p_specialization_info = null,
    };

    const frag_bytes = blk: {
        const path = try asset_handler.getShaderPath(allocator, "shader.frag.spv");
        defer allocator.free(path);
        const bytes = try readFile(allocator, path);
        break :blk bytes;
    };
    defer allocator.free(frag_bytes);

    const frag_module = try createShaderModule(vkd, device, frag_bytes);
    defer vkd.destroyShaderModule(device, frag_module, null);

    const frag_stage_info = vk.PipelineShaderStageCreateInfo{
        .flags = .{},
        .stage = .{ .fragment_bit = true },
        .module = frag_module,
        .p_name = "main",
        .p_specialization_info = null,
    };

    const shader_stages_info = [_]vk.PipelineShaderStageCreateInfo{
        vert_stage_info,
        frag_stage_info,
    };

    const vertex_binding_description = Vertex.getBindingDescription();
    const vertex_attribute_description = Vertex.getAttributeDescriptions();
    const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
        .flags = .{},
        .vertex_binding_description_count = 1,
        .p_vertex_binding_descriptions = @ptrCast([*]const vk.VertexInputBindingDescription, &vertex_binding_description),
        .vertex_attribute_description_count = vertex_attribute_description.len,
        .p_vertex_attribute_descriptions = &vertex_attribute_description,
    };

    const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
        .flags = .{},
        .topology = .triangle_list,
        .primitive_restart_enable = vk.FALSE,
    };

    const viewport = vk.Viewport{
        .x = 0,
        .y = 0,
        .width = @intToFloat(f32, swapchain_extent.width),
        .height = @intToFloat(f32, swapchain_extent.height),
        .min_depth = 0,
        .max_depth = 1,
    };
    const scissor = vk.Rect2D{
        .offset = vk.Offset2D{ .x = 0, .y = 0 },
        .extent = swapchain_extent,
    };

    const dynamic_state = [_]vk.DynamicState{ .viewport, .scissor };
    const dynamic_state_info = vk.PipelineDynamicStateCreateInfo{
        .flags = .{},
        .dynamic_state_count = dynamic_state.len,
        .p_dynamic_states = &dynamic_state,
    };

    const viewport_state_info = vk.PipelineViewportStateCreateInfo{
        .flags = .{},
        .viewport_count = 1,
        .p_viewports = @ptrCast([*]const vk.Viewport, &viewport),
        .scissor_count = 1,
        .p_scissors = @ptrCast([*]const vk.Rect2D, &scissor),
    };

    const rasterization_state_info = vk.PipelineRasterizationStateCreateInfo{
        .flags = .{},
        .depth_clamp_enable = vk.FALSE,
        .rasterizer_discard_enable = vk.FALSE,
        .polygon_mode = .fill,
        .cull_mode = .{ .back_bit = true },
        .front_face = .clockwise,
        .depth_bias_enable = vk.FALSE,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1,
    };

    const multisampling = vk.PipelineMultisampleStateCreateInfo{
        .flags = .{},
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = vk.FALSE,
        .min_sample_shading = 1,
        .p_sample_mask = null,
        .alpha_to_coverage_enable = vk.FALSE,
        .alpha_to_one_enable = vk.FALSE,
    };

    const color_blend_attachment = vk.PipelineColorBlendAttachmentState{
        .blend_enable = vk.FALSE,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{
            .r_bit = true,
            .g_bit = true,
            .b_bit = true,
            .a_bit = true,
        },
    };

    const color_blend_info = vk.PipelineColorBlendStateCreateInfo{
        .flags = .{},
        .logic_op_enable = vk.FALSE,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @ptrCast([*]const vk.PipelineColorBlendAttachmentState, &color_blend_attachment),
        .blend_constants = [4]f32{ 0, 0, 0, 0 },
    };

    const pipeline_info = vk.GraphicsPipelineCreateInfo{
        .flags = .{},
        .stage_count = shader_stages_info.len,
        .p_stages = &shader_stages_info,
        .p_vertex_input_state = &vertex_input_info,
        .p_input_assembly_state = &input_assembly,
        .p_tessellation_state = null,
        .p_viewport_state = &viewport_state_info,
        .p_rasterization_state = &rasterization_state_info,
        .p_multisample_state = &multisampling,
        .p_depth_stencil_state = null,
        .p_color_blend_state = &color_blend_info,
        .p_dynamic_state = &dynamic_state_info,
        .layout = pipeline_layout,
        .render_pass = render_pass,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };
    var pipeline: vk.Pipeline = undefined;
    _ = try vkd.createGraphicsPipelines(
        device,
        .null_handle,
        1,
        @ptrCast([*]const vk.GraphicsPipelineCreateInfo, &pipeline_info),
        null,
        @ptrCast([*]vk.Pipeline, &pipeline),
    );

    return pipeline;
}

inline fn createShaderModule(vkd: DeviceDispatch, device: vk.Device, shader_code: []const u8) !vk.ShaderModule {
    std.debug.assert(@mod(shader_code.len, 4) == 0);
    const create_info = vk.ShaderModuleCreateInfo{
        .flags = .{},
        .code_size = shader_code.len,
        .p_code = @ptrCast([*]const u32, @alignCast(@alignOf(u32), shader_code.ptr)),
    };
    return vkd.createShaderModule(device, &create_info, null);
}

inline fn instantiateImageViews(
    image_views: []vk.ImageView,
    vkd: DeviceDispatch,
    device: vk.Device,
    swapchain_images: []vk.Image,
    swapchain_image_format: vk.Format,
) !void {
    var views_created: usize = 0;
    errdefer {
        for (image_views[0..views_created]) |image_view| {
            vkd.destroyImageView(device, image_view, null);
        }
    }

    const identity = vk.ComponentSwizzle.identity;
    for (swapchain_images) |swapchain_image, i| {
        const create_info = vk.ImageViewCreateInfo{
            .flags = .{},
            .image = swapchain_image,
            .view_type = .@"2d",
            .format = swapchain_image_format,
            .components = .{
                .r = identity,
                .g = identity,
                .b = identity,
                .a = identity,
            },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };

        image_views[i] = try vkd.createImageView(device, &create_info, null);
        views_created = i;
    }
}

inline fn instantiateFramebuffer(
    framebuffers: []vk.Framebuffer,
    vkd: DeviceDispatch,
    device: vk.Device,
    render_pass: vk.RenderPass,
    swapchain_extent: vk.Extent2D,
    swapchain_image_views: []vk.ImageView,
) !void {
    var created_framebuffers: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < created_framebuffers) : (i += 1) {
            vkd.destroyFramebuffer(device, framebuffers[i], null);
        }
    }

    for (framebuffers) |*framebuffer, i| {
        const attachments = [_]vk.ImageView{swapchain_image_views[i]};
        const framebuffer_info = vk.FramebufferCreateInfo{
            .flags = .{},
            .render_pass = render_pass,
            .attachment_count = attachments.len,
            .p_attachments = &attachments,
            .width = swapchain_extent.width,
            .height = swapchain_extent.height,
            .layers = 1,
        };

        framebuffer.* = try vkd.createFramebuffer(device, &framebuffer_info, null);
        created_framebuffers = i;
    }
}

inline fn recordGraphicsCommandBuffer(
    vkd: DeviceDispatch,
    command_buffer: vk.CommandBuffer,
    render_pass: vk.RenderPass,
    framebuffer: vk.Framebuffer,
    swapchain_extent: vk.Extent2D,
    pipeline: vk.Pipeline,
    vertex_buffer_size: vk.DeviceSize,
    vertex_index_buffer: vk.Buffer,
) !void {
    const begin_info = vk.CommandBufferBeginInfo{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    };
    try vkd.beginCommandBuffer(command_buffer, &begin_info);

    const clear_values = [1]vk.ClearValue{.{
        .color = .{
            .float_32 = [_]f32{ 0, 0, 0, 1 },
        },
    }};
    const render_area = vk.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = swapchain_extent,
    };
    const render_pass_info = vk.RenderPassBeginInfo{
        .render_pass = render_pass,
        .framebuffer = framebuffer,
        .render_area = render_area,
        .clear_value_count = clear_values.len,
        .p_clear_values = &clear_values,
    };
    vkd.cmdBeginRenderPass(command_buffer, &render_pass_info, .@"inline");
    vkd.cmdBindPipeline(command_buffer, .graphics, pipeline);

    const viewport = vk.Viewport{
        .x = 0,
        .y = 0,
        .width = @intToFloat(f32, swapchain_extent.width),
        .height = @intToFloat(f32, swapchain_extent.height),
        .min_depth = 0,
        .max_depth = 1,
    };
    vkd.cmdSetViewport(command_buffer, 0, 1, @ptrCast([*]const vk.Viewport, &viewport));
    vkd.cmdSetScissor(command_buffer, 0, 1, @ptrCast([*]const vk.Rect2D, &render_area));

    const vertex_offsets = [_]vk.DeviceSize{0};
    vkd.cmdBindVertexBuffers(
        command_buffer,
        0,
        1,
        @ptrCast([*]const vk.Buffer, &vertex_index_buffer),
        @ptrCast([*]const vk.DeviceSize, &vertex_offsets),
    );
    vkd.cmdBindIndexBuffer(
        command_buffer,
        vertex_index_buffer,
        vertex_buffer_size,
        vk.IndexType.uint16,
    );

    vkd.cmdDrawIndexed(command_buffer, @intCast(u32, indices.len), 1, 0, 0, 0);

    vkd.cmdEndRenderPass(command_buffer);
    try vkd.endCommandBuffer(command_buffer);
}
