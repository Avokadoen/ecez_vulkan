const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");
const zgui = @import("zgui");

const vk_dispatch = @import("vk_dispatch.zig");
const DeviceDispatch = vk_dispatch.DeviceDispatch;
const InstanceDispatch = vk_dispatch.InstanceDispatch;

const pipeline_utils = @import("pipeline_utils.zig");

const MutableBuffer = @import("MutableBuffer.zig");
const StagingBuffer = @import("StagingBuffer.zig");
const dmem = @import("device_memory.zig");

// based on sascha's imgui example

// TODO: do I even need all this logic?? https://github.com/GameTechDev/MetricsGui/blob/master/imgui/examples/imgui_impl_vulkan.h

const vertex_index_buffer_size = 8 * dmem.bytes_in_megabyte;

const AssetHandler = @import("AssetHandler.zig");

const ImguiPipeline = @This();

pub const PushConstant = struct {
    scale: [2]f32,
    translate: [2]f32,
};

font_sampler: vk.Sampler,
font_image: vk.Image,
font_image_memory: vk.DeviceMemory,
font_view: vk.ImageView,

// TODO: we can have multiple frames in flight, we need multiple buffers to avoid race hazards
vertex_index_buffer: MutableBuffer,
buffer_offsets: []vk.DeviceSize,
vertex_buffer_offsets: []vk.DeviceSize,
index_buffer_offsets: []vk.DeviceSize,
swapchain_count: u32,

pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,
descriptor_pool: vk.DescriptorPool,
descriptor_set_layout: vk.DescriptorSetLayout,
descriptor_set: vk.DescriptorSet,

non_coherent_atom_size: vk.DeviceSize,

