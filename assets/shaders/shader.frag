#version 450

layout(location = 0) in vec3 fragTexCoord;

layout(location = 0) out vec4 outColor;

// TODO: array of normal samplers instead using indexed descriptor sets
layout(binding = 0) uniform sampler2D texSampler;

void main() {
    outColor = texture(texSampler, fragTexCoord.xy);
}
