const std = @import("std");

const vk = @import("vulkan");

const vk_dispatch = @import("vk_dispatch.zig");
const InstanceDispatch = vk_dispatch.InstanceDispatch;
const DeviceDispatch = vk_dispatch.DeviceDispatch;

const dmem = @import("device_memory.zig");
const sync = @import("sync.zig");

pub const Config = struct {
    size: vk.DeviceSize = 64 * dmem.bytes_in_megabyte, // default of 64 megabyte for staging
};

pub const ImageTransition = struct {
    format: vk.Format,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
};

const StagingContext = struct {
    size: vk.DeviceSize,
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,

    incoherent_memory_bytes: vk.DeviceSize = 0,
    non_coherent_atom_size: vk.DeviceSize,

    // TODO: reduce duplicate memory
    // memory still not flushed
    memory_in_flight: u32 = 0,
    mapped_ranges: [max_transfers_scheduled]vk.MappedMemoryRange = undefined,

    transfer_queue: vk.Queue,
    command_pool: vk.CommandPool,
    command_buffer: vk.CommandBuffer,
    transfer_fence: vk.Fence,

    device_data: []u8,

    pub inline fn init(
        vki: InstanceDispatch,
        physical_device: vk.PhysicalDevice,
        vkd: DeviceDispatch,
        device: vk.Device,
        non_coherent_atom_size: vk.DeviceSize,
        transfer_family_index: u32,
        transfer_queue: vk.Queue,
        config: Config,
    ) !StagingContext {
        std.debug.assert(config.size != 0);

        const size = dmem.pow2Align(non_coherent_atom_size, config.size);

        // create device memory and transfer vertices to host
        const buffer = try dmem.createBuffer(
            vkd,
            device,
            non_coherent_atom_size,
            size,
            .{ .transfer_src_bit = true },
        );
        errdefer vkd.destroyBuffer(device, buffer, null);
        const memory = try dmem.createDeviceMemory(
            vkd,
            device,
            vki,
            physical_device,
            buffer,
            .{ .host_visible_bit = true },
        );
        errdefer vkd.freeMemory(device, memory, null);
        try vkd.bindBufferMemory(device, buffer, memory, 0);

        const pool_info = vk.CommandPoolCreateInfo{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = transfer_family_index,
        };
        const command_pool = try vkd.createCommandPool(device, &pool_info, null);
        errdefer vkd.destroyCommandPool(device, command_pool, null);

        var command_buffer: vk.CommandBuffer = undefined;
        const cmd_buffer_info = vk.CommandBufferAllocateInfo{
            .command_pool = command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        };
        try vkd.allocateCommandBuffers(device, &cmd_buffer_info, @as([*]vk.CommandBuffer, @ptrCast(&command_buffer)));

        const transfer_fence = try sync.createFence(vkd, device, false);
        errdefer vkd.destroyFence(device, transfer_fence, null);

        const device_data: []u8 = blk: {
            var raw_device_ptr = try vkd.mapMemory(device, memory, 0, size, .{});
            break :blk @as([*]u8, @ptrCast(raw_device_ptr))[0..size];
        };

        return StagingContext{
            .size = size,
            .buffer = buffer,
            .memory = memory,
            .non_coherent_atom_size = non_coherent_atom_size,
            .command_pool = command_pool,
            .command_buffer = command_buffer,
            .transfer_queue = transfer_queue,
            .transfer_fence = transfer_fence,
            .device_data = device_data,
        };
    }

    pub inline fn deinit(self: StagingContext, vkd: DeviceDispatch, device: vk.Device) void {
        _ = vkd.waitForFences(device, 1, @as([*]const vk.Fence, @ptrCast(&self.transfer_fence)), vk.TRUE, std.time.ns_per_s) catch {};
        vkd.unmapMemory(device, self.memory);
        vkd.destroyFence(device, self.transfer_fence, null);
        vkd.destroyCommandPool(device, self.command_pool, null);
        vkd.freeMemory(device, self.memory, null);
        vkd.destroyBuffer(device, self.buffer, null);
    }
};

