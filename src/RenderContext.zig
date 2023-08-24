const std = @import("std");
const Allocator = std.mem.Allocator;

const builtin = @import("builtin");

const vk = @import("vulkan");
const glfw = @import("glfw");
const zm = @import("zmath");
const zigimg = @import("zigimg");
const zmesh = @import("zmesh");

const vk_dispatch = @import("vk_dispatch.zig");
const BaseDispatch = vk_dispatch.BaseDispatch;
const InstanceDispatch = vk_dispatch.InstanceDispatch;
const DeviceDispatch = vk_dispatch.DeviceDispatch;

const AssetHandler = @import("AssetHandler.zig");

const pipeline_utils = @import("pipeline_utils.zig");

const ImguiPipeline = @import("ImguiPipeline.zig");

const StagingBuffer = @import("StagingBuffer.zig");
const ImmutableBuffer = @import("ImmutableBuffer.zig");
const MutableBuffer = @import("MutableBuffer.zig");
const QueueFamilyIndices = @import("QueueFamilyIndices.zig");

const sync = @import("sync.zig");
const dmem = @import("device_memory.zig");
const application_ext_layers = @import("application_ext_layers.zig");

pub const is_debug_build = builtin.mode == .Debug;
pub const max_frames_in_flight = 2;

const UserPointer = extern struct {
    type: u32 = 0,
    ptr: *RenderContext,
    next: ?*UserPointer,
};

const RenderContext = @This();

// TODO: reduce debug assert, replace with errors
// TODO: use sync2

// TODO: make enable_imgui = false functional
// TODO: make this configurable in build
pub const enable_imgui = true;

pub const MeshHandle = u16;

pub const UpdateRate = union(enum) {
    time_seconds: f32, // every nth microsecond
    every_nth_frame: u32, // every nth frame
    always: void,
    manually: void,
};

pub const Config = struct {
    update_rate: UpdateRate = .always,
};

// TODO: evaluate if we want
pub const InstanceHandle = packed struct {
    mesh_handle: MeshHandle,
    lookup_index: u48,
};

pub const OpaqueInstance = u32;
pub const InstanceLookup = struct {
    opaque_instance: OpaqueInstance,
};

pub const MeshInstancehInitializeContex = struct {
    cgltf_path: []const u8,
    instance_count: u32,
};

/// Metadata about a given grouping of instance
const MeshInstanceContext = struct {
    total_instance_count: u32,
};

const PushConstant = struct {
    camera_projection_view: zm.Mat,

    pub fn fromCamera(camera: Camera) PushConstant {
        return PushConstant{
            .camera_projection_view = zm.mul(camera.view, camera.projection),
        };
    }
};

pub const Camera = struct {
    view: zm.Mat,
    projection: zm.Mat,

    pub fn calcView(orientation: zm.Quat, pos: zm.Vec) zm.Mat {
        return zm.mul(zm.quatToMat(orientation), zm.translationV(pos));
    }

    pub fn calcProjection(swapchain_extent: vk.Extent2D, fov_degree: f32) zm.Mat {
        const fovy = std.math.degreesToRadians(f32, fov_degree);
        const aspect = @as(f32, @floatFromInt(swapchain_extent.width)) / @as(f32, @floatFromInt(swapchain_extent.height));
        const near = 0.01;
        const far = 300;
        return zm.perspectiveFovRh(fovy, aspect, near, far);
    }
};

const DrawInstance = struct {
    pub const binding = 1;

    texture_index: u32,
    transform: zm.Mat,

    pub fn getBindingDescription() vk.VertexInputBindingDescription {
        return vk.VertexInputBindingDescription{
            .binding = binding,
            .stride = @sizeOf(DrawInstance),
            .input_rate = .instance,
        };
    }

    pub fn getAttributeDescriptions() [5]vk.VertexInputAttributeDescription {
        return [_]vk.VertexInputAttributeDescription{
            .{
                .location = 2,
                .binding = binding,
                .format = .r32_sint,
                .offset = @offsetOf(DrawInstance, "texture_index"),
            },
            .{
                .location = 3,
                .binding = binding,
                .format = .r32g32b32a32_sfloat,
                .offset = @offsetOf(DrawInstance, "transform") + @sizeOf(zm.F32x4) * 0,
            },
            .{
                .location = 4,
                .binding = binding,
                .format = .r32g32b32a32_sfloat,
                .offset = @offsetOf(DrawInstance, "transform") + @sizeOf(zm.F32x4) * 1,
            },
            .{
                .location = 5,
                .binding = binding,
                .format = .r32g32b32a32_sfloat,
                .offset = @offsetOf(DrawInstance, "transform") + @sizeOf(zm.F32x4) * 2,
            },
            .{
                .location = 6,
                .binding = binding,
                .format = .r32g32b32a32_sfloat,
                .offset = @offsetOf(DrawInstance, "transform") + @sizeOf(zm.F32x4) * 3,
            },
        };
    }
};

pub const MeshVertex = struct {
    pub const binding = 0;

    pos: [3]f32,
    text_coord: [2]f32,

    pub fn getBindingDescription() vk.VertexInputBindingDescription {
        return vk.VertexInputBindingDescription{
            .binding = binding,
            .stride = @sizeOf(MeshVertex),
            .input_rate = .vertex,
        };
    }

    pub fn getAttributeDescriptions() [2]vk.VertexInputAttributeDescription {
        return [_]vk.VertexInputAttributeDescription{
            .{
                .location = 0,
                .binding = binding,
                .format = .r32g32b32_sfloat,
                .offset = @offsetOf(MeshVertex, "pos"),
            },
            .{
                .location = 1,
                .binding = binding,
                .format = .r32g32_sfloat,
                .offset = @offsetOf(MeshVertex, "text_coord"),
            },
        };
    }
};

const InstanceLookupList = std.ArrayList(InstanceLookup);

asset_handler: AssetHandler,

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

buffer_staging_buffer: StagingBuffer.Buffer,
image_staging_buffer: StagingBuffer.Image,

vertex_buffer_size: vk.DeviceSize,
index_buffer_size: vk.DeviceSize,
index_buffer_offset: vk.DeviceSize,
// TODO: rename
vertex_index_buffer: ImmutableBuffer,

camera: Camera,

// TODO: rename model_contexts
/// This is used to supply users with handles for any instance when
/// they request a new object to render
instance_contexts: []MeshInstanceContext,

// TODO: code smell: map to array lists :')
instance_handle_map: std.AutoArrayHashMap(MeshHandle, InstanceLookupList),

instances_desc_set_layout: vk.DescriptorSetLayout,
instances_desc_set_pool: vk.DescriptorPool,
instances_desc_set: vk.DescriptorSet,

instance_images: []vk.Image,
instance_image_views: []vk.ImageView,
instances_image_sampler: vk.Sampler,

queue_family_indices: QueueFamilyIndices,
primary_graphics_queue: vk.Queue,
secondary_graphics_queue: vk.Queue,
transfer_queue: vk.Queue,

depth_image: vk.Image,
depth_image_view: vk.ImageView,
depth_image_memory: vk.DeviceMemory,

texture_image_memory: vk.DeviceMemory,

// TODO: double or triple buffer device data to avoid pipeline bubbles
// TODO: instance data should not be an internal concept.
//       it should be supplied by user code each frame!
instance_data: std.ArrayList(DrawInstance),
instance_data_buffer: MutableBuffer,

// Store the indirect draw commands containing index offsets and instance count per object
indirect_commands: std.ArrayList(vk.DrawIndexedIndirectCommand),
indirect_commands_buffer: ImmutableBuffer,

update_rate: UpdateRate,
last_update: UpdateRate,
missing_updated_frames: u32 = max_frames_in_flight,

// TODO: only members if build imgui enabled
// TODO: should not take memory if imgui_enabled == false
imgui_pipeline: ImguiPipeline,

user_pointer: UserPointer,

