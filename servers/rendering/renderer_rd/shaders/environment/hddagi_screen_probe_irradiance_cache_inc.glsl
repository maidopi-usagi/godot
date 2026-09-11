#ifndef HDDAGI_SCREEN_PROBE_IRRADIANCE_CACHE_INC_GLSL
#define HDDAGI_SCREEN_PROBE_IRRADIANCE_CACHE_INC_GLSL

#ifndef HDDAGI_IRRADIANCE_CACHE_SET
#error "HDDAGI_IRRADIANCE_CACHE_SET must name the irradiance-cache descriptor set"
#endif

// Fixed descriptor ABI shared by the screen-probe query variants and the
// maintenance shader. The host may expose fewer live entries/requests through
// control, but the allocations always use these hard limits.
#define HDDAGI_IRRADIANCE_CACHE_CASCADE_COUNT 12
#define HDDAGI_IRRADIANCE_CACHE_GRID_RESOLUTION 32
#define HDDAGI_IRRADIANCE_CACHE_GRID_CELL_COUNT 32768
#define HDDAGI_IRRADIANCE_CACHE_GRID_CAPACITY 393216
#define HDDAGI_IRRADIANCE_CACHE_ENTRY_CAPACITY 16384
#define HDDAGI_IRRADIANCE_CACHE_REQUEST_CAPACITY 65536
#define HDDAGI_IRRADIANCE_CACHE_ACCUM_STRIDE 16
#define HDDAGI_IRRADIANCE_CACHE_SPATIAL_STRIDE 3u
#define HDDAGI_IRRADIANCE_CACHE_MAX_SAMPLES_PER_ENTRY_PER_FRAME 4096

const uint HDDAGI_IRRADIANCE_CACHE_EMPTY = 0xfffffffeu;
const uint HDDAGI_IRRADIANCE_CACHE_LOCKED = 0xffffffffu;
const uint HDDAGI_IRRADIANCE_CACHE_VOTE_LOCK = 0x80000000u;
const uint HDDAGI_IRRADIANCE_CACHE_VOTE_COUNT_MASK = 0x7fffffffu;
const float HDDAGI_IRRADIANCE_CACHE_ACCUM_SCALE = 256.0;
const float HDDAGI_IRRADIANCE_CACHE_REPRESENTATIVE_DISTANCE_SCALE = 1.5;
const float HDDAGI_IRRADIANCE_CACHE_REPRESENTATIVE_NORMAL_THRESHOLD = 0.25;
const float HDDAGI_IRRADIANCE_CACHE_MIN_NORMALIZATION = 0.25;
const float HDDAGI_IRRADIANCE_CACHE_RADIANCE_CLAMP = 2047.0;
// Cap the effective temporal history rather than the diagnostic sample count.
// Dense entries can still react in one update because their new batch carries
// proportionally more weight, while sparse stochastic entries converge without
// following every individual refresh sample.
const uint HDDAGI_IRRADIANCE_CACHE_HISTORY_SAMPLE_CAP = 16u;
const uint HDDAGI_IRRADIANCE_CACHE_MULTIBOUNCE_HISTORY_SAMPLE_CAP = 8u;
const uint HDDAGI_IRRADIANCE_CACHE_HWRT_HISTORY_SAMPLE_CAP = 32u;

layout(set = HDDAGI_IRRADIANCE_CACHE_SET, binding = 0, std430) coherent restrict buffer HDDAGIIrradianceCacheMetaBuffer {
	uint hddagi_irradiance_cache_meta[4];
};

// x is an entry index, EMPTY, or LOCKED. y is the published entry generation.
layout(set = HDDAGI_IRRADIANCE_CACHE_SET, binding = 1, std430) coherent restrict buffer HDDAGIIrradianceCacheGridBuffer {
	uvec2 hddagi_irradiance_cache_grid[HDDAGI_IRRADIANCE_CACHE_GRID_CAPACITY];
};

// xyz is the exact (unwrapped) world cell; w is its flattened grid slot.
layout(set = HDDAGI_IRRADIANCE_CACHE_SET, binding = 2, std430) coherent restrict buffer HDDAGIIrradianceCacheEntryCellsBuffer {
	ivec4 hddagi_irradiance_cache_entry_cells[HDDAGI_IRRADIANCE_CACHE_ENTRY_CAPACITY];
};

// last_used, generation, sample_count, rank.
layout(set = HDDAGI_IRRADIANCE_CACHE_SET, binding = 3, std430) coherent restrict buffer HDDAGIIrradianceCacheEntryStateBuffer {
	uvec4 hddagi_irradiance_cache_entry_state[HDDAGI_IRRADIANCE_CACHE_ENTRY_CAPACITY];
};

