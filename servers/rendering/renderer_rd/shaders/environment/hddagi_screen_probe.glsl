#[compute]

#version 450

#VERSION_DEFINES

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform texture2D ambient_buffer;
layout(set = 0, binding = 1) uniform texture2D reflection_buffer;
layout(set = 0, binding = 2) uniform texture2D depth_buffer;
layout(set = 0, binding = 3) uniform texture2D normal_roughness_buffer;
layout(set = 0, binding = 4) uniform sampler linear_sampler;
layout(rgba16f, set = 0, binding = 5) uniform restrict writeonly image2D probe_radiance;
layout(rgba32ui, set = 0, binding = 6) uniform restrict uimage2D probe_reservoir;
layout(rg32ui, set = 0, binding = 7) uniform restrict uimage2D probe_surface_cache;
layout(set = 0, binding = 8) uniform texture2D atlas_radiance;
layout(set = 0, binding = 10) uniform texture2D atlas_history;
layout(rgba16f, set = 0, binding = 11) uniform restrict writeonly image2D probe_history;
layout(rg32ui, set = 0, binding = 12) uniform restrict readonly uimage3D hddagi_voxel_cascades;
layout(r8ui, set = 0, binding = 13) uniform restrict readonly uimage3D hddagi_voxel_region_cascades;
layout(set = 0, binding = 14) uniform texture3D hddagi_light_cascades;
layout(r32ui, set = 0, binding = 15) uniform restrict readonly uimage3D hddagi_voxel_neighbours;
layout(rgba32ui, set = 0, binding = 17) uniform restrict readonly uimage2D previous_reservoir;
layout(r8ui, set = 0, binding = 18) uniform restrict readonly uimage3D hddagi_voxel_disocclusion;
layout(r32ui, set = 0, binding = 19) uniform restrict writeonly uimage2D screen_probe_ambient_output;

struct HDDAGIProbeCascadeData {
	vec3 position;
	float to_probe;

	ivec3 region_world_offset;
	float to_cell;

	vec3 pad;
	float exposure_normalization;

	uvec4 pad2;
};

layout(set = 0, binding = 16, std140) uniform HDDAGIData {
	ivec3 grid_size;
	int max_cascades;

	float normal_bias;
	float energy;
	float y_mult;
	float reflection_bias;

	ivec3 probe_axis_size;
	float esm_strength;

	uvec4 pad3;

	HDDAGIProbeCascadeData cascades[8];
}
hddagi;

layout(set = 0, binding = 9, std140) uniform SceneData {
	mat4 inv_projection[2];
	mat4 cam_transform;
	vec4 eye_offset[2];

	ivec2 scene_screen_size;
	float scene_pad1;
	float scene_pad2;

	mat4 projection[2];
	mat4 previous_projection[2];
	mat4 previous_cam_inv_transform;
}
scene_data;

layout(push_constant, std430) uniform Params {
	ivec2 gi_size;
	ivec2 screen_size;

	int probe_size;
	uint view_index;
	uint frame_index;
	uint pass_mode;

	vec4 proj_info;
	uint orthogonal;
	float normal_bias;
	uint history_valid;
	float history_blend_hit;
	float history_distance_tolerance;
	float history_direction_threshold;
	int spatial_reuse_radius;
	float spatial_normal_threshold;
	float spatial_depth_tolerance_min;
	float spatial_depth_tolerance_scale;
	float miss_confidence;
	float history_sample_count_max;
	float miss_ambient_fallback_weight;
	float base_ambient_prior_weight;
	int debug_mode;
	uint surface_cache_enabled;
}
params;

const int OCTAHEDRAL_SIZE = 1;
const int HDDAGI_REGION_SIZE = 8;
const float TAU = 6.283185307179586;

vec3 octahedral_to_direction(vec2 e);
vec4 load_probe_ray(ivec2 probe_pos, ivec2 cell_pos);
float linearize_depth(float depth);

