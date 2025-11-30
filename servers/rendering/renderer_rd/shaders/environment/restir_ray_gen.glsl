#[compute]

#version 450

#VERSION_DEFINES

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Textures
layout(set = 0, binding = 0) uniform sampler2D u_gbuffer_normal_depth;
layout(set = 0, binding = 1) uniform sampler2D u_gbuffer_diffuse;

// Output
layout(rgba16f, set = 0, binding = 2) uniform restrict writeonly image2D ray_directions;

// Configuration
layout(set = 0, binding = 3, std140) uniform RayGenParams {
	ivec2 probe_resolution;
	uint frame_count;
	uint ray_count_mode; // 0=Performance, 1=Quality, 2=Cinematic
	float ray_length;
	uint use_importance_sampling;
	vec2 padding;
	mat4 view_to_world;
} params;

// Random number generation (PCG)
uint pcg_hash(uint seed) {
	uint state = seed * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return (word >> 22u) ^ word;
}

float random(inout uint seed) {
	seed = pcg_hash(seed);
	return float(seed) / 4294967296.0;
}

// Generate uniform random direction in hemisphere around normal
vec3 random_hemisphere_direction(vec3 normal, inout uint seed) {
	// Cosine-weighted hemisphere sampling
	float r1 = random(seed);
	float r2 = random(seed);
	
	float phi = 2.0 * 3.14159265359 * r1;
	float cos_theta = sqrt(1.0 - r2);
	float sin_theta = sqrt(r2);
	
	vec3 h;
	h.x = cos(phi) * sin_theta;
	h.y = sin(phi) * sin_theta;
	h.z = cos_theta;
	
	// Build tangent space
	vec3 up = abs(normal.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
	vec3 tangent = normalize(cross(up, normal));
	vec3 bitangent = cross(normal, tangent);
	
	// Transform to world space
	return normalize(tangent * h.x + bitangent * h.y + normal * h.z);
}

// Blue noise sampling (simplified - in production use texture-based blue noise)
vec3 blue_noise_hemisphere_direction(vec3 normal, uint pixel_index, uint frame_index) {
	// Golden ratio for better distribution
	const float PHI = 1.618033988749895;
	float theta = 2.0 * 3.14159265359 * fract(float(pixel_index) * PHI + float(frame_index) * 0.618);
	float cos_theta = sqrt(fract(float(pixel_index) / PHI + float(frame_index) * PHI));
	float sin_theta = sqrt(1.0 - cos_theta * cos_theta);
	
	vec3 h;
	h.x = cos(theta) * sin_theta;
	h.y = sin(theta) * sin_theta;
	h.z = cos_theta;
	
	// Build tangent space
	vec3 up = abs(normal.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
	vec3 tangent = normalize(cross(up, normal));
	vec3 bitangent = cross(normal, tangent);
	
	return normalize(tangent * h.x + bitangent * h.y + normal * h.z);
}

// Importance sampling based on BRDF (simplified Lambertian)
vec3 importance_sample_direction(vec3 normal, vec3 view_dir, float roughness, inout uint seed) {
	// For diffuse surfaces, cosine-weighted sampling
	// For specular, we would do GGX sampling (TODO)
	
	float r1 = random(seed);
	float r2 = random(seed);
	
	// Cosine-weighted sampling
	float phi = 2.0 * 3.14159265359 * r1;
	float cos_theta = sqrt(1.0 - r2);
	float sin_theta = sqrt(r2);
	
	vec3 h;
	h.x = cos(phi) * sin_theta;
	h.y = sin(phi) * sin_theta;
	h.z = cos_theta;
	
	// Build tangent space aligned with normal
	vec3 up = abs(normal.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
	vec3 tangent = normalize(cross(up, normal));
	vec3 bitangent = cross(normal, tangent);
	
	vec3 sample_dir = tangent * h.x + bitangent * h.y + normal * h.z;
	return normalize(sample_dir);
}

void main() {
	ivec2 probe_pos = ivec2(gl_GlobalInvocationID.xy);
	
	if (probe_pos.x >= params.probe_resolution.x || probe_pos.y >= params.probe_resolution.y) {
		return;
	}
	
	// Read GBuffer data
	vec2 uv = (vec2(probe_pos) + 0.5) / vec2(params.probe_resolution);
	vec4 gbuffer_data = texture(u_gbuffer_normal_depth, uv);
	vec3 normal = normalize(gbuffer_data.xyz);
	float depth = gbuffer_data.w;
	
	// Check if valid surface
	if (depth <= 0.0001 || length(normal) < 0.1) {
		// No geometry at this probe position - write invalid ray
		imageStore(ray_directions, probe_pos, vec4(0.0));
		return;
	}
	
	// Initialize random seed
	uint seed = probe_pos.x + probe_pos.y * params.probe_resolution.x;
	seed = seed * 1664525u + 1013904223u;
	seed += params.frame_count * 1973272911u;
	
	// Generate ray direction
	vec3 ray_dir;
	
	if (params.use_importance_sampling > 0u) {
		// Importance sampling (better for specular surfaces)
		vec3 view_dir = vec3(0.0, 0.0, 1.0); // TODO: compute from camera
		float roughness = 1.0; // TODO: extract from GBuffer if available
		ray_dir = importance_sample_direction(normal, view_dir, roughness, seed);
	} else {
		// Blue noise sampling for temporal stability
		uint pixel_index = probe_pos.x + probe_pos.y * params.probe_resolution.x;
		ray_dir = blue_noise_hemisphere_direction(normal, pixel_index, params.frame_count);
	}
	
	// Store ray direction and length in w component
	imageStore(ray_directions, probe_pos, vec4(ray_dir, params.ray_length));
}