// Three radiance moments and one normalization moment per entry. All four use
// the first-order basis [1, normal]. HWRT stores incident irradiance / PI;
// software retains its outgoing endpoint-radiance convention.
layout(set = HDDAGI_IRRADIANCE_CACHE_SET, binding = 4, std430) coherent restrict buffer HDDAGIIrradianceCacheSHBuffer {
	vec4 hddagi_irradiance_cache_sh[4 * HDDAGI_IRRADIANCE_CACHE_ENTRY_CAPACITY];
};

// Per entry: position/generation, normal/cell size, then the HWRT instance
// slot/surface version (low/high) and last lighting update frame, as uint bits.
layout(set = HDDAGI_IRRADIANCE_CACHE_SET, binding = 5, std430) coherent restrict buffer HDDAGIIrradianceCacheSpatialBuffer {
	vec4 hddagi_irradiance_cache_spatial[HDDAGI_IRRADIANCE_CACHE_SPATIAL_STRIDE * HDDAGI_IRRADIANCE_CACHE_ENTRY_CAPACITY];
};

// Same layout as spatial. AGE publishes the selected proposal into spatial.
layout(set = HDDAGI_IRRADIANCE_CACHE_SET, binding = 6, std430) coherent restrict buffer HDDAGIIrradianceCacheProposalBuffer {
	vec4 hddagi_irradiance_cache_proposals[HDDAGI_IRRADIANCE_CACHE_SPATIAL_STRIDE * HDDAGI_IRRADIANCE_CACHE_ENTRY_CAPACITY];
};

layout(set = HDDAGI_IRRADIANCE_CACHE_SET, binding = 7, std430) coherent restrict buffer HDDAGIIrradianceCacheVoteCountBuffer {
	uint hddagi_irradiance_cache_vote_count[HDDAGI_IRRADIANCE_CACHE_ENTRY_CAPACITY];
};

layout(set = HDDAGI_IRRADIANCE_CACHE_SET, binding = 8, std430) coherent restrict buffer HDDAGIIrradianceCacheFreePoolBuffer {
	uint hddagi_irradiance_cache_free_pool[HDDAGI_IRRADIANCE_CACHE_ENTRY_CAPACITY];
};

// Per request: position.xyz/entry bits, normal.xyz/generation bits, radiance.rgb.
// HWRT radiance.w packs the 24-bit instance slot and 8-bit (sample weight - 1).
layout(set = HDDAGI_IRRADIANCE_CACHE_SET, binding = 9, std430) coherent restrict buffer HDDAGIIrradianceCacheRequestBuffer {
	vec4 hddagi_irradiance_cache_requests[3 * HDDAGI_IRRADIANCE_CACHE_REQUEST_CAPACITY];
};

// RGB basis moments occupy [0, 12), sample count is [12], and the accumulated
// normal used to normalize those moments occupies [13, 16).
layout(set = HDDAGI_IRRADIANCE_CACHE_SET, binding = 10, std430) coherent restrict buffer HDDAGIIrradianceCacheAccumulationBuffer {
	int hddagi_irradiance_cache_accumulation[HDDAGI_IRRADIANCE_CACHE_ACCUM_STRIDE * HDDAGI_IRRADIANCE_CACHE_ENTRY_CAPACITY];
};

layout(set = HDDAGI_IRRADIANCE_CACHE_SET, binding = 11, std140) uniform HDDAGIIrradianceCacheParameters {
	vec4 camera_min_cell;
	uvec4 control; // frame, capacity, max requests, grid count.
	uvec4 training; // flags, representative-update stride, sky mode, fast lighting refresh.
	// Constant color.rgb or texture border in x; w is sky energy.
	vec4 sky_color_or_border_energy;
}
hddagi_irradiance_cache_params;

// Stable slots shared with the HWRT TLAS. Software binds an unused zero entry.
layout(set = HDDAGI_IRRADIANCE_CACHE_SET, binding = 12, std430) restrict readonly buffer HDDAGIIrradianceCacheGeometryBuffer {
	uvec4 hddagi_irradiance_cache_geometry[];
};

const uint HDDAGI_IRRADIANCE_CACHE_TRAINING_MULTIBOUNCE = 1u << 0u;
const uint HDDAGI_IRRADIANCE_CACHE_HWRT = 1u << 1u;

struct HDDAGIIrradianceCacheLookup {
	bool valid;
	bool has_radiance;
	bool needs_refresh;
	bool representative_valid;
	uint entry_index;
	uint generation;
	uint cascade;
	uint sample_count;
	float cell_size;
	vec3 radiance;
	vec3 sample_position;
	vec3 sample_normal;
	uvec3 surface_key;
};

uint hddagi_irradiance_cache_hash(uint value) {
	value ^= value >> 16u;
	value *= 0x7feb352du;
	value ^= value >> 15u;
	value *= 0x846ca68bu;
	value ^= value >> 16u;
	return value;
}

uint hddagi_irradiance_cache_hash_combine(uint seed, uint value) {
	return hddagi_irradiance_cache_hash(seed ^ (value + 0x9e3779b9u + (seed << 6u) + (seed >> 2u)));
}