bool trace_ray_hdda(vec3 ray_pos, vec3 ray_dir, int p_cascade, out ivec3 r_cell, out ivec3 r_side, out int r_cascade) {
	const int LEVEL_CASCADE = -1;
	const int LEVEL_REGION = 0;
	const int LEVEL_BLOCK = 1;
	const int LEVEL_VOXEL = 2;
	const int MAX_LEVEL = 3;

	const int fp_bits = 10;
	const int fp_block_bits = fp_bits + 2;
	const int fp_region_bits = fp_block_bits + 1;

	bvec3 limit_dir = greaterThan(ray_dir, vec3(0.0));
	ivec3 step = mix(ivec3(0), ivec3(1), limit_dir);
	ivec3 ray_sign = ivec3(sign(ray_dir));
	ivec3 ray_dir_fp = ivec3(ray_dir * float(1 << fp_bits));
	bvec3 ray_zero = lessThan(abs(ray_dir), vec3(1.0 / 127.0));
	ivec3 inv_ray_dir_fp = ivec3(float(1 << fp_bits) / ray_dir);

	const ivec3 level_masks[MAX_LEVEL] = ivec3[](
			ivec3(1 << fp_region_bits) - ivec3(1),
			ivec3(1 << fp_block_bits) - ivec3(1),
			ivec3(1 << fp_bits) - ivec3(1));

	ivec3 region_offset_mask = (hddagi.grid_size / HDDAGI_REGION_SIZE) - ivec3(1);
	ivec3 limits[MAX_LEVEL];
	limits[LEVEL_REGION] = ((hddagi.grid_size << fp_bits) - ivec3(1)) * step;

	int level = LEVEL_CASCADE;
	int cascade = p_cascade - 1;
	ivec3 cascade_base;
	ivec3 region_base;
	uvec2 block;
	bool hit = false;
	ivec3 pos;

	while (true) {
		if (level == LEVEL_VOXEL) {
			ivec3 block_local = (pos & level_masks[LEVEL_BLOCK]) >> fp_bits;
			uint block_index = uint(block_local.z * 16 + block_local.y * 4 + block_local.x);
			if (block_index < 32) {
				if (bool(block.x & uint(1 << block_index))) {
					hit = true;
					break;
				}
			} else {
				block_index -= 32;
				if (bool(block.y & uint(1 << block_index))) {
					hit = true;
					break;
				}
			}
		} else if (level == LEVEL_BLOCK) {
			ivec3 block_local = (pos & level_masks[LEVEL_REGION]) >> fp_block_bits;
			block = imageLoad(hddagi_voxel_cascades, region_base + block_local).rg;
			if (block != uvec2(0)) {
				level = LEVEL_VOXEL;
				limits[LEVEL_VOXEL] = pos - (pos & level_masks[LEVEL_BLOCK]) + step * (level_masks[LEVEL_BLOCK] + ivec3(1));
				continue;
			}
		} else if (level == LEVEL_REGION) {
			ivec3 region = pos >> fp_region_bits;
			region = (hddagi.cascades[cascade].region_world_offset + region) & region_offset_mask;
			region += cascade_base;
			bool region_used = imageLoad(hddagi_voxel_region_cascades, region).r > 0;
			if (region_used) {
				region_base = region << 1;
				level = LEVEL_BLOCK;
				limits[LEVEL_BLOCK] = pos - (pos & level_masks[LEVEL_REGION]) + step * (level_masks[LEVEL_REGION] + ivec3(1));
				continue;
			}
		} else if (level == LEVEL_CASCADE) {
			if (cascade >= p_cascade) {
				ray_pos = vec3(pos) / float(1 << fp_bits);
				ray_pos /= hddagi.cascades[cascade].to_cell;
				ray_pos += hddagi.cascades[cascade].position;
			}

			cascade++;
			if (cascade == hddagi.max_cascades) {
				break;
			}

			ray_pos -= hddagi.cascades[cascade].position;
			ray_pos *= hddagi.cascades[cascade].to_cell;
			pos = ivec3(ray_pos * float(1 << fp_bits));
			if (any(lessThan(pos, ivec3(0))) || any(greaterThanEqual(pos, hddagi.grid_size << fp_bits))) {
				continue;
			}

			cascade_base = ivec3(0, int(hddagi.grid_size.y / HDDAGI_REGION_SIZE) * cascade, 0);
			level = LEVEL_REGION;
			continue;
		}

		ivec3 mask = level_masks[level];
		ivec3 box = mask * step;
		ivec3 pos_diff = box - (pos & mask);
		ivec3 mul_res = (pos_diff * inv_ray_dir_fp) >> fp_bits;
		ivec3 tv = mix(mul_res, ivec3(0x7FFFFFFF), ray_zero);
		int t = min(tv.x, min(tv.y, tv.z));
		ivec3 adv_box = pos_diff + ray_sign;
		ivec3 adv_t = (ray_dir_fp * t) >> fp_bits;
		pos += mix(adv_t, adv_box, equal(ivec3(t), tv));

		while (true) {
			bvec3 limit = lessThan(pos, limits[level]);
			bool inside = all(equal(limit, limit_dir));
			if (inside) {
				break;
			}
			level -= 1;
			if (level == LEVEL_CASCADE) {
				break;
			}
		}
	}

	if (hit) {
		ivec3 mask = level_masks[LEVEL_VOXEL];
		ivec3 box = mask * (step ^ ivec3(1));
		ivec3 pos_diff = box - (pos & mask);
		ivec3 mul_res = pos_diff * -inv_ray_dir_fp;
		ivec3 tv = mix(mul_res, ivec3(0x7FFFFFFF), ray_zero);

		int m;
		if (tv.x < tv.y) {
			r_side = ivec3(1, 0, 0);
			m = tv.x;
		} else {
			r_side = ivec3(0, 1, 0);
			m = tv.y;
		}
		if (tv.z < m) {
			r_side = ivec3(0, 0, 1);
		}

		r_side *= -ray_sign;
		r_cell = pos >> fp_bits;
		r_cascade = cascade;
	}

	return hit;
}

float point_to_ray_distance(vec3 point, vec3 ray_origin, vec3 ray_direction) {
	vec3 point_to_ray = point - ray_origin;
	float t = dot(point_to_ray, normalize(ray_direction));
	vec3 projected = ray_origin + ray_direction * t;
	return length(point - projected);
}

float validate_history(ivec2 atlas_pos, float previous_linear_depth, vec3 origin_world_normal) {
	uvec4 previous = imageLoad(previous_reservoir, atlas_pos);
	uint previous_frame = previous.a;

	if (previous_frame + 1u != params.frame_index) {
		return 0.0;
	}

	float stored_linear_depth = unpackHalf2x16(previous.g).x;
	vec3 previous_world_normal = octahedral_to_direction(unpackHalf2x16(previous.b));
	float normal_validity = smoothstep(params.history_direction_threshold, 1.0, dot(previous_world_normal, origin_world_normal));
	float depth_scale = max(params.history_distance_tolerance, max(params.spatial_depth_tolerance_min, abs(previous_linear_depth) * params.spatial_depth_tolerance_scale));
	float depth_validity = 1.0 - smoothstep(0.0, depth_scale, abs(stored_linear_depth - previous_linear_depth));
	return normal_validity * depth_validity;
}

vec3 cosine_sample_hemisphere(vec2 u) {
	float r = sqrt(u.x);
	float phi = TAU * u.y;
	return vec3(r * cos(phi), r * sin(phi), sqrt(max(0.0, 1.0 - u.x)));
}

vec3 tangent_to_world(vec3 local_dir, vec3 normal) {
	vec3 up = abs(normal.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0);
	vec3 tangent = normalize(cross(up, normal));
	vec3 bitangent = cross(normal, tangent);
	return normalize(tangent * local_dir.x + bitangent * local_dir.y + normal * local_dir.z);
}

vec3 normal_to_world(vec3 normal) {
	return normalize(mat3(scene_data.cam_transform) * normal);
}

uint hash_uvec3(uvec3 v) {
	v = v * 1664525u + 1013904223u;
	v.x += v.y * v.z;
	v.y += v.z * v.x;
	v.z += v.x * v.y;
	v ^= v >> 16u;
	v.x += v.y * v.z;
	return v.x ^ v.y ^ v.z;
}

float hash_float(uvec3 v) {
	return float(hash_uvec3(v) & 0x00ffffffu) / float(0x01000000u);
}

