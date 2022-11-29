#version 450

layout(binding = 0) uniform UniformBufferObject {
    mat4 transform;
} ubo;

//push constants block
layout(push_constant) uniform push_constants
{
	mat4 projection_view;
} camera;

layout(location = 0) in vec2 inPosition;
layout(location = 1) in vec3 inColor;

layout(location = 0) out vec3 fragColor;

void main() {
    gl_Position = camera.projection_view * ubo.transform * vec4(inPosition, 0.0, 1.0);
    fragColor = inColor;
}