const max_transfers_scheduled = 32;

pub const Buffer = struct {
    const TransferBufferDestination = struct {
        buffer: vk.Buffer,
        offset: vk.DeviceSize,
    };

    ctx: StagingContext,
    buffer_destinations: [max_transfers_scheduled]TransferBufferDestination = undefined,

    pub fn init(
        vki: InstanceDispatch,
        physical_device: vk.PhysicalDevice,
        vkd: DeviceDispatch,
        device: vk.Device,
        non_coherent_atom_size: vk.DeviceSize,
        transfer_family_index: u32,
        transfer_queue: vk.Queue,
        config: Config,
    ) !Buffer {
        return Buffer{
            .ctx = try StagingContext.init(
                vki,
                physical_device,
                vkd,
                device,
                non_coherent_atom_size,
                transfer_family_index,
                transfer_queue,
                config,
            ),
        };
    }

    pub fn deinit(self: Buffer, vkd: DeviceDispatch, device: vk.Device) void {
        self.ctx.deinit(vkd, device);
    }

    pub fn scheduleTransferToDst(
        self: *Buffer,
        destination_buffer: vk.Buffer,
        destination_offset: vk.DeviceSize,
        comptime T: type,
        data: []const T,
    ) !vk.DeviceSize {
        if (self.ctx.memory_in_flight >= max_transfers_scheduled) {
            return error.OutOfTransferSlots;
        }

        const raw_data = std.mem.sliceAsBytes(data);
        if (raw_data.len > self.ctx.size) {
            return error.InsufficentStagingSize; // the staging buffer can not transfer this data in one transfer
        }
        if (self.ctx.incoherent_memory_bytes + raw_data.len > self.ctx.size) {
            return error.OutOfMemory;
        }

        const aligned_memory_size = dmem.pow2Align(
            self.ctx.non_coherent_atom_size,
            @as(vk.DeviceSize, @intCast(raw_data.len)),
        );

        var vacant_device_data = self.ctx.device_data[self.ctx.incoherent_memory_bytes..];
        std.mem.copy(u8, vacant_device_data, raw_data);

        self.ctx.mapped_ranges[self.ctx.memory_in_flight] = vk.MappedMemoryRange{
            .memory = self.ctx.memory,
            .offset = self.ctx.incoherent_memory_bytes,
            .size = aligned_memory_size,
        };
        self.buffer_destinations[self.ctx.memory_in_flight] = TransferBufferDestination{
            .buffer = destination_buffer,
            .offset = destination_offset,
        };

        self.ctx.memory_in_flight += 1;
        self.ctx.incoherent_memory_bytes += aligned_memory_size;

        return aligned_memory_size;
    }

    pub fn flushAndCopyToDestination(
        self: *Buffer,
        vkd: DeviceDispatch,
        device: vk.Device,
        transfers_complete_semaphores: ?[]vk.Semaphore,
    ) !void {
        // TODO: propert errdefers in function

        if (self.ctx.memory_in_flight == 0) return;

        try vkd.flushMappedMemoryRanges(device, self.ctx.memory_in_flight, &self.ctx.mapped_ranges);

        const begin_info = vk.CommandBufferBeginInfo{
            .flags = .{ .one_time_submit_bit = true },
            .p_inheritance_info = null,
        };
        try vkd.beginCommandBuffer(self.ctx.command_buffer, &begin_info);

        // TODO: reduce buffers, only have one of each dst buffer
        var copy_regions: [max_transfers_scheduled]vk.BufferCopy = undefined;
        for (self.buffer_destinations[0..self.ctx.memory_in_flight], 0..) |dest, i| {
            const source_range = self.ctx.mapped_ranges[i];
            copy_regions[i] = vk.BufferCopy{
                .src_offset = source_range.offset,
                .dst_offset = dest.offset,
                .size = source_range.size,
            };
            vkd.cmdCopyBuffer(self.ctx.command_buffer, self.ctx.buffer, dest.buffer, 1, copy_regions[i..].ptr);
        }

        try vkd.endCommandBuffer(self.ctx.command_buffer);

        const submit_into = vk.SubmitInfo{
            .wait_semaphore_count = 0,
            .p_wait_semaphores = undefined,
            .p_wait_dst_stage_mask = undefined,
            .command_buffer_count = 1,
            .p_command_buffers = @as([*]vk.CommandBuffer, @ptrCast(&self.ctx.command_buffer)),
            .signal_semaphore_count = if (transfers_complete_semaphores) |semaphores| @as(u32, @intCast(semaphores.len)) else 0,
            .p_signal_semaphores = if (transfers_complete_semaphores) |semaphores| semaphores.ptr else undefined,
        };
        try vkd.queueSubmit(self.ctx.transfer_queue, 1, @as([*]const vk.SubmitInfo, @ptrCast(&submit_into)), self.ctx.transfer_fence);

        // TODO: do not force wait if there is a semaphore
        _ = vkd.waitForFences(device, 1, @as([*]const vk.Fence, @ptrCast(&self.ctx.transfer_fence)), vk.TRUE, std.time.ns_per_s) catch {};
        try vkd.resetFences(device, 1, @as([*]const vk.Fence, @ptrCast(&self.ctx.transfer_fence)));

        self.ctx.memory_in_flight = 0;
        self.ctx.incoherent_memory_bytes = 0;
        try vkd.resetCommandPool(device, self.ctx.command_pool, .{});
    }
};