uint rgbe_encode(vec3 rgb) {
	const float rgbe_max = uintBitsToFloat(0x477F8000);
	const float rgbe_min = uintBitsToFloat(0x37800000);

	rgb = clamp(rgb, vec3(0.0), vec3(rgbe_max));
	float max_channel = max(max(rgbe_min, rgb.r), max(rgb.g, rgb.b));
	float bias = uintBitsToFloat((floatBitsToUint(max_channel) + 0x07804000) & 0x7F800000);

	uvec3 urgb = floatBitsToUint(rgb + bias);
	uint e = (floatBitsToUint(bias) << 4) + 0x10000000;
	return e | (urgb.b << 18) | (urgb.g << 9) | (urgb.r & 0x1FF);
}

vec3 rgbe_decode(uint rgbe) {
	uint exponent = (rgbe >> 27) & 0x1fu;
	vec3 mantissa = vec3(float(rgbe & 0x1ffu), float((rgbe >> 9) & 0x1ffu), float((rgbe >> 18) & 0x1ffu)) / 512.0;
	return mantissa * exp2(float(exponent) - 15.0);
}

vec3 clip_to_aabb(vec3 color, vec3 minimum, vec3 maximum) {
	vec3 center = (maximum + minimum) * 0.5;
	vec3 extents = max((maximum - minimum) * 0.5, vec3(0.0001));
	vec3 offset = color - center;
	vec3 unit = abs(offset / extents);
	float max_unit = max(unit.x, max(unit.y, unit.z));
	return max_unit > 1.0 ? center + offset / max_unit : color;
}

vec2 octahedral_wrap(vec2 v) {
	vec2 sign_val;
	sign_val.x = v.x >= 0.0 ? 1.0 : -1.0;
	sign_val.y = v.y >= 0.0 ? 1.0 : -1.0;
	return (1.0 - abs(v.yx)) * sign_val;
}

vec2 octahedral_encode(vec3 n) {
	n /= abs(n.x) + abs(n.y) + abs(n.z);
	n.xy = n.z >= 0.0 ? n.xy : octahedral_wrap(n.xy);
	return n.xy * 0.5 + 0.5;
}

ivec2 gi_to_screen(ivec2 gi_pos) {
	return clamp(gi_pos * params.screen_size / params.gi_size, ivec2(0), params.screen_size - ivec2(1));
}

ivec2 screen_to_gi(ivec2 screen_pos) {
	return clamp(screen_pos * params.gi_size / params.screen_size, ivec2(0), params.gi_size - ivec2(1));
}

vec3 load_source_radiance(ivec2 screen_pos) {
	screen_pos = clamp(screen_pos, ivec2(0), params.screen_size - ivec2(1));
	ivec2 gi_pos = screen_to_gi(screen_pos);
	vec3 ambient = texelFetch(sampler2D(ambient_buffer, linear_sampler), gi_pos, 0).rgb;
	vec3 reflection = texelFetch(sampler2D(reflection_buffer, linear_sampler), gi_pos, 0).rgb;
	return ambient + reflection;
}

vec3 load_source_ambient(ivec2 screen_pos) {
	screen_pos = clamp(screen_pos, ivec2(0), params.screen_size - ivec2(1));
	ivec2 gi_pos = screen_to_gi(screen_pos);
	return texelFetch(sampler2D(ambient_buffer, linear_sampler), gi_pos, 0).rgb;
}

bool load_surface_screen(ivec2 screen_pos, out float r_depth, out vec3 r_normal) {
	if (any(lessThan(screen_pos, ivec2(0))) || any(greaterThanEqual(screen_pos, params.screen_size))) {
		return false;
	}

	r_depth = texelFetch(sampler2D(depth_buffer, linear_sampler), screen_pos, 0).r;
	if (r_depth <= 0.0) {
		return false;
	}

	r_normal = texelFetch(sampler2D(normal_roughness_buffer, linear_sampler), screen_pos, 0).xyz * 2.0 - 1.0;
	float normal_len_sq = dot(r_normal, r_normal);
	if (normal_len_sq < 0.001) {
		return false;
	}
	r_normal *= inversesqrt(normal_len_sq);
	return true;
}

float linearize_depth(float depth) {
	vec4 pos = vec4(0.0, 0.0, depth, 1.0);
	pos = scene_data.inv_projection[params.view_index] * pos;
	return pos.z / pos.w;
}

vec3 compute_view_pos(vec3 screen_pos) {
	vec4 pos = vec4(screen_pos.xy * 2.0 - 1.0, screen_pos.z, 1.0);
	pos = scene_data.inv_projection[params.view_index] * pos;
	return pos.xyz / pos.w;
}

bool reproject_history(ivec2 origin_pos, float origin_depth, ivec2 cell_pos, out ivec2 r_previous_atlas_pos, out float r_previous_linear_depth) {
	vec2 origin_uv = (vec2(origin_pos) + 0.5) / vec2(params.screen_size);
	vec3 view_pos = compute_view_pos(vec3(origin_uv, origin_depth));
	vec4 world_pos = scene_data.cam_transform * vec4(view_pos.x, -view_pos.y, view_pos.z, 1.0);
	vec4 previous_view = scene_data.previous_cam_inv_transform * world_pos;
	vec4 previous_project_pos = vec4(previous_view.x, -previous_view.y, previous_view.z, 1.0);
	vec4 previous_clip = scene_data.previous_projection[params.view_index] * previous_project_pos;
	if (previous_clip.w <= 0.0) {
		return false;
	}

	vec3 previous_ndc = previous_clip.xyz / previous_clip.w;
	vec2 previous_uv = previous_ndc.xy * 0.5 + 0.5;
	if (any(lessThan(previous_uv, vec2(0.0))) || any(greaterThanEqual(previous_uv, vec2(1.0)))) {
		return false;
	}

	ivec2 previous_screen_pos = clamp(ivec2(previous_uv * vec2(params.screen_size)), ivec2(0), params.screen_size - ivec2(1));
	ivec2 previous_gi_pos = screen_to_gi(previous_screen_pos);
	ivec2 previous_probe_pos = previous_gi_pos / params.probe_size;
	ivec2 previous_atlas_size = textureSize(sampler2D(atlas_history, linear_sampler), 0);
	r_previous_atlas_pos = previous_probe_pos * OCTAHEDRAL_SIZE + cell_pos;
	if (any(lessThan(r_previous_atlas_pos, ivec2(0))) || any(greaterThanEqual(r_previous_atlas_pos, previous_atlas_size))) {
		return false;
	}

	r_previous_linear_depth = previous_project_pos.z;
	return true;
}

