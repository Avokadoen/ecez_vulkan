const vk = @import("vulkan");

pub const required_extensions = [_][:0]const u8{
    vk.extension_info.khr_swapchain.name,
    vk.extension_info.khr_synchronization_2.name,
};

pub const required_extensions_cstr = [_][*:0]const u8{
    vk.extension_info.khr_swapchain.name,
    vk.extension_info.khr_synchronization_2.name,
};

pub const desired_layers = [_][*:0]const u8{
    "VK_LAYER_KHRONOS_validation",
};
