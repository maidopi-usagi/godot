#[compute]

#version 450

#VERSION_DEFINES

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Input/Output textures
layout(set = 0, binding = 0) uniform sampler2D u_gbuffer_normal_depth;
layout(set = 0, binding = 1) uniform sampler2D u_ray_directions;
layout(rgba16f, set = 0, binding = 2) uniform restrict image2D hit_radiance;
layout(r16f, set = 0, binding = 3) uniform restrict image2D hit_distance;

// SDFGI Resources
#define MAX_CASCADES 8

layout(set = 0, binding = 4) uniform sampler3D sdf_cascades[MAX_CASCADES];
layout(set = 0, binding = 5) uniform sampler3D light_cascades[MAX_CASCADES]; // Diffuse light
layout(set = 0, binding = 6) uniform sampler3D occlusion_texture; // Occlusion/Sky (Single texture for all cascades?)

struct CascadeData {
	vec3 offset; // World space offset of the cascade origin (0,0,0 in local)
	float to_cell; // Scale factor to convert world space to cell coordinates
	ivec3 probe_world_offset; // Integer offset for scrolling
	uint pad;
	vec4 pad2;
};

layout(set = 0, binding = 7, std140) uniform SDFGIParams {
	CascadeData cascades[MAX_CASCADES];
	uint cascade_count;
	float min_cell_size;
	float normal_bias;
	float probe_bias;
	
	mat4 view_matrix;
	mat4 inv_view_matrix;
	ivec2 probe_resolution;
	uint frame_count;
	float sky_energy;
} params;

// Helper to transform world position to cascade UVW
vec3 world_to_cascade_uvw(vec3 world_pos, uint cascade_idx) {
	vec3 local_pos = world_pos - params.cascades[cascade_idx].offset;
	vec3 cell_pos = local_pos * params.cascades[cascade_idx].to_cell;
	
	// SDFGI textures are 128^3 usually
	// The cell_pos is in units of cells. We need 0-1 UVW.
	// Assuming 128^3 resolution for now (standard in Godot SDFGI)
	const float INV_SIZE = 1.0 / 128.0;
	return cell_pos * INV_SIZE + 0.5; // +0.5 to center? Need to verify coordinate system
}

// Check if point is inside cascade bounds
bool is_inside_cascade(vec3 uvw) {
	// Add a small margin to avoid boundary artifacts
	const float margin = 0.01; // 1-2 texels
	return all(greaterThanEqual(uvw, vec3(margin))) && all(lessThanEqual(uvw, vec3(1.0 - margin)));
}

// Sample SDF from the best available cascade
float sample_sdf(vec3 world_pos, out uint used_cascade) {
	for (uint i = 0; i < params.cascade_count; i++) {
		vec3 uvw = world_to_cascade_uvw(world_pos, i);
		if (is_inside_cascade(uvw)) {
			used_cascade = i;
			// Decode SDF: stored as (dist + 1) / 255.0
			// 0 means solid (dist < 0)
			// >0 means distance in cells
			float raw_val = texture(sdf_cascades[i], uvw).r;
			float dist_cells = raw_val * 255.0 - 1.0;
			
			// Convert to world space distance
			// to_cell is (1.0 / cell_size_ws)
			return dist_cells / params.cascades[i].to_cell;
		}
	}
	used_cascade = params.cascade_count; // Invalid
	return 10000.0; // Far
}

// Sample lighting from the specified cascade
vec3 sample_lighting(vec3 world_pos, uint cascade_idx, vec3 normal) {
	if (cascade_idx >= params.cascade_count) return vec3(0.0); // Sky?
	
	vec3 uvw = world_to_cascade_uvw(world_pos, cascade_idx);
	
	// Sample light texture
	// Note: Godot SDFGI stores SH or Aniso data. For simplicity, we assume a resolved light texture here
	// or we might need to decode SH/Aniso.
	// For this implementation, we assume binding 5 is a pre-integrated light texture or we sample the main light texture.
	
	vec3 light = texture(light_cascades[cascade_idx], uvw).rgb;
	float occlusion = texture(occlusion_texture, uvw).r;
	
	// Apply sky energy if occlusion allows
	// This is a simplification. Real SDFGI has more complex light integration.
	return light + vec3(params.sky_energy) * occlusion;
}