bool reproject_screen_history(ivec2 screen_pos, float depth, out ivec2 r_previous_screen_pos) {
	vec2 uv = (vec2(screen_pos) + 0.5) / vec2(params.screen_size);
	vec3 view_pos = compute_view_pos(vec3(uv, depth));
	vec4 world_pos = scene_data.cam_transform * vec4(view_pos.x, -view_pos.y, view_pos.z, 1.0);
	vec4 previous_view = scene_data.previous_cam_inv_transform * world_pos;
	vec4 previous_project_pos = vec4(previous_view.x, -previous_view.y, previous_view.z, 1.0);
	vec4 previous_clip = scene_data.previous_projection[params.view_index] * previous_project_pos;
	if (previous_clip.w <= 0.0) {
		return false;
	}

	vec3 previous_ndc = previous_clip.xyz / previous_clip.w;
	vec2 previous_uv = previous_ndc.xy * 0.5 + 0.5;
	if (any(lessThan(previous_uv, vec2(0.0))) || any(greaterThanEqual(previous_uv, vec2(1.0)))) {
		return false;
	}

	ivec2 previous_history_size = textureSize(sampler2D(atlas_history, linear_sampler), 0);
	r_previous_screen_pos = ivec2(previous_uv * vec2(previous_history_size));
	return !any(lessThan(r_previous_screen_pos, ivec2(0))) && !any(greaterThanEqual(r_previous_screen_pos, previous_history_size));
}

vec3 octahedral_to_direction(vec2 e) {
	e = e * 2.0 - 1.0;
	vec3 v = vec3(e.x, e.y, 1.0 - abs(e.x) - abs(e.y));
	if (v.z < 0.0) {
		vec2 folded = (1.0 - abs(v.yx)) * sign(v.xy);
		v = vec3(folded, v.z);
	}
	return normalize(v);
}

bool find_probe_surface(ivec2 probe_pos, out ivec2 r_screen_pos, out float r_depth, out vec3 r_normal) {
	ivec2 gi_origin = probe_pos * params.probe_size;
	ivec2 gi_offset = ivec2(params.probe_size / 2);
	ivec2 gi_pos = clamp(gi_origin + gi_offset, ivec2(0), params.gi_size - ivec2(1));
	r_screen_pos = gi_to_screen(gi_pos);
	if (load_surface_screen(r_screen_pos, r_depth, r_normal)) {
		return true;
	}

	ivec2 gi_end = min(gi_origin + ivec2(params.probe_size), params.gi_size);
	float best_distance = 1e20;
	ivec2 best_screen_pos = ivec2(0);
	float best_depth = 0.0;
	vec3 best_normal = vec3(0.0);
	bool found = false;
	for (int y = 0; y < params.probe_size; y++) {
		for (int x = 0; x < params.probe_size; x++) {
			gi_pos = gi_origin + ivec2(x, y);
			if (any(greaterThanEqual(gi_pos, gi_end))) {
				continue;
			}

			ivec2 screen_pos = gi_to_screen(gi_pos);
			float depth;
			vec3 normal;
			if (load_surface_screen(screen_pos, depth, normal)) {
				float distance = dot(vec2(ivec2(x, y) - gi_offset), vec2(ivec2(x, y) - gi_offset));
				if (!found || distance < best_distance) {
					best_distance = distance;
					best_screen_pos = screen_pos;
					best_depth = depth;
					best_normal = normal;
					found = true;
				}
			}
		}
	}

	if (found) {
		r_screen_pos = best_screen_pos;
		r_depth = best_depth;
		r_normal = best_normal;
	}
	return found;
}

void store_probe_surface(ivec2 probe_pos, ivec2 screen_pos) {
	imageStore(probe_surface_cache, probe_pos, uvec4(uint(screen_pos.x), uint(screen_pos.y), 0u, 0u));
}

void store_invalid_probe_surface(ivec2 probe_pos) {
	imageStore(probe_surface_cache, probe_pos, uvec4(0xffffffffu, 0xffffffffu, 0u, 0u));
}

bool load_probe_surface(ivec2 probe_pos, out ivec2 r_screen_pos, out float r_depth, out vec3 r_normal) {
	if (params.surface_cache_enabled == 0u) {
		return find_probe_surface(probe_pos, r_screen_pos, r_depth, r_normal);
	}

	if (any(lessThan(probe_pos, ivec2(0))) || any(greaterThanEqual(probe_pos, imageSize(probe_surface_cache)))) {
		return false;
	}

	uvec2 screen_pos = imageLoad(probe_surface_cache, probe_pos).rg;
	if (all(equal(screen_pos, uvec2(0xffffffffu)))) {
		return false;
	}

	r_screen_pos = ivec2(screen_pos);
	return load_surface_screen(r_screen_pos, r_depth, r_normal);
}

