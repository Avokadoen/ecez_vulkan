#version 450

layout(binding = 0) uniform UniformBufferObject {
    mat4 transform;
} ubo;

//push constants block
layout(push_constant) uniform push_constants
{
	mat4 projection_view;
} camera;

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec2 inTexCoord;

layout(location = 0) out vec2 fragTexCoord;

void main() {
    gl_Position = camera.projection_view * ubo.transform * vec4(inPosition, 1.0);
    fragTexCoord = inTexCoord;
}