bool hddagi_irradiance_cache_is_finite(vec3 value) {
	return !any(isnan(value)) && !any(isinf(value));
}

vec3 hddagi_irradiance_cache_safe_normalize(vec3 value) {
	float length_squared = dot(value, value);
	if (!(length_squared > 1e-12) || !hddagi_irradiance_cache_is_finite(value)) {
		return vec3(0.0, 1.0, 0.0);
	}
	return value * inversesqrt(length_squared);
}

uint hddagi_irradiance_cache_capacity() {
	return min(hddagi_irradiance_cache_params.control.y, uint(HDDAGI_IRRADIANCE_CACHE_ENTRY_CAPACITY));
}

uint hddagi_irradiance_cache_request_limit() {
	return min(hddagi_irradiance_cache_params.control.z, uint(HDDAGI_IRRADIANCE_CACHE_REQUEST_CAPACITY));
}

uint hddagi_irradiance_cache_grid_count() {
	return min(hddagi_irradiance_cache_params.control.w, uint(HDDAGI_IRRADIANCE_CACHE_GRID_CAPACITY));
}

bool hddagi_irradiance_cache_multibounce_enabled() {
	return (hddagi_irradiance_cache_params.training.x & HDDAGI_IRRADIANCE_CACHE_TRAINING_MULTIBOUNCE) != 0u;
}

bool hddagi_irradiance_cache_hwrt() {
	return (hddagi_irradiance_cache_params.training.x & HDDAGI_IRRADIANCE_CACHE_HWRT) != 0u;
}

uvec3 hddagi_irradiance_cache_surface_key(uint entry_index) {
	return floatBitsToUint(hddagi_irradiance_cache_spatial[entry_index * HDDAGI_IRRADIANCE_CACHE_SPATIAL_STRIDE + 2u].xyz);
}

bool hddagi_irradiance_cache_geometry_current(uint entry_index) {
	if (!hddagi_irradiance_cache_hwrt()) {
		return true;
	}
	uvec3 key = hddagi_irradiance_cache_surface_key(entry_index);
	return key.x < uint(hddagi_irradiance_cache_geometry.length()) && any(notEqual(key.yz, uvec2(0u))) &&
			all(equal(key.yz, hddagi_irradiance_cache_geometry[key.x].zw));
}

uint hddagi_irradiance_cache_training_stride() {
	return max(hddagi_irradiance_cache_params.training.y, 1u);
}

HDDAGIIrradianceCacheLookup hddagi_irradiance_cache_empty_lookup() {
	HDDAGIIrradianceCacheLookup result;
	result.valid = false;
	result.has_radiance = false;
	result.needs_refresh = true;
	result.representative_valid = false;
	result.entry_index = HDDAGI_IRRADIANCE_CACHE_LOCKED;
	result.generation = 0u;
	result.cascade = 0u;
	result.sample_count = 0u;
	result.cell_size = 0.0;
	result.radiance = vec3(0.0);
	result.sample_position = vec3(0.0);
	result.sample_normal = vec3(0.0, 1.0, 0.0);
	result.surface_key = uvec3(0u);
	return result;
}

uint hddagi_irradiance_cache_select_cascade(vec3 position, float minimum_cell_size, uint cascade_count) {
	vec3 camera_delta = abs(position - hddagi_irradiance_cache_params.camera_min_cell.xyz);
	float chebyshev_distance = max(camera_delta.x, max(camera_delta.y, camera_delta.z));
	float maximum_distance = ldexp(15.0 * minimum_cell_size, int(cascade_count - 1u));
	if (chebyshev_distance > maximum_distance) {
		return cascade_count;
	}
	float level_ratio = max(chebyshev_distance / max(15.0 * minimum_cell_size, 1e-6), 1.0);
	uint cascade = uint(max(ceil(log2(level_ratio)), 0.0));
	return cascade;
}

uint hddagi_irradiance_cache_flatten_slot(uint cascade, ivec3 world_cell) {
	// Keep a world cell's physical slot stable while the camera moves. Cells
	// entering opposite sides of the camera-centered window differ by exactly
	// the grid resolution and therefore replace only the outgoing toroidal slice.
	uvec3 wrapped = uvec3(world_cell) & uvec3(HDDAGI_IRRADIANCE_CACHE_GRID_RESOLUTION - 1);
	uint local_slot = wrapped.x + wrapped.y * uint(HDDAGI_IRRADIANCE_CACHE_GRID_RESOLUTION) + wrapped.z * uint(HDDAGI_IRRADIANCE_CACHE_GRID_RESOLUTION * HDDAGI_IRRADIANCE_CACHE_GRID_RESOLUTION);
	return cascade * uint(HDDAGI_IRRADIANCE_CACHE_GRID_CELL_COUNT) + local_slot;
}