pub fn init(
    allocator: Allocator,
    asset_handler: AssetHandler,
    vki: InstanceDispatch,
    physical_device: vk.PhysicalDevice,
    vkd: DeviceDispatch,
    device: vk.Device,
    non_coherent_atom_size: vk.DeviceSize,
    swapchain_extent: vk.Extent2D,
    swapchain_count: u32,
    render_pass: vk.RenderPass,
    image_staging_buffer: *StagingBuffer.Image,
) !ImguiPipeline {
    // initialize imgui
    zgui.init(allocator);
    errdefer zgui.deinit();

    {
        const font_path = try asset_handler.getCPath(allocator, "fonts/quinque-five-font/Quinquefive-K7qep.ttf");
        defer allocator.free(font_path);
        const font = zgui.io.addFontFromFile(font_path, 10.0);
        zgui.io.setDefaultFont(font);
    }

    // Create font texture
    var font_atlas_width: i32 = undefined;
    var font_atlas_height: i32 = undefined;
    const font_atlas_pixels = zgui.io.getFontsTextDataAsRgba32(&font_atlas_width, &font_atlas_height);

    const font_image_format: vk.Format = .r8g8b8a8_unorm;
    const font_image = blk: {
        const image_info = vk.ImageCreateInfo{
            .flags = .{},
            .image_type = .@"2d",
            .format = font_image_format,
            .extent = .{
                .width = @intCast(u32, font_atlas_width),
                .height = @intCast(u32, font_atlas_height),
                .depth = @intCast(u32, 1),
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
    errdefer vkd.destroyImage(device, font_image, null);

    // TODO: use same image buffer as main pipeline
    const font_image_memory = try dmem.createDeviceImageMemory(
        vki,
        physical_device,
        vkd,
        device,
        &[_]vk.Image{font_image},
    );
    errdefer vkd.freeMemory(device, font_image_memory, null);
    try vkd.bindImageMemory(device, font_image, font_image_memory, 0);

    const font_view = blk: {
        const view_info = vk.ImageViewCreateInfo{
            .flags = .{},
            .image = font_image,
            .view_type = .@"2d",
            .format = font_image_format,
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
    errdefer vkd.destroyImageView(device, font_view, null);

    // upload texture data to gpu
    try image_staging_buffer.scheduleLayoutTransitionBeforeTransfers(font_image, .{
        .format = font_image_format,
        .old_layout = .undefined,
        .new_layout = .transfer_dst_optimal,
    });
    try image_staging_buffer.scheduleTransferToDst(
        font_image,
        vk.Extent2D{
            .width = @intCast(u32, font_atlas_width),
            .height = @intCast(u32, font_atlas_height),
        },
        u32,
        font_atlas_pixels[0..@intCast(usize, font_atlas_width * font_atlas_height)],
    );
    try image_staging_buffer.scheduleLayoutTransitionAfterTransfers(font_image, .{
        .format = font_image_format,
        .old_layout = .transfer_dst_optimal,
        .new_layout = .shader_read_only_optimal,
    });

    const font_sampler = blk: {
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
    errdefer vkd.destroySampler(device, font_sampler, null);

    const descriptor_pool = blk: {
        const pool_sizes = [_]vk.DescriptorPoolSize{.{
            .type = .combined_image_sampler,
            .descriptor_count = 1, // TODO: swap image size ?
        }};
        const descriptor_pool_info = vk.DescriptorPoolCreateInfo{
            .flags = .{},
            .max_sets = swapchain_count,
            .pool_size_count = pool_sizes.len,
            .p_pool_sizes = @ptrCast([*]const vk.DescriptorPoolSize, &pool_sizes),
        };
        break :blk try vkd.createDescriptorPool(device, &descriptor_pool_info, null);
    };
    errdefer vkd.destroyDescriptorPool(device, descriptor_pool, null);

    const descriptor_set_layout = blk: {
        const set_layout_bindings = [_]vk.DescriptorSetLayoutBinding{.{
            .binding = 0,
            .descriptor_type = .combined_image_sampler,
            .descriptor_count = 1,
            .stage_flags = .{
                .fragment_bit = true,
            },
            .p_immutable_samplers = null,
        }};
        const set_layout_info = vk.DescriptorSetLayoutCreateInfo{
            .flags = .{},
            .binding_count = set_layout_bindings.len,
            .p_bindings = @ptrCast([*]const vk.DescriptorSetLayoutBinding, &set_layout_bindings),
        };
        break :blk try vkd.createDescriptorSetLayout(device, &set_layout_info, null);
    };
    errdefer vkd.destroyDescriptorSetLayout(device, descriptor_set_layout, null);

    const descriptor_set = blk: {
        const alloc_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast([*]const vk.DescriptorSetLayout, &descriptor_set_layout),
        };
        var descriptor_set_tmp: vk.DescriptorSet = undefined;
        try vkd.allocateDescriptorSets(
            device,
            &alloc_info,
            @ptrCast([*]vk.DescriptorSet, &descriptor_set_tmp),
        );
        break :blk descriptor_set_tmp;
    };

    {
        const descriptor_info = vk.DescriptorImageInfo{
            .sampler = font_sampler,
            .image_view = font_view,
            .image_layout = .shader_read_only_optimal,
        };
        const write_descriptor_sets = [_]vk.WriteDescriptorSet{.{
            .dst_set = descriptor_set,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = @ptrCast([*]const vk.DescriptorImageInfo, &descriptor_info),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        }};
        vkd.updateDescriptorSets(
            device,
            write_descriptor_sets.len,
            @ptrCast([*]const vk.WriteDescriptorSet, &write_descriptor_sets),
            0,
            undefined,
        );
    }

    const pipeline_layout = blk: {
        const push_constant_range = vk.PushConstantRange{
            .stage_flags = .{ .vertex_bit = true },
            .offset = 0,
            .size = @sizeOf(PushConstant),
        };
        const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
            .flags = .{},
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast([*]const vk.DescriptorSetLayout, &descriptor_set_layout),
            .push_constant_range_count = 1,
            .p_push_constant_ranges = @ptrCast([*]const vk.PushConstantRange, &push_constant_range),
        };
        break :blk try vkd.createPipelineLayout(device, &pipeline_layout_info, null);
    };
    errdefer vkd.destroyPipelineLayout(device, pipeline_layout, null);

    var pipeline: vk.Pipeline = undefined;
    {
        const vert_bytes = blk: {
            const path = try asset_handler.getPath(allocator, "shaders/ui.vert.spv");
            defer allocator.free(path);
            const bytes = try pipeline_utils.readFile(allocator, path);
            break :blk bytes;
        };
        defer allocator.free(vert_bytes);

        const vert_module = try pipeline_utils.createShaderModule(vkd, device, vert_bytes);
        defer vkd.destroyShaderModule(device, vert_module, null);

        const vert_stage_info = vk.PipelineShaderStageCreateInfo{
            .flags = .{},
            .stage = .{ .vertex_bit = true },
            .module = vert_module,
            .p_name = "main",
            .p_specialization_info = null,
        };

        const frag_bytes = blk: {
            const path = try asset_handler.getPath(allocator, "shaders/ui.frag.spv");
            defer allocator.free(path);
            const bytes = try pipeline_utils.readFile(allocator, path);
            break :blk bytes;
        };
        defer allocator.free(frag_bytes);

        const frag_module = try pipeline_utils.createShaderModule(vkd, device, frag_bytes);
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
            getDrawVertBindingDescription(),
        };
        const attribute_descriptions = getDrawVertAttributeDescriptions();
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
            .cull_mode = .{},
            .front_face = .counter_clockwise,
            .depth_bias_enable = 0,
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
            .blend_enable = vk.TRUE,
            .src_color_blend_factor = .src_alpha,
            .dst_color_blend_factor = .one_minus_src_alpha,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one_minus_src_alpha,
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
            .logic_op = .clear,
            .attachment_count = 1,
            .p_attachments = @ptrCast([*]const vk.PipelineColorBlendAttachmentState, &color_blend_attachment),
            .blend_constants = [4]f32{ 0, 0, 0, 0 },
        };

        const depth_stencil_info: ?*vk.PipelineDepthStencilStateCreateInfo = null;

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
            .p_depth_stencil_state = depth_stencil_info,
            .p_color_blend_state = &color_blend_info,
            .p_dynamic_state = &dynamic_state_info,
            .layout = pipeline_layout,
            .render_pass = render_pass,
            .subpass = 1,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        };

        _ = try vkd.createGraphicsPipelines(
            device,
            .null_handle,
            1,
            @ptrCast([*]const vk.GraphicsPipelineCreateInfo, &pipeline_info),
            null,
            @ptrCast([*]vk.Pipeline, &pipeline),
        );
    }
    errdefer vkd.destroyPipeline(device, pipeline, null);

    var vertex_index_buffer = try MutableBuffer.init(
        vki,
        physical_device,
        vkd,
        device,
        non_coherent_atom_size,
        .{ .vertex_buffer_bit = true, .index_buffer_bit = true },
        .{ .size = vertex_index_buffer_size },
    );
    errdefer vertex_index_buffer.deinit(vkd, device);

    var buffer_offsets = try allocator.alloc(vk.DeviceSize, swapchain_count * 2);
    errdefer allocator.free(buffer_offsets);

    std.mem.set(vk.DeviceSize, buffer_offsets, 0);

    return ImguiPipeline{
        .font_sampler = font_sampler,
        .font_image = font_image,
        .font_image_memory = font_image_memory,
        .font_view = font_view,
        .vertex_index_buffer = vertex_index_buffer,
        .buffer_offsets = buffer_offsets,
        .vertex_buffer_offsets = buffer_offsets[0..swapchain_count],
        .index_buffer_offsets = buffer_offsets[swapchain_count..],
        .swapchain_count = swapchain_count,
        .pipeline_layout = pipeline_layout,
        .pipeline = pipeline,
        .descriptor_pool = descriptor_pool,
        .descriptor_set_layout = descriptor_set_layout,
        .descriptor_set = descriptor_set,
        .non_coherent_atom_size = non_coherent_atom_size,
    };
}

pub fn deinit(self: ImguiPipeline, allocator: Allocator, vkd: DeviceDispatch, device: vk.Device) void {
    allocator.free(self.buffer_offsets);
    self.vertex_index_buffer.deinit(vkd, device);

    vkd.destroyPipeline(device, self.pipeline, null);
    vkd.destroyPipelineLayout(device, self.pipeline_layout, null);
    vkd.destroyDescriptorSetLayout(device, self.descriptor_set_layout, null);
    vkd.destroyDescriptorPool(device, self.descriptor_pool, null);
    vkd.destroySampler(device, self.font_sampler, null);
    vkd.destroyImageView(device, self.font_view, null);
    vkd.freeMemory(device, self.font_image_memory, null);
    vkd.destroyImage(device, self.font_image, null);

    zgui.deinit();
}

pub inline fn updateDisplay(self: ImguiPipeline, swapchain_extent: vk.Extent2D) void {
    _ = self;

    // update gui state
    zgui.io.setDisplaySize(@intToFloat(f32, swapchain_extent.width), @intToFloat(f32, swapchain_extent.height));
    zgui.io.setDisplayFramebufferScale(1.0, 1.0);
}

pub fn draw(self: *ImguiPipeline, vkd: DeviceDispatch, device: vk.Device, command_buffer: vk.CommandBuffer, current_frame: usize) !void {
    // update vertex & index buffer
    try self.updateBuffers(vkd, device, current_frame);

    // record secondary command buffer
    self.recordCommandBuffer(vkd, command_buffer, current_frame);
}

inline fn updateBuffers(self: *ImguiPipeline, vkd: DeviceDispatch, device: vk.Device, current_frame: usize) !void {
    // const update_buffers_zone = tracy.ZoneN(@src(), "imgui: vertex & index update");
    // defer update_buffers_zone.End();

    const draw_data = zgui.getDrawData();
    if (draw_data.valid == false) {
        return;
    }

    const vertex_count = draw_data.total_vtx_count;
    const index_count = draw_data.total_idx_count;

    const vertex_size = @intCast(vk.DeviceSize, vertex_count * @sizeOf(zgui.DrawVert));
    const index_size = @intCast(vk.DeviceSize, index_count * @sizeOf(zgui.DrawIdx));

    if (index_size == 0 or vertex_size == 0) {
        return; // nothing to draw
    }

    {
        var vertex_offset: vk.DeviceSize = self.vertex_buffer_offsets[current_frame];
        var index_offset: vk.DeviceSize = vertex_offset + vertex_size;
        // TODO: we can actually handle this case by swapping the MutableBuffer in the error event of a schedule transfer
        std.debug.assert((index_offset + index_size) < self.vertex_index_buffer.size);

        // update current frame index_offset
        self.index_buffer_offsets[current_frame] = index_offset;

        const command_lists = draw_data.cmd_lists[0..@intCast(usize, draw_data.cmd_lists_count)];
        for (command_lists) |command_list| {
            // transfer vertex data for this command list
            {
                const vertex_buffer_length = command_list.getVertexBufferLength();
                const vertex_buffer_data = command_list.getVertexBufferData()[0..@intCast(usize, vertex_buffer_length)];
                try self.vertex_index_buffer.scheduleTransfer(vertex_offset, zgui.DrawVert, vertex_buffer_data);
                vertex_offset += @intCast(vk.DeviceSize, @sizeOf(zgui.DrawVert) * vertex_buffer_length);
            }

            // transfer index data for this command list
            {
                const index_buffer_length = command_list.getIndexBufferLength();
                const index_buffer_data = command_list.getIndexBufferData()[0..@intCast(usize, index_buffer_length)];
                try self.vertex_index_buffer.scheduleTransfer(index_offset, zgui.DrawIdx, index_buffer_data);
                index_offset += @intCast(vk.DeviceSize, @sizeOf(zgui.DrawIdx) * index_buffer_length);
            }
        }
        // send changes to GPU
        try self.vertex_index_buffer.flush(vkd, device);
    }

    // update next frame offsets
    const next_frame = (current_frame + 1) % self.swapchain_count;
    if (next_frame == 0) {
        self.vertex_buffer_offsets[next_frame] = 0;
    } else {
        self.vertex_buffer_offsets[next_frame] = dmem.pow2Align(
            self.non_coherent_atom_size,
            self.vertex_buffer_offsets[current_frame] + vertex_size + index_size,
        );
    }
}

inline fn recordCommandBuffer(self: ImguiPipeline, vkd: DeviceDispatch, command_buffer: vk.CommandBuffer, current_frame: usize) void {
    // const record_zone = tracy.ZoneN(@src(), "imgui record vk commands");
    // defer record_zone.End();

    // always increment subpass counter
    vkd.cmdNextSubpass(command_buffer, .@"inline");

    const draw_data: zgui.DrawData = zgui.getDrawData();
    if (draw_data.valid == false or (draw_data.total_idx_count + draw_data.total_vtx_count) == 0) {
        return;
    }

    const display_size_x = draw_data.display_size[0];
    const display_size_y = draw_data.display_size[1];

    vkd.cmdBindPipeline(command_buffer, .graphics, self.pipeline);
    vkd.cmdBindDescriptorSets(
        command_buffer,
        .graphics,
        self.pipeline_layout,
        0,
        1,
        @ptrCast([*]const vk.DescriptorSet, &self.descriptor_set),
        0,
        undefined,
    );
    const viewport = vk.Viewport{
        .x = draw_data.display_pos[0],
        .y = draw_data.display_pos[1],
        .width = display_size_x,
        .height = display_size_y,
        .min_depth = 0,
        .max_depth = 1,
    };
    vkd.cmdSetViewport(command_buffer, 0, 1, @ptrCast([*]const vk.Viewport, &viewport));

    // UI scale and translate via push constants
    const push_constant = PushConstant{
        .scale = [2]f32{ 2 / display_size_x, 2 / display_size_y },
        .translate = [2]f32{
            -1,
            -1,
        },
    };
    vkd.cmdPushConstants(command_buffer, self.pipeline_layout, .{ .vertex_bit = true }, 0, @sizeOf(PushConstant), &push_constant);

    if (draw_data.cmd_lists_count > 0) {
        vkd.cmdBindVertexBuffers(
            command_buffer,
            0,
            1,
            @ptrCast([*]const vk.Buffer, &self.vertex_index_buffer.buffer),
            self.vertex_buffer_offsets[current_frame..].ptr,
        );
        vkd.cmdBindIndexBuffer(
            command_buffer,
            self.vertex_index_buffer.buffer,
            self.index_buffer_offsets[current_frame],
            .uint16,
        );

        // Render commands
        var vertex_offset: i32 = 0;
        var index_offset: u32 = 0;
        const command_lists = draw_data.cmd_lists[0..@intCast(usize, draw_data.cmd_lists_count)];
        for (command_lists) |command_list| {
            const command_buffer_length = command_list.getCmdBufferLength();
            const command_buffer_data = command_list.getCmdBufferData();

            for (command_buffer_data[0..@intCast(usize, command_buffer_length)]) |draw_command| {
                const X = 0;
                const Y = 1;
                const Z = 2;
                const W = 3;
                const scissor_rect = vk.Rect2D{
                    .offset = .{
                        .x = @max(@floatToInt(i32, draw_command.clip_rect[X]), 0),
                        .y = @max(@floatToInt(i32, draw_command.clip_rect[Y]), 0),
                    },
                    .extent = .{
                        .width = @floatToInt(u32, draw_command.clip_rect[Z] - draw_command.clip_rect[X]),
                        .height = @floatToInt(u32, draw_command.clip_rect[W] - draw_command.clip_rect[Y]),
                    },
                };
                vkd.cmdSetScissor(command_buffer, 0, 1, @ptrCast([*]const vk.Rect2D, &scissor_rect));
                vkd.cmdDrawIndexed(
                    command_buffer,
                    draw_command.elem_count,
                    1,
                    index_offset,
                    vertex_offset,
                    0,
                );
                index_offset += draw_command.elem_count;
            }
            vertex_offset += command_list.getVertexBufferLength();
        }
    }
}

// TODO: this function is trivial to generalize for all vertex data using meta programming
inline fn getDrawVertBindingDescription() vk.VertexInputBindingDescription {
    return vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(zgui.DrawVert),
        .input_rate = .vertex,
    };
}

// TODO: this function is trivial to generalize for all vertex data using meta programming
inline fn getDrawVertAttributeDescriptions() [3]vk.VertexInputAttributeDescription {
    return [_]vk.VertexInputAttributeDescription{
        .{
            .location = 0,
            .binding = 0,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(zgui.DrawVert, "pos"),
        },
        .{
            .location = 1,
            .binding = 0,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(zgui.DrawVert, "uv"),
        },
        .{
            .location = 2,
            .binding = 0,
            .format = .r8g8b8a8_unorm,
            .offset = @offsetOf(zgui.DrawVert, "color"),
        },
    };
}