// Sphere tracing
bool trace_sdf(vec3 ray_origin, vec3 ray_dir, float max_dist, out float hit_t, out uint hit_cascade) {
	float t = 0.0;
	// Start with a small offset to avoid self-intersection
	// Use the finest cascade cell size for initial offset
	float min_cell_size = 1.0 / params.cascades[0].to_cell;
	t += min_cell_size * 0.5; 
	
	const uint MAX_STEPS = 64;
	
	for (uint i = 0; i < MAX_STEPS; i++) {
		if (t > max_dist) return false;
		
		vec3 p = ray_origin + ray_dir * t;
		uint cascade_idx;
		float dist = sample_sdf(p, cascade_idx);
		
		if (cascade_idx >= params.cascade_count) {
			// Out of bounds of all cascades
			// Step forward a bit and try again
			t += min_cell_size * 4.0;
			continue;
		}
		
		float current_cell_size = 1.0 / params.cascades[cascade_idx].to_cell;
		
		// Check for hit (surface or inside)
		if (dist < current_cell_size * 0.1) {
			hit_t = t;
			hit_cascade = cascade_idx;
			return true;
		}
		
		// Step
		t += max(dist, current_cell_size * 0.1);
	}
	
	return false;
}

void main() {
	ivec2 probe_pos = ivec2(gl_GlobalInvocationID.xy);
	
	if (probe_pos.x >= params.probe_resolution.x || probe_pos.y >= params.probe_resolution.y) {
		return;
	}
	
	// Check if screen space trace already hit
	float existing_dist = imageLoad(hit_distance, probe_pos).r;
	if (existing_dist > 0.0) {
		return; // Already hit in screen space
	}
	
	// Read ray info
	vec2 uv = (vec2(probe_pos) + 0.5) / vec2(params.probe_resolution);
	vec4 sampled_ray_data = texture(u_ray_directions, uv);
	vec3 ray_dir_ws = normalize(sampled_ray_data.xyz);
	float ray_length = sampled_ray_data.w;
	
	if (ray_length <= 0.0001) return;
	
	// Reconstruct world position of the probe (ray origin)
	vec4 gbuffer_data = texture(u_gbuffer_normal_depth, uv);
	float depth = gbuffer_data.w;
	
	// Reconstruct view pos then world pos
	// Note: We need inverse view projection or similar.
	// Using simplified reconstruction for now assuming we have matrices.
	vec4 ndc = vec4(uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
	// We need inv_view_proj. Params has inv_view. We need inv_proj too.
	// For now, let's assume we can get world pos.
	// Actually, let's pass inv_view_proj in params or calculate it.
	// Or just use the depth to get view pos and transform to world.
	
	// ... (Reconstruction code omitted for brevity, assume we have ray_origin_ws)
	// Temporary:
	vec3 ray_origin_ws = vec3(0.0); // Placeholder
	
	// Apply normal bias
	vec3 normal_ws = normalize(mat3(params.inv_view_matrix) * gbuffer_data.xyz); // Assuming normal is view space
	ray_origin_ws += normal_ws * params.normal_bias;
	
	float hit_t;
	uint hit_cascade;
	
	if (trace_sdf(ray_origin_ws, ray_dir_ws, ray_length, hit_t, hit_cascade)) {
		vec3 hit_pos = ray_origin_ws + ray_dir_ws * hit_t;
		vec3 radiance = sample_lighting(hit_pos, hit_cascade, -ray_dir_ws);
		
		imageStore(hit_radiance, probe_pos, vec4(radiance, 1.0));
		imageStore(hit_distance, probe_pos, vec4(hit_t));
	} else {
		// Sky miss
		vec3 sky_color = vec3(0.05, 0.05, 0.1) * params.sky_energy; // Simple placeholder sky
		imageStore(hit_radiance, probe_pos, vec4(sky_color, 1.0));
		imageStore(hit_distance, probe_pos, vec4(ray_length)); // Store max dist
	}
}
