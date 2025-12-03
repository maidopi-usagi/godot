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
layout(set = 0, binding = 8) uniform sampler3D aniso0_cascades[MAX_CASCADES];
layout(set = 0, binding = 9) uniform sampler3D aniso1_cascades[MAX_CASCADES];

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
	mat4 projection_matrix;
	mat4 inv_projection_matrix;
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
	return cell_pos * INV_SIZE;
}

vec3 decode_octahedral_normal(vec2 e) {
	vec3 v = vec3(e.xy, 1.0 - abs(e.x) - abs(e.y));
	if (v.z < 0.0) {
		v.xy = (1.0 - abs(v.yx)) * sign(v.xy);
	}
	return normalize(v);
}

// Reconstruct world position from depth
vec3 reconstruct_world_pos(vec2 uv, float depth) {
	vec4 ndc = vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec4 view_pos = params.inv_projection_matrix * ndc;
	view_pos /= view_pos.w;
	vec4 world_pos = params.inv_view_matrix * view_pos;
	return world_pos.xyz;
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
			float dist_cells = raw_val * 255.0 - 1.7;
			
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
	vec3 light = texture(light_cascades[cascade_idx], uvw).rgb;
	
	// Apply Anisotropic Spherical Gaussians (ASG)
	vec4 aniso0 = texture(aniso0_cascades[cascade_idx], uvw);
	vec3 hit_aniso0 = aniso0.rgb;
	vec3 hit_aniso1 = vec3(aniso0.a, texture(aniso1_cascades[cascade_idx], uvw).rg);

	// Modulate light by normal and anisotropy
	// This matches Godot's sdfgi_debug.glsl logic
	light *= (dot(max(vec3(0.0), (normal * hit_aniso0)), vec3(1.0)) + dot(max(vec3(0.0), (-normal * hit_aniso1)), vec3(1.0)));

	float occlusion = texture(occlusion_texture, uvw).r;
	
	// Apply sky energy if occlusion allows
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

vec3 calculate_sdf_normal(vec3 world_pos, uint cascade_idx) {
	vec3 uvw = world_to_cascade_uvw(world_pos, cascade_idx);
	const float EPSILON = 0.001;
	
	float dx = texture(sdf_cascades[cascade_idx], uvw + vec3(EPSILON, 0.0, 0.0)).r - texture(sdf_cascades[cascade_idx], uvw - vec3(EPSILON, 0.0, 0.0)).r;
	float dy = texture(sdf_cascades[cascade_idx], uvw + vec3(0.0, EPSILON, 0.0)).r - texture(sdf_cascades[cascade_idx], uvw - vec3(0.0, EPSILON, 0.0)).r;
	float dz = texture(sdf_cascades[cascade_idx], uvw + vec3(0.0, 0.0, EPSILON)).r - texture(sdf_cascades[cascade_idx], uvw - vec3(0.0, 0.0, EPSILON)).r;
	
	return normalize(vec3(dx, dy, dz));
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
	
	vec3 ray_origin_ws = reconstruct_world_pos(uv, depth);
	
	// Apply normal bias
	// GBuffer stores View Space normals in XYZ (decoded in prepass)
	vec3 normal_ws = normalize(mat3(params.inv_view_matrix) * gbuffer_data.xyz); 
		
	// Bias should be proportional to cell size to escape the voxel
	// params.normal_bias is usually ~1.1 (ratio)
	// We use the finest cascade (0) cell size for bias
	float cell_size = 1.0 / params.cascades[0].to_cell;
	// ray_origin_ws += normal_ws * (cell_size * params.normal_bias);
	
	float hit_t;
	uint hit_cascade;
	
	if (trace_sdf(ray_origin_ws, ray_dir_ws, ray_length, hit_t, hit_cascade)) {
		vec3 hit_pos = ray_origin_ws + ray_dir_ws * hit_t;
		vec3 hit_normal = calculate_sdf_normal(hit_pos, hit_cascade);
		vec3 radiance = sample_lighting(hit_pos, hit_cascade, hit_normal);
		
		imageStore(hit_radiance, probe_pos, vec4(radiance, 1.0));
		imageStore(hit_distance, probe_pos, vec4(hit_t));
	} else {
		// Sky miss
		// Simple procedural sky gradient for debugging
		float t = 0.5 * (ray_dir_ws.y + 1.0);
		vec3 sky_gradient = mix(vec3(0.0, 0.0, 0.0), vec3(0.2, 0.4, 0.8), t); // White horizon to Blue zenith
		vec3 sky_color = sky_gradient; 
		
		imageStore(hit_radiance, probe_pos, vec4(sky_color, 1.0));
		imageStore(hit_distance, probe_pos, vec4(ray_length)); // Store max dist
	}
}