bool load_hddagi_ray_radiance(ivec2 origin_pos, float origin_depth, vec3 origin_normal, vec3 ray_dir, out vec3 r_radiance, out float r_hit_distance) {
	vec2 origin_uv = (vec2(origin_pos) + 0.5) / vec2(params.screen_size);
	vec3 ray_pos = compute_view_pos(vec3(origin_uv, origin_depth));
	ray_pos.y = -ray_pos.y;

	mat3 camera_basis = mat3(scene_data.cam_transform);
	ray_pos = camera_basis * ray_pos;
	ray_dir = normalize(camera_basis * ray_dir);
	vec3 hddagi_normal = normalize(camera_basis * origin_normal);

	ray_pos.y *= hddagi.y_mult;
	ray_dir.y *= hddagi.y_mult;
	hddagi_normal.y *= hddagi.y_mult;
	ray_dir = normalize(ray_dir);
	hddagi_normal = normalize(hddagi_normal);

	int cascade = 0x7FFFFFFF;
	vec3 cascade_pos = vec3(0.0);
	for (int i = 0; i < hddagi.max_cascades; i++) {
		cascade_pos = (ray_pos - hddagi.cascades[i].position) * hddagi.cascades[i].to_cell;
		if (any(lessThan(cascade_pos, vec3(0.0))) || any(greaterThanEqual(cascade_pos, vec3(hddagi.grid_size)))) {
			continue;
		}

		cascade = i;
		break;
	}

	if (cascade >= hddagi.max_cascades) {
		return false;
	}

	vec3 ray_origin = ray_pos;
	vec3 start_cell = (ray_pos - hddagi.cascades[cascade].position) * hddagi.cascades[cascade].to_cell;
	vec3 abs_normal = abs(hddagi_normal);
	vec3 ray_bias = hddagi_normal / max(abs_normal.x, max(abs_normal.y, abs_normal.z));
	start_cell += ray_bias * params.normal_bias;
	ray_pos = start_cell / hddagi.cascades[cascade].to_cell + hddagi.cascades[cascade].position;

	ivec3 hit_cell;
	ivec3 hit_face;
	int hit_cascade;
	if (!trace_ray_hdda(ray_pos, ray_dir, cascade, hit_cell, hit_face, hit_cascade)) {
		return false;
	}

	bool disoccluded = false;
	if (hit_cascade == cascade && ivec3(start_cell) == hit_cell) {
		ivec3 read_cell = (hit_cell + hddagi.cascades[hit_cascade].region_world_offset * HDDAGI_REGION_SIZE) & (hddagi.grid_size - 1);
		uint disocclusion = imageLoad(hddagi_voxel_disocclusion, read_cell + ivec3(0, hddagi.grid_size.y * hit_cascade, 0)).r;
		if (disocclusion == 0) {
			vec3 abs_normal = abs(hddagi_normal);
			int closest_axis = 0;
			float max_normal = abs_normal.x;
			if (abs_normal.y > max_normal) {
				max_normal = abs_normal.y;
				closest_axis = 1;
			}
			if (abs_normal.z > max_normal) {
				closest_axis = 2;
			}

			vec3 local = fract(start_cell) - 0.5;
			const vec3 axes[5] = vec3[](vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, 1), vec3(1, 0, 0), vec3(0, 1, 0));
			vec3 axis_a = axes[closest_axis + 1];
			vec3 axis_b = axes[closest_axis + 2];
			vec3 advance;
			if (abs(dot(axis_a, local)) > abs(dot(axis_b, local))) {
				advance = axis_a * sign(local);
			} else {
				advance = axis_b * sign(local);
			}

			start_cell += advance;
			hit_cell += ivec3(advance);
			read_cell = (hit_cell + hddagi.cascades[hit_cascade].region_world_offset * HDDAGI_REGION_SIZE) & (hddagi.grid_size - 1);
			disocclusion = imageLoad(hddagi_voxel_disocclusion, read_cell + ivec3(0, hddagi.grid_size.y * hit_cascade, 0)).r;
		}

		if (disocclusion != 0) {
			vec3 local = fract(start_cell) - 0.5;
			const vec3 aniso_dir[6] = vec3[](vec3(-1, 0, 0), vec3(1, 0, 0), vec3(0, -1, 0), vec3(0, 1, 0), vec3(0, 0, -1), vec3(0, 0, 1));
			int best_axis = 0;
			float best_d = -20.0;
			for (int i = 0; i < 6; i++) {
				if (bool(disocclusion & (1 << i))) {
					float d = dot(local, aniso_dir[i]);
					if (d > best_d) {
						best_axis = i;
						best_d = d;
					}
				}
			}
			hit_face = ivec3(aniso_dir[best_axis]);
			disoccluded = true;
		}
	}

	hit_cell += hit_face;
	ivec3 read_cell = (hit_cell + hddagi.cascades[hit_cascade].region_world_offset * HDDAGI_REGION_SIZE) & (hddagi.grid_size - 1);
	vec3 light = texelFetch(sampler3D(hddagi_light_cascades, linear_sampler), read_cell + ivec3(0, hddagi.grid_size.y * hit_cascade, 0), 0).rgb;

	uint neighbour_bits = disoccluded ? 0 : imageLoad(hddagi_voxel_neighbours, read_cell + ivec3(0, hddagi.grid_size.y * hit_cascade, 0)).r;
	vec3 cascade_offset = hddagi.cascades[hit_cascade].position;
	float to_cell = hddagi.cascades[hit_cascade].to_cell;
	float cascade_cell_size = 1.0 / to_cell;
	const ivec3 facing_directions[26] = ivec3[](ivec3(-1, 0, 0), ivec3(1, 0, 0), ivec3(0, -1, 0), ivec3(0, 1, 0), ivec3(0, 0, -1), ivec3(0, 0, 1), ivec3(-1, -1, -1), ivec3(-1, -1, 0), ivec3(-1, -1, 1), ivec3(-1, 0, -1), ivec3(-1, 0, 1), ivec3(-1, 1, -1), ivec3(-1, 1, 0), ivec3(-1, 1, 1), ivec3(0, -1, -1), ivec3(0, -1, 1), ivec3(0, 1, -1), ivec3(0, 1, 1), ivec3(1, -1, -1), ivec3(1, -1, 0), ivec3(1, -1, 1), ivec3(1, 0, -1), ivec3(1, 0, 1), ivec3(1, 1, -1), ivec3(1, 1, 0), ivec3(1, 1, 1));
	vec3 light_cell_pos = (vec3(hit_cell) + 0.5) * cascade_cell_size + cascade_offset;
	r_hit_distance = length(light_cell_pos - ray_origin);
	vec4 light_accum = vec4(light, 1.0) * max(0.0, 1.0 - point_to_ray_distance(light_cell_pos, ray_pos, ray_dir) * to_cell);
	while (neighbour_bits != 0) {
		uint msb = findLSB(neighbour_bits);
		vec3 neighbour_pos = light_cell_pos + vec3(facing_directions[msb]) * cascade_cell_size;
		float weight = max(0.0, 1.0 - point_to_ray_distance(neighbour_pos, ray_pos, ray_dir) * to_cell);
		if (weight > 0.0) {
			ivec3 neighbour_cell = hit_cell + facing_directions[msb];
			read_cell = (neighbour_cell + hddagi.cascades[hit_cascade].region_world_offset * HDDAGI_REGION_SIZE) & (hddagi.grid_size - 1);
			vec3 neighbour_light = texelFetch(sampler3D(hddagi_light_cascades, linear_sampler), read_cell + ivec3(0, hddagi.grid_size.y * hit_cascade, 0), 0).rgb;
			light_accum += vec4(neighbour_light, 1.0) * weight;
		}

		neighbour_bits &= ~(1 << msb);
	}

	if (light_accum.a > 0.0) {
		light = light_accum.rgb / light_accum.a;
	}

	r_radiance = light * hddagi.energy;
	return true;
}

