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
	vec4 sample_dir_dist; // xyz: direction, w: distance
};

// Uniforms
layout(set = 0, binding = 0) uniform sampler2D u_gbuffer_normal_depth;
layout(set = 0, binding = 1) uniform sampler2D u_gbuffer_motion;
layout(set = 0, binding = 2) uniform sampler2D u_trace_radiance;
layout(set = 0, binding = 3) uniform sampler2D u_trace_ray_direction; // xyz: dir, w: distance (from ray gen or trace?)
// Wait, ray_gen outputs ray_directions (RGBA16F). Trace outputs hit_distance (R16F) and hit_radiance (RGBA16F).
layout(set = 0, binding = 4) uniform sampler2D u_trace_hit_distance;

// Reservoirs
layout(set = 0, binding = 5, std430) restrict readonly buffer PrevReservoirs {
	Reservoir data[];
} prev_reservoirs;

layout(set = 0, binding = 6, std430) restrict writeonly buffer CurrentReservoirs {
	Reservoir data[];
} current_reservoirs;

// Params
layout(set = 0, binding = 7, std140) uniform TemporalParams {
	ivec2 screen_size;
	uint frame_index;
	uint max_history_length;
	float temporal_depth_rejection;
	float temporal_normal_rejection;
	vec2 padding;
} params;

// Helper functions
float luminance(vec3 color) {
	return dot(color, vec3(0.2126, 0.7152, 0.0722));
}

// Update reservoir with a new sample
void update_reservoir(inout Reservoir r, vec4 s_radiance, vec4 s_dir_dist, float w, inout uint seed) {
	r.w_sum += w;
	r.M += 1;
	
	// RIS selection
	float random_val = float(seed) / 4294967296.0;
	seed = seed * 747796405u + 2891336453u; // Simple PCG step
	
	if (random_val * r.w_sum < w) {
		r.sample_radiance = s_radiance;
		r.sample_dir_dist = s_dir_dist;
	}
}

// Merge another reservoir
void merge_reservoir(inout Reservoir r, Reservoir other, float p_hat, inout uint seed) {
	float M0 = float(r.M);
	float M1 = float(other.M);
	float w = p_hat * other.W * M1;
	
	update_reservoir(r, other.sample_radiance, other.sample_dir_dist, w, seed);
	r.M = uint(M0 + M1);
}

void main() {
	ivec2 pixel_pos = ivec2(gl_GlobalInvocationID.xy);
	if (pixel_pos.x >= params.screen_size.x || pixel_pos.y >= params.screen_size.y) {
		return;
	}
	
	uint pixel_index = pixel_pos.y * params.screen_size.x + pixel_pos.x;
	uint seed = pixel_index * params.frame_index + 719393u; // Init seed

	// 1. Create Initial Reservoir from current frame trace
	vec4 trace_radiance = texelFetch(u_trace_radiance, pixel_pos, 0);
	vec4 ray_dir_raw = texelFetch(u_trace_ray_direction, pixel_pos, 0);
	float hit_dist = texelFetch(u_trace_hit_distance, pixel_pos, 0).r;
	
	vec4 sample_dir_dist = vec4(ray_dir_raw.xyz, hit_dist);
	
	// Target PDF (p_hat) is usually luminance of the sample
	float p_hat = luminance(trace_radiance.rgb);
	
	Reservoir r;
	r.w_sum = 0.0;
	r.W = 0.0;
	r.M = 0;
	r.pad = 0;
	r.sample_radiance = vec4(0.0);
	r.sample_dir_dist = vec4(0.0);
	
	// 1. Initial Candidate from current frame trace
	update_reservoir(r, trace_radiance, sample_dir_dist, p_hat, seed);
	
	// 2. Temporal Resampling
	// Reproject to previous frame
	vec2 motion = texture(u_gbuffer_motion, vec2(pixel_pos) / vec2(params.screen_size)).xy;
	vec2 prev_uv = (vec2(pixel_pos) + 0.5) / vec2(params.screen_size) - motion;
	ivec2 prev_pos = ivec2(prev_uv * vec2(params.screen_size));
	
	if (prev_pos.x >= 0 && prev_pos.y >= 0 && prev_pos.x < params.screen_size.x && prev_pos.y < params.screen_size.y) {
		uint prev_index = prev_pos.y * params.screen_size.x + prev_pos.x;
		Reservoir prev_r = prev_reservoirs.data[prev_index];
		
		// TODO: Geometric similarity check (Depth & Normal)
		// We need previous frame's GBuffer to do this robustly.
		// For now, we skip it or use a very loose check if possible.
		// Since we don't have prev_gbuffer, we assume it's valid if M > 0.
		
		if (prev_r.M > 0) {
			// Clamp M to max history length
			if (prev_r.M > params.max_history_length) {
				prev_r.M = params.max_history_length;
			}
			
			// Merge
			// p_hat of the previous sample in the CURRENT context
			// We should evaluate the target function (luminance) of the previous sample's radiance
			// But strictly we should re-evaluate the lighting for the previous sample at the current shading point.
			// For ReSTIR GI, we often just use the stored radiance (approximate).
			float prev_p_hat = luminance(prev_r.sample_radiance.rgb);
			
			merge_reservoir(r, prev_r, prev_p_hat, seed);
		}
	}
	
	// 3. Finalize
	// W = w_sum / (M * p_hat)
	float target_p = luminance(r.sample_radiance.rgb);
	if (target_p > 0.0) {
		r.W = r.w_sum / (float(r.M) * target_p);
	} else {
		r.W = 0.0;
	}
	
	current_reservoirs.data[pixel_index] = r;
}
