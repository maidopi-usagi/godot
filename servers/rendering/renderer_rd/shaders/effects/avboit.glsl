#[compute]

#version 450

#VERSION_DEFINES

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

#ifdef MODE_INTEGRATE
layout(r32ui, set = 0, binding = 0) uniform restrict readonly uimage2DArray extinction_buffer;
layout(r16f, set = 0, binding = 1) uniform restrict writeonly image2DArray integral_buffer;
#endif

#ifdef MODE_RESOLVE
layout(set = 0, binding = 0) uniform sampler2D splat_buffer;
layout(rgba16f, set = 0, binding = 1) uniform restrict image2D color_buffer;
layout(set = 0, binding = 2) uniform sampler2DArray integral_buffer;
#endif

layout(push_constant, std430) uniform Params {
	uvec2 size;
	uvec2 full_size;
	uint slice_count;
	uint pad[3];
}
params;

void main() {
	uvec2 pos = gl_GlobalInvocationID.xy;

#ifdef MODE_INTEGRATE
	if (any(greaterThanEqual(pos, params.size))) {
		return;
	}

	float extinction_sum = 0.0;
	for (uint slice = 0; slice < params.slice_count; slice++) {
		uint packed_extinction = imageLoad(extinction_buffer, ivec3(pos, slice)).r;
		extinction_sum += float(packed_extinction) / 255.0;
		imageStore(integral_buffer, ivec3(pos, slice), vec4(extinction_sum, 0.0, 0.0, 0.0));
	}
#endif

#ifdef MODE_RESOLVE
	if (any(greaterThanEqual(pos, params.full_size))) {
		return;
	}

	vec2 uv = (vec2(pos) + vec2(0.5)) / vec2(params.full_size);
	vec4 splat = textureLod(splat_buffer, uv, 0.0);
	float integral = textureLod(integral_buffer, vec3(uv, float(params.slice_count - 1u)), 0.0).r;
	float transmittance = exp(-integral);
	float accumulated_alpha = max(splat.a, 0.0001);
	float coverage = clamp(max(clamp(splat.a, 0.0, 1.0), 1.0 - transmittance), 0.0, 1.0);
	vec3 transparent_color = splat.rgb / accumulated_alpha;

	ivec2 color_pos = ivec2(pos);
	vec4 color = imageLoad(color_buffer, color_pos);
	color.rgb = mix(color.rgb, transparent_color, coverage);
	imageStore(color_buffer, color_pos, color);
#endif
}
