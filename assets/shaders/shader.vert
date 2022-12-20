#version 450

// Push constants block
layout(push_constant) uniform push_constants
{
	mat4 projection_view;
} camera;

// Vertex attributes
layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec2 inTexCoord;

// Instanced attributes
layout(location = 2) in int instanceTexIndex;
layout(location = 3) in mat4 instanceTransform;

layout(location = 0) out vec2 fragTexCoord;
layout(location = 1) flat out int fragTexIndex;

void main() {
    gl_Position = camera.projection_view * instanceTransform * vec4(inPosition, 1.0);
    fragTexCoord = inTexCoord;
    fragTexIndex = instanceTexIndex;
}
