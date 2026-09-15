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
#define HDDAGI_IRRADIANCE_CACHE_SPATIAL_STRIDE 4u
#define HDDAGI_IRRADIANCE_CACHE_TEMPORAL_STRIDE 4u
#define HDDAGI_IRRADIANCE_CACHE_GUIDE_STRIDE 51u
#define HDDAGI_IRRADIANCE_CACHE_GUIDE_CDF_OFFSET 16u
#define HDDAGI_IRRADIANCE_CACHE_GUIDE_BATCH_OFFSET 34u
#define HDDAGI_IRRADIANCE_CACHE_GUIDE_META_OFFSET 50u
#define HDDAGI_IRRADIANCE_CACHE_MAX_SAMPLES_PER_ENTRY_PER_FRAME 4096
#define HDDAGI_IRRADIANCE_CACHE_HWRT_BUCKET_SIZE 8u

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
// HWRT retains a separate recent estimate for change detection. Stable entries
// accumulate progressively; this large limit only protects float precision.
const float HDDAGI_IRRADIANCE_CACHE_HWRT_MAX_HISTORY = 16777216.0;
const float HDDAGI_IRRADIANCE_CACHE_HWRT_RECENT_SAMPLES = 128.0;
const float HDDAGI_IRRADIANCE_CACHE_HWRT_VARIANCE_SAMPLES = 8192.0;
const uint HDDAGI_IRRADIANCE_CACHE_HWRT_BOOTSTRAP_SAMPLES = 1024u;
const uint HDDAGI_IRRADIANCE_CACHE_HWRT_ANIMATED_SAMPLE_CAP = 128u;
const uint HDDAGI_IRRADIANCE_CACHE_HWRT_REFRESH_SAMPLE_CAP = 32u;

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

// Per entry: position/generation, shading normal/cell size, HWRT instance
// slot/surface version (low/high) and last lighting update frame as uint bits,
// then geometric normal/padding. Training offsets rays using the physical
// triangle normal while integrating irradiance around the shading normal.
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

// Per entry: recent RGB mean/sample count, RGB batch variance/effective history,
// signed per-channel change confirmations/remaining settling batches, and a
// long-term RGB squared residual/reference sample count for rare bright paths.
// This state belongs to the entry generation and is retired with its payload.
layout(set = HDDAGI_IRRADIANCE_CACHE_SET, binding = 13, std430) coherent restrict buffer HDDAGIIrradianceCacheTemporalBuffer {
	vec4 hddagi_irradiance_cache_temporal[HDDAGI_IRRADIANCE_CACHE_TEMPORAL_STRIDE * HDDAGI_IRRADIANCE_CACHE_ENTRY_CAPACITY];
};

// Per entry: 64 directional masses, an 8-row / 64-column hierarchical CDF,
// 64 pending masses, then history samples / pending samples / valid CDF / spare.
// These are incoming-light directions, independent of the irradiance SH basis.
// Training writes only pending data; RESOLVE publishes before visible queries.
layout(set = HDDAGI_IRRADIANCE_CACHE_SET, binding = 14, std430) coherent restrict buffer HDDAGIIrradianceCacheGuideBuffer {
	vec4 hddagi_irradiance_cache_guide[];
};

// A position-only index lets raster receivers find guides without an instance
// ID. Rebuilt by maintenance; queries never allocate or modify this index.
layout(set = HDDAGI_IRRADIANCE_CACHE_SET, binding = 15, std430) coherent restrict buffer HDDAGIIrradianceCacheGuideGridBuffer {
	uint hddagi_irradiance_cache_guide_grid[];
};

const uint HDDAGI_IRRADIANCE_CACHE_TRAINING_MULTIBOUNCE = 1u << 0u;
const uint HDDAGI_IRRADIANCE_CACHE_HWRT = 1u << 1u;
const uint HDDAGI_IRRADIANCE_CACHE_ANIMATED_MATERIALS = 1u << 2u;

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
	vec3 sample_geometric_normal;
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
	return key.x < uint(hddagi_irradiance_cache_geometry.length()) / 2u && any(notEqual(key.yz, uvec2(0u))) &&
			all(equal(key.yz, hddagi_irradiance_cache_geometry[key.x * 2u].zw));
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
	result.sample_geometric_normal = result.sample_normal;
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

