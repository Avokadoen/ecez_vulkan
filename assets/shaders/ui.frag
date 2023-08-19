#version 450

#extension GL_EXT_nonuniform_qualifier : require

layout (set = 0, binding = 0) uniform sampler2D textureSamplers[];

const uint FONT_INDEX = 0;
const uint ICON_INDEX = 1;

const vec4 ERROR_COLOR = vec4(0.8, 0, 0.8, 1);

layout (push_constant) uniform PushConstants {
	layout (offset = 16) uint samplerIndex;
} pushConstant;

layout (location = 0) in vec2 inUV;
layout (location = 1) in vec4 inColor;

layout (location = 0) out vec4 outColor;

void main() 
{
	const uint samplerIndex = pushConstant.samplerIndex;
	vec4 textureColor;
	if (samplerIndex == FONT_INDEX) {
		textureColor = texture(textureSamplers[nonuniformEXT(pushConstant.samplerIndex)], inUV);
	} else if (samplerIndex == ICON_INDEX) {
		// icon texture should be greyscale
		textureColor = vec4(1, 1, 1, texture(textureSamplers[nonuniformEXT(pushConstant.samplerIndex)], inUV).r);
	} else {
		outColor = ERROR_COLOR;
		return;
	}

	outColor = inColor * textureColor;
}
