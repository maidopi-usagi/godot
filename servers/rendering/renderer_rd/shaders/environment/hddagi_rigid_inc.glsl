#ifndef HDDAGI_RIGID_INC_GLSL
#define HDDAGI_RIGID_INC_GLSL

#include "hddagi_rigid_data_inc.glsl"

const uint HDDAGI_RIGID_LIGHT_VALID = 1u << 26u;
const float HDDAGI_RIGID_RAY_EPSILON = 0.001;
const ivec3 HDDAGI_RIGID_NEIGHBOURS[26] = ivec3[](
		ivec3(-1, 0, 0), ivec3(1, 0, 0), ivec3(0, -1, 0), ivec3(0, 1, 0), ivec3(0, 0, -1), ivec3(0, 0, 1),
		ivec3(-1, -1, -1), ivec3(-1, -1, 0), ivec3(-1, -1, 1), ivec3(-1, 0, -1), ivec3(-1, 0, 1),
		ivec3(-1, 1, -1), ivec3(-1, 1, 0), ivec3(-1, 1, 1), ivec3(0, -1, -1), ivec3(0, -1, 1),
		ivec3(0, 1, -1), ivec3(0, 1, 1), ivec3(1, -1, -1), ivec3(1, -1, 0), ivec3(1, -1, 1),
		ivec3(1, 0, -1), ivec3(1, 0, 1), ivec3(1, 1, -1), ivec3(1, 1, 0), ivec3(1, 1, 1));

struct HDDAGIRigidHit {
	uint instance;
	float distance;
	ivec3 cell;
	ivec3 side;
	vec3 local_position;
	vec3 position;
};

uint hddagi_rigid_cell_index(ivec3 cell, uvec3 dimensions) {
	return uint(cell.x) + dimensions.x * (uint(cell.y) + dimensions.y * uint(cell.z));
}

bool hddagi_rigid_cell_valid(ivec3 cell, uvec3 dimensions) {
	return all(greaterThanEqual(cell, ivec3(0))) && all(lessThan(cell, ivec3(dimensions)));
}

bool hddagi_rigid_cell_occupied(HDDAGIRigidInstance instance, ivec3 cell) {
	if (!hddagi_rigid_cell_valid(cell, instance.grid.xyz)) {
		return false;
	}
	uint bit_index = hddagi_rigid_cell_index(cell & 3, uvec3(4));
	uint address = instance.grid.w + hddagi_rigid_cell_index(cell >> 2, instance.grid.xyz >> 2u) * 2u + (bit_index >> 5u);
	return (hddagi_rigid_geometry.data[address] & (1u << (bit_index & 31u))) != 0u;
}

vec3 hddagi_rigid_decode(uint packed) {
	uvec4 channels = (uvec4(packed) >> uvec4(0, 9, 18, 27)) & uvec4(511, 511, 511, 31);
	return vec3(channels.xyz) * exp2(float(channels.w) - 24.0);
}

uint hddagi_rigid_encode(vec3 rgb) {
	rgb = clamp(rgb, vec3(0.0), vec3(uintBitsToFloat(0x477f8000u)));
	float largest = max(uintBitsToFloat(0x37800000u), max(rgb.x, max(rgb.y, rgb.z)));
	float bias = uintBitsToFloat((floatBitsToUint(largest) + 0x07804000u) & 0x7f800000u);
	uvec3 mantissa = floatBitsToUint(rgb + bias);
	uint exponent = (floatBitsToUint(bias) << 4u) + 0x10000000u;
	return exponent | (mantissa.b << 18u) | (mantissa.g << 9u) | (mantissa.r & 511u);
}

vec3 hddagi_rigid_decode_normal(uint packed) {
	vec2 oct = vec2((uvec2(packed) >> uvec2(16, 24)) & 255u) / 255.0 * 2.0 - 1.0;
	vec3 normal = vec3(oct, 1.0 - abs(oct.x) - abs(oct.y));
	float correction = clamp(-normal.z, 0.0, 1.0);
	normal.xy += mix(vec2(correction), vec2(-correction), greaterThanEqual(normal.xy, vec2(0.0)));
	return normalize(normal);
}

