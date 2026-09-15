#ifndef HDDAGI_SCREEN_PROBE_PATH_GUIDING_INC_GLSL
#define HDDAGI_SCREEN_PROBE_PATH_GUIDING_INC_GLSL

// Equal-area octahedral coordinates, shared by both HWRT diffuse estimators.
// Each of the 8x8 bins subtends 4 PI / 64 steradians.
const float HDDAGI_GUIDE_PI = 3.141592653589793;

bool hddagi_guide_enabled() {
	return hddagi_irradiance_cache_hwrt() && (hddagi_irradiance_cache_params.training.x & 8u) != 0u;
}

vec3 hddagi_guide_square_to_sphere(vec2 uv) {
	vec2 square = uv * 2.0 - 1.0;
	float diagonal = 1.0 - (abs(square.x) + abs(square.y));
	float radius = 1.0 - abs(diagonal);
	float angle = radius > 1e-8 ? (HDDAGI_GUIDE_PI * 0.25) * ((abs(square.y) - abs(square.x)) / radius + 1.0) : 0.0;
	float planar_radius = radius * sqrt(max(2.0 - radius * radius, 0.0));
	vec2 square_sign = vec2(square.x < 0.0 ? -1.0 : 1.0, square.y < 0.0 ? -1.0 : 1.0);
	return normalize(vec3(planar_radius * square_sign.x * abs(cos(angle)),
			planar_radius * square_sign.y * abs(sin(angle)), (diagonal < 0.0 ? -1.0 : 1.0) * (1.0 - radius * radius)));
}

vec2 hddagi_guide_sphere_to_square(vec3 direction) {
	vec3 absolute_direction = abs(direction);
	float radius = sqrt(max(1.0 - absolute_direction.z, 0.0));
	float ratio = min(absolute_direction.x, absolute_direction.y) / max(max(absolute_direction.x, absolute_direction.y), 5.42101086243e-20);
	float angle = atan(ratio) * (2.0 / HDDAGI_GUIDE_PI);
	if (absolute_direction.x < absolute_direction.y) {
		angle = 1.0 - angle;
	}
	vec2 square = vec2(radius * (1.0 - angle), radius * angle);
	if (direction.z < 0.0) {
		square = vec2(1.0 - square.y, 1.0 - square.x);
	}
	square *= vec2(direction.x < 0.0 ? -1.0 : 1.0, direction.y < 0.0 ? -1.0 : 1.0);
	return clamp(square * 0.5 + 0.5, vec2(0.0), vec2(uintBitsToFloat(0x3f7fffffu)));
}

uint hddagi_guide_bin(vec3 direction) {
	uvec2 bin = min(uvec2(hddagi_guide_sphere_to_square(direction) * 8.0), uvec2(7u));
	return bin.y * 8u + bin.x;
}

float hddagi_guide_cdf(uint entry_index, uint offset) {
	uint base = entry_index * HDDAGI_IRRADIANCE_CACHE_GUIDE_STRIDE + HDDAGI_IRRADIANCE_CACHE_GUIDE_CDF_OFFSET;
	return hddagi_irradiance_cache_guide[base + offset / 4u][offset & 3u];
}

float hddagi_guide_probability(uint entry_index, uint bin) {
	uint row = bin / 8u;
	float row_probability = hddagi_guide_cdf(entry_index, row) - (row == 0u ? 0.0 : hddagi_guide_cdf(entry_index, row - 1u));
	float column_probability = hddagi_guide_cdf(entry_index, 8u + bin) - ((bin & 7u) == 0u ? 0.0 : hddagi_guide_cdf(entry_index, 7u + bin));
	return max(row_probability, 0.0) * max(column_probability, 0.0);
}

float hddagi_guide_pdf(uint entry_index, vec3 direction) {
	return hddagi_guide_probability(entry_index, hddagi_guide_bin(direction)) * (16.0 / HDDAGI_GUIDE_PI);
}

// Binary-search one CDF level and recycle its uniform variate inside the bin.
uint hddagi_guide_sample_cdf(uint entry_index, uint offset, inout float random_sample) {
	uint first = 0u;
	for (uint step = 4u; step > 0u; step >>= 1u) {
		uint middle = first + step - 1u;
		if (random_sample >= hddagi_guide_cdf(entry_index, offset + middle)) {
			first += step;
		}
	}
	uint bin = min(first, 7u);
	float lower = bin == 0u ? 0.0 : hddagi_guide_cdf(entry_index, offset + bin - 1u);
	float probability = hddagi_guide_cdf(entry_index, offset + bin) - lower;
	random_sample = clamp((random_sample - lower) / max(probability, 1e-20), 0.0, uintBitsToFloat(0x3f7fffffu));
	return bin;
}

