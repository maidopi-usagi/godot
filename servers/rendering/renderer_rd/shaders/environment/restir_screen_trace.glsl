#[compute]

#version 450

#VERSION_DEFINES

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Input textures
layout(set = 0, binding = 0) uniform sampler2D u_gbuffer_normal_depth;
layout(set = 0, binding = 1) uniform sampler2D u_ray_directions;
layout(set = 0, binding = 2) uniform sampler2D u_depth_pyramid; // Hierarchical depth buffer
layout(set = 0, binding = 3) uniform sampler2D u_screen_color;  // Scene color for hit lighting

// Output
layout(rgba16f, set = 0, binding = 4) uniform restrict writeonly image2D hit_radiance;
layout(r16f, set = 0, binding = 5) uniform restrict writeonly image2D hit_distance;

// Uniforms
layout(set = 0, binding = 6, std140) uniform ScreenSpaceParams {
	mat4 projection_matrix;
	mat4 inv_projection_matrix;
	mat4 view_matrix;
	vec2 screen_size;
	vec2 inv_screen_size;
	ivec2 probe_resolution;
	float max_ray_distance;
	uint max_steps;
	float thickness;
	float stride;
	float jitter_amount;
	uint frame_count;
	vec2 padding;
} params;

// PCG random
uint pcg_hash(uint seed) {
	uint state = seed * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return (word >> 22u) ^ word;
}

float random(inout uint seed) {
	seed = pcg_hash(seed);
	return float(seed) / 4294967296.0;
}

