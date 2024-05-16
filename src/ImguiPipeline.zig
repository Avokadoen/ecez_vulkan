const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("vulkan");
const zgui = @import("zgui");
const zigimg = @import("zigimg");

const AssetHandler = @import("AssetHandler.zig");

const vk_dispatch = @import("vk_dispatch.zig");
const DeviceDispatch = vk_dispatch.DeviceDispatch;
const InstanceDispatch = vk_dispatch.InstanceDispatch;

const pipeline_utils = @import("pipeline_utils.zig");

const MutableBuffer = @import("MutableBuffer.zig");
const StagingBuffer = @import("StagingBuffer.zig");
const dmem = @import("device_memory.zig");

const ImageResource = @import("ImageResource.zig");

// based on sascha's imgui example

// TODO: do I even need all this logic?? https://github.com/GameTechDev/MetricsGui/blob/master/imgui/examples/imgui_impl_vulkan.h

const vertex_index_buffer_size = 8 * dmem.bytes_in_megabyte;

const ImguiPipeline = @This();

pub const UiPushConstant = extern struct {
    scale: [2]f32,
    translate: [2]f32,
};

// TODO: move these out of ImguiPipeline
pub const uv_stride: f32 = 0.0625;
pub const atlas_dimension: f32 = 288.0;
pub const TextureIndices = struct {
    font: c_uint = 0,
    icon: c_uint = 1,
};
pub const FragDrawPushConstant = extern struct {
    texture_index: c_uint,
};