// The direction is deliberately not normalized after world_to_cell, so all
// traversal distances retain the caller's world-space ray parameter.
bool hddagi_rigid_ray_box_inverse(vec3 origin, vec3 inverse_direction, bvec3 parallel, vec3 bounds_min, vec3 bounds_max, out float entry, out float exit_distance) {
	// Parallel rays on the box boundary are inside. Avoid infinity * zero.
	entry = -1e30;
	exit_distance = 1e30;
	bvec3 outside = bvec3(origin.x < bounds_min.x || origin.x > bounds_max.x,
			origin.y < bounds_min.y || origin.y > bounds_max.y,
			origin.z < bounds_min.z || origin.z > bounds_max.z);
	if (any(bvec3(parallel.x && outside.x, parallel.y && outside.y, parallel.z && outside.z))) {
		return false;
	}
	vec3 a = (bounds_min - origin) * inverse_direction;
	vec3 b = (bounds_max - origin) * inverse_direction;
	vec3 near_time = mix(min(a, b), vec3(-1e30), parallel);
	vec3 far_time = mix(max(a, b), vec3(1e30), parallel);
	entry = max(-1e30, max(near_time.x, max(near_time.y, near_time.z)));
	exit_distance = min(1e30, min(far_time.x, min(far_time.y, far_time.z)));
	return exit_distance >= entry;
}

bool hddagi_rigid_ray_box(vec3 origin, vec3 direction, vec3 bounds_min, vec3 bounds_max, out float entry, out float exit_distance) {
	bvec3 parallel = lessThan(abs(direction), vec3(1e-12));
	vec3 inverse_direction = 1.0 / mix(direction, vec3(1.0), parallel);
	return hddagi_rigid_ray_box_inverse(origin, inverse_direction, parallel, bounds_min, bounds_max, entry, exit_distance);
}

// Conservative coarse test for a group of segments, against all instances.
bool hddagi_rigid_may_overlap(vec3 bounds_min, vec3 bounds_max) {
	if (hddagi_rigid_instances.header.x == 0u) {
		return false;
	}
	HDDAGIRigidBVHNode root = hddagi_rigid_bvh.data[0];
	return all(lessThanEqual(bounds_min, root.bounds_max)) && all(greaterThanEqual(bounds_max, root.bounds_min));
}