uint hddagi_irradiance_cache_next_generation() {
	uint generation = atomicAdd(hddagi_irradiance_cache_meta[2], 1u) + 1u;
	if (generation == 0u) {
		generation = atomicAdd(hddagi_irradiance_cache_meta[2], 1u) + 1u;
	}
	return generation;
}

bool hddagi_irradiance_cache_pop_free(out uint entry_index) {
	entry_index = HDDAGI_IRRADIANCE_CACHE_LOCKED;
	if (hddagi_irradiance_cache_hwrt()) {
		// AGE is the only producer and never overlaps queries. Failed pops may
		// temporarily underflow the unsigned count; restore them without ever
		// indexing the pool. All successful reservations are unique.
		uint count = atomicAdd(hddagi_irradiance_cache_meta[0], 0xffffffffu);
		if (count == 0u || count > hddagi_irradiance_cache_capacity()) {
			atomicAdd(hddagi_irradiance_cache_meta[0], 1u);
			return false;
		}
		entry_index = hddagi_irradiance_cache_free_pool[count - 1u];
		return entry_index < hddagi_irradiance_cache_capacity();
	}
	uint count = hddagi_irradiance_cache_meta[0];
	for (uint attempt = 0u; attempt < 32u; attempt++) {
		if (count == 0u) {
			return false;
		}
		uint previous = atomicCompSwap(hddagi_irradiance_cache_meta[0], count, count - 1u);
		if (previous == count) {
			memoryBarrierBuffer();
			entry_index = hddagi_irradiance_cache_free_pool[count - 1u];
			return entry_index < hddagi_irradiance_cache_capacity();
		}
		count = previous;
	}
	return false;
}

bool hddagi_irradiance_cache_push_free(uint entry_index) {
	uint capacity = hddagi_irradiance_cache_capacity();
	// During AGE, only producers access the stack, so atomicAdd reserves a unique
	// slot without a retry cap that could strand a successfully evicted entry.
	uint count = atomicAdd(hddagi_irradiance_cache_meta[0], 1u);
	if (count < capacity) {
		hddagi_irradiance_cache_free_pool[count] = entry_index;
		memoryBarrierBuffer();
		return true;
	}
	// Defensive rollback for a double-free or corrupt count.
	atomicAdd(hddagi_irradiance_cache_meta[0], 0xffffffffu);
	return false;
}

void hddagi_irradiance_cache_clear_entry_payload(uint entry_index) {
	uint sh_base = entry_index * 4u;
	hddagi_irradiance_cache_sh[sh_base + 0u] = vec4(0.0);
	hddagi_irradiance_cache_sh[sh_base + 1u] = vec4(0.0);
	hddagi_irradiance_cache_sh[sh_base + 2u] = vec4(0.0);
	hddagi_irradiance_cache_sh[sh_base + 3u] = vec4(0.0);

	uint spatial_base = entry_index * HDDAGI_IRRADIANCE_CACHE_SPATIAL_STRIDE;
	hddagi_irradiance_cache_spatial[spatial_base + 0u] = vec4(0.0);
	hddagi_irradiance_cache_spatial[spatial_base + 1u] = vec4(0.0);
	hddagi_irradiance_cache_spatial[spatial_base + 2u] = vec4(0.0);
	hddagi_irradiance_cache_proposals[spatial_base + 0u] = vec4(0.0);
	hddagi_irradiance_cache_proposals[spatial_base + 1u] = vec4(0.0);
	hddagi_irradiance_cache_proposals[spatial_base + 2u] = vec4(0.0);
	hddagi_irradiance_cache_vote_count[entry_index] = 0u;

	uint accumulation_base = entry_index * uint(HDDAGI_IRRADIANCE_CACHE_ACCUM_STRIDE);
	for (uint coefficient = 0u; coefficient < uint(HDDAGI_IRRADIANCE_CACHE_ACCUM_STRIDE); coefficient++) {
		hddagi_irradiance_cache_accumulation[accumulation_base + coefficient] = 0;
	}
}

bool hddagi_irradiance_cache_evaluate(uint entry_index, vec3 normal, out vec3 r_radiance) {
	r_radiance = vec3(0.0);
	vec4 basis = vec4(1.0, normal);
	uint sh_base = entry_index * 4u;
	float normalization = dot(hddagi_irradiance_cache_sh[sh_base + 3u], basis);
	if (!(normalization > HDDAGI_IRRADIANCE_CACHE_MIN_NORMALIZATION) || isnan(normalization) || isinf(normalization)) {
		return false;
	}
	vec3 radiance = vec3(
							dot(hddagi_irradiance_cache_sh[sh_base + 0u], basis),
							dot(hddagi_irradiance_cache_sh[sh_base + 1u], basis),
							dot(hddagi_irradiance_cache_sh[sh_base + 2u], basis)) /
			normalization;
	if (!hddagi_irradiance_cache_is_finite(radiance)) {
		return false;
	}
	r_radiance = max(radiance, vec3(0.0));
	return true;
}