font_image_resources: ImageResource,
icon_image_resources: ImageResource,
image_memory: vk.DeviceMemory,
texture_indices: *TextureIndices,

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
    vki: InstanceDispatch,
    physical_device: vk.PhysicalDevice,
    vkd: DeviceDispatch,
    device: vk.Device,
    non_coherent_atom_size: vk.DeviceSize,
    swapchain_extent: vk.Extent2D,
    swapchain_count: u32,
    render_pass: vk.RenderPass,
    image_staging_buffer: *StagingBuffer.Image,
    asset_handler: AssetHandler,
) !ImguiPipeline {
    // initialize imgui
    zgui.init(allocator);
    errdefer zgui.deinit();

    // {
    //     const font_path = try asset_handler.getCPath(allocator, "fonts/quinque-five-font/Quinquefive-K7qep.ttf");
    //     defer allocator.free(font_path);
    //     const font = zgui.io.addFontFromFile(font_path, 10.0);
    //     zgui.io.setDefaultFont(font);
    // }

    // TODO: image creation should be global since we are using descriptor indexing?
    // Create font texture
    var image_memory: vk.DeviceMemory = .null_handle;
    var font_image_resources: ImageResource = undefined;
    var icon_image_resources: ImageResource = undefined;
    {
        const font_atlas = zgui.io.getFontsTextDataAsRgba32();

        font_image_resources = try ImageResource.init(
            vkd,
            device,
            @intCast(font_atlas.width),
            @intCast(font_atlas.height),
            .r8g8b8a8_unorm,
        );
        errdefer font_image_resources.deinit(vkd, device);

        const icon_path = try asset_handler.getPath(allocator, "images/iconset.png");
        defer allocator.free(icon_path);

        var icon_image = try zigimg.Image.fromFilePath(allocator, icon_path);
        defer icon_image.deinit();

        // current icon atlas assumptions, specifically this pipeline and EditorIcons rely on these assumptions
        std.debug.assert(icon_image.pixelFormat() == .grayscale8);
        std.debug.assert(icon_image.width == @as(usize, @intFromFloat(atlas_dimension)));
        std.debug.assert(icon_image.height == @as(usize, @intFromFloat(atlas_dimension)));

        icon_image_resources = try ImageResource.init(
            vkd,
            device,
            @intCast(icon_image.width),
            @intCast(icon_image.height),
            .r8_unorm,
        );
        errdefer icon_image_resources.deinit(vkd, device);

        const raw_font_atlas_pixels: [*]const u8 = @ptrCast(font_atlas.pixels);
        const icon_image_pixels = icon_image.pixels.asBytes();

        image_memory = try ImageResource.bindImagesToMemory(
            vki,
            vkd,
            physical_device,
            device,
            &[_]*ImageResource{
                &font_image_resources,
                &icon_image_resources,
            },
            &[_][]const u8{
                raw_font_atlas_pixels[0..@intCast(font_atlas.width * font_atlas.height * @sizeOf(u32))],
                icon_image_pixels,
            },
            image_staging_buffer,
        );
    }
    errdefer {
        vkd.freeMemory(device, image_memory, null);
        icon_image_resources.deinit(vkd, device);
        font_image_resources.deinit(vkd, device);
    }

    const texture_indices = try allocator.create(TextureIndices);
    errdefer allocator.destroy(texture_indices);

    texture_indices.* = .{};
    // set imgui font index
    zgui.io.setFontsTexId(&texture_indices.font);

    // font atlas + icon atlas
    const image_count = 2;

    const descriptor_pool = blk: {
        const pool_sizes = [_]vk.DescriptorPoolSize{.{
            .type = .combined_image_sampler,
            .descriptor_count = image_count,
        }};
        const descriptor_pool_info = vk.DescriptorPoolCreateInfo{
            .flags = .{},
            .max_sets = swapchain_count,
            .pool_size_count = pool_sizes.len,
            .p_pool_sizes = @as([*]const vk.DescriptorPoolSize, @ptrCast(&pool_sizes)),
        };
        break :blk try vkd.createDescriptorPool(device, &descriptor_pool_info, null);
    };
    errdefer vkd.destroyDescriptorPool(device, descriptor_pool, null);

    const descriptor_set_layout = blk: {
        const set_layout_bindings = [_]vk.DescriptorSetLayoutBinding{.{
            .binding = 0,
            .descriptor_type = .combined_image_sampler,
            .descriptor_count = image_count,
            .stage_flags = .{ .fragment_bit = true },
            .p_immutable_samplers = null,
        }};

        const binding_flags = [set_layout_bindings.len]vk.DescriptorBindingFlagsEXT{.{ .variable_descriptor_count_bit = true }};

        // Mark descriptor binding as variable count
        const set_layout_binding_flags = vk.DescriptorSetLayoutBindingFlagsCreateInfoEXT{
            .binding_count = binding_flags.len,
            .p_binding_flags = &binding_flags,
        };

        const set_layout_info = vk.DescriptorSetLayoutCreateInfo{
            .p_next = &set_layout_binding_flags,
            .flags = .{},
            .binding_count = set_layout_bindings.len,
            .p_bindings = @as([*]const vk.DescriptorSetLayoutBinding, @ptrCast(&set_layout_bindings)),
        };
        break :blk try vkd.createDescriptorSetLayout(device, &set_layout_info, null);
    };
    errdefer vkd.destroyDescriptorSetLayout(device, descriptor_set_layout, null);

    const variable_counts = [_]u32{image_count};
    const variable_descriptor_count_alloc_info = vk.DescriptorSetVariableDescriptorCountAllocateInfoEXT{
        .descriptor_set_count = variable_counts.len,
        .p_descriptor_counts = &variable_counts,
    };

    const descriptor_set = blk: {
        const alloc_info = vk.DescriptorSetAllocateInfo{
            .p_next = &variable_descriptor_count_alloc_info,
            .descriptor_pool = descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @as([*]const vk.DescriptorSetLayout, @ptrCast(&descriptor_set_layout)),
        };
        var descriptor_set_tmp: vk.DescriptorSet = undefined;
        try vkd.allocateDescriptorSets(
            device,
            &alloc_info,
            @as([*]vk.DescriptorSet, @ptrCast(&descriptor_set_tmp)),
        );
        break :blk descriptor_set_tmp;
    };

    {
        const descriptor_info = [_]vk.DescriptorImageInfo{ .{
            .sampler = font_image_resources.sampler,
            .image_view = font_image_resources.view.?,
            .image_layout = .shader_read_only_optimal,
        }, .{
            .sampler = icon_image_resources.sampler,
            .image_view = icon_image_resources.view.?,
            .image_layout = .shader_read_only_optimal,
        } };
        const write_descriptor_sets = [_]vk.WriteDescriptorSet{.{
            .dst_set = descriptor_set,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = descriptor_info.len,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = &descriptor_info,
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        }};
        vkd.updateDescriptorSets(
            device,
            write_descriptor_sets.len,
            @as([*]const vk.WriteDescriptorSet, @ptrCast(&write_descriptor_sets)),
            0,
            undefined,
        );
    }

    // shaders assume 16
    std.debug.assert(@sizeOf(UiPushConstant) == 16);

    const pipeline_layout = blk: {
        const push_constant_range = [_]vk.PushConstantRange{
            .{
                .stage_flags = .{ .vertex_bit = true },
                .offset = 0,
                .size = @sizeOf(UiPushConstant),
            },
            .{
                .stage_flags = .{ .fragment_bit = true },
                .offset = @sizeOf(UiPushConstant),
                .size = @sizeOf(FragDrawPushConstant),
            },
        };
        const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
            .flags = .{},
            .set_layout_count = 1,
            .p_set_layouts = @as([*]const vk.DescriptorSetLayout, @ptrCast(&descriptor_set_layout)),
            .push_constant_range_count = push_constant_range.len,
            .p_push_constant_ranges = &push_constant_range,
        };
        break :blk try vkd.createPipelineLayout(device, &pipeline_layout_info, null);
    };
    errdefer vkd.destroyPipelineLayout(device, pipeline_layout, null);

    var pipeline: vk.Pipeline = undefined;
    {
        const shaders = @import("shaders");

        const vert_bytes = shaders.ui_vert_spv;
        const vert_module = try pipeline_utils.createShaderModule(vkd, device, &vert_bytes);
        defer vkd.destroyShaderModule(device, vert_module, null);

        const vert_stage_info = vk.PipelineShaderStageCreateInfo{
            .flags = .{},
            .stage = .{ .vertex_bit = true },
            .module = vert_module,
            .p_name = "main",
            .p_specialization_info = null,
        };

        const frag_bytes = shaders.ui_frag_spv;
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
            .p_attachments = @as([*]const vk.PipelineColorBlendAttachmentState, @ptrCast(&color_blend_attachment)),
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
            @as([*]const vk.GraphicsPipelineCreateInfo, @ptrCast(&pipeline_info)),
            null,
            @as([*]vk.Pipeline, @ptrCast(&pipeline)),
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

    @memset(buffer_offsets, 0);

    return ImguiPipeline{
        .font_image_resources = font_image_resources,
        .icon_image_resources = icon_image_resources,
        .image_memory = image_memory,
        .texture_indices = texture_indices,
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
    allocator.destroy(self.texture_indices);
    allocator.free(self.buffer_offsets);
    self.vertex_index_buffer.deinit(vkd, device);

    vkd.destroyPipeline(device, self.pipeline, null);
    vkd.destroyPipelineLayout(device, self.pipeline_layout, null);
    vkd.destroyDescriptorSetLayout(device, self.descriptor_set_layout, null);
    vkd.destroyDescriptorPool(device, self.descriptor_pool, null);

    vkd.freeMemory(device, self.image_memory, null);
    self.icon_image_resources.deinit(vkd, device);
    self.font_image_resources.deinit(vkd, device);

    zgui.deinit();
}

pub inline fn updateDisplay(self: ImguiPipeline, swapchain_extent: vk.Extent2D) void {
    _ = self;

    // update gui state
    zgui.io.setDisplaySize(@as(f32, @floatFromInt(swapchain_extent.width)), @as(f32, @floatFromInt(swapchain_extent.height)));
    zgui.io.setDisplayFramebufferScale(1.0, 1.0);
}

pub fn draw(self: *ImguiPipeline, vkd: DeviceDispatch, device: vk.Device, command_buffer: vk.CommandBuffer, current_frame: usize) !void {
    // update vertex & index buffer
    try self.updateBuffers(vkd, device, current_frame);

    // record secondary command buffer
    self.recordCommandBuffer(vkd, command_buffer, current_frame);
}

fn updateBuffers(self: *ImguiPipeline, vkd: DeviceDispatch, device: vk.Device, current_frame: usize) !void {
    // const update_buffers_zone = tracy.ZoneN(@src(), "imgui: vertex & index update");
    // defer update_buffers_zone.End();

    const draw_data = zgui.getDrawData();
    if (draw_data.valid == false) {
        return;
    }

    const vertex_count = draw_data.total_vtx_count;
    const index_count = draw_data.total_idx_count;

    const vertex_size = @as(vk.DeviceSize, @intCast(vertex_count * @sizeOf(zgui.DrawVert)));
    const index_size = @as(vk.DeviceSize, @intCast(index_count * @sizeOf(zgui.DrawIdx)));

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

        const command_lists = draw_data.cmd_lists.items[0..@as(usize, @intCast(draw_data.cmd_lists_count))];
        for (command_lists) |command_list| {
            // transfer vertex data for this command list
            {
                const vertex_buffer_length = command_list.getVertexBufferLength();
                const vertex_buffer_data = command_list.getVertexBufferData()[0..@as(usize, @intCast(vertex_buffer_length))];
                try self.vertex_index_buffer.scheduleTransfer(vertex_offset, zgui.DrawVert, vertex_buffer_data);
                vertex_offset += @as(vk.DeviceSize, @intCast(@sizeOf(zgui.DrawVert) * vertex_buffer_length));
            }

            // transfer index data for this command list
            {
                const index_buffer_length = command_list.getIndexBufferLength();
                const index_buffer_data = command_list.getIndexBufferData()[0..@as(usize, @intCast(index_buffer_length))];
                try self.vertex_index_buffer.scheduleTransfer(index_offset, zgui.DrawIdx, index_buffer_data);
                index_offset += @as(vk.DeviceSize, @intCast(@sizeOf(zgui.DrawIdx) * index_buffer_length));
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
        @as([*]const vk.DescriptorSet, @ptrCast(&self.descriptor_set)),
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
    vkd.cmdSetViewport(command_buffer, 0, 1, @as([*]const vk.Viewport, @ptrCast(&viewport)));

    // UI scale and translate via push constants
    const ui_push_constant = UiPushConstant{
        .scale = [2]f32{ 2 / display_size_x, 2 / display_size_y },
        .translate = [2]f32{
            -1,
            -1,
        },
    };
    vkd.cmdPushConstants(
        command_buffer,
        self.pipeline_layout,
        .{ .vertex_bit = true },
        0,
        @sizeOf(UiPushConstant),
        &ui_push_constant,
    );

    if (draw_data.cmd_lists_count > 0) {
        vkd.cmdBindVertexBuffers(
            command_buffer,
            0,
            1,
            @as([*]const vk.Buffer, @ptrCast(&self.vertex_index_buffer.buffer)),
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
        const command_lists = draw_data.cmd_lists.items[0..@as(usize, @intCast(draw_data.cmd_lists_count))];
        for (command_lists) |command_list| {
            const command_buffer_length = command_list.getCmdBufferLength();
            const command_buffer_data = command_list.getCmdBufferData();

            for (command_buffer_data[0..@as(usize, @intCast(command_buffer_length))]) |draw_command| {
                const X = 0;
                const Y = 1;
                const Z = 2;
                const W = 3;
                const scissor_rect = vk.Rect2D{
                    .offset = .{
                        .x = @max(@as(i32, @intFromFloat(draw_command.clip_rect[X])), 0),
                        .y = @max(@as(i32, @intFromFloat(draw_command.clip_rect[Y])), 0),
                    },
                    .extent = .{
                        .width = @as(u32, @intFromFloat(draw_command.clip_rect[Z] - draw_command.clip_rect[X])),
                        .height = @as(u32, @intFromFloat(draw_command.clip_rect[W] - draw_command.clip_rect[Y])),
                    },
                };
                vkd.cmdSetScissor(command_buffer, 0, 1, @as([*]const vk.Rect2D, @ptrCast(&scissor_rect)));

                const texture_id: *c_uint = @ptrCast(@alignCast(draw_command.texture_id));
                vkd.cmdPushConstants(
                    command_buffer,
                    self.pipeline_layout,
                    .{ .fragment_bit = true },
                    @sizeOf(UiPushConstant),
                    @sizeOf(FragDrawPushConstant),
                    texture_id,
                );

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