pub const Image = struct {
    const ImageTransferJob = struct {
        image: vk.Image,
        width: u32,
        height: u32,
    };

    const ImageTransitionJob = struct {
        image: vk.Image,
        transition: ImageTransition,
    };

    ctx: StagingContext,

    transitions_before_transfer_in_flight: u32 = 0,
    image_transitions_before: [max_transfers_scheduled / 2]ImageTransitionJob = undefined,

    transitions_after_transfer_in_flight: u32 = 0,
    image_transitions_after: [max_transfers_scheduled / 2]ImageTransitionJob = undefined,

    image_destinations: [max_transfers_scheduled]ImageTransferJob = undefined,

    pub fn init(
        vki: InstanceDispatch,
        physical_device: vk.PhysicalDevice,
        vkd: DeviceDispatch,
        device: vk.Device,
        non_coherent_atom_size: vk.DeviceSize,
        transfer_family_index: u32,
        transfer_queue: vk.Queue,
        config: Config,
    ) !Image {
        return Image{
            .ctx = try StagingContext.init(
                vki,
                physical_device,
                vkd,
                device,
                non_coherent_atom_size,
                transfer_family_index,
                transfer_queue,
                config,
            ),
        };
    }

    pub fn deinit(self: Image, vkd: DeviceDispatch, device: vk.Device) void {
        self.ctx.deinit(vkd, device);
    }

    pub fn scheduleTransferToDst(
        self: *Image,
        destination_image: vk.Image,
        image_extent: vk.Extent2D,
        comptime T: type,
        data: []const T,
    ) !void {
        if (self.ctx.memory_in_flight >= max_transfers_scheduled) {
            return error.OutOfTransferSlots;
        }

        const raw_data = std.mem.sliceAsBytes(data);
        if (raw_data.len > self.ctx.size) {
            return error.InsufficentStagingSize; // the staging buffer can not transfer this data in one transfer
        }
        if (self.ctx.incoherent_memory_bytes + raw_data.len > self.ctx.size) {
            return error.OutOfMemory;
        }

        const aligned_memory_size = dmem.pow2Align(self.ctx.non_coherent_atom_size, @as(vk.DeviceSize, @intCast(raw_data.len)));
        var vacant_device_data = self.ctx.device_data[self.ctx.incoherent_memory_bytes..];
        std.mem.copy(u8, vacant_device_data, raw_data);

        self.ctx.mapped_ranges[self.ctx.memory_in_flight] = vk.MappedMemoryRange{
            .memory = self.ctx.memory,
            .offset = self.ctx.incoherent_memory_bytes,
            .size = aligned_memory_size,
        };
        self.image_destinations[self.ctx.memory_in_flight] = ImageTransferJob{
            .image = destination_image,
            .width = @as(u32, @intCast(image_extent.width)),
            .height = @as(u32, @intCast(image_extent.height)),
        };

        self.ctx.memory_in_flight += 1;
        self.ctx.incoherent_memory_bytes += aligned_memory_size;
    }

    pub fn scheduleLayoutTransitionBeforeTransfers(
        self: *Image,
        image: vk.Image,
        transition: ImageTransition,
    ) !void {
        if (self.transitions_before_transfer_in_flight >= max_transfers_scheduled / 2) {
            return error.OutOfTransitionBeforeTransferSlots;
        }

        self.image_transitions_before[self.transitions_before_transfer_in_flight] = ImageTransitionJob{
            .image = image,
            .transition = transition,
        };

        self.transitions_before_transfer_in_flight += 1;
    }

    pub fn scheduleLayoutTransitionAfterTransfers(
        self: *Image,
        image: vk.Image,
        transition: ImageTransition,
    ) !void {
        if (self.transitions_after_transfer_in_flight >= max_transfers_scheduled / 2) {
            return error.OutOfTransitionAfterTransferSlots;
        }

        self.image_transitions_after[self.transitions_after_transfer_in_flight] = ImageTransitionJob{
            .image = image,
            .transition = transition,
        };

        self.transitions_after_transfer_in_flight += 1;
    }

    pub fn flushAndCopyToDestination(
        self: *Image,
        vkd: DeviceDispatch,
        device: vk.Device,
        transfers_complete_semaphores: ?[]vk.Semaphore,
    ) !void {
        // TODO: propert errdefers in function

        if (self.ctx.memory_in_flight == 0 and
            self.transitions_before_transfer_in_flight == 0 and
            self.transitions_after_transfer_in_flight == 0)
        {
            return;
        }

        if (self.ctx.memory_in_flight != 0) {
            try vkd.flushMappedMemoryRanges(device, self.ctx.memory_in_flight, &self.ctx.mapped_ranges);
        }

        const begin_info = vk.CommandBufferBeginInfo{
            .flags = .{ .one_time_submit_bit = true },
            .p_inheritance_info = null,
        };
        try vkd.beginCommandBuffer(self.ctx.command_buffer, &begin_info);

        for (self.image_transitions_before[0..self.transitions_before_transfer_in_flight]) |transition_job| {
            const transition = transition_job.transition;
            try transitionImage(
                vkd,
                self.ctx.command_buffer,
                transition_job.image,
                transition.format,
                transition.old_layout,
                transition.new_layout,
            );
        }

        var region = vk.BufferImageCopy{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = vk.ImageSubresourceLayers{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{
                .width = 0,
                .height = 0,
                .depth = 1,
            },
        };
        for (self.image_destinations[0..self.ctx.memory_in_flight], 0..) |dest, i| {
            region.buffer_offset = self.ctx.mapped_ranges[i].offset;
            region.image_extent.width = dest.width;
            region.image_extent.height = dest.height;

            vkd.cmdCopyBufferToImage(self.ctx.command_buffer, self.ctx.buffer, dest.image, .transfer_dst_optimal, 1, @as([*]const vk.BufferImageCopy, @ptrCast(&region)));
        }

        for (self.image_transitions_after[0..self.transitions_after_transfer_in_flight]) |transition_job| {
            const transition = transition_job.transition;
            try transitionImage(
                vkd,
                self.ctx.command_buffer,
                transition_job.image,
                transition.format,
                transition.old_layout,
                transition.new_layout,
            );
        }

        try vkd.endCommandBuffer(self.ctx.command_buffer);

        const submit_into = vk.SubmitInfo{
            .wait_semaphore_count = 0,
            .p_wait_semaphores = undefined,
            .p_wait_dst_stage_mask = undefined,
            .command_buffer_count = 1,
            .p_command_buffers = @as([*]vk.CommandBuffer, @ptrCast(&self.ctx.command_buffer)),
            .signal_semaphore_count = if (transfers_complete_semaphores) |semaphores| @as(u32, @intCast(semaphores.len)) else 0,
            .p_signal_semaphores = if (transfers_complete_semaphores) |semaphores| semaphores.ptr else undefined,
        };
        try vkd.queueSubmit(self.ctx.transfer_queue, 1, @as([*]const vk.SubmitInfo, @ptrCast(&submit_into)), self.ctx.transfer_fence);

        // TODO: we dont want to force fence wait here (should be a manuall call to reset, same for staging buffer)
        _ = vkd.waitForFences(device, 1, @as([*]const vk.Fence, @ptrCast(&self.ctx.transfer_fence)), vk.TRUE, std.time.ns_per_s) catch {};
        try vkd.resetFences(device, 1, @as([*]const vk.Fence, @ptrCast(&self.ctx.transfer_fence)));

        try vkd.resetCommandPool(device, self.ctx.command_pool, .{});

        self.ctx.memory_in_flight = 0;
        self.ctx.incoherent_memory_bytes = 0;
        self.transitions_before_transfer_in_flight = 0;
        self.transitions_after_transfer_in_flight = 0;
    }

    inline fn transitionImage(
        vkd: DeviceDispatch,
        command_buffer: vk.CommandBuffer,
        image: vk.Image,
        format: vk.Format,
        old_layout: vk.ImageLayout,
        new_layout: vk.ImageLayout,
    ) !void {
        const aspect_mask: vk.ImageAspectFlags = blk: {
            if (new_layout == .depth_stencil_attachment_optimal) {
                break :blk .{
                    .depth_bit = true,
                    .stencil_bit = hasStencilComponent(format),
                };
            }
            break :blk .{ .color_bit = true };
        };
        var barrier = vk.ImageMemoryBarrier{
            .src_access_mask = .{}, // TODO
            .dst_access_mask = .{},
            .old_layout = old_layout,
            .new_layout = new_layout,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresource_range = .{
                // default to color bit, can be overwritten by some layout changes
                .aspect_mask = aspect_mask,
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };

        const source_access_mask = blk: {
            switch (old_layout) {
                .undefined => {
                    barrier.src_access_mask = .{};
                    break :blk vk.PipelineStageFlags{ .top_of_pipe_bit = true };
                },
                .transfer_dst_optimal => {
                    barrier.src_access_mask = .{ .transfer_write_bit = true };
                    break :blk vk.PipelineStageFlags{ .transfer_bit = true };
                },
                else => std.debug.panic("\nunimplemented image old layout {any}\n", .{old_layout}),
            }
        };
        const destination_access_mask = blk: {
            switch (new_layout) {
                .transfer_dst_optimal => {
                    barrier.dst_access_mask = .{ .transfer_write_bit = true };
                    break :blk vk.PipelineStageFlags{ .transfer_bit = true };
                },
                .shader_read_only_optimal => {
                    barrier.dst_access_mask = .{ .shader_read_bit = true };
                    break :blk vk.PipelineStageFlags{ .fragment_shader_bit = true };
                },
                .depth_stencil_attachment_optimal => {
                    barrier.dst_access_mask = .{
                        .depth_stencil_attachment_read_bit = true,
                        .depth_stencil_attachment_write_bit = true,
                    };
                    break :blk vk.PipelineStageFlags{ .early_fragment_tests_bit = true };
                },
                else => std.debug.panic("\nunimplemented image new layout {any}\n", .{new_layout}),
            }
        };

        vkd.cmdPipelineBarrier(
            command_buffer,
            source_access_mask,
            destination_access_mask,
            .{},
            0,
            undefined,
            0,
            undefined,
            1,
            @as([*]const vk.ImageMemoryBarrier, @ptrCast(&barrier)),
        );
    }

    inline fn hasStencilComponent(format: vk.Format) bool {
        return format == .d32_sfloat_s8_uint or format == .d24_unorm_s8_uint;
    }
};