bool hddagi_irradiance_cache_load_representative(uint entry_index, uint generation, out vec3 r_position, out vec3 r_normal, out float r_cell_size) {
	uint spatial_base = entry_index * HDDAGI_IRRADIANCE_CACHE_SPATIAL_STRIDE;
	vec4 spatial_position = hddagi_irradiance_cache_spatial[spatial_base + 0u];
	vec4 spatial_normal = hddagi_irradiance_cache_spatial[spatial_base + 1u];
	if (floatBitsToUint(spatial_position.w) != generation || !hddagi_irradiance_cache_geometry_current(entry_index) ||
			!hddagi_irradiance_cache_is_finite(spatial_position.xyz) ||
			!hddagi_irradiance_cache_is_finite(spatial_normal.xyz) || !(spatial_normal.w > 0.0)) {
		return false;
	}
	r_position = spatial_position.xyz;
	r_normal = hddagi_irradiance_cache_safe_normalize(spatial_normal.xyz);
	r_cell_size = spatial_normal.w;
	return true;
}

bool hddagi_irradiance_cache_representative_compatible(uint entry_index, uint generation, float cell_size, vec3 position, vec3 normal) {
	vec3 representative_position;
	vec3 representative_normal;
	float representative_cell_size;
	if (!hddagi_irradiance_cache_load_representative(entry_index, generation, representative_position, representative_normal, representative_cell_size)) {
		return false;
	}
	float compatibility_cell_size = max(cell_size, representative_cell_size);
	if (hddagi_irradiance_cache_hwrt()) {
		vec3 delta = position - representative_position;
		float position_precision = max(0.0001, max(abs(position.x), max(abs(position.y), abs(position.z))) * 4e-7);
		float plane_tolerance = max(compatibility_cell_size * 0.05, position_precision);
		return length(delta) <= compatibility_cell_size * 1.5 && dot(normal, representative_normal) >= 0.95 &&
				max(abs(dot(delta, normal)), abs(dot(delta, representative_normal))) <= plane_tolerance;
	}
	return distance(position, representative_position) <= HDDAGI_IRRADIANCE_CACHE_REPRESENTATIVE_DISTANCE_SCALE * compatibility_cell_size &&
			dot(normal, representative_normal) >= HDDAGI_IRRADIANCE_CACHE_REPRESENTATIVE_NORMAL_THRESHOLD;
}

void hddagi_irradiance_cache_vote_position(uint entry_index, uint generation, float cell_size, vec3 position, vec3 normal, vec3 query_origin, uvec3 surface_key) {
	// Select one representative from the allocation frame's complete candidate
	// cohort, then keep that physical surface point stable for the entry's
	// lifetime. Re-running the reservoir every frame made recursive ray origins
	// jump even though incompatible surfaces were already forbidden from voting.
	// TTL eviction remains the mechanism that lets a cell select a new surface.
	vec3 representative_position;
	vec3 representative_normal;
	float representative_cell_size;
	if (hddagi_irradiance_cache_load_representative(entry_index, generation, representative_position, representative_normal, representative_cell_size)) {
		return;
	}
	if (!hddagi_irradiance_cache_is_finite(query_origin)) {
		query_origin = position;
	}
	vec3 proposal_position = position;
	// Multi-bounce training needs the physical surface point. The one-bounce
	// endpoint cache may keep its historical free-space pull, which reduces
	// self-intersection risk for a value that is never used as a ray origin.
	if (!hddagi_irradiance_cache_multibounce_enabled() && !hddagi_irradiance_cache_hwrt()) {
		vec3 to_origin = query_origin - position;
		float distance_to_origin = length(to_origin);
		if (distance_to_origin > 1e-6 && !isinf(distance_to_origin) && !isnan(distance_to_origin)) {
			float proposal_distance = min(0.5 * cell_size, distance_to_origin * 0.5);
			proposal_position += to_origin * (proposal_distance / distance_to_origin);
		}
	}

	// Serialize the representative payload with the high count bit. The bounded retry
	// can drop a vote under extreme contention, but it cannot tear the reservoir.
	uint vote_state = hddagi_irradiance_cache_vote_count[entry_index];
	for (uint attempt = 0u; attempt < 32u; attempt++) {
		if ((vote_state & HDDAGI_IRRADIANCE_CACHE_VOTE_LOCK) != 0u) {
			vote_state = hddagi_irradiance_cache_vote_count[entry_index];
			continue;
		}
		uint previous_vote_count = vote_state & HDDAGI_IRRADIANCE_CACHE_VOTE_COUNT_MASK;
		if (previous_vote_count == HDDAGI_IRRADIANCE_CACHE_VOTE_COUNT_MASK) {
			return;
		}
		uint previous = atomicCompSwap(hddagi_irradiance_cache_vote_count[entry_index], vote_state, vote_state | HDDAGI_IRRADIANCE_CACHE_VOTE_LOCK);
		if (previous != vote_state) {
			vote_state = previous;
			continue;
		}

		uint candidate_count = previous_vote_count + 1u;
		uint seed = hddagi_irradiance_cache_hash_combine(entry_index, generation);
		seed = hddagi_irradiance_cache_hash_combine(seed, hddagi_irradiance_cache_params.control.x);
		seed = hddagi_irradiance_cache_hash_combine(seed, previous_vote_count);
		seed = hddagi_irradiance_cache_hash_combine(seed, floatBitsToUint(position.x));
		seed = hddagi_irradiance_cache_hash_combine(seed, floatBitsToUint(position.y));
		seed = hddagi_irradiance_cache_hash_combine(seed, floatBitsToUint(position.z));
		if ((seed % candidate_count) == 0u) {
			uint proposal_base = entry_index * HDDAGI_IRRADIANCE_CACHE_SPATIAL_STRIDE;
			hddagi_irradiance_cache_proposals[proposal_base + 1u] = vec4(normal, cell_size);
			hddagi_irradiance_cache_proposals[proposal_base + 2u] = vec4(uintBitsToFloat(surface_key), 0.0);
			memoryBarrierBuffer();
			hddagi_irradiance_cache_proposals[proposal_base + 0u] = vec4(proposal_position, uintBitsToFloat(generation));
		}
		memoryBarrierBuffer();
		atomicExchange(hddagi_irradiance_cache_vote_count[entry_index], candidate_count);
		return;
	}
}