bool hddagi_rigid_trace_local(uint instance_index, vec3 origin_world, vec3 direction_world, float t_min, float t_max, bool exclude_origin_cell, bool any_hit, vec3 receiver_normal, out HDDAGIRigidHit hit) {
	HDDAGIRigidInstance instance = hddagi_rigid_instances.data[instance_index];
	vec3 origin = (instance.world_to_cell * vec4(origin_world, 1.0)).xyz;
	vec3 direction = mat3(instance.world_to_cell) * direction_world;
	vec3 world_bias = vec3(0.0);
	float distance_bias = 0.0;
	if (dot(receiver_normal, receiver_normal) > 0.0) {
		// A surface lies inside its conservative voxel shell. Excluding only one
		// cell makes outward grazing rays hit the next cell on the same surface.
		// Bias only the nearby surface of this instance; other objects keep the original ray.
		exclude_origin_cell = false;
		if (dot(receiver_normal, direction_world) > 1e-4) {
			ivec3 receiver_cell = ivec3(floor(origin));
			vec3 cell_normal = transpose(mat3(instance.cell_to_world)) * receiver_normal;
			vec3 absolute_normal = abs(cell_normal);
			int axis = absolute_normal.y > absolute_normal.x ? 1 : 0;
			axis = absolute_normal.z > absolute_normal[axis] ? 2 : axis;
			ivec3 adjacent = ivec3(0);
			adjacent[axis] = cell_normal[axis] > 0.0 ? 1 : -1;
			// Rasterization samples voxel centers. On a sloped surface the actual
			// receiver can be in an empty cell next to its captured surface voxel.
			bool near_surface = hddagi_rigid_cell_occupied(instance, receiver_cell) ||
					hddagi_rigid_cell_occupied(instance, receiver_cell + adjacent) ||
					hddagi_rigid_cell_occupied(instance, receiver_cell - adjacent);
			if (near_surface) {
				vec3 local_normal = mat3(instance.world_to_cell) * receiver_normal;
				vec3 local_bias = local_normal * (1.1 / max(abs(local_normal.x), max(abs(local_normal.y), abs(local_normal.z))));
				world_bias = mat3(instance.cell_to_world) * local_bias;
				origin += local_bias;
				// Keep nearest-hit ordering and the static endpoint limit in the
				// original world ray's parameter, despite the parallel normal offset.
				distance_bias = dot(world_bias, direction_world);
				t_min = max(0.0, t_min - distance_bias);
				t_max -= distance_bias;
			}
		}
	}
	bvec3 parallel = lessThan(abs(direction), vec3(1e-12));
	bvec3 positive_direction = greaterThan(direction, vec3(0.0));
	vec3 inverse_direction = 1.0 / mix(direction, vec3(1.0), parallel);
	vec3 direction_sign = sign(direction);
	float entry;
	float exit_distance;
	if (!hddagi_rigid_ray_box_inverse(origin, inverse_direction, parallel, vec3(0.0), vec3(instance.grid.xyz), entry, exit_distance)) {
		return false;
	}
	float distance = max(entry, t_min);
	exit_distance = min(exit_distance, t_max);
	ivec3 origin_cell = ivec3(floor(origin));
	ivec3 previous_region = ivec3(-1);
	ivec3 previous_block = ivec3(-1);
	uint region_occupied = 0u;
	uvec2 block_bits = uvec2(0u);
	while (distance < exit_distance) {
		vec3 position = origin + direction * distance + direction_sign * 0.0001;
		ivec3 cell = ivec3(floor(position));
		if (!hddagi_rigid_cell_valid(cell, instance.grid.xyz)) {
			break;
		}
		ivec3 region = cell >> 3;
		if (any(notEqual(region, previous_region))) {
			region_occupied = hddagi_rigid_geometry.data[instance.offsets.x + hddagi_rigid_cell_index(region, instance.grid.xyz >> 3u)];
			previous_region = region;
		}
		int step_size = 8;
		if (region_occupied != 0u) {
			ivec3 block = cell >> 2;
			if (any(notEqual(block, previous_block))) {
				uint address = instance.grid.w + hddagi_rigid_cell_index(block, instance.grid.xyz >> 2u) * 2u;
				block_bits = uvec2(hddagi_rigid_geometry.data[address], hddagi_rigid_geometry.data[address + 1u]);
				previous_block = block;
			}
			step_size = 4;
			if (any(notEqual(block_bits, uvec2(0u)))) {
				uint bit_index = hddagi_rigid_cell_index(cell & 3, uvec3(4));
				bool occupied = (block_bits[bit_index >> 5u] & (1u << (bit_index & 31u))) != 0u;
				// Only the origin voxel is excluded; the rest of a concave instance
				// and its frame remain valid occluders.
				if (occupied && (!exclude_origin_cell || any(notEqual(cell, origin_cell)))) {
					if (any_hit) {
						return true;
					}
					vec3 near_face = mix(vec3(cell + 1), vec3(cell), positive_direction);
					vec3 near_time = (near_face - origin) * inverse_direction;
					near_time = mix(near_time, vec3(-1e30), parallel);
					int axis = near_time.y > near_time.x ? 1 : 0;
					axis = near_time.z > near_time[axis] ? 2 : axis;
					hit.instance = instance_index;
					float local_distance = max(distance, near_time[axis]);
					hit.distance = local_distance + distance_bias;
					hit.cell = cell;
					hit.side = ivec3(0);
					hit.side[axis] = direction[axis] > 0.0 ? -1 : 1;
					if (dot(receiver_normal, direction_world) < 0.0 && all(equal(cell, origin_cell))) {
						// An inward surface ray starts inside the voxel shell. Its
						// extrapolated box entry can be a tangent face; use the known
						// receiver face instead. Normals are covectors, unlike the bias.
						vec3 local_surface_normal = transpose(mat3(instance.cell_to_world)) * receiver_normal;
						vec3 absolute_normal = abs(local_surface_normal);
						axis = absolute_normal.y > absolute_normal.x ? 1 : 0;
						axis = absolute_normal.z > absolute_normal[axis] ? 2 : axis;
						hit.side = ivec3(0);
						hit.side[axis] = local_surface_normal[axis] > 0.0 ? 1 : -1;
					}
					hit.local_position = origin + direction * local_distance;
					hit.position = origin_world + world_bias + direction_world * local_distance;
					return true;
				}
				step_size = 1;
			}
		}
		ivec3 base = cell & ivec3(-step_size); // Step sizes are powers of two: 1, 4, 8.
		vec3 next_boundary = vec3(base) + mix(vec3(0.0), vec3(float(step_size)), positive_direction);
		vec3 next_time = (next_boundary - origin) * inverse_direction;
		next_time = mix(next_time, vec3(1e30), parallel);
		distance = max(min(next_time.x, min(next_time.y, next_time.z)), uintBitsToFloat(floatBitsToUint(distance) + 1u));
	}
	return false;
}