uint hddagi_irradiance_cache_hwrt_slot(uint cascade, ivec3 world_cell, uvec3 surface_key) {
	// Multiple surfaces can occupy one world cell. Keep bounded hash buckets
	// inside each cascade so AGE can still recover the cascade from the slot.
	// Orientation belongs to the surface compatibility test, not the key: a
	// smooth normal crossing an axis must keep the same interpolation neighbors.
	uint seed = hddagi_irradiance_cache_hash_combine(uint(world_cell.x), uint(world_cell.y));
	seed = hddagi_irradiance_cache_hash_combine(seed, uint(world_cell.z));
	seed = hddagi_irradiance_cache_hash_combine(seed, surface_key.x);
	seed = hddagi_irradiance_cache_hash_combine(seed, surface_key.y);
	seed = hddagi_irradiance_cache_hash_combine(seed, surface_key.z);
	return cascade * uint(HDDAGI_IRRADIANCE_CACHE_GRID_CELL_COUNT) + seed % (uint(HDDAGI_IRRADIANCE_CACHE_GRID_CELL_COUNT) - HDDAGI_IRRADIANCE_CACHE_HWRT_BUCKET_SIZE + 1u);
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
	hddagi_irradiance_cache_spatial[spatial_base + 3u] = vec4(0.0);
	hddagi_irradiance_cache_proposals[spatial_base + 0u] = vec4(0.0);
	hddagi_irradiance_cache_proposals[spatial_base + 1u] = vec4(0.0);
	hddagi_irradiance_cache_proposals[spatial_base + 2u] = vec4(0.0);
	hddagi_irradiance_cache_proposals[spatial_base + 3u] = vec4(0.0);
	hddagi_irradiance_cache_vote_count[entry_index] = 0u;
	uint temporal_base = entry_index * HDDAGI_IRRADIANCE_CACHE_TEMPORAL_STRIDE;
	for (uint i = 0u; i < HDDAGI_IRRADIANCE_CACHE_TEMPORAL_STRIDE; i++) {
		hddagi_irradiance_cache_temporal[temporal_base + i] = vec4(0.0);
	}
	if (hddagi_irradiance_cache_hwrt()) {
		uint guide_base = entry_index * HDDAGI_IRRADIANCE_CACHE_GUIDE_STRIDE;
		for (uint i = 0u; i < HDDAGI_IRRADIANCE_CACHE_GUIDE_STRIDE; i++) {
			hddagi_irradiance_cache_guide[guide_base + i] = vec4(0.0);
		}
	}

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
		// The midpoint tangent handles a smooth curved surface without treating
		// its curvature as a gap between parallel sheets.
		return length(delta) <= compatibility_cell_size * 1.5 && dot(normal, representative_normal) >= 0.95 &&
				abs(dot(delta, normalize(normal + representative_normal))) <= plane_tolerance;
	}
	return distance(position, representative_position) <= HDDAGI_IRRADIANCE_CACHE_REPRESENTATIVE_DISTANCE_SCALE * compatibility_cell_size &&
			dot(normal, representative_normal) >= HDDAGI_IRRADIANCE_CACHE_REPRESENTATIVE_NORMAL_THRESHOLD;
}

bool hddagi_irradiance_cache_hwrt_surface_matches(uint entry_index, float cell_size, vec3 position, vec3 normal, uvec3 surface_key) {
	if (any(notEqual(hddagi_irradiance_cache_surface_key(entry_index), surface_key))) {
		return false;
	}
	uint spatial_base = entry_index * HDDAGI_IRRADIANCE_CACHE_SPATIAL_STRIDE;
	vec3 representative_position = hddagi_irradiance_cache_spatial[spatial_base].xyz;
	vec3 representative_normal = hddagi_irradiance_cache_spatial[spatial_base + 1u].xyz;
	vec3 delta = position - representative_position;
	float position_precision = max(0.0001, max(abs(position.x), max(abs(position.y), abs(position.z))) * 4e-7);
	return dot(normal, representative_normal) >= 0.95 && length(delta) <= cell_size * 1.5 &&
			abs(dot(delta, normalize(normal + representative_normal))) <= max(cell_size * 0.05, position_precision);
}