// Reconstruct view space position from depth
vec3 reconstruct_view_pos(vec2 uv, float depth) {
	vec4 ndc = vec4(uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
	vec4 view_pos = params.inv_projection_matrix * ndc;
	return view_pos.xyz / view_pos.w;
}

// Project view space position to screen space
vec3 project_to_screen(vec3 view_pos) {
	vec4 clip_pos = params.projection_matrix * vec4(view_pos, 1.0);
	vec3 ndc = clip_pos.xyz / clip_pos.w;
	return vec3(ndc.xy * 0.5 + 0.5, ndc.z);
}

// Sample depth pyramid at specific mip level
float sample_depth_pyramid(vec2 uv, float mip_level) {
	return textureLod(u_depth_pyramid, uv, mip_level).r;
}

// Hierarchical ray marching
bool trace_screen_space_ray(
	vec3 ray_origin_vs,
	vec3 ray_dir_vs,
	out vec2 hit_uv,
	out float hit_depth,
	inout uint rng_seed
) {
	// Project ray start to screen space
	vec3 ray_start_ss = project_to_screen(ray_origin_vs);
	
	// Advance ray by small epsilon to avoid self-intersection
	vec3 ray_end_vs = ray_origin_vs + ray_dir_vs * params.max_ray_distance;
	vec3 ray_end_ss = project_to_screen(ray_end_vs);
	
	// Check if ray goes off screen
	if (any(lessThan(ray_end_ss.xy, vec2(0.0))) || any(greaterThan(ray_end_ss.xy, vec2(1.0)))) {
		// Clip to screen bounds
		vec2 t_min = (vec2(0.0) - ray_start_ss.xy) / (ray_end_ss.xy - ray_start_ss.xy);
		vec2 t_max = (vec2(1.0) - ray_start_ss.xy) / (ray_end_ss.xy - ray_start_ss.xy);
		
		float t = max(max(t_min.x, t_min.y), 0.0);
		t = min(t, min(t_max.x, t_max.y));
		
		if (t >= 1.0) {
			return false; // Ray entirely off screen
		}
		
		ray_end_ss = mix(ray_start_ss, ray_end_ss, t);
	}
	
	// Calculate ray step in screen space
	vec3 ray_delta = ray_end_ss - ray_start_ss;
	float ray_length_ss = length(ray_delta.xy * params.screen_size);
	
	// Jitter start position for better temporal distribution
	float jitter = random(rng_seed) * params.jitter_amount;
	
	// Adaptive step count based on ray length
	uint step_count = min(params.max_steps, uint(ray_length_ss));
	step_count = max(step_count, 1u);
	
	vec3 ray_step = ray_delta / float(step_count);
	vec3 current_pos = ray_start_ss + ray_step * jitter;
	
	// Hierarchical ray marching with linear search refinement
	for (uint i = 0u; i < step_count; i++) {
		// Sample depth at current position
		float sampled_depth = sample_depth_pyramid(current_pos.xy, 0.0);
		
		// Check if ray is behind surface
		float depth_diff = current_pos.z - sampled_depth;
		
		if (depth_diff > 0.0 && depth_diff < params.thickness) {
			// Hit! Refine with binary search
			vec3 search_start = current_pos - ray_step;
			vec3 search_end = current_pos;
			
			// 4 iterations of binary search
			for (int j = 0; j < 4; j++) {
				vec3 search_mid = (search_start + search_end) * 0.5;
				float mid_depth = sample_depth_pyramid(search_mid.xy, 0.0);
				
				if (search_mid.z > mid_depth) {
					search_end = search_mid;
				} else {
					search_start = search_mid;
				}
			}
			
			hit_uv = search_end.xy;
			hit_depth = search_end.z;
			return true;
		}
		
		current_pos += ray_step;
		
		// Early out if ray goes off screen
		if (any(lessThan(current_pos.xy, vec2(0.0))) || any(greaterThan(current_pos.xy, vec2(1.0)))) {
			return false;
		}
	}
	
	return false;
}

void main() {
	ivec2 probe_pos = ivec2(gl_GlobalInvocationID.xy);
	
	if (probe_pos.x >= params.probe_resolution.x || probe_pos.y >= params.probe_resolution.y) {
		return;
	}
	
	vec2 uv = (vec2(probe_pos) + 0.5) / vec2(params.probe_resolution);
	
	// Read probe data
	vec4 gbuffer_data = texture(u_gbuffer_normal_depth, uv);
	vec3 normal_vs = mat3(params.view_matrix) * normalize(gbuffer_data.xyz);
	float depth = gbuffer_data.w;
	
	// Read ray direction
	vec4 sampled_ray_data = texture(u_ray_directions, uv);
	vec3 ray_dir_ws = normalize(sampled_ray_data.xyz);
	float ray_length = sampled_ray_data.w;
	
	// Check if valid ray
	if (depth <= 0.0001 || ray_length <= 0.0001) {
		imageStore(hit_radiance, probe_pos, vec4(0.0));
		imageStore(hit_distance, probe_pos, vec4(-1.0));
		return;
	}
	
	// Transform ray to view space
	vec3 ray_dir_vs = mat3(params.view_matrix) * ray_dir_ws;
	
	// Reconstruct ray origin in view space
	vec3 ray_origin_vs = reconstruct_view_pos(uv, depth);
	
	// Initialize RNG
	uint rng_seed = probe_pos.x + probe_pos.y * params.probe_resolution.x;
	rng_seed += params.frame_count * 1973272911u;
	
	// Trace ray in screen space
	vec2 hit_uv;
	float hit_depth_value;
	
	bool hit = trace_screen_space_ray(
		ray_origin_vs,
		ray_dir_vs,
		hit_uv,
		hit_depth_value,
		rng_seed
	);
	
	if (hit) {
		// Sample scene color at hit position
		vec3 radiance = texture(u_screen_color, hit_uv).rgb;
		
		// Calculate hit distance
		vec3 hit_pos_vs = reconstruct_view_pos(hit_uv, hit_depth_value);
		float distance = length(hit_pos_vs - ray_origin_vs);
		
		imageStore(hit_radiance, probe_pos, vec4(radiance, 1.0));
		imageStore(hit_distance, probe_pos, vec4(distance));
	} else {
		// No hit - mark for world space tracing
		imageStore(hit_radiance, probe_pos, vec4(0.0));
		imageStore(hit_distance, probe_pos, vec4(-1.0));
	}
}