bool hddagi_rigid_trace_internal(vec3 origin, vec3 direction, float t_min, float t_max, bool exclude_origin_cell, bool any_hit, vec3 receiver_normal, out HDDAGIRigidHit hit) {
	if (hddagi_rigid_instances.header.x == 0u || t_max <= t_min) {
		return false;
	}
	bvec3 parallel = lessThan(abs(direction), vec3(1e-12));
	vec3 inverse_direction = 1.0 / mix(direction, vec3(1.0), parallel);
	bool found = false;
	uint node_index = 0u;
	while (node_index < hddagi_rigid_instances.header.y) {
		HDDAGIRigidBVHNode node = hddagi_rigid_bvh.data[node_index];
		float entry;
		float exit_distance;
		if (!hddagi_rigid_ray_box_inverse(origin, inverse_direction, parallel, node.bounds_min, node.bounds_max, entry, exit_distance) || entry >= t_max || exit_distance <= t_min) {
			node_index = node.escape;
			continue;
		}
		if (node.instance == 0xffffffffu) {
			node_index++;
			continue;
		}
		HDDAGIRigidHit candidate;
		if (hddagi_rigid_trace_local(node.instance, origin, direction, t_min, t_max, exclude_origin_cell, any_hit, receiver_normal, candidate)) {
			if (any_hit) {
				return true;
			}
			hit = candidate;
			t_max = candidate.distance;
			found = true;
		}
		node_index = node.escape;
	}
	return found;
}

bool hddagi_rigid_trace(vec3 origin, vec3 direction, float t_min, float t_max, bool exclude_origin_cell, out HDDAGIRigidHit hit) {
	return hddagi_rigid_trace_internal(origin, direction, t_min, t_max, exclude_origin_cell, false, vec3(0.0), hit);
}

bool hddagi_rigid_trace(vec3 origin, vec3 direction, float t_min, float t_max, out HDDAGIRigidHit hit) {
	return hddagi_rigid_trace(origin, direction, t_min, t_max, true, hit);
}

bool hddagi_rigid_trace_surface(vec3 origin, vec3 direction, float t_min, float t_max, vec3 receiver_normal, out HDDAGIRigidHit hit) {
	return hddagi_rigid_trace_internal(origin, direction, t_min, t_max, false, false, receiver_normal, hit);
}

bool hddagi_rigid_dirty_segment(vec3 origin, vec3 endpoint) {
	if (hddagi_rigid_instances.header.w == 0u) {
		return false;
	}
	float entry;
	float exit_distance;
	return hddagi_rigid_ray_box(origin, endpoint - origin, hddagi_rigid_instances.dirty_min.xyz, hddagi_rigid_instances.dirty_max.xyz, entry, exit_distance) && entry < 1.0 && exit_distance > 0.0;
}

bool hddagi_rigid_dirty_cone(vec3 origin, vec3 direction, float max_distance, float angular_padding) {
	if (hddagi_rigid_instances.header.w == 0u) {
		return false;
	}
	vec3 center = (hddagi_rigid_instances.dirty_min.xyz + hddagi_rigid_instances.dirty_max.xyz) * 0.5;
	float padding = length(center - origin) * angular_padding;
	float entry;
	float exit_distance;
	return hddagi_rigid_ray_box(origin, direction, hddagi_rigid_instances.dirty_min.xyz - vec3(padding), hddagi_rigid_instances.dirty_max.xyz + vec3(padding), entry, exit_distance) && entry < max_distance && exit_distance > 0.0;
}

float hddagi_rigid_segment_visibility(vec3 origin, vec3 endpoint, vec3 receiver_normal) {
	if (hddagi_rigid_instances.header.x == 0u) {
		return 1.0;
	}
	vec3 delta = endpoint - origin;
	float distance = length(delta);
	if (distance <= HDDAGI_RIGID_RAY_EPSILON * 2.0) {
		return 1.0;
	}
	HDDAGIRigidHit hit;
	return hddagi_rigid_trace_internal(origin, delta / distance, HDDAGI_RIGID_RAY_EPSILON, distance - HDDAGI_RIGID_RAY_EPSILON, true, true, receiver_normal, hit) ? 0.0 : 1.0;
}

float hddagi_rigid_segment_visibility(vec3 origin, vec3 endpoint) {
	return hddagi_rigid_segment_visibility(origin, endpoint, vec3(0.0));
}

