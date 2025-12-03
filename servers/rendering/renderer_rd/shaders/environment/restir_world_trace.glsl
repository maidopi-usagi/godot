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
	// HACK: Force cascade to be centered on camera to debug offset issues
	// Snap camera position to cell size to avoid swimming artifacts
	float cell_size = 1.0 / params.cascades[cascade_idx].to_cell;
	vec3 camera_pos = params.inv_view_matrix[3].xyz;
	
	// Snap to grid
	vec3 snapped_cam_pos = floor(camera_pos / cell_size) * cell_size;
	vec3 hacked_offset = snapped_cam_pos - vec3(64.0 * cell_size);

	vec3 local_pos = world_pos - hacked_offset; 
	vec3 cell_pos = local_pos * params.cascades[cascade_idx].to_cell;
	
	// SDFGI textures are 128^3 usually
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
	// Match gi.glsl reconstruction logic
	// Remap depth to -1..1 for projection matrix
	float z = depth * 2.0 - 1.0;
	vec4 ndc = vec4(uv * 2.0 - 1.0, z, 1.0);
	
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
	vec3 current_pos = ray_origin;
	float total_dist = 0.0;
	vec3 inv_dir = 1.0 / (ray_dir + vec3(0.00001)); // Avoid div by zero
	
	const float GRID_SIZE = 128.0;
	
	for (uint c = 0; c < params.cascade_count; c++) {
		// Convert to local cascade coordinates (cells)
		// HACK: Use hacked offset to match world_to_cascade_uvw
		float cell_size = 1.0 / params.cascades[c].to_cell;
		vec3 camera_pos = params.inv_view_matrix[3].xyz;
		vec3 hacked_offset = camera_pos - vec3(64.0 * cell_size);
		
		vec3 local_pos = current_pos - hacked_offset; // params.cascades[c].offset;
		local_pos *= params.cascades[c].to_cell;
		
		// Check if inside bounds
		if (any(lessThan(local_pos, vec3(0.0))) || any(greaterThanEqual(local_pos, vec3(GRID_SIZE)))) {
			continue;
		}
		
		// Find distance to exit the box
		vec3 t0 = -local_pos * inv_dir;
		vec3 t1 = (vec3(GRID_SIZE) - local_pos) * inv_dir;
		vec3 tmax = max(t0, t1);
		float dist_to_exit = min(tmax.x, min(tmax.y, tmax.z));
		
		// Limit by remaining ray distance
		float remaining_dist_ws = max_dist - total_dist;
		if (remaining_dist_ws <= 0.0) return false;
		
		float max_advance_cells = min(dist_to_exit, remaining_dist_ws * params.cascades[c].to_cell);
		
		float advance = 0.0;
		bool hit = false;
		
		// Raymarch
		int steps = 0;
		while (advance < max_advance_cells && steps < 128) {
			vec3 sample_pos = local_pos + ray_dir * advance;
			vec3 uvw = sample_pos / GRID_SIZE;
			
			// Decode SDF: stored as (dist + 1) / 255.0
			// sdfgi_integrate uses -1.0 offset
			float d = texture(sdf_cascades[c], uvw).r * 255.0 - 1.0;
			
			if (d < 0.1) { // Relaxed threshold
				hit = true;
				break;
			}
			
			// Ensure minimum step to avoid getting stuck
			advance += max(d, 0.01);
			steps++;
		}
		
		if (hit) {
			float dist_ws = advance / params.cascades[c].to_cell;
			hit_t = total_dist + dist_ws;
			hit_cascade = c;
			return true;
		}
		
		// Advance world position to exit point
		float advanced_ws = max_advance_cells / params.cascades[c].to_cell;
		total_dist += advanced_ws;
		current_pos = ray_origin + ray_dir * total_dist;
		
		// Nudge slightly to ensure we cross the boundary? 
		// sdfgi_integrate doesn't seem to do it explicitly, but floating point might require it.
		// Let's rely on the loop finding the next cascade.
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
	// Use texelFetch to avoid linear filtering artifacts which cause instability
	vec4 gbuffer_data = texelFetch(u_gbuffer_normal_depth, probe_pos, 0);
	float depth = gbuffer_data.w;
	
	vec3 ray_origin_ws = reconstruct_world_pos(uv, depth);
	
	// Apply normal bias
	// GBuffer stores View Space normals in XYZ (decoded in prepass)
	vec3 view_normal = gbuffer_data.xyz;
	// view_normal.y = -view_normal.y; // Revert Y-flip as it didn't help
	vec3 normal_ws = normalize(mat3(params.inv_view_matrix) * view_normal); 
		
	// Bias should be proportional to cell size to escape the voxel
	// params.normal_bias is usually ~1.1 (ratio)
	// We use the finest cascade (0) cell size for bias
	float cell_size = 1.0 / params.cascades[0].to_cell;
	ray_origin_ws += normal_ws * (cell_size * 0.2);
	
	float hit_t;
	uint hit_cascade;
	
	if (trace_sdf(ray_origin_ws, ray_dir_ws, ray_length, hit_t, hit_cascade)) {
		vec3 hit_pos = ray_origin_ws + ray_dir_ws * hit_t;
		vec3 hit_normal = calculate_sdf_normal(hit_pos, hit_cascade);
		
		// Sample lighting components separately
		vec3 uvw = world_to_cascade_uvw(hit_pos, hit_cascade);
		vec3 light = texture(light_cascades[hit_cascade], uvw).rgb;
		
		// Anisotropy
		vec4 aniso0 = texture(aniso0_cascades[hit_cascade], uvw);
		vec3 hit_aniso0 = aniso0.rgb;
		vec3 hit_aniso1 = vec3(aniso0.a, texture(aniso1_cascades[hit_cascade], uvw).rg);
		vec3 modulated_light = light * (dot(max(vec3(0.0), (hit_normal * hit_aniso0)), vec3(1.0)) + dot(max(vec3(0.0), (-hit_normal * hit_aniso1)), vec3(1.0)));

		// Occlusion seems broken (always 1.0?), so we skip adding sky energy for now
		// float occlusion = texture(occlusion_texture, uvw).r;
		// vec3 final_light = modulated_light + vec3(params.sky_energy) * occlusion;
		
		// DEBUG: Visualize World Space Grid to check stability
		// If this grid slides when rotating camera, reconstruct_world_pos is wrong.
		vec3 grid = fract(ray_origin_ws);
		imageStore(hit_radiance, probe_pos, vec4(grid, 1.0));
		
		/*
		// DEBUG: Boost brightness significantly to see if data exists
		// Split screen: Left = Modulated, Right = Raw Light
		if (uv.x < 0.5) {
			imageStore(hit_radiance, probe_pos, vec4(modulated_light * 5.0, 1.0));
		} else {
			imageStore(hit_radiance, probe_pos, vec4(light * 5.0, 1.0));
		}
		*/
		
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