vec4 load_probe_ray(ivec2 probe_pos, ivec2 cell_pos) {
	ivec2 atlas_size = textureSize(sampler2D(atlas_radiance, linear_sampler), 0);
	ivec2 atlas_pos = probe_pos * OCTAHEDRAL_SIZE + cell_pos;
	if (any(lessThan(atlas_pos, ivec2(0))) || any(greaterThanEqual(atlas_pos, atlas_size))) {
		return vec4(0.0);
	}
	return texelFetch(sampler2D(atlas_radiance, linear_sampler), atlas_pos, 0);
}

float spatial_candidate_weight(ivec2 center_probe_pos, ivec2 candidate_probe_pos, vec3 center_normal, float center_linear_depth) {
	ivec2 candidate_screen_pos;
	float candidate_depth;
	vec3 candidate_normal;
	if (!load_probe_surface(candidate_probe_pos, candidate_screen_pos, candidate_depth, candidate_normal)) {
		return 0.0;
	}

	float normal_weight = smoothstep(params.spatial_normal_threshold, 1.0, dot(center_normal, candidate_normal));
	float candidate_linear_depth = linearize_depth(candidate_depth);
	float depth_scale = max(params.spatial_depth_tolerance_min, abs(center_linear_depth) * params.spatial_depth_tolerance_scale);
	float depth_weight = 1.0 - smoothstep(0.0, depth_scale, abs(center_linear_depth - candidate_linear_depth));
	vec2 probe_delta = vec2(candidate_probe_pos - center_probe_pos);
	float distance_weight = exp(-0.5 * dot(probe_delta, probe_delta));
	return normal_weight * depth_weight * distance_weight;
}

void spatial_reuse_screen_probe_radiance() {
	ivec2 atlas_pos = ivec2(gl_GlobalInvocationID.xy);
	ivec2 atlas_size = imageSize(probe_history);
	if (any(greaterThanEqual(atlas_pos, atlas_size))) {
		return;
	}

	ivec2 probe_pos = atlas_pos / OCTAHEDRAL_SIZE;
	ivec2 cell_pos = atlas_pos - probe_pos * OCTAHEDRAL_SIZE;
	ivec2 probe_count = atlas_size / OCTAHEDRAL_SIZE;

	ivec2 origin_pos;
	float origin_depth;
	vec3 origin_normal;
	if (!load_probe_surface(probe_pos, origin_pos, origin_depth, origin_normal)) {
		imageStore(probe_history, atlas_pos, vec4(0.0));
		return;
	}

	float origin_linear_depth = linearize_depth(origin_depth);
	vec4 center_radiance = texelFetch(sampler2D(atlas_radiance, linear_sampler), atlas_pos, 0);
	if (params.spatial_reuse_radius <= 0) {
		imageStore(probe_history, atlas_pos, center_radiance);
		return;
	}

	float max_sample_count = max(params.history_sample_count_max, 1.0);
	float center_sample_count = clamp(center_radiance.a, 0.0, max_sample_count);
	vec3 radiance = center_radiance.rgb * center_sample_count;
	float weight = center_sample_count;

	for (int y = -params.spatial_reuse_radius; y <= params.spatial_reuse_radius; y++) {
		for (int x = -params.spatial_reuse_radius; x <= params.spatial_reuse_radius; x++) {
			ivec2 candidate_probe_pos = probe_pos + ivec2(x, y);
			if ((x == 0 && y == 0) || any(lessThan(candidate_probe_pos, ivec2(0))) || any(greaterThanEqual(candidate_probe_pos, probe_count))) {
				continue;
			}

			float candidate_weight = spatial_candidate_weight(probe_pos, candidate_probe_pos, origin_normal, origin_linear_depth);
			if (candidate_weight <= 0.0) {
				continue;
			}

			vec4 candidate_radiance = load_probe_ray(candidate_probe_pos, cell_pos);
			candidate_weight *= clamp(candidate_radiance.a, 0.0, max_sample_count);
			radiance += candidate_radiance.rgb * candidate_weight;
			weight += candidate_weight;
		}
	}

	// Spatial reuse is a bilateral denoise over already-accumulated probe estimates. Keep alpha as
	// this probe's temporal sample count; otherwise pass 1 would turn the sample count into a 0..1
	// confidence value and break next frame's 1/N history accumulation.

	if (weight <= 0.0) {
		imageStore(probe_history, atlas_pos, center_radiance);
		return;
	}

	vec3 final_radiance = radiance / weight;
	imageStore(probe_history, atlas_pos, vec4(final_radiance, center_sample_count));
	// Reservoir is owned by pass 0 (fresh trace sample). Do not overwrite it here.
}

vec4 gather_probe_radiance(ivec2 probe_pos) {
	vec3 radiance = vec3(0.0);
	float weight = 0.0;
	for (int y = 0; y < OCTAHEDRAL_SIZE; y++) {
		for (int x = 0; x < OCTAHEDRAL_SIZE; x++) {
			vec4 ray = load_probe_ray(probe_pos, ivec2(x, y));
			float ray_weight = max(ray.a, 0.02);
			radiance += ray.rgb * ray_weight;
			weight += ray_weight;
		}
	}
	return vec4(radiance / max(weight, 0.0001), clamp(weight / 4.0, 0.0, 1.0));
}