HDDAGIIrradianceCacheLookup hddagi_irradiance_cache_finish_lookup(uint entry_index, uint generation, uint cascade, float cell_size, vec3 position, vec3 normal, vec3 query_origin, bool allow_update, uvec3 surface_key) {
	HDDAGIIrradianceCacheLookup result = hddagi_irradiance_cache_empty_lookup();
	uvec4 state = hddagi_irradiance_cache_entry_state[entry_index];
	if (generation == 0u || state.y != generation) {
		return result;
	}

	result.valid = true;
	result.entry_index = entry_index;
	result.generation = generation;
	result.cascade = cascade;
	result.sample_count = state.z;
	result.cell_size = cell_size;
	result.sample_position = position;
	result.sample_normal = normal;
	result.surface_key = surface_key;

	float representative_cell_size;
	if (hddagi_irradiance_cache_load_representative(entry_index, generation, result.sample_position, result.sample_normal, representative_cell_size)) {
		result.representative_valid = true;
	}
	bool representative_compatible = result.representative_valid &&
			hddagi_irradiance_cache_representative_compatible(entry_index, generation, cell_size, position, normal) &&
			(!hddagi_irradiance_cache_hwrt() || all(equal(surface_key, hddagi_irradiance_cache_surface_key(entry_index))));
	result.valid = !hddagi_irradiance_cache_hwrt() || !result.representative_valid || representative_compatible;
	// An incompatible surface may share this coarse spatial cell, but it must not
	// keep the old surface alive forever. Once compatible queries disappear, TTL
	// eviction lets the cell train a new representative.
	if (allow_update && (!result.representative_valid || representative_compatible)) {
		uint rank = min(cascade / 4u, 2u);
		atomicMax(hddagi_irradiance_cache_entry_state[entry_index].x, hddagi_irradiance_cache_params.control.x);
		atomicMin(hddagi_irradiance_cache_entry_state[entry_index].w, rank);
		if (!result.representative_valid) {
			hddagi_irradiance_cache_vote_position(entry_index, generation, cell_size, position, normal, query_origin, surface_key);
		}
	}
	bool radiance_valid = false;
	if (result.sample_count >= 4u && representative_compatible) {
		radiance_valid = hddagi_irradiance_cache_evaluate(entry_index, normal, result.radiance);
	}
	result.has_radiance = radiance_valid;

	uint refresh_hash = hddagi_irradiance_cache_hash_combine(entry_index, generation);
	refresh_hash = hddagi_irradiance_cache_hash_combine(refresh_hash, hddagi_irradiance_cache_params.control.x);
	result.needs_refresh = !radiance_valid || (allow_update && (refresh_hash & 3u) == 0u);
	return result;
}

