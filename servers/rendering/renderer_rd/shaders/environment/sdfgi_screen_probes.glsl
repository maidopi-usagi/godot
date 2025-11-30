#[compute]

#version 450

#VERSION_DEFINES

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

#define MAX_CASCADES 8

layout(set = 0, binding = 1) uniform texture3D sdf_cascades[MAX_CASCADES];
layout(set = 0, binding = 2) uniform texture3D light_cascades[MAX_CASCADES];
layout(set = 0, binding = 3) uniform texture3D aniso0_cascades[MAX_CASCADES];
layout(set = 0, binding = 4) uniform texture3D aniso1_cascades[MAX_CASCADES];
layout(set = 0, binding = 5) uniform sampler linear_sampler;

struct CascadeData {
	vec3 offset; //offset of (0,0,0) in world coordinates
	float to_cell; // 1/bounds * grid_size
	ivec3 probe_world_offset;
	uint pad;
	vec4 pad2;
};

layout(set = 0, binding = 6, std140) uniform Cascades {
	CascadeData data[MAX_CASCADES];
}
cascades;

layout(set = 0, binding = 7) uniform texture2D depth_texture;
layout(set = 0, binding = 8) uniform texture2D normal_texture;
layout(set = 0, binding = 9) uniform sampler nearest_sampler;

layout(rgba16f, set = 0, binding = 10) uniform restrict writeonly image2D screen_probes_texture;

layout(set = 0, binding = 11, std140) uniform SceneData {
	mat4 projection;
	mat4 inv_projection;
	mat4 transform;
} scene_data;

layout(set = 0, binding = 12) uniform texture2D history_texture;
layout(set = 0, binding = 13) uniform texture2D velocity_texture;

#ifdef USE_CUBEMAP_ARRAY
layout(set = 1, binding = 0) uniform textureCubeArray sky_irradiance;
#else
layout(set = 1, binding = 0) uniform textureCube sky_irradiance;
#endif
layout(set = 1, binding = 1) uniform sampler linear_sampler_mipmaps;

#define SKY_FLAGS_MODE_COLOR 0x01
#define SKY_FLAGS_MODE_SKY 0x02
#define SKY_FLAGS_ORIENTATION_SIGN 0x04

layout(push_constant, std430) uniform Params {
	vec3 grid_size;
	uint max_cascades;

	ivec2 screen_size;
	float y_mult;
	uint history_index;

	uint sky_flags;
	float sky_energy;
	vec3 sky_color_or_orientation;
	uint pad;
}
params;

const float PI = 3.14159265f;
const float GOLDEN_ANGLE = PI * (3.0 - sqrt(5.0));

vec3 sample_hemisphere_cosine(uint p_index, uint p_count, float p_offset) {
	float r = sqrt(float(p_index) + 0.5f) / sqrt(float(p_count));
	float theta = float(p_index) * GOLDEN_ANGLE + p_offset;
	float sin_theta = r;
	float cos_theta = sqrt(1.0 - r * r);
	return vec3(sin_theta * cos(theta), sin_theta * sin(theta), cos_theta);
}

uvec3 hash3(uvec3 x) {
	x = ((x >> 16) ^ x) * 0x45d9f3b;
	x = ((x >> 16) ^ x) * 0x45d9f3b;
	x = (x >> 16) ^ x;
	return x;
}