vec4 get_probe_debug_radiance(ivec2 probe_pos) {
	if (params.debug_mode == 1) {
		float sample_count = clamp(load_probe_ray(probe_pos, ivec2(0)).a / max(params.history_sample_count_max, 1.0), 0.0, 1.0);
		return vec4(sample_count, sample_count * sample_count, 1.0 - sample_count, 1.0);
	}

	uvec4 reservoir = imageLoad(probe_reservoir, clamp(probe_pos * OCTAHEDRAL_SIZE, ivec2(0), imageSize(probe_reservoir) - ivec2(1)));
	float hit_mask = unpackHalf2x16(reservoir.g).y;
	return vec4(hit_mask > 0.5 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0), 1.0);
}

void interpolate_screen_probe_radiance() {
	ivec2 screen_pos = ivec2(gl_GlobalInvocationID.xy);
	ivec2 output_size = imageSize(probe_radiance);
	if (any(greaterThanEqual(screen_pos, output_size))) {
		return;
	}

	float pixel_depth;
	vec3 pixel_normal;
	if (!load_surface_screen(screen_pos, pixel_depth, pixel_normal)) {
		imageStore(probe_radiance, screen_pos, vec4(0.0));
		return;
	}

	ivec2 gi_pos = screen_to_gi(screen_pos);
	ivec2 probe_base = gi_pos / params.probe_size;
	if (params.debug_mode != 0) {
		imageStore(probe_radiance, screen_pos, get_probe_debug_radiance(probe_base));
		return;
	}

	if (params.probe_size == 1) {
		imageStore(probe_radiance, screen_pos, load_probe_ray(probe_base, ivec2(0)));
		return;
	}

	ivec2 probe_count = textureSize(sampler2D(atlas_radiance, linear_sampler), 0) / OCTAHEDRAL_SIZE;

	float pixel_linear_depth = linearize_depth(pixel_depth);
	vec3 radiance = vec3(0.0);
	float weight = 0.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			ivec2 probe_pos = probe_base + ivec2(x, y);
			if (any(lessThan(probe_pos, ivec2(0))) || any(greaterThanEqual(probe_pos, probe_count))) {
				continue;
			}

			ivec2 probe_screen_pos;
			float probe_depth;
			vec3 probe_normal;
			if (!load_probe_surface(probe_pos, probe_screen_pos, probe_depth, probe_normal)) {
				continue;
			}

			float normal_weight = pow(max(dot(pixel_normal, probe_normal), 0.0), 4.0);
			float probe_linear_depth = linearize_depth(probe_depth);
			float depth_scale = max(0.02, abs(pixel_linear_depth) * 0.03);
			float depth_weight = 1.0 - smoothstep(0.0, depth_scale, abs(pixel_linear_depth - probe_linear_depth));
			float distance_weight = 1.0 / (1.0 + length(vec2(screen_pos - probe_screen_pos)) / float(max(params.probe_size, 1)));
			float probe_weight = normal_weight * depth_weight * distance_weight;
			if (probe_weight <= 0.0) {
				continue;
			}

			vec4 probe_radiance = gather_probe_radiance(probe_pos);
			probe_weight *= max(probe_radiance.a, 0.25);
			radiance += probe_radiance.rgb * probe_weight;
			weight += probe_weight;
		}
	}

	if (weight <= 0.0) {
		imageStore(probe_radiance, screen_pos, vec4(load_source_radiance(screen_pos) * 0.05, 0.0));
		return;
	}

	imageStore(probe_radiance, screen_pos, vec4(radiance / weight, clamp(weight / 2.0, 0.0, 1.0)));
}

void gather_screen_radiance_statistics(ivec2 screen_pos, out vec3 r_mean, out vec3 r_stddev) {
	ivec2 input_size = textureSize(sampler2D(atlas_radiance, linear_sampler), 0);
	vec3 moment1 = vec3(0.0);
	vec3 moment2 = vec3(0.0);
	float weight = 0.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			ivec2 sample_pos = clamp(screen_pos + ivec2(x, y), ivec2(0), input_size - ivec2(1));
			vec4 sample_radiance = texelFetch(sampler2D(atlas_radiance, linear_sampler), sample_pos, 0);
			float sample_weight = max(sample_radiance.a, 0.25) * exp(-0.75 * float(x * x + y * y));
			moment1 += sample_radiance.rgb * sample_weight;
			moment2 += sample_radiance.rgb * sample_radiance.rgb * sample_weight;
			weight += sample_weight;
		}
	}

	r_mean = moment1 / max(weight, 0.0001);
	r_stddev = sqrt(max(moment2 / max(weight, 0.0001) - r_mean * r_mean, vec3(0.0)));
}

void temporal_filter_screen_probe_radiance() {
	ivec2 screen_pos = ivec2(gl_GlobalInvocationID.xy);
	ivec2 output_size = imageSize(probe_radiance);
	if (any(greaterThanEqual(screen_pos, output_size))) {
		return;
	}

	vec4 current_radiance = texelFetch(sampler2D(atlas_radiance, linear_sampler), screen_pos, 0);
	if (params.debug_mode != 0) {
		imageStore(probe_radiance, screen_pos, current_radiance);
		return;
	}

	if (params.probe_size == 1) {
		imageStore(probe_radiance, screen_pos, current_radiance);
		return;
	}

	if (params.history_valid == 0 || current_radiance.a <= 0.0) {
		imageStore(probe_radiance, screen_pos, current_radiance);
		return;
	}

	float pixel_depth;
	vec3 pixel_normal;
	if (!load_surface_screen(screen_pos, pixel_depth, pixel_normal)) {
		imageStore(probe_radiance, screen_pos, current_radiance);
		return;
	}

	ivec2 previous_screen_pos;
	if (!reproject_screen_history(screen_pos, pixel_depth, previous_screen_pos)) {
		imageStore(probe_radiance, screen_pos, current_radiance);
		return;
	}

	vec4 previous_radiance = texelFetch(sampler2D(atlas_history, linear_sampler), previous_screen_pos, 0);
	if (previous_radiance.a <= 0.0) {
		imageStore(probe_radiance, screen_pos, current_radiance);
		return;
	}

	vec3 local_mean;
	vec3 local_stddev;
	gather_screen_radiance_statistics(screen_pos, local_mean, local_stddev);
	previous_radiance.rgb = clip_to_aabb(previous_radiance.rgb, local_mean - local_stddev * 2.0, local_mean + local_stddev * 2.0);

	float history_blend = clamp(max(params.history_blend_hit, 0.95) * mix(0.75, 1.0, previous_radiance.a) * mix(0.75, 1.0, current_radiance.a), 0.0, 0.98);
	vec3 filtered = mix(current_radiance.rgb, previous_radiance.rgb, history_blend);
	float filtered_confidence = clamp(max(current_radiance.a, previous_radiance.a * 0.995) + 0.04, 0.0, 1.0);
	imageStore(probe_radiance, screen_pos, vec4(filtered, filtered_confidence));
}