vec3 hddagi_guide_sample(uint entry_index, vec2 random_sample) {
	uint row = hddagi_guide_sample_cdf(entry_index, 0u, random_sample.x);
	uint column = hddagi_guide_sample_cdf(entry_index, 8u + row * 8u, random_sample.y);
	return hddagi_guide_square_to_sphere((vec2(column, row) + random_sample.yx) * 0.125);
}

float hddagi_guide_strength(uint entry_index) {
	if (entry_index >= hddagi_irradiance_cache_capacity()) {
		return 0.0;
	}
	vec4 meta = hddagi_irradiance_cache_guide[entry_index * HDDAGI_IRRADIANCE_CACHE_GUIDE_STRIDE + HDDAGI_IRRADIANCE_CACHE_GUIDE_META_OFFSET];
	return meta.z > 0.0 ? 0.5 * smoothstep(32.0, 256.0, meta.x) : 0.0;
}

uint hddagi_guide_lookup(vec3 position, vec3 normal) {
	if (!hddagi_irradiance_cache_hwrt() || !hddagi_irradiance_cache_is_finite(position) || !hddagi_irradiance_cache_is_finite(normal) || dot(normal, normal) <= 1e-12) {
		return HDDAGI_IRRADIANCE_CACHE_EMPTY;
	}
	normal = hddagi_irradiance_cache_safe_normalize(normal);
	float minimum_cell_size = max(hddagi_irradiance_cache_params.camera_min_cell.w, 1e-4);
	uint cascade_count = min(uint(HDDAGI_IRRADIANCE_CACHE_CASCADE_COUNT), hddagi_irradiance_cache_grid_count() / uint(HDDAGI_IRRADIANCE_CACHE_GRID_CELL_COUNT));
	if (cascade_count == 0u) {
		return HDDAGI_IRRADIANCE_CACHE_EMPTY;
	}
	uint cascade = hddagi_irradiance_cache_select_cascade(position, minimum_cell_size, cascade_count);
	if (cascade >= cascade_count) {
		return HDDAGI_IRRADIANCE_CACHE_EMPTY;
	}
	float cell_size = ldexp(minimum_cell_size, int(cascade));
	// Use the same normal bias as entry allocation, including on grid planes.
	vec3 cell_float = floor((position + normal * (0.5 * cell_size)) / cell_size);
	if (any(lessThan(cell_float, vec3(-2147483648.0))) || any(greaterThan(cell_float, vec3(2147483520.0)))) {
		return HDDAGI_IRRADIANCE_CACHE_EMPTY;
	}
	ivec3 cell = ivec3(cell_float);
	uint first_slot = hddagi_irradiance_cache_hwrt_slot(cascade, cell, uvec3(0u));
	uint best_entry = HDDAGI_IRRADIANCE_CACHE_EMPTY;
	float best_distance = cell_size * cell_size * 2.25;
	for (uint candidate = 0u; candidate < HDDAGI_IRRADIANCE_CACHE_HWRT_BUCKET_SIZE; candidate++) {
		uint entry_index = hddagi_irradiance_cache_guide_grid[first_slot + candidate];
		if (entry_index >= hddagi_irradiance_cache_capacity()) {
			continue;
		}
		ivec4 entry_cell = hddagi_irradiance_cache_entry_cells[entry_index];
		if (entry_cell.w < 0 || uint(entry_cell.w) / uint(HDDAGI_IRRADIANCE_CACHE_GRID_CELL_COUNT) != cascade || any(notEqual(entry_cell.xyz, cell))) {
			continue;
		}
		uint generation = hddagi_irradiance_cache_entry_state[entry_index].y;
		if (generation == 0u || !hddagi_irradiance_cache_representative_compatible(entry_index, generation, cell_size, position, normal)) {
			continue;
		}
		vec3 delta = position - hddagi_irradiance_cache_spatial[entry_index * HDDAGI_IRRADIANCE_CACHE_SPATIAL_STRIDE].xyz;
		float distance_squared = dot(delta, delta);
		if (distance_squared < best_distance && hddagi_guide_strength(entry_index) > 0.0) {
			best_distance = distance_squared;
			best_entry = entry_index;
		}
	}
	return best_entry;
}

#endif // HDDAGI_SCREEN_PROBE_PATH_GUIDING_INC_GLSL
