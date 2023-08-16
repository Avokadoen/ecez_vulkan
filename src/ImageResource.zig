const vk = @import("vulkan");

const vk_dispatch = @import("vk_dispatch.zig");
const DeviceDispatch = vk_dispatch.DeviceDispatch;
const InstanceDispatch = vk_dispatch.InstanceDispatch;

const dmem = @import("device_memory.zig");

const StagingBuffer = @import("StagingBuffer.zig");

const ImageResource = @This();

// only support r8g8b8a8_unorm for now
pub const image_format: vk.Format = .r8g8b8a8_unorm;

image: vk.Image,
view: ?vk.ImageView,
sampler: vk.Sampler,

width: u32,
height: u32,

pub fn init(
    vkd: DeviceDispatch,
    device: vk.Device,
    width: u32,
    height: u32,
) !ImageResource {
    const image = blk: {
        const image_info = vk.ImageCreateInfo{
            .flags = .{},
            .image_type = .@"2d",
            .format = image_format,
            .extent = .{
                .width = width,
                .height = height,
                .depth = @as(u32, 1),
            },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{
                .@"1_bit" = true,
            },
            .tiling = .optimal,
            .usage = .{
                .sampled_bit = true,
                .transfer_dst_bit = true,
            },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
            .initial_layout = .undefined,
        };
        break :blk try vkd.createImage(device, &image_info, null);
    };
    errdefer vkd.destroyImage(device, image, null);

    const sampler = blk: {
        const sampler_info = vk.SamplerCreateInfo{
            .flags = .{},
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_mode = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .mip_lod_bias = 0,
            .anisotropy_enable = vk.FALSE,
            .max_anisotropy = 0,
            .compare_enable = vk.FALSE,
            .compare_op = .never,
            .min_lod = 0,
            .max_lod = 0,
            .border_color = .float_opaque_white,
            .unnormalized_coordinates = vk.FALSE,
        };
        break :blk try vkd.createSampler(device, &sampler_info, null);
    };
    errdefer vkd.destroySampler(device, sampler, null);

    return ImageResource{
        .image = image,
        .view = null,
        .sampler = sampler,
        .width = width,
        .height = height,
    };
}

pub fn deinit(self: ImageResource, vkd: DeviceDispatch, device: vk.Device) void {
    vkd.destroySampler(device, self.sampler, null);
    if (self.view) |view| {
        vkd.destroyImageView(device, view, null);
    }
    vkd.destroyImage(device, self.image, null);
}

pub fn bindImagesToMemory(
    vki: InstanceDispatch,
    vkd: DeviceDispatch,
    physical_device: vk.PhysicalDevice,
    device: vk.Device,
    image_resources: []const *ImageResource,
    image_pixels: []const []const u32,
    image_staging_buffer: *StagingBuffer.Image,
) !vk.DeviceMemory {
    // TODO: use same image buffer as main pipeline

    const image_memory = try image_memory_alloc_blk: {
        var allocation_size: vk.DeviceSize = 0;
        var memory_type_bits: u32 = 0;
        for (image_resources) |image_resource| {
            const memory_requirements = vkd.getImageMemoryRequirements(device, image_resource.image);
            allocation_size += dmem.pow2Align(memory_requirements.alignment, memory_requirements.size);
            memory_type_bits |= memory_requirements.memory_type_bits;
        }

        const allocation_info = vk.MemoryAllocateInfo{
            .allocation_size = allocation_size,
            .memory_type_index = try dmem.findMemoryTypeIndex(vki, physical_device, memory_type_bits, .{ .device_local_bit = true }),
        };

        break :image_memory_alloc_blk vkd.allocateMemory(device, &allocation_info, null);
    };
    errdefer vkd.freeMemory(device, image_memory, null);

    var created_views: usize = 0;
    errdefer {
        for (image_resources[0..created_views]) |image_resource| {
            vkd.destroyImageView(device, image_resource.view.?, null);
        }
    }

    var memory_cursor: vk.DeviceSize = 0;
    for (image_resources, 0..) |image_resource, image_index| {
        const memory_requirements = vkd.getImageMemoryRequirements(device, image_resource.image);
        try vkd.bindImageMemory(device, image_resource.image, image_memory, memory_cursor);
        memory_cursor = dmem.pow2Align(memory_requirements.alignment, memory_requirements.size);

        image_resource.view = blk: {
            const view_info = vk.ImageViewCreateInfo{
                .flags = .{},
                .image = image_resource.image,
                .view_type = .@"2d",
                .format = ImageResource.image_format,
                .components = .{
                    .r = .identity,
                    .g = .identity,
                    .b = .identity,
                    .a = .identity,
                },
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            };
            break :blk try vkd.createImageView(device, &view_info, null);
        };
        errdefer vkd.destroyImageView(device, image_resource.view, null);

        created_views = image_index + 1;
    }

    // upload texture data to gpu
    for (image_resources, image_pixels) |image_resource, pixels| {
        try image_staging_buffer.scheduleLayoutTransitionBeforeTransfers(image_resource.image, .{
            .format = ImageResource.image_format,
            .old_layout = .undefined,
            .new_layout = .transfer_dst_optimal,
        });
        try image_staging_buffer.scheduleTransferToDst(
            image_resource.image,
            vk.Extent2D{
                .width = image_resource.width,
                .height = image_resource.height,
            },
            u32,
            pixels,
        );
        try image_staging_buffer.scheduleLayoutTransitionAfterTransfers(image_resource.image, .{
            .format = ImageResource.image_format,
            .old_layout = .transfer_dst_optimal,
            .new_layout = .shader_read_only_optimal,
        });
    }

    try image_staging_buffer.flushAndCopyToDestination(vkd, device, null);

    return image_memory;
}