// Finds or creates the toroidal clipmap entry containing position. query_origin
// is the point toward which the position-reservoir proposal is pulled.
// Read-only queries never allocate, vote, touch TTL, or wait on a writer.
HDDAGIIrradianceCacheLookup hddagi_irradiance_cache_lookup(vec3 position, vec3 normal, vec3 query_origin, bool allow_update, uvec3 surface_key) {
	HDDAGIIrradianceCacheLookup result = hddagi_irradiance_cache_empty_lookup();
	if (!hddagi_irradiance_cache_is_finite(position) || !hddagi_irradiance_cache_is_finite(normal) || !(dot(normal, normal) > 1e-12)) {
		return result;
	}

	uint capacity = hddagi_irradiance_cache_capacity();
	uint grid_count = hddagi_irradiance_cache_grid_count();
	uint cascade_count = min(uint(HDDAGI_IRRADIANCE_CACHE_CASCADE_COUNT), grid_count / uint(HDDAGI_IRRADIANCE_CACHE_GRID_CELL_COUNT));
	if (capacity == 0u || cascade_count == 0u) {
		return result;
	}

	normal = hddagi_irradiance_cache_safe_normalize(normal);
	float minimum_cell_size = max(hddagi_irradiance_cache_params.camera_min_cell.w, 1e-4);
	uint cascade = hddagi_irradiance_cache_select_cascade(position, minimum_cell_size, cascade_count);
	if (cascade >= cascade_count) {
		return result;
	}
	float cell_size = ldexp(minimum_cell_size, int(cascade));
	vec3 biased_position = position + normal * (0.5 * cell_size);
	vec3 world_cell_float = floor(biased_position / cell_size);
	// GLSL float-to-int conversion outside the signed 32-bit range is undefined.
	// Reject extreme absolute coordinates instead of publishing an ambiguous key.
	if (any(lessThan(world_cell_float, vec3(-2147483648.0))) || any(greaterThan(world_cell_float, vec3(2147483520.0)))) {
		return result;
	}
	ivec3 world_cell = ivec3(world_cell_float);
	uint slot = hddagi_irradiance_cache_flatten_slot(cascade, world_cell);
	if (slot >= grid_count) {
		return result;
	}

	uint rank = min(cascade / 4u, 2u);
	for (uint attempt = 0u; attempt < 32u; attempt++) {
		uvec2 grid_value = hddagi_irradiance_cache_grid[slot];
		if (grid_value.x == HDDAGI_IRRADIANCE_CACHE_LOCKED) {
			if (!allow_update || hddagi_irradiance_cache_hwrt()) {
				return result;
			}
			continue;
		}

		if (grid_value.x < capacity) {
			uint entry_index = grid_value.x;
			ivec4 entry_cell = hddagi_irradiance_cache_entry_cells[entry_index];
			uvec4 entry_state = hddagi_irradiance_cache_entry_state[entry_index];
			if (grid_value.y != 0u && entry_state.y == grid_value.y && all(equal(entry_cell.xyz, world_cell)) && entry_cell.w == int(slot)) {
				return hddagi_irradiance_cache_finish_lookup(entry_index, grid_value.y, cascade, cell_size, position, normal, query_origin, allow_update, surface_key);
			}
		}
		// HWRT training reads the published solution while discovering secondary
		// surfaces. Recycle occupied slots only in AGE, never under those readers.
		if (!allow_update || (hddagi_irradiance_cache_hwrt() && grid_value.x < capacity)) {
			return result;
		}

		uint expected = grid_value.x;
		if (expected != HDDAGI_IRRADIANCE_CACHE_EMPTY && expected >= capacity) {
			expected = grid_value.x;
		}
		uint previous = atomicCompSwap(hddagi_irradiance_cache_grid[slot].x, expected, HDDAGI_IRRADIANCE_CACHE_LOCKED);
		if (previous != expected) {
			if (hddagi_irradiance_cache_hwrt()) {
				return result;
			}
			continue;
		}

		uint entry_index = expected;
		if (expected == HDDAGI_IRRADIANCE_CACHE_EMPTY || expected >= capacity) {
			if (!hddagi_irradiance_cache_pop_free(entry_index)) {
				hddagi_irradiance_cache_grid[slot].y = 0u;
				memoryBarrierBuffer();
				atomicExchange(hddagi_irradiance_cache_grid[slot].x, HDDAGI_IRRADIANCE_CACHE_EMPTY);
				return result;
			}
		}

		uint generation = hddagi_irradiance_cache_next_generation();
		hddagi_irradiance_cache_entry_state[entry_index] = uvec4(0u);
		hddagi_irradiance_cache_entry_cells[entry_index] = ivec4(world_cell, int(slot));
		hddagi_irradiance_cache_clear_entry_payload(entry_index);
		hddagi_irradiance_cache_entry_state[entry_index] = uvec4(hddagi_irradiance_cache_params.control.x, generation, 0u, rank);
		hddagi_irradiance_cache_grid[slot].y = generation;
		memoryBarrierBuffer();
		atomicExchange(hddagi_irradiance_cache_grid[slot].x, entry_index);
		return hddagi_irradiance_cache_finish_lookup(entry_index, generation, cascade, cell_size, position, normal, query_origin, allow_update, surface_key);
	}

	return result;
}

HDDAGIIrradianceCacheLookup hddagi_irradiance_cache_lookup(vec3 position, vec3 normal, vec3 query_origin, bool allow_update) {
	return hddagi_irradiance_cache_lookup(position, normal, query_origin, allow_update, uvec3(0u));
}

HDDAGIIrradianceCacheLookup hddagi_irradiance_cache_lookup(vec3 position, vec3 normal, vec3 query_origin) {
	return hddagi_irradiance_cache_lookup(position, normal, query_origin, true);
}