void apply_screen_probe_ambient() {
	ivec2 gi_pos = ivec2(gl_GlobalInvocationID.xy);
	ivec2 output_size = imageSize(screen_probe_ambient_output);
	if (any(greaterThanEqual(gi_pos, output_size))) {
		return;
	}

	ivec2 screen_pos = clamp(gi_pos * params.screen_size / output_size, ivec2(0), params.screen_size - ivec2(1));
	vec4 probe_radiance = texelFetch(sampler2D(atlas_radiance, linear_sampler), screen_pos, 0);
	// Confidence (alpha) is a validity flag, not an energy multiplier. Multiplying by it makes the
	// final ambient grow/shrink as the temporal accumulator warms up, which prevents convergence
	// to a stable result.
	vec3 final_rgb;
	final_rgb = probe_radiance.a > 0.0 ? probe_radiance.rgb : vec3(0.0);
	imageStore(screen_probe_ambient_output, gi_pos, uvec4(rgbe_encode(final_rgb)));
}

void main() {
	if (params.pass_mode == 1) {
		spatial_reuse_screen_probe_radiance();
		return;
	}
	if (params.pass_mode == 2) {
		interpolate_screen_probe_radiance();
		return;
	}
	if (params.pass_mode == 3) {
		temporal_filter_screen_probe_radiance();
		return;
	}
	if (params.pass_mode == 4) {
		apply_screen_probe_ambient();
		return;
	}

	ivec2 atlas_pos = ivec2(gl_GlobalInvocationID.xy);
	ivec2 atlas_size = imageSize(probe_radiance);
	if (any(greaterThanEqual(atlas_pos, atlas_size))) {
		return;
	}

	ivec2 probe_pos = atlas_pos / OCTAHEDRAL_SIZE;
	ivec2 cell_pos = atlas_pos - probe_pos * OCTAHEDRAL_SIZE;

	ivec2 origin_pos;
	float origin_depth;
	vec3 origin_normal;
	if (!find_probe_surface(probe_pos, origin_pos, origin_depth, origin_normal)) {
		store_invalid_probe_surface(probe_pos);
		imageStore(probe_radiance, atlas_pos, vec4(0.0));
		imageStore(probe_history, atlas_pos, vec4(0.0));
		imageStore(probe_reservoir, atlas_pos, uvec4(0));
		return;
	}
	if (params.surface_cache_enabled != 0u) {
		store_probe_surface(probe_pos, origin_pos);
	}

	float frame = float(params.frame_index & 0xffffu);
	vec2 ray_jitter = fract(vec2(
			hash_float(uvec3(atlas_pos, 0u)) + frame * 0.7548776662466927,
			hash_float(uvec3(atlas_pos.yx, 1u)) + frame * 0.5698402909980532));
	vec2 sample_uv = (vec2(cell_pos) + ray_jitter) / float(OCTAHEDRAL_SIZE);
	vec3 ray_dir = tangent_to_world(cosine_sample_hemisphere(sample_uv), origin_normal);

	float hit_distance;
	vec3 radiance;
	vec3 base_ambient = load_source_ambient(origin_pos);
	bool hit = load_hddagi_ray_radiance(origin_pos, origin_depth, origin_normal, ray_dir, radiance, hit_distance);
	float sample_count = 1.0;
	if (!hit) {
		// Fall back only to the base ambient GI. Do not include reflection_buffer here: that would
		// feed screen-space/reflection history back into the probe estimator and can drift.
		radiance = base_ambient * params.miss_ambient_fallback_weight;
		hit_distance = 0.0;
	} else {
		// Blend a small base-GI prior into hits as well so hit/miss areas share the same low-frequency
		// baseline instead of cutting sharply between traced radiance and fallback radiance.
		radiance = mix(radiance, base_ambient, params.base_ambient_prior_weight);
	}

	vec4 current_radiance = vec4(radiance, sample_count);
	ivec2 previous_atlas_pos;
	float previous_linear_depth;
	vec3 origin_world_normal = normal_to_world(origin_normal);
	bool history_reprojected = reproject_history(origin_pos, origin_depth, cell_pos, previous_atlas_pos, previous_linear_depth);
	vec4 previous_radiance = history_reprojected ? texelFetch(sampler2D(atlas_history, linear_sampler), previous_atlas_pos, 0) : vec4(0.0);
	float history_validity = history_reprojected ? validate_history(previous_atlas_pos, previous_linear_depth, origin_world_normal) : 0.0;
	if (params.history_valid != 0 && previous_radiance.a > 0.0 && history_validity > 0.0) {
		float previous_sample_count = min(previous_radiance.a, max(params.history_sample_count_max, 1.0) - 1.0);
		sample_count = previous_sample_count + 1.0;
		current_radiance.rgb = (previous_radiance.rgb * previous_sample_count + radiance) / sample_count;
		current_radiance.a = sample_count;
	}

	imageStore(probe_radiance, atlas_pos, current_radiance);
	imageStore(probe_history, atlas_pos, current_radiance);
	imageStore(probe_reservoir, atlas_pos, uvec4(rgbe_encode(radiance), packHalf2x16(vec2(linearize_depth(origin_depth), hit ? 1.0 : params.miss_confidence)), packHalf2x16(octahedral_encode(origin_world_normal)), params.frame_index));
}