// Reconstruction has wider, continuous support than allocation. A strict
// compatibility cutoff is useful to keep training cohorts on one surface, but
// using it as a binary read weight exposes their boundaries in reflections.
float hddagi_irradiance_cache_reconstruction_weight(uint entry_index, uint generation, float cell_size, vec3 position, vec3 normal, uvec3 surface_key) {
	if (any(notEqual(hddagi_irradiance_cache_surface_key(entry_index), surface_key))) {
		return 0.0;
	}
	vec3 representative_position;
	vec3 representative_normal;
	float representative_cell_size;
	if (!hddagi_irradiance_cache_load_representative(entry_index, generation, representative_position, representative_normal, representative_cell_size)) {
		return 0.0;
	}
	float normal_weight = smoothstep(0.75, 0.95, dot(normal, representative_normal));
	if (normal_weight <= 0.0) {
		return 0.0;
	}
	float compatibility_cell_size = max(cell_size, representative_cell_size);
	vec3 delta = position - representative_position;
	float position_precision = max(0.0001, max(abs(position.x), max(abs(position.y), abs(position.z))) * 4e-7);
	float plane_tolerance = max(compatibility_cell_size * 0.05, position_precision);
	float plane_error = abs(dot(delta, normalize(normal + representative_normal)));
	float plane_weight = 1.0 - smoothstep(0.5 * plane_tolerance, plane_tolerance, plane_error);
	float distance_weight = 1.0 - smoothstep(compatibility_cell_size, compatibility_cell_size * 1.5, length(delta));
	return normal_weight * plane_weight * distance_weight;
}

// Interpolate the published solution without allocating entries or changing
// their lifetime. Restrict all taps to the same versioned surface and tangent
// plane so interpolation cannot blend opposite sides of thin walls.
bool hddagi_irradiance_cache_interpolate(vec3 position, vec3 normal, uvec3 surface_key, out vec3 r_radiance) {
	r_radiance = vec3(0.0);
	if (!hddagi_irradiance_cache_is_finite(position) || !hddagi_irradiance_cache_is_finite(normal) || !(dot(normal, normal) > 1e-12)) {
		return false;
	}
	uint cascade_count = min(uint(HDDAGI_IRRADIANCE_CACHE_CASCADE_COUNT), hddagi_irradiance_cache_grid_count() / uint(HDDAGI_IRRADIANCE_CACHE_GRID_CELL_COUNT));
	if (cascade_count == 0u) {
		return false;
	}
	normal = hddagi_irradiance_cache_safe_normalize(normal);
	float minimum_cell_size = max(hddagi_irradiance_cache_params.camera_min_cell.w, 1e-4);
	uint cascade = hddagi_irradiance_cache_select_cascade(position, minimum_cell_size, cascade_count);
	if (cascade >= cascade_count) {
		return false;
	}
	float cell_size = ldexp(minimum_cell_size, int(cascade));
	vec3 coordinate = (position + normal * (0.5 * cell_size)) / cell_size - 0.5;
	vec3 base_float = floor(coordinate);
	if (any(lessThan(base_float, vec3(-2147483648.0))) || any(greaterThan(base_float, vec3(2147483520.0)))) {
		return false;
	}
	ivec3 base = ivec3(base_float);
	vec3 fraction = coordinate - base_float;
	float weight_sum = 0.0;
	for (uint tap = 0u; tap < 8u; tap++) {
		ivec3 offset = ivec3(int(tap & 1u), int((tap >> 1u) & 1u), int(tap >> 2u));
		vec3 axis_weight = mix(vec3(1.0) - fraction, fraction, vec3(offset));
		float weight = axis_weight.x * axis_weight.y * axis_weight.z;
		if (weight <= 0.0) {
			continue;
		}
		ivec3 cell = base + offset;
		uint first_slot = hddagi_irradiance_cache_hwrt_slot(cascade, cell, surface_key);
		vec3 cell_radiance = vec3(0.0);
		float cell_weight = 0.0;
		float cell_confidence = 0.0;
		for (uint candidate = 0u; candidate < HDDAGI_IRRADIANCE_CACHE_HWRT_BUCKET_SIZE; candidate++) {
			uint slot = first_slot + candidate;
			uvec2 grid_value = hddagi_irradiance_cache_grid[slot];
			if (grid_value.x >= hddagi_irradiance_cache_capacity() || grid_value.y == 0u) {
				continue;
			}
			uint entry_index = grid_value.x;
			uvec4 state = hddagi_irradiance_cache_entry_state[entry_index];
			if (state.y != grid_value.y || state.z < 4u ||
					any(notEqual(hddagi_irradiance_cache_entry_cells[entry_index], ivec4(cell, int(slot))))) {
				continue;
			}
			float candidate_weight = hddagi_irradiance_cache_reconstruction_weight(entry_index, grid_value.y, cell_size, position, normal, surface_key);
			if (candidate_weight <= 0.0) {
				continue;
			}
			vec3 radiance;
			if (!hddagi_irradiance_cache_evaluate(entry_index, normal, radiance)) {
				continue;
			}
			// Fade newly trained neighbors into the reconstruction instead of giving
			// their first noisy estimate the weight of a mature entry.
			candidate_weight *= min(float(state.z) / 64.0, 1.0);
			cell_radiance += radiance * candidate_weight;
			cell_weight += candidate_weight;
			cell_confidence = max(cell_confidence, candidate_weight);
		}
		if (cell_weight > 0.0) {
			// Each cell contributes once, regardless of how many compatible
			// representatives it contains. Extra cohorts improve coverage, not
			// the cell's spatial weight or the confidence of duplicate samples.
			float tap_weight = weight * cell_confidence;
			r_radiance += (cell_radiance / cell_weight) * tap_weight;
			weight_sum += tap_weight;
		}
	}
	if (weight_sum <= 1e-6) {
		return false;
	}
	r_radiance /= weight_sum;
	return true;
}