bool hddagi_rigid_sample_cell(HDDAGIRigidInstance instance, ivec3 cell, vec3 endpoint, vec3 normal, uvec2 facing_bits, out vec3 radiance, out float weight, out uint metadata) {
	radiance = vec3(0.0);
	weight = 0.0;
	metadata = 0u;
	if (!hddagi_rigid_cell_valid(cell, instance.grid.xyz)) {
		return false;
	}
	uint index = hddagi_rigid_cell_index(cell, instance.grid.xyz);
	uvec4 surface = hddagi_rigid_surfaces.data[instance.offsets.y + index];
	metadata = surface.z;
	if ((metadata & HDDAGI_RIGID_LIGHT_VALID) == 0u) {
		return false;
	}
	// The hit normal is a signed grid axis: alignment is exactly zero or one.
	if ((surface.w & facing_bits.y) != facing_bits.x) {
		return false;
	}
	vec3 delta = vec3(cell) + 0.5 - endpoint;
	float normal_distance = dot(delta, normal);
	vec3 tangent = delta - normal_distance * normal;
	weight = max(0.0, 1.0 - abs(normal_distance - 0.75) / 1.25) * max(0.0, 1.0 - dot(tangent, tangent) / 2.25);
	if (weight <= 0.0) {
		return false;
	}
	radiance = hddagi_rigid_decode(hddagi_rigid_lighting.data[instance.offsets.z + index]);
	return true;
}

vec3 hddagi_rigid_sample_radiance(HDDAGIRigidHit hit) {
	HDDAGIRigidInstance instance = hddagi_rigid_instances.data[hit.instance];
	ivec3 anchor = hit.cell + hit.side;
	uint axis = hit.side.x != 0 ? 0u : (hit.side.y != 0 ? 1u : 2u);
	uint face = axis * 2u + (hit.side[axis] > 0 ? 1u : 0u);
	uvec2 facing_bits = uvec2(1u << face, 3u << (axis * 2u));
	vec3 light;
	float weight;
	uint metadata;
	if (!hddagi_rigid_sample_cell(instance, anchor, hit.local_position, vec3(hit.side), facing_bits, light, weight, metadata)) {
		// Corners may not have a light cell directly across the entered face.
		float best_weight = 0.0;
		for (int i = 0; i < 26; i++) {
			ivec3 candidate = hit.cell + HDDAGI_RIGID_NEIGHBOURS[i];
			vec3 candidate_light;
			float candidate_weight;
			uint candidate_metadata;
			if (hddagi_rigid_sample_cell(instance, candidate, hit.local_position, vec3(hit.side), facing_bits, candidate_light, candidate_weight, candidate_metadata) && candidate_weight > best_weight) {
				anchor = candidate;
				light = candidate_light;
				weight = candidate_weight;
				metadata = candidate_metadata;
				best_weight = candidate_weight;
			}
		}
		if (best_weight == 0.0) {
			return vec3(0.0);
		}
	}
	vec3 radiance_sum = light * weight;
	float weight_sum = weight;
	uint neighbours = metadata & (HDDAGI_RIGID_LIGHT_VALID - 1u);
	while (neighbours != 0u) {
		uint bit = findLSB(neighbours);
		if (hddagi_rigid_sample_cell(instance, anchor + HDDAGI_RIGID_NEIGHBOURS[bit], hit.local_position, vec3(hit.side), facing_bits, light, weight, metadata)) {
			radiance_sum += light * weight;
			weight_sum += weight;
		}
		neighbours &= ~(1u << bit);
	}
	return radiance_sum / weight_sum * instance.bounds_min.w;
}

vec3 hddagi_rigid_hit_normal(HDDAGIRigidHit hit) {
	return normalize(transpose(mat3(hddagi_rigid_instances.data[hit.instance].world_to_cell)) * vec3(hit.side));
}

vec3 hddagi_rigid_hit_albedo(HDDAGIRigidHit hit) {
	HDDAGIRigidInstance instance = hddagi_rigid_instances.data[hit.instance];
	ivec3 cell = hit.cell + hit.side;
	if (!hddagi_rigid_cell_valid(cell, instance.grid.xyz)) {
		return vec3(0.0);
	}
	uint packed = hddagi_rigid_surfaces.data[instance.offsets.y + hddagi_rigid_cell_index(cell, instance.grid.xyz)].x;
	return vec3((uvec3(packed) >> uvec3(0, 5, 11)) & uvec3(31, 63, 31)) / vec3(31.0, 63.0, 31.0);
}

#endif // HDDAGI_RIGID_INC_GLSL
