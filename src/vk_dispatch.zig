const vk = @import("vulkan");

pub const BaseDispatch = vk.BaseWrapper(.{
    .createInstance = true,
});