void hddagi_irradiance_cache_vote_position(uint entry_index, uint generation, float cell_size, vec3 position, vec3 normal, vec3 query_origin, uvec3 surface_key, vec3 geometric_normal) {
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
			hddagi_irradiance_cache_proposals[proposal_base + 3u] = vec4(geometric_normal, 0.0);
			memoryBarrierBuffer();
			hddagi_irradiance_cache_proposals[proposal_base + 0u] = vec4(proposal_position, uintBitsToFloat(generation));
		}
		memoryBarrierBuffer();
		atomicExchange(hddagi_irradiance_cache_vote_count[entry_index], candidate_count);
		return;
	}
}

HDDAGIIrradianceCacheLookup hddagi_irradiance_cache_finish_lookup(uint entry_index, uint generation, uint cascade, float cell_size, vec3 position, vec3 normal, vec3 query_origin, bool allow_update, uvec3 surface_key, vec3 geometric_normal) {
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
	result.sample_geometric_normal = geometric_normal;
	result.surface_key = surface_key;

	float representative_cell_size;
	if (hddagi_irradiance_cache_load_representative(entry_index, generation, result.sample_position, result.sample_normal, representative_cell_size)) {
		result.representative_valid = true;
		result.sample_geometric_normal = hddagi_irradiance_cache_safe_normalize(hddagi_irradiance_cache_spatial[entry_index * HDDAGI_IRRADIANCE_CACHE_SPATIAL_STRIDE + 3u].xyz);
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
			hddagi_irradiance_cache_vote_position(entry_index, generation, cell_size, position, normal, query_origin, surface_key, geometric_normal);
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

// Finds or creates a surface entry in the HWRT hash grid or software clipmap.
// query_origin is the point toward which the position-reservoir proposal is pulled.
// Read-only queries never allocate, vote, touch TTL, or wait on a writer.
HDDAGIIrradianceCacheLookup hddagi_irradiance_cache_lookup(vec3 position, vec3 normal, vec3 query_origin, bool allow_update, uvec3 surface_key, vec3 geometric_normal) {
	HDDAGIIrradianceCacheLookup result = hddagi_irradiance_cache_empty_lookup();
	if (!hddagi_irradiance_cache_is_finite(position) || !hddagi_irradiance_cache_is_finite(normal) || !(dot(normal, normal) > 1e-12) ||
			!hddagi_irradiance_cache_is_finite(geometric_normal) || !(dot(geometric_normal, geometric_normal) > 1e-12)) {
		return result;
	}

	uint capacity = hddagi_irradiance_cache_capacity();
	uint grid_count = hddagi_irradiance_cache_grid_count();
	uint cascade_count = min(uint(HDDAGI_IRRADIANCE_CACHE_CASCADE_COUNT), grid_count / uint(HDDAGI_IRRADIANCE_CACHE_GRID_CELL_COUNT));
	if (capacity == 0u || cascade_count == 0u) {
		return result;
	}

	normal = hddagi_irradiance_cache_safe_normalize(normal);
	geometric_normal = hddagi_irradiance_cache_safe_normalize(geometric_normal);
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
	bool hwrt = hddagi_irradiance_cache_hwrt();
	uint first_slot = hwrt ? hddagi_irradiance_cache_hwrt_slot(cascade, world_cell, surface_key) : hddagi_irradiance_cache_flatten_slot(cascade, world_cell);
	uint slot = first_slot;
	if (slot >= grid_count) {
		return result;
	}
	if (hwrt) {
		// AGE can leave holes in a bucket. Search the entire bucket before
		// inserting, otherwise a hole would hide an existing trained surface.
		slot = HDDAGI_IRRADIANCE_CACHE_EMPTY;
		for (uint candidate = 0u; candidate < HDDAGI_IRRADIANCE_CACHE_HWRT_BUCKET_SIZE; candidate++) {
			uint candidate_slot = first_slot + candidate;
			uvec2 grid_value = hddagi_irradiance_cache_grid[candidate_slot];
			if (grid_value.x == HDDAGI_IRRADIANCE_CACHE_LOCKED) {
				if (allow_update) {
					// Do not duplicate an unpublished insertion or spin on another lane.
					return result;
				}
				continue;
			}
			if (grid_value.x < capacity) {
				ivec4 cell = hddagi_irradiance_cache_entry_cells[grid_value.x];
				if (grid_value.y != 0u && hddagi_irradiance_cache_entry_state[grid_value.x].y == grid_value.y &&
						all(equal(cell, ivec4(world_cell, int(candidate_slot)))) &&
						hddagi_irradiance_cache_hwrt_surface_matches(grid_value.x, cell_size, position, normal, surface_key)) {
					return hddagi_irradiance_cache_finish_lookup(grid_value.x, grid_value.y, cascade, cell_size, position, normal, query_origin, allow_update, surface_key, geometric_normal);
				}
			} else if (grid_value.x == HDDAGI_IRRADIANCE_CACHE_EMPTY && slot == HDDAGI_IRRADIANCE_CACHE_EMPTY) {
				slot = candidate_slot;
			}
		}
		if (!allow_update || slot == HDDAGI_IRRADIANCE_CACHE_EMPTY) {
			return result;
		}
	}

	uint rank = min(cascade / 4u, 2u);
	for (uint attempt = 0u; attempt < 32u; attempt++) {
		if (hwrt && attempt > 0u) {
			return result;
		}
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
				if (hwrt && !hddagi_irradiance_cache_hwrt_surface_matches(entry_index, cell_size, position, normal, surface_key)) {
					return result;
				}
				return hddagi_irradiance_cache_finish_lookup(entry_index, grid_value.y, cascade, cell_size, position, normal, query_origin, allow_update, surface_key, geometric_normal);
			}
		}
		// HWRT training reads the published solution while discovering secondary
		// surfaces. Recycle occupied slots only in AGE, never under those readers.
		if (!allow_update || (hwrt && grid_value.x < capacity)) {
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
		if (hwrt) {
			// Publish the allocation's surface identity before releasing the grid
			// lock. Other queries can then distinguish concurrent surfaces in the
			// same cell even before AGE publishes the representative reservoir.
			uint spatial_base = entry_index * HDDAGI_IRRADIANCE_CACHE_SPATIAL_STRIDE;
			hddagi_irradiance_cache_spatial[spatial_base] = vec4(position, 0.0);
			hddagi_irradiance_cache_spatial[spatial_base + 1u] = vec4(normal, cell_size);
			hddagi_irradiance_cache_spatial[spatial_base + 2u] = vec4(uintBitsToFloat(surface_key), 0.0);
			hddagi_irradiance_cache_spatial[spatial_base + 3u] = vec4(geometric_normal, 0.0);
		}
		hddagi_irradiance_cache_entry_state[entry_index] = uvec4(hddagi_irradiance_cache_params.control.x, generation, 0u, rank);
		hddagi_irradiance_cache_grid[slot].y = generation;
		memoryBarrierBuffer();
		atomicExchange(hddagi_irradiance_cache_grid[slot].x, entry_index);
		return hddagi_irradiance_cache_finish_lookup(entry_index, generation, cascade, cell_size, position, normal, query_origin, allow_update, surface_key, geometric_normal);
	}

	return result;
}

HDDAGIIrradianceCacheLookup hddagi_irradiance_cache_lookup(vec3 position, vec3 normal, vec3 query_origin, bool allow_update, uvec3 surface_key) {
	return hddagi_irradiance_cache_lookup(position, normal, query_origin, allow_update, surface_key, normal);
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
	result.sample_geometric_normal = hddagi_irradiance_cache_safe_normalize(hddagi_irradiance_cache_spatial[entry_index * HDDAGI_IRRADIANCE_CACHE_SPATIAL_STRIDE + 3u].xyz);
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

#include "hddagi_screen_probe_path_guiding_inc.glsl"

#endif // HDDAGI_SCREEN_PROBE_IRRADIANCE_CACHE_INC_GLSL