pub fn init(
    allocator: Allocator,
    window: glfw.Window,
    mesh_instance_initalizers: []const MeshInstancehInitializeContex,
    config: Config,
) !RenderContext {
    zmesh.init(allocator);
    errdefer zmesh.deinit();

    const asset_handler = try AssetHandler.init(allocator);
    errdefer asset_handler.deinit(allocator);

    // bind the glfw instance proc pointer
    const vk_proc = @as(
        *const fn (instance: vk.Instance, procname: [*:0]const u8) callconv(.C) vk.PfnVoidFunction,
        @ptrCast(&glfw.getInstanceProcAddress),
    );
    const vkb = try BaseDispatch.load(vk_proc);

    // get validation layers if we are in debug mode
    const validation_layers = try application_ext_layers.getValidationLayers(allocator, vkb);

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

        // append glfw extensions, function can not fail since glfw.vulkanSupported should already have been called
        const glfw_extensions = glfw.getRequiredInstanceExtensions() orelse unreachable;
        try extensions.appendSlice(glfw_extensions);

        // required extension for VK_EXT_DESCRIPTOR_INDEXING_EXTENSION
        try extensions.append(vk.extension_info.khr_get_physical_device_properties_2.name);

        if (is_debug_build) {
            // add the debug utils extension
            try extensions.append(vk.extension_info.ext_debug_utils.name);
        }

        const instance_info = vk.InstanceCreateInfo{
            .flags = .{},
            .p_next = if (is_debug_build) null else &debug_message_info,
            .p_application_info = &application_info,
            .enabled_layer_count = @as(u32, @intCast(validation_layers.len)),
            .pp_enabled_layer_names = validation_layers.ptr,
            .enabled_extension_count = @as(u32, @intCast(extensions.items.len)),
            .pp_enabled_extension_names = extensions.items.ptr,
        };
        break :blk (try vkb.createInstance(&instance_info, null));
    };
    const vki = try InstanceDispatch.load(instance, vk_proc);
    errdefer vki.destroyInstance(instance, null);

    const surface = blk: {
        var s: vk.SurfaceKHR = undefined;
        const result = @as(vk.Result, @enumFromInt(glfw.createWindowSurface(instance, window, null, &s)));
        if (result != .success) {
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
    const non_coherent_atom_size = device_properties.limits.non_coherent_atom_size;

    const swapchain_support_details = try SwapchainSupportDetails.init(allocator, vki, physical_device, surface);
    errdefer swapchain_support_details.deinit(allocator);
    const swapchain_extent = try swapchain_support_details.chooseExtent(window);

    const queue_family_indices = try QueueFamilyIndices.init(vki, physical_device, surface);
    const device = try createLogicalDevice(vki, physical_device, queue_family_indices, validation_layers);
    const vkd = try DeviceDispatch.load(device, vki.dispatch.vkGetDeviceProcAddr);
    errdefer vkd.destroyDevice(device, null);

    const primary_graphics_queue = vkd.getDeviceQueue(device, queue_family_indices.graphicsIndex(), 0);
    const secondary_graphics_queue = blk: {
        if (queue_family_indices.graphics_queue_count > 1) {
            break :blk vkd.getDeviceQueue(device, queue_family_indices.graphicsIndex(), 1);
        }

        break :blk primary_graphics_queue;
    };

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

    var image_staging_buffer = try StagingBuffer.Image.init(
        vki,
        physical_device,
        vkd,
        device,
        non_coherent_atom_size,
        queue_family_indices.graphicsIndex(),
        secondary_graphics_queue,
        .{ .size = dmem.bytes_in_megabyte * 32 },
    );
    errdefer image_staging_buffer.deinit(vkd, device);

    const depth_format = try findDepthFormat(vki, physical_device);
    const depth_image = try createImage(vkd, device, depth_format, .{ .transfer_dst_bit = true, .depth_stencil_attachment_bit = true }, swapchain_extent);
    errdefer vkd.destroyImage(device, depth_image, null);

    const depth_image_memory = try dmem.createDeviceImageMemory(
        vki,
        physical_device,
        vkd,
        device,
        &[_]vk.Image{depth_image},
    );
    errdefer vkd.freeMemory(device, depth_image_memory, null);
    try vkd.bindImageMemory(device, depth_image, depth_image_memory, 0);

    const depth_image_view = try createDefaultImageView(vkd, device, depth_image, depth_format, .{ .depth_bit = true });
    errdefer vkd.destroyImageView(device, depth_image_view, null);

    // buffer overflow error is not possible yet
    image_staging_buffer.scheduleLayoutTransitionBeforeTransfers(depth_image, .{
        .format = depth_format,
        .old_layout = .undefined,
        .new_layout = .depth_stencil_attachment_optimal,
    }) catch unreachable;

    const render_pass = try createRenderPass(
        vkd,
        device,
        swapchain_support_details.preferredFormat().format,
        depth_format,
    );
    errdefer vkd.destroyRenderPass(device, render_pass, null);

    var framebuffers = try allocator.alloc(vk.Framebuffer, swapchain_images.len);
    errdefer allocator.free(framebuffers);

    try instantiateFramebuffer(
        framebuffers,
        vkd,
        device,
        render_pass,
        swapchain_extent,
        swapchain_image_views,
        depth_image_view,
    );
    errdefer {
        for (framebuffers) |framebuffer| {
            vkd.destroyFramebuffer(device, framebuffer, null);
        }
    }

    // we have one base color texture per mesh
    const texture_count = @as(u32, @intCast(mesh_instance_initalizers.len));
    const instances_desc_set_layout = try createDescriptorSetLayout(vkd, device, texture_count);
    errdefer vkd.destroyDescriptorSetLayout(device, instances_desc_set_layout, null);

    const instances_desc_set_pool = blk: {
        const pool_size = [_]vk.DescriptorPoolSize{
            .{
                .type = .combined_image_sampler,
                .descriptor_count = texture_count,
            },
        };
        const pool_info = vk.DescriptorPoolCreateInfo{
            .flags = .{},
            .max_sets = 1,
            .pool_size_count = pool_size.len,
            .p_pool_sizes = &pool_size,
        };
        break :blk try vkd.createDescriptorPool(device, &pool_info, null);
    };
    errdefer vkd.destroyDescriptorPool(device, instances_desc_set_pool, null);

    const variable_counts = [_]u32{texture_count};
    const variable_descriptor_count_alloc_info = vk.DescriptorSetVariableDescriptorCountAllocateInfoEXT{
        .descriptor_set_count = variable_counts.len,
        .p_descriptor_counts = &variable_counts,
    };

    const instances_desc_set = blk: {
        const alloc_info = vk.DescriptorSetAllocateInfo{
            .p_next = &variable_descriptor_count_alloc_info,
            .descriptor_pool = instances_desc_set_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @as([*]const vk.DescriptorSetLayout, @ptrCast(&instances_desc_set_layout)),
        };
        var desc_set: vk.DescriptorSet = undefined;
        try vkd.allocateDescriptorSets(device, &alloc_info, @as([*]vk.DescriptorSet, @ptrCast(&desc_set)));
        break :blk desc_set;
    };

    const camera = Camera{
        .view = Camera.calcView(zm.qidentity(), zm.f32x4(0, 0, -4, 1)),
        .projection = Camera.calcProjection(swapchain_extent, 45),
    };

    const pipeline_layout = blk: {
        const push_constant_range = vk.PushConstantRange{
            .stage_flags = .{ .vertex_bit = true },
            .offset = 0,
            .size = @sizeOf(PushConstant),
        };
        const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
            .flags = .{},
            .set_layout_count = 1,
            .p_set_layouts = @as([*]const vk.DescriptorSetLayout, @ptrCast(&instances_desc_set_layout)),
            .push_constant_range_count = 1,
            .p_push_constant_ranges = @as([*]const vk.PushConstantRange, @ptrCast(&push_constant_range)),
        };
        break :blk try vkd.createPipelineLayout(device, &pipeline_layout_info, null);
    };
    errdefer vkd.destroyPipelineLayout(device, pipeline_layout, null);

    const pipeline = try createGraphicsPipeline(
        vkd,
        device,
        swapchain_extent,
        render_pass,
        pipeline_layout,
    );
    errdefer vkd.destroyPipeline(device, pipeline, null);

    // TODO: spawn pools according to how many threads we have
    const command_pools = blk: {
        var pools = try allocator.alloc(vk.CommandPool, max_frames_in_flight);
        errdefer allocator.free(pools);

        var pools_initiated: usize = 0;
        errdefer {
            for (0..pools_initiated) |pool_index| {
                vkd.destroyCommandPool(device, pools[pool_index], null);
            }
        }

        const pool_info = vk.CommandPoolCreateInfo{
            .flags = .{},
            .queue_family_index = queue_family_indices.graphicsIndex(),
        };
        for (pools) |*pool| {
            pool.* = try vkd.createCommandPool(device, &pool_info, null);
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

        for (buffers, 0..) |*cmd_buffer, i| {
            const cmd_buffer_info = vk.CommandBufferAllocateInfo{
                .command_pool = command_pools[i],
                .level = .primary,
                .command_buffer_count = 1,
            };
            try vkd.allocateCommandBuffers(device, &cmd_buffer_info, @as([*]vk.CommandBuffer, @ptrCast(cmd_buffer)));
        }
        break :blk buffers;
    };
    errdefer allocator.free(command_buffers);

    // create all sempahores we need which we can slice later
    const all_semaphores = blk: {
        var semaphores = try allocator.alloc(vk.Semaphore, max_frames_in_flight * 2);

        var initialized_semaphores: usize = 0;
        errdefer {
            for (0..initialized_semaphores) |semaphore_index| {
                vkd.destroySemaphore(device, semaphores[semaphore_index], null);
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
            for (0..initialized_fences) |fence_index| {
                vkd.destroyFence(device, fences[fence_index], null);
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

    var buffer_staging_buffer = try StagingBuffer.Buffer.init(
        vki,
        physical_device,
        vkd,
        device,
        non_coherent_atom_size,
        queue_family_indices.transferIndex(),
        transfer_queue,
        .{ .size = 64 * dmem.bytes_in_megabyte },
    );
    errdefer buffer_staging_buffer.deinit(vkd, device);

    // TODO: simplfiy buffer aligned creation (createBuffer accept size array and do this internally)
    // TODO: find a way to query vertex and index size before commiting GPU memory
    // We don't really know how big these buffers must be so we just allocate
    // the biggest size recommend for a chunk of memory (256mb - some leeway)
    const vertex_index_buffer = try ImmutableBuffer.init(
        vki,
        physical_device,
        vkd,
        device,
        non_coherent_atom_size,
        .{ .vertex_buffer_bit = true, .index_buffer_bit = true },
        .{ .size = 256 * dmem.bytes_in_megabyte },
    );

    var vertex_buffer_size: vk.DeviceSize = 0;
    var index_buffer_size: vk.DeviceSize = 0;
    const index_buffer_offset = dmem.pow2Align(non_coherent_atom_size, vertex_index_buffer.size / 2);

    var image_memory_offsets = try allocator.alloc(vk.DeviceSize, mesh_instance_initalizers.len);
    defer allocator.free(image_memory_offsets);

    // TODO: errdefer: cleanup vk resources here as well
    // all image resources needed by each model
    var instance_images = try allocator.alloc(vk.Image, mesh_instance_initalizers.len);
    errdefer allocator.free(instance_images);

    var instance_image_views = try allocator.alloc(vk.ImageView, mesh_instance_initalizers.len);
    errdefer allocator.free(instance_image_views);

    // we use the same sampler for all images
    var instances_image_sampler = try createDefaultSampler(vkd, device, device_properties.limits);
    errdefer vkd.destroySampler(device, instances_image_sampler, null);

    // TODO: use slice instead?
    // create our indirect draw calls
    var indirect_commands = try std.ArrayList(vk.DrawIndexedIndirectCommand).initCapacity(allocator, mesh_instance_initalizers.len);
    errdefer indirect_commands.deinit();

    // TODO: storing all images on CPU is a bit sad ...
    // TODO: proper errdefer clean images
    var model_base_color_images = try allocator.alloc(zigimg.Image, mesh_instance_initalizers.len);
    defer allocator.free(model_base_color_images);

    // counts used by the indirect commands and the instance data list
    var instance_count: u32 = 0;

    // Load all models and process the data using meshoptimizer
    {
        // prepare some storage for mesh data to be loaded in
        var mesh_indices = std.ArrayList(u32).init(allocator);
        defer mesh_indices.deinit();

        var mesh_positions = std.ArrayList([3]f32).init(allocator);
        defer mesh_positions.deinit();

        // var mesh_normals = std.ArrayList([3]f32).init(allocator);
        // defer mesh_normals.deinit();

        var mesh_text_coords = std.ArrayList([2]f32).init(allocator);
        defer mesh_text_coords.deinit();

        var vertices = std.ArrayList(MeshVertex).init(allocator);
        defer vertices.deinit();

        var remap = std.ArrayList(u32).init(allocator);
        defer remap.deinit();

        var optimized_indices = std.ArrayList(u32).init(allocator);
        defer optimized_indices.deinit();

        var optimized_vertices = std.ArrayList(MeshVertex).init(allocator);
        defer optimized_vertices.deinit();

        var vertex_buffer_position: vk.DeviceSize = 0;
        defer vertex_buffer_size = vertex_buffer_position;

        var index_buffer_position: vk.DeviceSize = index_buffer_offset;
        defer index_buffer_size = index_buffer_position - index_buffer_offset;

        for (mesh_instance_initalizers, 0..) |model_init, i| {
            // Do not reuse data from previous iterations (but reuse the memory)
            defer {
                // cant OOM when requesting 0
                mesh_indices.resize(0) catch unreachable;
                mesh_positions.resize(0) catch unreachable;
                mesh_text_coords.resize(0) catch unreachable;
                vertices.resize(0) catch unreachable;
                remap.resize(0) catch unreachable;
                optimized_indices.resize(0) catch unreachable;
                optimized_vertices.resize(0) catch unreachable;
            }

            const content_path = try asset_handler.getCPath(allocator, model_init.cgltf_path);
            defer allocator.free(content_path);

            const gltf_data = try zmesh.io.parseAndLoadFile(content_path);
            defer zmesh.io.freeData(gltf_data);

            try zmesh.io.appendMeshPrimitive(
                gltf_data, // *zmesh.io.cgltf.Data
                0, // mesh index
                0, // gltf primitive index (submesh index)
                &mesh_indices,
                &mesh_positions,
                null, // &mesh_normals, // normals (optional)
                &mesh_text_coords, // texcoords (optional)
                null, // tangents (optional)
            );

            try vertices.ensureUnusedCapacity(mesh_positions.items.len);
            for (mesh_positions.items, 0..) |pos, j| {
                vertices.appendAssumeCapacity(MeshVertex{
                    .pos = pos,
                    .text_coord = mesh_text_coords.items[j],
                });
            }

            try remap.resize(mesh_indices.items.len);
            const num_unique_vertices = zmesh.opt.generateVertexRemap(
                remap.items, // 'vertex remap' (destination)
                null, // non-optimized indices
                MeshVertex, // Zig type describing your vertex
                vertices.items, // non-optimized vertices
            );

            try optimized_indices.resize(mesh_indices.items.len);
            zmesh.opt.remapIndexBuffer(optimized_indices.items, mesh_indices.items, remap.items);

            try optimized_vertices.resize(num_unique_vertices);
            zmesh.opt.remapVertexBuffer(MeshVertex, optimized_vertices.items, vertices.items, remap.items);

            zmesh.opt.optimizeVertexCache(optimized_indices.items, optimized_indices.items, optimized_vertices.items.len);
            zmesh.opt.optimizeOverdraw(optimized_indices.items, optimized_indices.items, MeshVertex, optimized_vertices.items, 1.05);
            // TODO: utilize meshoptimizer quantization here
            // TODO: LOD!

            // TODO: scheduling transfer of data that is not atom aligned is problematic. How should this be communicated or enforced?
            // TODO: move this fancy pancy staging behaviour into a staging buffer function instead of copy pasting code?

            // attempt to schedule transfer of vertex data, perform a transfer if the stage is out of slots
            var vertex_size = buffer_staging_buffer.scheduleTransferToDst(
                vertex_index_buffer.buffer,
                vertex_buffer_position,
                MeshVertex,
                optimized_vertices.items,
            ) catch |err| blk: {
                // flush all pending memory
                try buffer_staging_buffer.flushAndCopyToDestination(vkd, device, null);
                if (err == error.InsufficentStagingSize) {
                    // TODO: too lazy to implement this now, implement this later:
                    unreachable;
                    // const transfer_size = std.mem.sliceAsBytes(optimized_vertices.items).len;
                    // // Ceil divide
                    // var transfers_needed = @min(1, (transfer_size + buffer_staging_buffer.ctx.size - 1) / buffer_staging_buffer.ctx.size);
                    // var i: usize = 0;
                    // while (i < transfers_needed) : (i += 1) {
                    //     buffer_staging_buffer.scheduleTransferToDst(vertex_index_buffer.buffer, )
                    // }
                } else {
                    // This transfer cant fail because we know the staging buffer has sufficent size (did not hit error.InsufficentStagingSize)
                    // and we have emptied the buffer for pending transfers.
                    break :blk buffer_staging_buffer.scheduleTransferToDst(
                        vertex_index_buffer.buffer,
                        vertex_buffer_position,
                        MeshVertex,
                        optimized_vertices.items,
                    ) catch unreachable;
                }
            };

            // MeshVertex has a bad alignment (20) so we need to do some funky alignment!
            vertex_size = dmem.aribtraryAlign(@sizeOf(MeshVertex), vertex_size);

            // attempt to schedule transfer to dst, perform a transfer if the stage is out of slots
            const index_size = buffer_staging_buffer.scheduleTransferToDst(
                vertex_index_buffer.buffer,
                index_buffer_position,
                u32,
                optimized_indices.items,
            ) catch |err| blk: {
                try buffer_staging_buffer.flushAndCopyToDestination(vkd, device, null);
                if (err == error.InsufficentStagingSize) {
                    // TODO:
                    unreachable; // very much reachable :)
                } else {
                    // This transfer cant fail because we know the staging buffer has sufficent size (did not hit error.InsufficentStagingSize)
                    // and we have emptied the buffer for pending transfers.
                    break :blk buffer_staging_buffer.scheduleTransferToDst(
                        vertex_index_buffer.buffer,
                        index_buffer_position,
                        u32,
                        optimized_indices.items,
                    ) catch unreachable;
                }
            };

            // flush data to gpu before we reuse cpu data for next model
            try buffer_staging_buffer.flushAndCopyToDestination(vkd, device, null);

            // load image on cpu
            model_base_color_images[i] = blk: {
                const image_uri = std.mem.span(gltf_data.images.?[0].uri.?);
                const join_path = [_][]const u8{ content_path, "..", image_uri };
                const image_path = try std.fs.path.resolve(allocator, join_path[0..]);
                defer allocator.free(image_path);

                break :blk try zigimg.Image.fromFilePath(allocator, image_path);
            };

            // store the byte size of the image for when we bind the memory later
            // the sizes will be shifted once to get offsets later
            image_memory_offsets[i] = @as(
                vk.DeviceSize,
                @intCast(model_base_color_images[i].imageByteSize()),
            ) + if (i > 0) image_memory_offsets[i - 1] else 0;

            const loaded_image_extent = vk.Extent2D{
                .width = @as(u32, @intCast(model_base_color_images[i].width)),
                .height = @as(u32, @intCast(model_base_color_images[i].height)),
            };

            instance_images[i] = try createImage(vkd, device, .r8g8b8a8_srgb, .{ .transfer_dst_bit = true, .sampled_bit = true }, loaded_image_extent);
            errdefer vkd.destroyImage(device, instance_images[i], null);

            // TODO: only load image dimension in this loop and then we can load the actual image
            //       in a later loop after image memory has been created.
            // Note: we can not force a flush in the loop for this currently because the image memory does not exist yet
            try image_staging_buffer.scheduleLayoutTransitionBeforeTransfers(instance_images[i], .{
                .format = .r8g8b8a8_srgb,
                .old_layout = .undefined,
                .new_layout = .transfer_dst_optimal,
            });
            try image_staging_buffer.scheduleTransferToDst(
                instance_images[i],
                loaded_image_extent,
                u8,
                model_base_color_images[i].pixels.asBytes(),
            );
            try image_staging_buffer.scheduleLayoutTransitionAfterTransfers(instance_images[i], .{
                .format = .r8g8b8a8_srgb,
                .old_layout = .transfer_dst_optimal,
                .new_layout = .shader_read_only_optimal,
            });

            // populate our indirect commands with some initial state
            indirect_commands.appendAssumeCapacity(vk.DrawIndexedIndirectCommand{
                .vertex_offset = @as(i32, @intCast(vertex_buffer_position / @sizeOf(MeshVertex))),
                .first_index = @as(u32, @intCast(index_buffer_position - index_buffer_offset)) / 4,
                .index_count = @as(u32, @intCast(index_size / 4)),
                .instance_count = 0,
                .first_instance = instance_count,
            });

            vertex_buffer_position += vertex_size;
            index_buffer_position += index_size;
            instance_count += model_init.instance_count;
        }
    }

    const texture_image_memory = try dmem.createDeviceImageMemory(vki, physical_device, vkd, device, instance_images);
    errdefer vkd.freeMemory(device, texture_image_memory, null);

    // move sizes to the right to get offsets instead
    std.mem.rotate(vk.DeviceSize, image_memory_offsets, image_memory_offsets.len - 1);
    image_memory_offsets[0] = 0;

    for (instance_images, 0..) |vk_image, i| {
        try vkd.bindImageMemory(device, vk_image, texture_image_memory, image_memory_offsets[i]);

        instance_image_views[i] = try createDefaultImageView(vkd, device, vk_image, .r8g8b8a8_srgb, .{ .color_bit = true });
        errdefer vkd.destroyImageView(device, instance_image_views[i], null);
    }

    for (model_base_color_images) |*cpu_image| {
        cpu_image.deinit();
    }

    {
        var instances_desc_image_info = try allocator.alloc(vk.DescriptorImageInfo, texture_count);
        defer allocator.free(instances_desc_image_info);
        // for each loaded model texture
        for (instance_image_views, 0..) |image_view, i| {
            instances_desc_image_info[i] = vk.DescriptorImageInfo{
                .sampler = instances_image_sampler,
                .image_view = image_view,
                .image_layout = .shader_read_only_optimal,
            };
        }
        const instances_desc_type = [_]vk.WriteDescriptorSet{
            .{
                .dst_set = instances_desc_set,
                .dst_binding = 0,
                .dst_array_element = 0,
                .descriptor_count = @as(u32, @intCast(instances_desc_image_info.len)),
                .descriptor_type = .combined_image_sampler,
                .p_image_info = instances_desc_image_info.ptr,
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            },
        };
        vkd.updateDescriptorSets(device, instances_desc_type.len, &instances_desc_type, 0, undefined);
    }

    var instance_data = try std.ArrayList(DrawInstance).initCapacity(allocator, instance_count);
    errdefer instance_data.deinit();
    for (mesh_instance_initalizers, 0..) |instancing_init, i| {
        var j: usize = 0;
        while (j < instancing_init.instance_count) : (j += 1) {
            instance_data.appendAssumeCapacity(.{
                .texture_index = @as(u32, @intCast(i)),
                .transform = undefined,
            });
        }
    }

    const instance_data_size = dmem.pow2Align(
        non_coherent_atom_size,
        instance_data.items.len * @sizeOf(DrawInstance),
    );
    var instance_data_buffer = try MutableBuffer.init(
        vki,
        physical_device,
        vkd,
        device,
        non_coherent_atom_size,
        .{ .vertex_buffer_bit = true },
        .{ .size = instance_data_size * max_frames_in_flight },
    );
    errdefer instance_data_buffer.deinit(vkd, device);
    {
        var i: usize = 0;
        while (i < max_frames_in_flight) : (i += 1) {
            try instance_data_buffer.scheduleTransfer(instance_data_size * i, DrawInstance, instance_data.items);
        }
    }
    try instance_data_buffer.flush(vkd, device);

    // create device memory for our draw calls
    const indirect_commands_buffer_size = dmem.pow2Align(
        non_coherent_atom_size,
        @sizeOf(vk.DrawIndexedIndirectCommand) * indirect_commands.items.len,
    );
    var indirect_commands_buffer = try ImmutableBuffer.init(
        vki,
        physical_device,
        vkd,
        device,
        non_coherent_atom_size,
        .{ .indirect_buffer_bit = true },
        .{ .size = indirect_commands_buffer_size * max_frames_in_flight },
    );
    errdefer indirect_commands_buffer.deinit(vkd, device);
    {
        const indirect_commands_size = dmem.pow2Align(
            non_coherent_atom_size,
            indirect_commands.items.len * @sizeOf(vk.DrawIndexedIndirectCommand),
        );

        var i: usize = 0;
        while (i < max_frames_in_flight) : (i += 1) {
            _ = try buffer_staging_buffer.scheduleTransferToDst(
                indirect_commands_buffer.buffer,
                indirect_commands_size * i,
                vk.DrawIndexedIndirectCommand,
                indirect_commands.items,
            );
        }
    }

    const imgui_pipeline = if (enable_imgui) try ImguiPipeline.init(
        allocator,
        vki,
        physical_device,
        vkd,
        device,
        non_coherent_atom_size,
        swapchain_extent,
        @as(u32, @intCast(swapchain_images.len)),
        render_pass,
        &image_staging_buffer,
        asset_handler,
    ) else undefined;

    // transfer all data to GPU memory at the end of init
    try image_staging_buffer.flushAndCopyToDestination(vkd, device, null);
    try buffer_staging_buffer.flushAndCopyToDestination(vkd, device, null);

    var instance_handle_map = std.AutoArrayHashMap(MeshHandle, InstanceLookupList).init(allocator);
    errdefer {
        for (instance_handle_map.values()) |lookup_list| {
            lookup_list.deinit();
        }
        instance_handle_map.deinit();
    }
    try instance_handle_map.ensureTotalCapacity(mesh_instance_initalizers.len);

    const instance_contexts = try allocator.alloc(MeshInstanceContext, mesh_instance_initalizers.len);
    errdefer allocator.free(instance_contexts);
    for (mesh_instance_initalizers, 0..) |instancing_init, i| {
        instance_contexts[i] = MeshInstanceContext{
            .total_instance_count = instancing_init.instance_count,
        };

        instance_handle_map.putAssumeCapacity(
            @as(MeshHandle, @intCast(i)),
            InstanceLookupList.init(allocator),
        );
    }

    return RenderContext{
        .asset_handler = asset_handler,
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
        .buffer_staging_buffer = buffer_staging_buffer,
        .image_staging_buffer = image_staging_buffer,
        .vertex_buffer_size = vertex_buffer_size,
        .index_buffer_size = index_buffer_size,
        .vertex_index_buffer = vertex_index_buffer,
        .camera = camera,
        .instances_desc_set_layout = instances_desc_set_layout,
        .instances_desc_set_pool = instances_desc_set_pool,
        .instances_desc_set = instances_desc_set,
        .queue_family_indices = queue_family_indices,
        .primary_graphics_queue = primary_graphics_queue,
        .secondary_graphics_queue = secondary_graphics_queue,
        .transfer_queue = transfer_queue,
        .depth_image = depth_image,
        .depth_image_memory = depth_image_memory,
        .depth_image_view = depth_image_view,
        .instance_images = instance_images,
        .instance_image_views = instance_image_views,
        .instances_image_sampler = instances_image_sampler,
        .texture_image_memory = texture_image_memory,
        .instance_contexts = instance_contexts,
        .instance_handle_map = instance_handle_map,
        .instance_data = instance_data,
        .instance_data_buffer = instance_data_buffer,
        .indirect_commands = indirect_commands,
        .indirect_commands_buffer = indirect_commands_buffer,
        .index_buffer_offset = index_buffer_offset,
        .update_rate = config.update_rate,
        .last_update = config.update_rate,
        .imgui_pipeline = imgui_pipeline,
        // assigned by handleFramebufferResize
        .user_pointer = undefined,
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

    var image_count = @as(u32, @intCast(self.swapchain_images.len));
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

    // recreate depth buffer
    {
        self.vkd.destroyImageView(self.device, self.depth_image_view, null);
        self.vkd.freeMemory(self.device, self.depth_image_memory, null);
        self.vkd.destroyImage(self.device, self.depth_image, null);

        const depth_format = try findDepthFormat(self.vki, self.physical_device);
        self.depth_image = try createImage(
            self.vkd,
            self.device,
            depth_format,
            .{ .transfer_dst_bit = true, .depth_stencil_attachment_bit = true },
            self.swapchain_extent,
        );
        errdefer self.vkd.destroyImage(self.device, self.depth_image, null);

        self.depth_image_memory = try dmem.createDeviceImageMemory(
            self.vki,
            self.physical_device,
            self.vkd,
            self.device,
            &[_]vk.Image{self.depth_image},
        );
        errdefer self.vkd.freeMemory(self.device, self.depth_image_memory, null);
        try self.vkd.bindImageMemory(self.device, self.depth_image, self.depth_image_memory, 0);

        self.depth_image_view = try createDefaultImageView(self.vkd, self.device, self.depth_image, depth_format, .{ .depth_bit = true });
        errdefer self.vkd.destroyImageView(self.device, self.depth_image_view, null);

        // buffer overflow error is not possible yet
        self.image_staging_buffer.scheduleLayoutTransitionBeforeTransfers(self.depth_image, .{
            .format = depth_format,
            .old_layout = .undefined,
            .new_layout = .depth_stencil_attachment_optimal,
        }) catch unreachable;

        try self.image_staging_buffer.flushAndCopyToDestination(self.vkd, self.device, null);
    }

    try instantiateFramebuffer(
        self.framebuffers,
        self.vkd,
        self.device,
        self.render_pass,
        self.swapchain_extent,
        self.swapchain_image_views,
        self.depth_image_view,
    );

    self.camera.projection = Camera.calcProjection(self.swapchain_extent, 45);
}

pub fn deinit(self: *RenderContext, allocator: Allocator) void {
    for (self.instance_handle_map.values()) |lookup_list| {
        lookup_list.deinit();
    }
    self.instance_handle_map.deinit();

    self.vkd.deviceWaitIdle(self.device) catch {};

    if (enable_imgui) {
        self.imgui_pipeline.deinit(allocator, self.vkd, self.device);
    }

    zmesh.deinit();
    self.asset_handler.deinit(allocator);

    allocator.free(self.instance_contexts);
    self.instance_data.deinit();
    self.instance_data_buffer.deinit(self.vkd, self.device);
    self.indirect_commands.deinit();
    self.indirect_commands_buffer.deinit(self.vkd, self.device);

    self.vkd.destroyImageView(self.device, self.depth_image_view, null);
    self.vkd.freeMemory(self.device, self.depth_image_memory, null);
    self.vkd.destroyImage(self.device, self.depth_image, null);

    self.vkd.destroySampler(self.device, self.instances_image_sampler, null);
    for (self.instance_image_views) |image_view| {
        self.vkd.destroyImageView(self.device, image_view, null);
    }
    allocator.free(self.instance_image_views);
    self.vkd.freeMemory(self.device, self.texture_image_memory, null);
    for (self.instance_images) |image| {
        self.vkd.destroyImage(self.device, image, null);
    }
    allocator.free(self.instance_images);

    self.buffer_staging_buffer.deinit(self.vkd, self.device);
    self.image_staging_buffer.deinit(self.vkd, self.device);
    self.vertex_index_buffer.deinit(self.vkd, self.device);

    self.vkd.destroyDescriptorPool(self.device, self.instances_desc_set_pool, null);
    self.vkd.destroyDescriptorSetLayout(self.device, self.instances_desc_set_layout, null);

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

/// manually signal renderer to update all buffers
pub inline fn signalUpdate(self: *RenderContext) void {
    self.missing_updated_frames = max_frames_in_flight;
}

pub fn drawFrame(self: *RenderContext, window: glfw.Window, delta_time: f32) !void {
    // TODO: utilize comptime for this when we introduce the component logic (issue #23)?
    switch (self.update_rate) {
        .always => self.missing_updated_frames = max_frames_in_flight,
        .every_nth_frame => |frame| {
            if (self.last_update.every_nth_frame >= frame) {
                self.last_update.every_nth_frame = 0;
                self.missing_updated_frames = max_frames_in_flight;
            } else {
                self.last_update.every_nth_frame += 1;
            }
        },
        .time_seconds => |ms| {
            if (self.last_update.time_seconds >= ms) {
                self.last_update.time_seconds = 0;
                self.missing_updated_frames = max_frames_in_flight;
            } else {
                self.last_update.time_seconds += delta_time;
            }
        },
        .manually => {},
    }

    if (self.missing_updated_frames > 0) {
        self.missing_updated_frames -= 1;
        // start by updating any pending gpu state
        const instance_data_size = dmem.pow2Align(
            self.nonCoherentAtomSize(),
            self.instance_data.items.len * @sizeOf(DrawInstance),
        );
        try self.instance_data_buffer.scheduleTransfer(
            instance_data_size * self.current_frame,
            DrawInstance,
            self.instance_data.items,
        );
    }

    _ = try self.vkd.waitForFences(self.device, 1, @as([*]const vk.Fence, @ptrCast(&self.in_flight_fences[self.current_frame])), vk.TRUE, std.math.maxInt(u64));

    if (enable_imgui) {
        // flush instance data changes to GPU before rendering
        try self.instance_data_buffer.flush(self.vkd, self.device);
        self.imgui_pipeline.updateDisplay(self.swapchain_extent);
    }

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

    try self.vkd.resetFences(self.device, 1, @as([*]const vk.Fence, @ptrCast(&self.in_flight_fences[self.current_frame])));

    try self.vkd.resetCommandPool(self.device, self.command_pools[self.current_frame], .{});

    {
        const command_buffer = self.command_buffers[self.current_frame];

        const begin_info = vk.CommandBufferBeginInfo{
            .flags = .{ .one_time_submit_bit = true },
            .p_inheritance_info = null,
        };
        try self.vkd.beginCommandBuffer(command_buffer, &begin_info);

        const clear_values = [_]vk.ClearValue{ .{
            .color = .{
                .float_32 = [_]f32{ 0, 0, 0, 1 },
            },
        }, .{
            .depth_stencil = .{
                .depth = 1,
                .stencil = 0,
            },
        } };
        const render_area = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swapchain_extent,
        };
        const render_pass_info = vk.RenderPassBeginInfo{
            .render_pass = self.render_pass,
            .framebuffer = self.framebuffers[image_index],
            .render_area = render_area,
            .clear_value_count = clear_values.len,
            .p_clear_values = &clear_values,
        };
        self.vkd.cmdBeginRenderPass(command_buffer, &render_pass_info, .@"inline");
        self.vkd.cmdBindPipeline(command_buffer, .graphics, self.pipeline);

        const viewport = vk.Viewport{
            .x = 0,
            .y = 0,
            .width = @as(f32, @floatFromInt(self.swapchain_extent.width)),
            .height = @as(f32, @floatFromInt(self.swapchain_extent.height)),
            .min_depth = 0,
            .max_depth = 1,
        };
        self.vkd.cmdSetViewport(command_buffer, 0, 1, @as([*]const vk.Viewport, @ptrCast(&viewport)));
        self.vkd.cmdSetScissor(command_buffer, 0, 1, @as([*]const vk.Rect2D, @ptrCast(&render_area)));

        const push_constant = PushConstant.fromCamera(self.camera);
        self.vkd.cmdPushConstants(
            command_buffer,
            self.pipeline_layout,
            .{ .vertex_bit = true },
            0,
            @sizeOf(PushConstant),
            &push_constant,
        );

        const vertex_offsets = [_]vk.DeviceSize{0};
        self.vkd.cmdBindVertexBuffers(
            command_buffer,
            MeshVertex.binding,
            1,
            @as([*]const vk.Buffer, @ptrCast(&self.vertex_index_buffer.buffer)),
            &vertex_offsets,
        );
        self.vkd.cmdBindIndexBuffer(
            command_buffer,
            self.vertex_index_buffer.buffer,
            self.index_buffer_offset,
            vk.IndexType.uint32,
        );

        const instance_offset = [_]vk.DeviceSize{@as(
            vk.DeviceSize,
            @intCast(dmem.pow2Align(
                self.nonCoherentAtomSize(),
                self.instance_data.items.len * @sizeOf(DrawInstance),
            ) * self.current_frame),
        )};
        self.vkd.cmdBindVertexBuffers(
            command_buffer,
            DrawInstance.binding,
            1,
            @as([*]const vk.Buffer, @ptrCast(&self.instance_data_buffer.buffer)),
            &instance_offset,
        );

        self.vkd.cmdBindDescriptorSets(
            command_buffer,
            .graphics,
            self.pipeline_layout,
            0,
            1,
            @as([*]const vk.DescriptorSet, @ptrCast(&self.instances_desc_set)),
            0,
            undefined,
        );

        const index_buffer_offset = @as(
            vk.DeviceSize,
            @intCast(dmem.pow2Align(
                self.nonCoherentAtomSize(),
                self.indirect_commands.items.len * @sizeOf(vk.DrawIndexedIndirectCommand),
            ) * self.current_frame),
        );
        self.vkd.cmdDrawIndexedIndirect(
            command_buffer,
            self.indirect_commands_buffer.buffer,
            index_buffer_offset,
            @as(u32, @intCast(self.indirect_commands.items.len)),
            @sizeOf(vk.DrawIndexedIndirectCommand),
        );

        // draw imgui content
        if (enable_imgui) {
            try self.imgui_pipeline.draw(self.vkd, self.device, command_buffer, self.current_frame);
        }

        self.vkd.cmdEndRenderPass(command_buffer);
        try self.vkd.endCommandBuffer(command_buffer);
    }

    const render_finish_semaphore = @as([*]const vk.Semaphore, @ptrCast(&self.render_finished_semaphores[self.current_frame]));
    const submit_info = vk.SubmitInfo{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = &[_]vk.Semaphore{self.image_available_semaphores[self.current_frame]},
        .p_wait_dst_stage_mask = &[_]vk.PipelineStageFlags{.{ .color_attachment_output_bit = true }},
        .command_buffer_count = 1,
        .p_command_buffers = @as([*]const vk.CommandBuffer, @ptrCast(&self.command_buffers[self.current_frame])),
        .signal_semaphore_count = 1,
        .p_signal_semaphores = render_finish_semaphore,
    };
    try self.vkd.queueSubmit(
        self.primary_graphics_queue,
        1,
        @as([*]const vk.SubmitInfo, @ptrCast(&submit_info)),
        self.in_flight_fences[self.current_frame],
    );

    const recreate_present_resources = blk: {
        const present_info = vk.PresentInfoKHR{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = render_finish_semaphore,
            .swapchain_count = 1,
            .p_swapchains = @as([*]const vk.SwapchainKHR, @ptrCast(&self.swapchain)),
            .p_image_indices = @as([*]const u32, @ptrCast(&image_index)),
            .p_results = null,
        };
        const result = self.vkd.queuePresentKHR(self.primary_graphics_queue, &present_info) catch |err| {
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
fn selectPhysicalDevice(allocator: Allocator, instance: vk.Instance, vki: InstanceDispatch, surface: vk.SurfaceKHR) !vk.PhysicalDevice {
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

    var found_any_device = false;

    // include first element even though we start by using it as selected device
    // this is so we can validate later that the device is valid for the application
    device_search: for (devices[0..]) |current_device| {
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
                if (field.type != u32 and field.type != f32) {
                    continue :limit_grading;
                }

                const selected_limit_field = @field(selected_device_properties.limits, field.name);
                const current_limit_field = @field(current_device_properties.limits, field.name);

                selected_limit_score += @as(u32, @intCast(@intFromBool(selected_limit_field > current_limit_field)));
                current_limit_score += @as(u32, @intCast(@intFromBool(selected_limit_field <= current_limit_field)));
            }

            if (current_limit_score < selected_limit_score) {
                continue :device_search;
            }
        }

        var current_device_features: vk.PhysicalDeviceFeatures = vki.getPhysicalDeviceFeatures(current_device);
        // at the time of writing this comment 82.5% support this
        if (current_device_features.multi_draw_indirect != vk.TRUE) {
            continue :device_search;
        }
        // at the time of writing this comment 90% support this
        if (current_device_features.sampler_anisotropy != vk.TRUE) {
            continue :device_search;
        }

        var selected_feature_sum: u32 = 0;
        var current_feature_sum: u32 = 0;
        const feature_info = @typeInfo(vk.PhysicalDeviceFeatures).Struct;
        inline for (feature_info.fields) |field| {
            if (field.type != vk.Bool32) {
                @compileError("unexpected field type"); // something has changed in vk wrapper
            }

            selected_feature_sum += @as(u32, @intCast(@field(selected_device_features, field.name)));
            current_feature_sum += @as(u32, @intCast(@field(current_device_features, field.name)));
        }

        // if current should be selected
        if (selected_feature_sum <= current_feature_sum) {
            selected_device = current_device;
            selected_device_properties = current_device_properties;
            selected_device_features = current_device_features;
            selected_queue_families = current_queue_families;
            found_any_device = true;
        }
    }

    if (found_any_device == false) {
        return error.NoSuitableDevice; // no device has the required feature set
    }

    if (is_debug_build) {
        std.debug.print("\nselected gpu: {s}\n", .{selected_device_properties.device_name});
    }

    return selected_device;
}

pub inline fn getNthMeshHandle(self: RenderContext, nth: usize) MeshHandle {
    std.debug.assert(nth < self.instance_contexts.len);
    return @as(MeshHandle, @intCast(nth));
}

pub fn getNewInstance(self: *RenderContext, mesh_handle: MeshHandle) !InstanceHandle {
    const instance_context = self.instance_contexts[mesh_handle];
    const active_instance_count = self.indirect_commands.items[mesh_handle].instance_count;
    if (active_instance_count >= instance_context.total_instance_count) {
        return error.OutOfInstances; // no more unique instances to use
    }

    // add the inital offset for this mesh handle
    var instance_offset: u64 = active_instance_count;
    for (self.instance_contexts[0..mesh_handle]) |other_instance_context| {
        instance_offset += @as(u64, @intCast(other_instance_context.total_instance_count));
    }

    self.indirect_commands.items[mesh_handle].instance_count += 1;

    // TODO: RC: flushing commands that are potentially in flight
    //       we should only transfer to buffer area for image frame we are about to draw (in drawFrame)
    const indirect_commands_size = dmem.pow2Align(
        self.nonCoherentAtomSize(),
        self.indirect_commands.items.len * @sizeOf(vk.DrawIndexedIndirectCommand),
    );
    var i: usize = 0;
    while (i < max_frames_in_flight) : (i += 1) {
        _ = try self.buffer_staging_buffer.scheduleTransferToDst(
            self.indirect_commands_buffer.buffer,
            indirect_commands_size * i,
            vk.DrawIndexedIndirectCommand,
            self.indirect_commands.items,
        );
    }

    // TODO: always flushing is really stupid. Maybe always flush staging in render frame
    //       or when staging buffer is full (check returned error)
    try self.buffer_staging_buffer.flushAndCopyToDestination(self.vkd, self.device, null);

    var mesh_instance_lookups = self.instance_handle_map.getPtr(mesh_handle).?;
    const instance_handle = InstanceHandle{
        .mesh_handle = mesh_handle,
        .lookup_index = @as(u48, @intCast(mesh_instance_lookups.items.len)),
    };

    try mesh_instance_lookups.append(InstanceLookup{
        .opaque_instance = @as(u32, @intCast(instance_offset)),
    });

    return instance_handle;
}

/// Destroy the instance handle
pub fn destroyInstanceHandle(self: *RenderContext, instance_handle: InstanceHandle) void {
    var mesh_instance_lookups = self.instance_handle_map.getPtr(instance_handle.mesh_handle).?;
    const remove_lookup = mesh_instance_lookups.items[instance_handle.lookup_index];

    // remove draw instance entry and keep order of remaining data
    _ = self.instance_data.orderedRemove(remove_lookup.opaque_instance);

    // update the indices to the right of destroyed handle
    if (mesh_instance_lookups.items.len > remove_lookup.opaque_instance) {
        for (mesh_instance_lookups.items[remove_lookup.opaque_instance + 1 ..]) |*lookup| {
            lookup.opaque_instance -= 1;
        }
    }

    // only if the current handle is the last entry will we remove it from the lookup array
    if (mesh_instance_lookups.items.len - 1 == instance_handle.lookup_index) {
        _ = mesh_instance_lookups.pop();
    }

    // update the draw command to draw one less object
    self.indirect_commands.items[instance_handle.mesh_handle].instance_count -= 1;
}

inline fn instanceLookup(self: RenderContext, instance_handle: InstanceHandle) *DrawInstance {
    var mesh_instance_lookups = self.instance_handle_map.getPtr(instance_handle.mesh_handle).?;
    const lookup = mesh_instance_lookups.items[instance_handle.lookup_index];
    return &self.instance_data.items[lookup.opaque_instance];
}

pub inline fn setInstanceTransform(self: *RenderContext, instance_handle: InstanceHandle, transform: zm.Mat) void {
    var draw_instance = self.instanceLookup(instance_handle);
    draw_instance.transform = transform;
}

pub inline fn getInstanceTransform(self: RenderContext, instance_handle: InstanceHandle) zm.Mat {
    var draw_instance = self.instanceLookup(instance_handle);
    return draw_instance.transform;
}

pub inline fn getInstanceTransformPtr(self: *RenderContext, instance_handle: InstanceHandle) *zm.Mat {
    var draw_instance = self.instanceLookup(instance_handle);
    return &draw_instance.transform;
}

/// Free all instances so that the render can be reused for new scenes
/// This will invalidate all current InstanceHandles
pub fn clearInstancesRetainingCapacity(self: *RenderContext) void {
    // remove all current lookups
    for (self.instance_handle_map.values()) |*lookup_list| {
        lookup_list.clearRetainingCapacity();
    }

    // set each indirect command to draw 0
    for (self.indirect_commands.items) |*indirect_command| {
        indirect_command.instance_count = 0;
    }
}

/// Ensure render context handle resizing.
pub fn handleFramebufferResize(self: *RenderContext, window: glfw.Window, set_window_user_pointer: bool) void {
    const callback = struct {
        pub fn func(_window: glfw.Window, width: u32, height: u32) void {
            _ = width;
            _ = height;

            // TODO: very unsafe, find a better solution to this
            const render_context_ptr = search_user_ptr_blk: {
                var user_ptr = _window.getUserPointer(UserPointer) orelse return;
                while (user_ptr.type != 0) {
                    user_ptr = user_ptr.next orelse return;
                }

                break :search_user_ptr_blk user_ptr.ptr;
            };

            render_context_ptr.recreatePresentResources(_window) catch {};
        }
    }.func;

    self.user_pointer = UserPointer{
        .ptr = self,
        .next = null,
    };
    if (set_window_user_pointer) {
        window.setUserPointer(&self.user_pointer);
    }

    window.setFramebufferSizeCallback(callback);
}

pub inline fn nonCoherentAtomSize(self: RenderContext) vk.DeviceSize {
    return self.device_properties.limits.non_coherent_atom_size;
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
        var format_len: u32 = @as(u32, @intCast(formats.len));
        _ = try vki.getPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_len, formats.ptr);

        const preferred_format_index = blk: {
            for (formats, 0..) |format, i| {
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
        var present_modes_len: u32 = @as(u32, @intCast(present_modes.len));
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
            for (self.formats, 0..) |format, i| {
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

        const frame_buffer_size = window.getFramebufferSize();

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
    validation_layers: []const [*:0]const u8,
) InstanceDispatch.CreateDeviceError!vk.Device {
    const one_index = queue_families.graphicsIndex() == queue_families.transferIndex();
    const queue_priorities = [_]f32{1};
    const queue_create_info = [_]vk.DeviceQueueCreateInfo{
        .{
            .flags = .{},
            .queue_family_index = queue_families.graphicsIndex(),
            .queue_count = if (queue_families.graphics_queue_count > 1) 2 else 1,
            .p_queue_priorities = &queue_priorities,
        },
        .{
            .flags = .{},
            .queue_family_index = queue_families.transferIndex(),
            .queue_count = 1,
            .p_queue_priorities = &queue_priorities,
        },
    };

    // request features needed to dynamically select textures at runtime
    const descriptor_indexing_freatures = vk.PhysicalDeviceDescriptorIndexingFeatures{
        .shader_sampled_image_array_non_uniform_indexing = vk.TRUE,
        .descriptor_binding_variable_descriptor_count = vk.TRUE,
        .runtime_descriptor_array = vk.TRUE,
    };

    const device_features = vk.PhysicalDeviceFeatures{
        .sampler_anisotropy = vk.TRUE,
        .multi_draw_indirect = vk.TRUE,
    };
    const create_info = vk.DeviceCreateInfo{
        .p_next = &descriptor_indexing_freatures,
        .flags = .{},
        .queue_create_info_count = if (one_index) 1 else queue_create_info.len,
        .p_queue_create_infos = &queue_create_info,
        .enabled_layer_count = if (is_debug_build) @as(u32, @intCast(validation_layers.len)) else 0,
        .pp_enabled_layer_names = validation_layers.ptr,
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
    .pfn_user_callback = &messageCallback,
    .p_user_data = null,
};

/// set up debug messenger if we are in a debug build
inline fn setupDebugMessenger(vki: InstanceDispatch, instance: vk.Instance) !?vk.DebugUtilsMessengerEXT {
    if (comptime (is_debug_build == false)) {
        return null;
    }

    return (try vki.createDebugUtilsMessengerEXT(instance, &debug_message_info, null));
}

fn messageCallback(
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    message_types: vk.DebugUtilsMessageTypeFlagsEXT,
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
    const is_severe = (error_mask.toInt() & message_severity.toInt()) > 0;
    const writer = if (is_severe) std.io.getStdErr().writer() else std.io.getStdOut().writer();

    if (p_callback_data) |data| {
        writer.print("validation layer: {s}\n", .{data.p_message}) catch {
            std.debug.print("error from stdout print in message callback", .{});
        };
    }

    return vk.FALSE;
}

inline fn createRenderPass(vkd: DeviceDispatch, device: vk.Device, swapchain_format: vk.Format, depth_format: vk.Format) !vk.RenderPass {
    const common_color_attachment_ref = vk.AttachmentReference{
        .attachment = 0,
        .layout = .color_attachment_optimal,
    };

    // TODO: dont clear when we have more real use case scenes because we will draw on top anyways
    const game_color_attachment = vk.AttachmentDescription{
        .flags = .{},
        .format = swapchain_format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .present_src_khr,
    };
    const game_depth_attachment = vk.AttachmentDescription{
        .flags = .{},
        .format = depth_format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .dont_care,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .depth_stencil_attachment_optimal,
    };
    const game_depth_attachment_ref = vk.AttachmentReference{
        .attachment = 1,
        .layout = .depth_stencil_attachment_optimal,
    };
    const game_subpass = vk.SubpassDescription{
        .flags = .{},
        .pipeline_bind_point = .graphics,
        .input_attachment_count = 0,
        .p_input_attachments = undefined,
        .color_attachment_count = 1,
        .p_color_attachments = @as([*]const vk.AttachmentReference, @ptrCast(&common_color_attachment_ref)),
        .p_resolve_attachments = null,
        .p_depth_stencil_attachment = &game_depth_attachment_ref,
        .preserve_attachment_count = 0,
        .p_preserve_attachments = undefined,
    };

    const gui_color_attachment = vk.AttachmentDescription{
        .flags = .{},
        .format = swapchain_format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .load,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .present_src_khr,
        .final_layout = .present_src_khr,
    };
    const gui_subpass = vk.SubpassDescription{
        .flags = .{},
        .pipeline_bind_point = .graphics,
        .input_attachment_count = 0,
        .p_input_attachments = undefined,
        .color_attachment_count = 1,
        .p_color_attachments = @as([*]const vk.AttachmentReference, @ptrCast(&common_color_attachment_ref)),
        .p_resolve_attachments = null,
        .p_depth_stencil_attachment = null,
        .preserve_attachment_count = 0,
        .p_preserve_attachments = undefined,
    };

    // we are rendering the gui on top of the game view
    const game_subpass_dependency = vk.SubpassDependency{
        .src_subpass = vk.SUBPASS_EXTERNAL,
        .dst_subpass = 0,
        .src_stage_mask = .{ .color_attachment_output_bit = true, .early_fragment_tests_bit = true },
        .dst_stage_mask = .{ .color_attachment_output_bit = true, .early_fragment_tests_bit = true },
        .src_access_mask = .{},
        .dst_access_mask = .{ .color_attachment_write_bit = true, .depth_stencil_attachment_write_bit = true },
        .dependency_flags = .{},
    };
    const gui_subpass_dependency = vk.SubpassDependency{
        .src_subpass = 0,
        .dst_subpass = 1,
        .src_stage_mask = .{ .color_attachment_output_bit = true, .early_fragment_tests_bit = true },
        .dst_stage_mask = .{ .color_attachment_output_bit = true },
        .src_access_mask = .{ .color_attachment_write_bit = true },
        .dst_access_mask = .{ .color_attachment_read_bit = true, .color_attachment_write_bit = true },
        .dependency_flags = .{ .by_region_bit = true },
    };

    const attachments = [_]vk.AttachmentDescription{ game_color_attachment, game_depth_attachment, gui_color_attachment };
    const subpasses = [_]vk.SubpassDescription{ game_subpass, gui_subpass };
    const subpass_dependencies = [_]vk.SubpassDependency{ game_subpass_dependency, gui_subpass_dependency };
    const render_pass_info = vk.RenderPassCreateInfo{
        .flags = .{},
        .attachment_count = attachments.len - if (enable_imgui) 0 else 1,
        .p_attachments = &attachments,
        .subpass_count = subpasses.len - if (enable_imgui) 0 else 1,
        .p_subpasses = &subpasses,
        .dependency_count = subpass_dependencies.len - if (enable_imgui) 0 else 1,
        .p_dependencies = &subpass_dependencies,
    };
    return vkd.createRenderPass(device, &render_pass_info, null);
}

// TODO: remove this, copy code inline instead
fn createGraphicsPipeline(
    vkd: DeviceDispatch,
    device: vk.Device,
    swapchain_extent: vk.Extent2D,
    render_pass: vk.RenderPass,
    pipeline_layout: vk.PipelineLayout,
) !vk.Pipeline {
    const shaders = @import("shaders");

    const vert_bytes = shaders.mesh_vert_spv;
    const vert_module = try pipeline_utils.createShaderModule(vkd, device, &vert_bytes);
    defer vkd.destroyShaderModule(device, vert_module, null);

    const vert_stage_info = vk.PipelineShaderStageCreateInfo{
        .flags = .{},
        .stage = .{ .vertex_bit = true },
        .module = vert_module,
        .p_name = "main",
        .p_specialization_info = null,
    };

    const frag_bytes = shaders.mesh_frag_spv;
    const frag_module = try pipeline_utils.createShaderModule(vkd, device, &frag_bytes);
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

    const binding_descriptions = [_]vk.VertexInputBindingDescription{
        MeshVertex.getBindingDescription(),
        DrawInstance.getBindingDescription(),
    };
    const attribute_descriptions = MeshVertex.getAttributeDescriptions() ++ DrawInstance.getAttributeDescriptions();
    const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
        .flags = .{},
        .vertex_binding_description_count = binding_descriptions.len,
        .p_vertex_binding_descriptions = &binding_descriptions,
        .vertex_attribute_description_count = attribute_descriptions.len,
        .p_vertex_attribute_descriptions = &attribute_descriptions,
    };

    const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
        .flags = .{},
        .topology = .triangle_list,
        .primitive_restart_enable = vk.FALSE,
    };

    const viewport = vk.Viewport{
        .x = 0,
        .y = 0,
        .width = @as(f32, @floatFromInt(swapchain_extent.width)),
        .height = @as(f32, @floatFromInt(swapchain_extent.height)),
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
        .p_viewports = @as([*]const vk.Viewport, @ptrCast(&viewport)),
        .scissor_count = 1,
        .p_scissors = @as([*]const vk.Rect2D, @ptrCast(&scissor)),
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
        .p_attachments = @as([*]const vk.PipelineColorBlendAttachmentState, @ptrCast(&color_blend_attachment)),
        .blend_constants = [4]f32{ 0, 0, 0, 0 },
    };

    const nop_front_back = vk.StencilOpState{
        .fail_op = .keep,
        .pass_op = .keep,
        .depth_fail_op = .keep,
        .compare_op = .never,
        .compare_mask = 0,
        .write_mask = 0,
        .reference = 0,
    };
    const depth_stencil_info = vk.PipelineDepthStencilStateCreateInfo{
        .flags = .{},
        .depth_test_enable = vk.TRUE,
        .depth_write_enable = vk.TRUE,
        .depth_compare_op = .less,
        .depth_bounds_test_enable = vk.FALSE,
        .stencil_test_enable = vk.FALSE,
        .front = nop_front_back,
        .back = nop_front_back,
        .min_depth_bounds = 0,
        .max_depth_bounds = 1,
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
        .p_depth_stencil_state = &depth_stencil_info,
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
        @as([*]const vk.GraphicsPipelineCreateInfo, @ptrCast(&pipeline_info)),
        null,
        @as([*]vk.Pipeline, @ptrCast(&pipeline)),
    );

    return pipeline;
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

    for (swapchain_images, 0..) |swapchain_image, i| {
        image_views[i] = try createDefaultImageView(vkd, device, swapchain_image, swapchain_image_format, .{ .color_bit = true });
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
    depth_image_view: vk.ImageView,
) !void {
    var created_framebuffers: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < created_framebuffers) : (i += 1) {
            vkd.destroyFramebuffer(device, framebuffers[i], null);
        }
    }

    for (framebuffers, 0..) |*framebuffer, i| {
        const attachments = [_]vk.ImageView{ swapchain_image_views[i], depth_image_view, swapchain_image_views[i] };
        const attachments_len = if (enable_imgui) attachments.len else attachments.len - 1;
        const framebuffer_info = vk.FramebufferCreateInfo{
            .flags = .{},
            .render_pass = render_pass,
            .attachment_count = attachments_len,
            .p_attachments = &attachments,
            .width = swapchain_extent.width,
            .height = swapchain_extent.height,
            .layers = 1,
        };

        framebuffer.* = try vkd.createFramebuffer(device, &framebuffer_info, null);
        created_framebuffers = i;
    }
}

fn createDescriptorSetLayout(vkd: DeviceDispatch, device: vk.Device, texture_count: u32) !vk.DescriptorSetLayout {
    const texture_layout_binding = vk.DescriptorSetLayoutBinding{
        .binding = 0,
        .descriptor_type = .combined_image_sampler,
        .descriptor_count = texture_count,
        .stage_flags = .{ .fragment_bit = true },
        .p_immutable_samplers = null,
    };
    const bindings = [_]vk.DescriptorSetLayoutBinding{
        texture_layout_binding,
    };

    const binding_flags = [bindings.len]vk.DescriptorBindingFlagsEXT{.{ .variable_descriptor_count_bit = true }};
    // Mark descriptor binding as variable count
    const set_layout_binding_flags = vk.DescriptorSetLayoutBindingFlagsCreateInfoEXT{
        .binding_count = binding_flags.len,
        .p_binding_flags = &binding_flags,
    };

    const layout_info = vk.DescriptorSetLayoutCreateInfo{
        .p_next = &set_layout_binding_flags,
        .flags = .{},
        .binding_count = bindings.len,
        .p_bindings = &bindings,
    };
    return vkd.createDescriptorSetLayout(device, &layout_info, null);
}

// TODO: BasicImage.zig
// TODO: function take a zigimg.Image and produce some vk resources
inline fn createImage(vkd: DeviceDispatch, device: vk.Device, format: vk.Format, usage: vk.ImageUsageFlags, image_extent: vk.Extent2D) !vk.Image {
    const image_info = vk.ImageCreateInfo{
        .flags = .{},
        .image_type = .@"2d",
        .format = format,
        .extent = vk.Extent3D{
            .width = image_extent.width,
            .height = image_extent.height,
            .depth = 1,
        },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = usage,
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .initial_layout = .undefined,
    };
    return try vkd.createImage(device, &image_info, null);
}

// TODO: BasicImage.zig
inline fn createDefaultImageView(vkd: DeviceDispatch, device: vk.Device, image: vk.Image, format: vk.Format, aspect_flags: vk.ImageAspectFlags) !vk.ImageView {
    const image_view_info = vk.ImageViewCreateInfo{
        .flags = .{},
        .image = image,
        .view_type = .@"2d",
        .format = format,
        .components = .{
            .r = .identity,
            .g = .identity,
            .b = .identity,
            .a = .identity,
        },
        .subresource_range = .{
            .aspect_mask = aspect_flags,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
    return vkd.createImageView(device, &image_view_info, null);
}

inline fn createDefaultSampler(vkd: DeviceDispatch, device: vk.Device, device_limits: vk.PhysicalDeviceLimits) !vk.Sampler {
    const sampler_info = vk.SamplerCreateInfo{
        .flags = .{},
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_mode = .linear,
        .address_mode_u = .repeat,
        .address_mode_v = .repeat,
        .address_mode_w = .repeat,
        .mip_lod_bias = 0,
        .anisotropy_enable = vk.TRUE,
        .max_anisotropy = device_limits.max_sampler_anisotropy,
        .compare_enable = vk.FALSE,
        .compare_op = .always,
        .min_lod = 0,
        .max_lod = 0,
        .border_color = .int_opaque_black,
        .unnormalized_coordinates = vk.FALSE,
    };
    return vkd.createSampler(device, &sampler_info, null);
}

inline fn findSupportedFormat(
    vki: InstanceDispatch,
    physical_device: vk.PhysicalDevice,
    candidate_formats: []const vk.Format,
    features: vk.FormatFeatureFlags,
    comptime tiling: vk.ImageTiling,
) !vk.Format {
    const field = comptime switch (tiling) {
        .linear => "linear_tiling_features",
        .optimal => "optimal_tiling_features",
        else => @compileError("unsupported tiling used " ++ @tagName(tiling)),
    };

    for (candidate_formats) |format| {
        const format_properties = vki.getPhysicalDeviceFormatProperties(physical_device, format);
        if ((features.intersect(@field(format_properties, field))).toInt() != 0) {
            return format;
        }
    }

    return error.NoSuitableFormat;
}

inline fn findDepthFormat(vki: InstanceDispatch, physical_device: vk.PhysicalDevice) !vk.Format {
    return findSupportedFormat(
        vki,
        physical_device,
        &[_]vk.Format{ .d32_sfloat, .d24_unorm_s8_uint, .d32_sfloat_s8_uint },
        .{ .depth_stencil_attachment_bit = true },
        .optimal,
    );
}
