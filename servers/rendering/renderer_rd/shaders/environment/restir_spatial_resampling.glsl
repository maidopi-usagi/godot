#[compute]

#version 450

#VERSION_DEFINES

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Structures
struct Reservoir {
	float w_sum;
	float W;
	uint M;
	uint pad;
	vec4 sample_radiance;
	vec4 sample_dir_dist;
};

// Uniforms
layout(set = 0, binding = 0) uniform sampler2D u_gbuffer_normal_depth;

// Reservoirs
layout(set = 0, binding = 1, std430) restrict readonly buffer InputReservoirs {
	Reservoir data[];
} input_reservoirs;

layout(set = 0, binding = 2, std430) restrict writeonly buffer OutputReservoirs {
	Reservoir data[];
} output_reservoirs;

// Params
layout(set = 0, binding = 3, std140) uniform SpatialParams {
	ivec2 screen_size;
	uint frame_index;
	uint neighbor_count;
	float spatial_radius;
	float depth_threshold;
	float normal_threshold;
	float padding;
} params;

// Helper functions
float luminance(vec3 color) {
	return dot(color, vec3(0.2126, 0.7152, 0.0722));
}

uint pcg_hash(uint seed) {
	uint state = seed * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return (word >> 22u) ^ word;
}

float random(inout uint seed) {
	seed = pcg_hash(seed);
	return float(seed) / 4294967296.0;
}

void update_reservoir(inout Reservoir r, vec4 s_radiance, vec4 s_dir_dist, float w, inout uint seed) {
	r.w_sum += w;
	r.M += 1;
	
	float random_val = random(seed);
	if (random_val * r.w_sum < w) {
		r.sample_radiance = s_radiance;
		r.sample_dir_dist = s_dir_dist;
	}
}

void merge_reservoir(inout Reservoir r, Reservoir other, float p_hat, inout uint seed) {
	float M0 = float(r.M);
	float M1 = float(other.M);
	float w = p_hat * other.W * M1;
	
	update_reservoir(r, other.sample_radiance, other.sample_dir_dist, w, seed);
	r.M = uint(M0 + M1);
}

vec3 decode_octahedral_normal(vec2 e) {
	vec3 v = vec3(e.xy, 1.0 - abs(e.x) - abs(e.y));
	if (v.z < 0.0) {
		v.xy = (1.0 - abs(v.yx)) * sign(v.xy);
	}
	return normalize(v);
}

void main() {
	ivec2 pixel_pos = ivec2(gl_GlobalInvocationID.xy);
	if (pixel_pos.x >= params.screen_size.x || pixel_pos.y >= params.screen_size.y) {
		return;
	}
	
	uint pixel_index = pixel_pos.y * params.screen_size.x + pixel_pos.x;
	uint seed = pixel_index * params.frame_index + 19349663u;

	// Read center reservoir
	Reservoir r = input_reservoirs.data[pixel_index];
	
	// Read center GBuffer
	vec4 center_nd = texelFetch(u_gbuffer_normal_depth, pixel_pos, 0);
	vec3 center_normal = center_nd.xyz; // GBuffer prepass stores decoded normal in XYZ
	float center_depth = center_nd.w;
	
	// Initial reservoir is the temporal output (input_reservoirs)
	// We copy it to a local reservoir
	Reservoir state = r;
	
	// Spatial reuse loop
	for (uint i = 0; i < params.neighbor_count; i++) {
		// Random neighbor
		float angle = random(seed) * 6.28318530718;
		float radius = sqrt(random(seed)) * params.spatial_radius;
		vec2 offset = vec2(cos(angle), sin(angle)) * radius;
		
		ivec2 neighbor_pos = pixel_pos + ivec2(offset);
		
		// Clamp to screen
		neighbor_pos = clamp(neighbor_pos, ivec2(0), params.screen_size - ivec2(1));
		
		if (neighbor_pos == pixel_pos) {
			continue;
		}
		
		uint neighbor_index = neighbor_pos.y * params.screen_size.x + neighbor_pos.x;
		
		// Geometric similarity check
		vec4 neighbor_nd = texelFetch(u_gbuffer_normal_depth, neighbor_pos, 0);
		vec3 neighbor_normal = neighbor_nd.xyz;
		float neighbor_depth = neighbor_nd.w;
		
		// Check normal
		if (dot(center_normal, neighbor_normal) < params.normal_threshold) {
			continue;
		}
		
		// Check depth (relative difference)
		if (abs(center_depth - neighbor_depth) / (center_depth + 1e-6) > params.depth_threshold) {
			continue;
		}
		
		// Merge
		Reservoir neighbor_r = input_reservoirs.data[neighbor_index];
		float neighbor_p_hat = luminance(neighbor_r.sample_radiance.rgb);
		
		merge_reservoir(state, neighbor_r, neighbor_p_hat, seed);
	}
	
	// Finalize
	float target_p = luminance(state.sample_radiance.rgb);
	if (target_p > 0.0) {
		state.W = state.w_sum / (float(state.M) * target_p);
	} else {
		state.W = 0.0;
	}
	
	output_reservoirs.data[pixel_index] = state;
}