// Loads one published representative without touching its lifetime or voting
// reservoir. The multi-bounce pass dispatches exactly once per entry and uses
// this stable handle to read the previous solution and submit the next iterate.
HDDAGIIrradianceCacheLookup hddagi_irradiance_cache_load_entry(uint entry_index) {
	HDDAGIIrradianceCacheLookup result = hddagi_irradiance_cache_empty_lookup();
	if (entry_index >= hddagi_irradiance_cache_capacity()) {
		return result;
	}

	uvec4 state = hddagi_irradiance_cache_entry_state[entry_index];
	if (state.y == 0u) {
		return result;
	}
	float representative_cell_size;
	if (!hddagi_irradiance_cache_load_representative(entry_index, state.y, result.sample_position, result.sample_normal, representative_cell_size)) {
		return result;
	}

	result.valid = true;
	result.representative_valid = true;
	result.entry_index = entry_index;
	result.generation = state.y;
	result.sample_count = state.z;
	result.cell_size = representative_cell_size;
	result.surface_key = hddagi_irradiance_cache_surface_key(entry_index);
	if (result.sample_count >= 4u) {
		result.has_radiance = hddagi_irradiance_cache_evaluate(entry_index, result.sample_normal, result.radiance);
	}
	result.needs_refresh = !result.has_radiance;
	return result;
}

// Endpoint estimates only bootstrap the representative trainer. Mixing shorter
// paths into its steady-state iterates would attenuate recursive illumination.
bool hddagi_irradiance_cache_should_submit_endpoint_sample(HDDAGIIrradianceCacheLookup lookup) {
	return (!hddagi_irradiance_cache_multibounce_enabled() && !hddagi_irradiance_cache_hwrt()) || (!lookup.has_radiance && lookup.sample_count < 4u);
}

// Requests beyond the host limit are discarded. PROCESS revalidates the
// generation before accumulating and clamps the count to the allocation.
bool hddagi_irradiance_cache_submit(HDDAGIIrradianceCacheLookup lookup, vec3 position, vec3 normal, vec3 radiance, uint sample_weight) {
	uint capacity = hddagi_irradiance_cache_capacity();
	if (!lookup.valid || lookup.entry_index >= capacity || lookup.generation == 0u ||
			hddagi_irradiance_cache_entry_state[lookup.entry_index].y != lookup.generation ||
			!hddagi_irradiance_cache_is_finite(position) || !hddagi_irradiance_cache_is_finite(normal) ||
			!(dot(normal, normal) > 1e-12) || !hddagi_irradiance_cache_is_finite(radiance)) {
		return false;
	}

	normal = hddagi_irradiance_cache_safe_normalize(normal);
	radiance = max(radiance, vec3(0.0));
	if (lookup.representative_valid &&
			(distance(position, lookup.sample_position) > HDDAGI_IRRADIANCE_CACHE_REPRESENTATIVE_DISTANCE_SCALE * lookup.cell_size ||
					dot(normal, lookup.sample_normal) < HDDAGI_IRRADIANCE_CACHE_REPRESENTATIVE_NORMAL_THRESHOLD)) {
		return false;
	}
	uint request_limit = hddagi_irradiance_cache_request_limit();
	uint request_index = request_limit;
	if (hddagi_irradiance_cache_hwrt()) {
		// HWRT has bounded training and sparse endpoint writers. A single atomic
		// reservation avoids starving whole waves in a contended CAS retry loop.
		request_index = atomicAdd(hddagi_irradiance_cache_meta[1], 1u);
	} else {
		uint request_count = hddagi_irradiance_cache_meta[1];
		for (uint attempt = 0u; attempt < 32u && request_count < request_limit; attempt++) {
			uint previous = atomicCompSwap(hddagi_irradiance_cache_meta[1], request_count, request_count + 1u);
			if (previous == request_count) {
				request_index = request_count;
				break;
			}
			request_count = previous;
		}
	}
	if (request_index >= request_limit) {
		return false;
	}
	uint request_base = request_index * 3u;
	hddagi_irradiance_cache_requests[request_base + 0u] = vec4(position, uintBitsToFloat(lookup.entry_index));
	hddagi_irradiance_cache_requests[request_base + 1u] = vec4(normal, uintBitsToFloat(lookup.generation));
	hddagi_irradiance_cache_requests[request_base + 2u] = vec4(radiance, uintBitsToFloat(lookup.surface_key.x | ((clamp(sample_weight, 1u, 256u) - 1u) << 24u)));
	memoryBarrierBuffer();
	return true;
}

bool hddagi_irradiance_cache_submit(HDDAGIIrradianceCacheLookup lookup, vec3 position, vec3 normal, vec3 radiance) {
	return hddagi_irradiance_cache_submit(lookup, position, normal, radiance, 1u);
}

#endif // HDDAGI_SCREEN_PROBE_IRRADIANCE_CACHE_INC_GLSL
