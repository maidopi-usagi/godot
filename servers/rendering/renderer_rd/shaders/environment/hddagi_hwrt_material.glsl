#[compute]

#version 450

#VERSION_DEFINES

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D source_albedo;
layout(set = 0, binding = 1) uniform sampler2D source_orm;
layout(set = 0, binding = 2) uniform sampler2D source_emission;
layout(set = 0, binding = 3, std430) restrict writeonly buffer MaterialSamples {
	uvec2 data[];
}
material_samples;

layout(push_constant, std430) uniform Params {
	uvec2 size;
	uint triangle_count;
	uint sample_offset;
}
params;

// Same RGB9E5 conversion as Color::to_rgbe9995() and the existing GI shaders.
uint rgbe_encode(vec3 rgb) {
	rgb = clamp(rgb, 0.0, 65408.0);
	float max_channel = max(max(rgb.r, rgb.g), max(rgb.b, uintBitsToFloat(0x37800000u)));
	uint bias_bits = (floatBitsToUint(max_channel) + 0x07804000u) & 0x7F800000u;
	uvec3 channels = floatBitsToUint(rgb + uintBitsToFloat(bias_bits));
	uint exponent = (bias_bits << 4u) + 0x10000000u;
	return exponent | (channels.b << 18u) | (channels.g << 9u) | (channels.r & 0x1FFu);
}

void main() {
	uvec2 pixel = gl_GlobalInvocationID.xy;
	if (any(greaterThanEqual(pixel, params.size))) {
		return;
	}
	uint triangle = pixel.x / 4u + (pixel.y / 4u) * 128u;
	if (triangle >= params.triangle_count) {
		return;
	}
	vec3 albedo = texelFetch(source_albedo, ivec2(pixel), 0).rgb;
	float metallic = texelFetch(source_orm, ivec2(pixel), 0).b;
	vec3 emission = texelFetch(source_emission, ivec2(pixel), 0).rgb;
	uint sample_index = triangle * 16u + (pixel.y % 4u) * 4u + pixel.x % 4u;
	material_samples.data[params.sample_offset + sample_index] = uvec2(packUnorm4x8(vec4(albedo, metallic)), rgbe_encode(emission));
}
