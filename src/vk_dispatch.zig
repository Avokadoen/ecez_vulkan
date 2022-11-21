const builtin = @import("builtin");
const vk = @import("vulkan");

const is_debug_build = builtin.mode == .Debug;

pub const BaseDispatch = vk.BaseWrapper(.{
    .createInstance = true,
    .enumerateInstanceLayerProperties = true,
});

pub const InstanceDispatch = vk.InstanceWrapper(.{
    .createDebugUtilsMessengerEXT = is_debug_build,
    .createDevice = true,
    .destroyDebugUtilsMessengerEXT = is_debug_build,
    .destroyInstance = true,
    .destroySurfaceKHR = true,
    .enumerateDeviceExtensionProperties = true,
    .enumeratePhysicalDevices = true,
    .getDeviceProcAddr = true,
    .getPhysicalDeviceFeatures = true,
    .getPhysicalDeviceMemoryProperties = true,
    .getPhysicalDeviceProperties = true,
    .getPhysicalDeviceQueueFamilyProperties = true,
    .getPhysicalDeviceSurfaceCapabilitiesKHR = true,
    .getPhysicalDeviceSurfaceFormatsKHR = true,
    .getPhysicalDeviceSurfacePresentModesKHR = true,
    .getPhysicalDeviceSurfaceSupportKHR = true,
});

pub const DeviceDispatch = vk.DeviceWrapper(.{
    .acquireNextImageKHR = true,
    .allocateCommandBuffers = true,
    .allocateMemory = true,
    .beginCommandBuffer = true,
    .bindBufferMemory = true,
    .cmdBeginRenderPass = true,
    .cmdBindPipeline = true,
    .cmdBindVertexBuffers = true,
    .cmdDraw = true,
    .cmdEndRenderPass = true,
    .cmdSetScissor = true,
    .cmdSetViewport = true,
    .createBuffer = true,
    .createCommandPool = true,
    .createFence = true,
    .createFramebuffer = true,
    .createGraphicsPipelines = true,
    .createImageView = true,
    .createPipelineLayout = true,
    .createRenderPass = true,
    .createSemaphore = true,
    .createShaderModule = true,
    .createSwapchainKHR = true,
    .destroyBuffer = true,
    .destroyCommandPool = true,
    .destroyDevice = true,
    .destroyFence = true,
    .destroyFramebuffer = true,
    .destroyImageView = true,
    .destroyPipeline = true,
    .destroyPipelineLayout = true,
    .destroyRenderPass = true,
    .destroySemaphore = true,
    .destroyShaderModule = true,
    .destroySwapchainKHR = true,
    .deviceWaitIdle = true,
    .endCommandBuffer = true,
    .flushMappedMemoryRanges = true,
    .freeMemory = true,
    .getBufferMemoryRequirements = true,
    .getDeviceQueue = true,
    .getSwapchainImagesKHR = true,
    .mapMemory = true,
    .queuePresentKHR = true,
    .queueSubmit = true,
    .resetCommandPool = true,
    .resetFences = true,
    .unmapMemory = true,
    .waitForFences = true,
});