float hashf3(vec3 co) {
	return fract(sin(dot(co, vec3(12.9898, 78.233, 137.13451))) * 43758.5453);
}

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pos, params.screen_size))) {
		return;
	}

	vec2 uv = (vec2(pos) + 0.5) / vec2(params.screen_size);

	// Sample depth
	float depth = texture(sampler2D(depth_texture, nearest_sampler), uv).r;
	if (depth == 1.0) { // Background
		imageStore(screen_probes_texture, pos, vec4(0.0));
		return;
	}

	// Reconstruct world position
	// Note: Godot's Projection class uses OpenGL conventions (-1..1 for Z), even on Vulkan.
	// The depth buffer is 0..1 (Vulkan), so we need to remap to -1..1 for unprojection.
	vec4 ndc = vec4(uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
	vec4 view_pos = scene_data.inv_projection * ndc;
	view_pos /= view_pos.w;
	vec3 world_pos = (scene_data.transform * view_pos).xyz;

	if (depth == 0.0 || depth == 1.0) {
		imageStore(screen_probes_texture, pos, vec4(0.0));
		return;
	}

	// Sample normal (assuming view space normals in normal_texture, encoded as 0..1)
	vec3 view_normal = texture(sampler2D(normal_texture, nearest_sampler), uv).xyz * 2.0 - 1.0;
	vec3 world_normal = normalize(mat3(scene_data.transform) * view_normal);

	// Ray march settings
	uint ray_count = 32; // Reduced for performance, relying on temporal accumulation
	vec3 total_light = vec3(0.0);

	// Random rotation for the hemisphere
	// Use a different seed per frame if we want to dither over time, but for now static noise is fine if we move?
	// Actually, for temporal accumulation to work best with low ray count, we should jitter the noise over time.
	// But we don't have a frame index here.
	// Let's stick to static noise for now, or maybe use the history to jitter?
	// Ideally we pass a frame index in push constants.
	uvec3 h3 = hash3(uvec3(ivec3(pos, 0)));
	float offset = hashf3(vec3(h3 & uvec3(0xFFFFF)));

	// Construct basis from normal
	vec3 up = abs(world_normal.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
	vec3 tangent = normalize(cross(up, world_normal));
	vec3 bitangent = cross(world_normal, tangent);
	mat3 tbn = mat3(tangent, bitangent, world_normal);

	vec3 pos_to_uvw = 1.0 / params.grid_size;

	for (uint i = 0; i < ray_count; i++) {
		vec3 ray_dir_local = sample_hemisphere_cosine(i, ray_count, offset);
		vec3 ray_dir = normalize(tbn * ray_dir_local);

		// Trace ray
		vec3 ray_pos = world_pos;
		vec3 inv_dir = 1.0 / ray_dir;

		bool hit = false;
		uint hit_cascade = 0;
		vec3 hit_uvw = vec3(0.0);

		// Bias to avoid self-intersection
		// Use the finest cascade cell size as reference for bias
		float min_cell_size = 1.0 / cascades.data[0].to_cell;
		
		// Logic adapted from gi.glsl sdfgi_compute()
		float bias_mult = 1.5; 
		vec3 abs_ray_dir = abs(ray_dir);
		float ray_dir_factor = 1.0 / max(abs_ray_dir.x, max(abs_ray_dir.y, abs_ray_dir.z));
		
		ray_pos += (world_normal * 1.4 + ray_dir * ray_dir_factor) * bias_mult * min_cell_size;

		for (uint j = 0; j < params.max_cascades; j++) {
			//convert to local bounds
			vec3 pos_local = ray_pos - cascades.data[j].offset;
			pos_local *= cascades.data[j].to_cell;

			if (any(lessThan(pos_local, vec3(0.0))) || any(greaterThanEqual(pos_local, params.grid_size))) {
				continue; //already past bounds for this cascade, goto next
			}

			//find maximum advance distance (until reaching bounds)
			vec3 t0 = -pos_local * inv_dir;
			vec3 t1 = (params.grid_size - pos_local) * inv_dir;
			vec3 tmax = max(t0, t1);
			float max_advance = min(tmax.x, min(tmax.y, tmax.z));

			float advance = 0.0;
			vec3 uvw;

			while (advance < max_advance) {
				//read how much to advance from SDF
				uvw = (pos_local + ray_dir * advance) * pos_to_uvw;

				float distance = texture(sampler3D(sdf_cascades[j], linear_sampler), uvw).r * 255.0 - 1.1;
				if (distance < 0.2) {
					//consider hit
					hit = true;
					hit_uvw = uvw;
					break;
				}

				advance += distance;
			}

			if (hit) {
				hit_cascade = j;
				break;
			}

			//change ray origin to collision with bounds
			pos_local += ray_dir * max_advance;
			pos_local /= cascades.data[j].to_cell;
			pos_local += cascades.data[j].offset;
			ray_pos = pos_local;
		}

		if (hit) {
			// Sample light
			vec3 hit_light = texture(sampler3D(light_cascades[hit_cascade], linear_sampler), hit_uvw).rgb;
			
			// Calculate normal from SDF gradient
			const float EPSILON = 0.001;
			vec3 hit_normal = normalize(vec3(
					texture(sampler3D(sdf_cascades[hit_cascade], linear_sampler), hit_uvw + vec3(EPSILON, 0.0, 0.0)).r - texture(sampler3D(sdf_cascades[hit_cascade], linear_sampler), hit_uvw - vec3(EPSILON, 0.0, 0.0)).r,
					texture(sampler3D(sdf_cascades[hit_cascade], linear_sampler), hit_uvw + vec3(0.0, EPSILON, 0.0)).r - texture(sampler3D(sdf_cascades[hit_cascade], linear_sampler), hit_uvw - vec3(0.0, EPSILON, 0.0)).r,
					texture(sampler3D(sdf_cascades[hit_cascade], linear_sampler), hit_uvw + vec3(0.0, 0.0, EPSILON)).r - texture(sampler3D(sdf_cascades[hit_cascade], linear_sampler), hit_uvw - vec3(0.0, 0.0, EPSILON)).r));

			vec4 aniso0 = texture(sampler3D(aniso0_cascades[hit_cascade], linear_sampler), hit_uvw);
			vec3 hit_aniso0 = aniso0.rgb;
			vec3 hit_aniso1 = vec3(aniso0.a, texture(sampler3D(aniso1_cascades[hit_cascade], linear_sampler), hit_uvw).rg);

			vec3 light_contrib = hit_light * (dot(max(vec3(0.0), (hit_normal * hit_aniso0)), vec3(1.0)) + dot(max(vec3(0.0), (-hit_normal * hit_aniso1)), vec3(1.0)));
			
			total_light += light_contrib;
		} else {
			vec3 light_contrib = vec3(0.0);
			if (bool(params.sky_flags & SKY_FLAGS_MODE_SKY)) {
				// Reconstruct sky orientation as quaternion and rotate ray_dir before sampling.
				float sky_sign = bool(params.sky_flags & SKY_FLAGS_ORIENTATION_SIGN) ? 1.0 : -1.0;
				vec4 sky_quat = vec4(params.sky_color_or_orientation, sky_sign * sqrt(1.0 - dot(params.sky_color_or_orientation, params.sky_color_or_orientation)));
				vec3 sky_dir = cross(sky_quat.xyz, ray_dir);
				sky_dir = ray_dir + ((sky_dir * sky_quat.w) + cross(sky_quat.xyz, sky_dir)) * 2.0;
#ifdef USE_CUBEMAP_ARRAY
				light_contrib = textureLod(samplerCubeArray(sky_irradiance, linear_sampler_mipmaps), vec4(sky_dir, 0.0), 2.0).rgb; 
#else
				light_contrib = textureLod(samplerCube(sky_irradiance, linear_sampler_mipmaps), sky_dir, 2.0).rgb; 
#endif
				light_contrib *= params.sky_energy;

			} else if (bool(params.sky_flags & SKY_FLAGS_MODE_COLOR)) {
				light_contrib = params.sky_color_or_orientation;
				light_contrib *= params.sky_energy;
			}
			total_light += light_contrib;
		}
	}

	vec3 current_color = total_light * PI / float(ray_count);

	// Temporal Accumulation
	vec2 velocity = texture(sampler2D(velocity_texture, linear_sampler), uv).xy;
	vec2 prev_uv = uv - velocity;

	bool history_valid = all(greaterThanEqual(prev_uv, vec2(0.0))) && all(lessThan(prev_uv, vec2(1.0)));
	
	vec3 history_color = vec3(0.0);
	if (history_valid) {
		history_color = texture(sampler2D(history_texture, linear_sampler), prev_uv).rgb;
	}

	float blend = history_valid ? 0.05 : 1.0;
	vec3 final_color = mix(history_color, current_color, blend);

	imageStore(screen_probes_texture, pos, vec4(final_color, 1.0));
}
