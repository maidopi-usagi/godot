#[compute]

#version 450

#VERSION_DEFINES

#define HDDAGI_IRRADIANCE_CACHE_SET 0
#include "hddagi_screen_probe_irradiance_cache_inc.glsl"

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

uint hddagi_irradiance_cache_ttl(uint rank) {
	if (hddagi_irradiance_cache_hwrt()) {
		return rank == 0u ? 240u : (rank == 1u ? 120u : 60u);
	}
	return rank == 0u ? 12u : (rank == 1u ? 8u : 4u);
}

void hddagi_irradiance_cache_clear(uint index) {
	uint capacity = hddagi_irradiance_cache_capacity();
	if (index == 0u) {
		hddagi_irradiance_cache_meta[0] = capacity;
		hddagi_irradiance_cache_meta[1] = 0u;
		hddagi_irradiance_cache_meta[2] = 0u;
		hddagi_irradiance_cache_meta[3] = 0u;
	}

	if (index < uint(HDDAGI_IRRADIANCE_CACHE_GRID_CAPACITY)) {
		hddagi_irradiance_cache_grid[index] = uvec2(HDDAGI_IRRADIANCE_CACHE_EMPTY, 0u);
		if (hddagi_irradiance_cache_hwrt()) {
			hddagi_irradiance_cache_guide_grid[index] = HDDAGI_IRRADIANCE_CACHE_EMPTY;
		}
	}
	if (index < uint(HDDAGI_IRRADIANCE_CACHE_ENTRY_CAPACITY)) {
		hddagi_irradiance_cache_entry_cells[index] = ivec4(0, 0, 0, -1);
		hddagi_irradiance_cache_entry_state[index] = uvec4(0u);
		hddagi_irradiance_cache_clear_entry_payload(index);
		hddagi_irradiance_cache_free_pool[index] = index < capacity ? index : HDDAGI_IRRADIANCE_CACHE_LOCKED;
	}
	if (index < uint(HDDAGI_IRRADIANCE_CACHE_REQUEST_CAPACITY)) {
		uint request_base = index * 3u;
		hddagi_irradiance_cache_requests[request_base + 0u] = vec4(0.0);
		hddagi_irradiance_cache_requests[request_base + 1u] = vec4(0.0);
		hddagi_irradiance_cache_requests[request_base + 2u] = vec4(0.0);
	}
}

void hddagi_irradiance_cache_flush_spatial(uint entry_index, uint generation) {
	uint vote_count = atomicExchange(hddagi_irradiance_cache_vote_count[entry_index], 0u);
	if (vote_count == 0u || generation == 0u) {
		return;
	}
	memoryBarrierBuffer();
	uint spatial_base = entry_index * HDDAGI_IRRADIANCE_CACHE_SPATIAL_STRIDE;
	vec4 proposal_position = hddagi_irradiance_cache_proposals[spatial_base + 0u];
	vec4 proposal_normal = hddagi_irradiance_cache_proposals[spatial_base + 1u];
	vec4 proposal_geometric_normal = hddagi_irradiance_cache_proposals[spatial_base + 3u];
	if (floatBitsToUint(proposal_position.w) != generation ||
			!hddagi_irradiance_cache_is_finite(proposal_position.xyz) ||
			!hddagi_irradiance_cache_is_finite(proposal_normal.xyz) ||
			!hddagi_irradiance_cache_is_finite(proposal_geometric_normal.xyz)) {
		return;
	}

	// Publish the generation marker last, mirroring the proposal writer.
	hddagi_irradiance_cache_spatial[spatial_base + 1u] = proposal_normal;
	hddagi_irradiance_cache_spatial[spatial_base + 2u] = hddagi_irradiance_cache_proposals[spatial_base + 2u];
	hddagi_irradiance_cache_spatial[spatial_base + 3u] = proposal_geometric_normal;
	memoryBarrierBuffer();
	hddagi_irradiance_cache_spatial[spatial_base + 0u] = proposal_position;
	hddagi_irradiance_cache_proposals[spatial_base + 0u] = vec4(0.0);
	hddagi_irradiance_cache_proposals[spatial_base + 1u] = vec4(0.0);
	hddagi_irradiance_cache_proposals[spatial_base + 2u] = vec4(0.0);
	hddagi_irradiance_cache_proposals[spatial_base + 3u] = vec4(0.0);
}

void hddagi_irradiance_cache_age(uint entry_index) {
	uint capacity = hddagi_irradiance_cache_capacity();
	if (entry_index >= capacity) {
		return;
	}
	if (hddagi_irradiance_cache_hwrt()) {
		for (uint slot = entry_index; slot < hddagi_irradiance_cache_grid_count(); slot += capacity) {
			hddagi_irradiance_cache_guide_grid[slot] = HDDAGI_IRRADIANCE_CACHE_EMPTY;
		}
	}

	uvec4 state = hddagi_irradiance_cache_entry_state[entry_index];
	hddagi_irradiance_cache_flush_spatial(entry_index, state.y);
	uint accumulation_base = entry_index * uint(HDDAGI_IRRADIANCE_CACHE_ACCUM_STRIDE);
	for (uint coefficient = 0u; coefficient < uint(HDDAGI_IRRADIANCE_CACHE_ACCUM_STRIDE); coefficient++) {
		hddagi_irradiance_cache_accumulation[accumulation_base + coefficient] = 0;
	}

	if (state.y == 0u) {
		return;
	}
	uint age = hddagi_irradiance_cache_params.control.x - state.x;
	ivec4 entry_cell = hddagi_irradiance_cache_entry_cells[entry_index];
	bool in_clip = true;
	if (hddagi_irradiance_cache_hwrt() && entry_cell.w >= 0) {
		vec3 position = hddagi_irradiance_cache_spatial[entry_index * HDDAGI_IRRADIANCE_CACHE_SPATIAL_STRIDE].xyz;
		uint cascade = uint(entry_cell.w) / uint(HDDAGI_IRRADIANCE_CACHE_GRID_CELL_COUNT);
		in_clip = hddagi_irradiance_cache_select_cascade(position, max(hddagi_irradiance_cache_params.camera_min_cell.w, 1e-4), uint(HDDAGI_IRRADIANCE_CACHE_CASCADE_COUNT)) <= cascade;
	}
	if (age <= hddagi_irradiance_cache_ttl(min(state.w, 2u)) && in_clip && hddagi_irradiance_cache_geometry_current(entry_index)) {
		return;
	}

	if (entry_cell.w < 0) {
		return;
	}
	uint slot = uint(entry_cell.w);
	if (slot >= hddagi_irradiance_cache_grid_count()) {
		return;
	}
	uint previous = atomicCompSwap(hddagi_irradiance_cache_grid[slot].x, entry_index, HDDAGI_IRRADIANCE_CACHE_LOCKED);
	if (previous != entry_index) {
		return;
	}
	if (hddagi_irradiance_cache_grid[slot].y != state.y ||
			hddagi_irradiance_cache_entry_state[entry_index].y != state.y ||
			any(notEqual(hddagi_irradiance_cache_entry_cells[entry_index], entry_cell))) {
		atomicExchange(hddagi_irradiance_cache_grid[slot].x, entry_index);
		return;
	}
	// No consumer pops the stack during AGE. Reserve and publish the free slot
	// before destroying the entry so even a defensive overflow failure can
	// restore the grid mapping instead of leaking the entry.
	if (!hddagi_irradiance_cache_push_free(entry_index)) {
		atomicExchange(hddagi_irradiance_cache_grid[slot].x, entry_index);
		return;
	}

	hddagi_irradiance_cache_entry_state[entry_index] = uvec4(0u);
	hddagi_irradiance_cache_entry_cells[entry_index] = ivec4(0, 0, 0, -1);
	hddagi_irradiance_cache_clear_entry_payload(entry_index);
	hddagi_irradiance_cache_grid[slot].y = 0u;
	memoryBarrierBuffer();
	atomicExchange(hddagi_irradiance_cache_grid[slot].x, HDDAGI_IRRADIANCE_CACHE_EMPTY);
}

void hddagi_irradiance_cache_process(uint request_index) {
	uint request_count = min(hddagi_irradiance_cache_meta[1], hddagi_irradiance_cache_request_limit());
	if (request_index >= request_count) {
		return;
	}

	uint request_base = request_index * 3u;
	vec4 request_position = hddagi_irradiance_cache_requests[request_base + 0u];
	vec4 request_normal = hddagi_irradiance_cache_requests[request_base + 1u];
	vec3 radiance = hddagi_irradiance_cache_requests[request_base + 2u].xyz;
	uint entry_index = floatBitsToUint(request_position.w);
	uint generation = floatBitsToUint(request_normal.w);
	if (entry_index >= hddagi_irradiance_cache_capacity() || generation == 0u ||
			!hddagi_irradiance_cache_is_finite(request_position.xyz) ||
			!hddagi_irradiance_cache_is_finite(request_normal.xyz) ||
			!hddagi_irradiance_cache_is_finite(radiance) ||
			hddagi_irradiance_cache_entry_state[entry_index].y != generation) {
		return;
	}

	vec3 normal = hddagi_irradiance_cache_safe_normalize(request_normal.xyz);
	uint packed_surface = floatBitsToUint(hddagi_irradiance_cache_requests[request_base + 2u].w);
	int sample_weight = hddagi_irradiance_cache_hwrt() ? int(packed_surface >> 24u) + 1 : 1;
	if (hddagi_irradiance_cache_hwrt() && (packed_surface & 0xffffffu) != hddagi_irradiance_cache_surface_key(entry_index).x) {
		return;
	}
	radiance = max(radiance, vec3(0.0));
	// AGE publishes the representative before PROCESS. Revalidate delayed
	// requests against that surface so the first frame cannot mix walls or let a
	// later representative vote reinterpret coefficients trained elsewhere.
	if (!hddagi_irradiance_cache_representative_compatible(entry_index, generation, 0.0, request_position.xyz, normal)) {
		return;
	}
	uint accumulation_base = entry_index * uint(HDDAGI_IRRADIANCE_CACHE_ACCUM_STRIDE);
	int previous_count = atomicAdd(hddagi_irradiance_cache_accumulation[accumulation_base + 12u], sample_weight);
	if (previous_count + sample_weight > HDDAGI_IRRADIANCE_CACHE_MAX_SAMPLES_PER_ENTRY_PER_FRAME) {
		atomicAdd(hddagi_irradiance_cache_accumulation[accumulation_base + 12u], -sample_weight);
		return;
	}
	vec4 basis = vec4(1.0, normal);
	for (uint channel = 0u; channel < 3u; channel++) {
		for (uint coefficient = 0u; coefficient < 4u; coefficient++) {
			// The per-entry request cap keeps 4096 contributions at this bound in
			// signed 32-bit range, retaining HDR values up to roughly 2048.
			float scaled = clamp(radiance[channel] * basis[coefficient] * HDDAGI_IRRADIANCE_CACHE_ACCUM_SCALE, -524287.0, 524287.0);
			atomicAdd(hddagi_irradiance_cache_accumulation[accumulation_base + channel * 4u + coefficient], int(round(scaled)) * sample_weight);
		}
	}
	atomicAdd(hddagi_irradiance_cache_accumulation[accumulation_base + 13u], int(round(normal.x * HDDAGI_IRRADIANCE_CACHE_ACCUM_SCALE)) * sample_weight);
	atomicAdd(hddagi_irradiance_cache_accumulation[accumulation_base + 14u], int(round(normal.y * HDDAGI_IRRADIANCE_CACHE_ACCUM_SCALE)) * sample_weight);
	atomicAdd(hddagi_irradiance_cache_accumulation[accumulation_base + 15u], int(round(normal.z * HDDAGI_IRRADIANCE_CACHE_ACCUM_SCALE)) * sample_weight);
}

float hddagi_irradiance_cache_history_weight(uint entry_index, uint sample_count, vec3 estimate, float update_weight) {
	if (!hddagi_irradiance_cache_hwrt()) {
		return float(min(sample_count, hddagi_irradiance_cache_multibounce_enabled() ? HDDAGI_IRRADIANCE_CACHE_MULTIBOUNCE_HISTORY_SAMPLE_CAP : HDDAGI_IRRADIANCE_CACHE_HISTORY_SAMPLE_CAP));
	}

	uint temporal_base = entry_index * HDDAGI_IRRADIANCE_CACHE_TEMPORAL_STRIDE;
	vec4 recent = hddagi_irradiance_cache_temporal[temporal_base + 0u];
	vec4 variance_history = hddagi_irradiance_cache_temporal[temporal_base + 1u];
	vec4 change = hddagi_irradiance_cache_temporal[temporal_base + 2u];
	vec4 residual = hddagi_irradiance_cache_temporal[temporal_base + 3u];
	float recent_weight = min(recent.w, HDDAGI_IRRADIANCE_CACHE_HWRT_RECENT_SAMPLES);
	float recent_blend = update_weight / (recent_weight + update_weight);
	vec3 delta = estimate - recent.xyz;
	recent.xyz += recent_blend * delta;
	variance_history.xyz = (1.0 - recent_blend) * (variance_history.xyz + recent_blend * delta * delta);
	recent.w = min(recent_weight + update_weight, HDDAGI_IRRADIANCE_CACHE_HWRT_RECENT_SAMPLES);
	float history_weight = variance_history.w;
	bool animated = (hddagi_irradiance_cache_params.training.x & HDDAGI_IRRADIANCE_CACHE_ANIMATED_MATERIALS) != 0u;
	bool lighting_hint = hddagi_irradiance_cache_params.training.w != 0u;

	// Compare a continuously refreshed estimator with the published solution.
	// Variance is measured between ray batches, not between the correlated SH
	// coefficients. Require a persistent change in the same RGB channel and
	// direction so isolated bright paths cannot repeatedly reopen long history.
	vec3 previous = vec3(hddagi_irradiance_cache_sh[entry_index * 4u + 0u].x,
			hddagi_irradiance_cache_sh[entry_index * 4u + 1u].x,
			hddagi_irradiance_cache_sh[entry_index * 4u + 2u].x);
	vec3 difference = recent.xyz - previous;
	// Recent variance alone forgets rare bright paths between hits and mistakes
	// their absence for an extinction event. Keep a longer residual reference.
	float residual_blend = update_weight / (residual.w + update_weight);
	vec3 batch_residual = estimate - previous;
	residual.xyz = mix(residual.xyz, batch_residual * batch_residual, residual_blend);
	residual.w = min(residual.w + update_weight, HDDAGI_IRRADIANCE_CACHE_HWRT_VARIANCE_SAMPLES);
	vec3 standard_error = sqrt(max(max(variance_history.xyz, residual.xyz) * recent_blend / (2.0 - recent_blend), vec3(0.0)));
	float sigma = animated ? 3.0 : 6.0;
	vec3 threshold = sigma * standard_error + 0.02 * max(recent.xyz, previous) + vec3(0.5 / HDDAGI_IRRADIANCE_CACHE_ACCUM_SCALE);
	for (uint channel = 0u; channel < 3u; channel++) {
		bool changed = recent_weight >= HDDAGI_IRRADIANCE_CACHE_HWRT_RECENT_SAMPLES && abs(difference[channel]) > threshold[channel];
		float direction = sign(difference[channel]);
		change[channel] = changed ? (sign(change[channel]) == direction ? change[channel] + direction : direction) : 0.0;
	}
	float confirmations = animated ? 2.0 : 4.0;
	if (change.w == 0.0 && any(greaterThanEqual(abs(change.xyz), vec3(confirmations)))) {
		// Keep sampling and updating the same surface. A short local settling
		// interval also lets delayed recursive light propagate through this entry.
		change.w = 16.0;
		change.xyz = vec3(0.0);
		residual = vec4(variance_history.xyz, recent.w);
	}
	if (lighting_hint || change.w > 0.0) {
		// Explicit edits affect visibility and recursive paths beyond the edited
		// surface. Conservatively refresh the cache while those paths settle.
		history_weight = min(history_weight, float(HDDAGI_IRRADIANCE_CACHE_HWRT_REFRESH_SAMPLE_CAP));
		change.w = max(change.w - 1.0, 0.0);
		change.xyz = vec3(0.0);
		residual = vec4(variance_history.xyz, recent.w);
	} else if (animated || sample_count < HDDAGI_IRRADIANCE_CACHE_HWRT_BOOTSTRAP_SAMPLES) {
		// Avoid retaining the initially dark recursive solution. TIME materials
		// keep a responsive history even when there is no explicit lighting edit.
		history_weight = min(history_weight, float(HDDAGI_IRRADIANCE_CACHE_HWRT_ANIMATED_SAMPLE_CAP));
	}
	variance_history.w = min(history_weight + update_weight, HDDAGI_IRRADIANCE_CACHE_HWRT_MAX_HISTORY);
	hddagi_irradiance_cache_temporal[temporal_base + 0u] = recent;
	hddagi_irradiance_cache_temporal[temporal_base + 1u] = variance_history;
	hddagi_irradiance_cache_temporal[temporal_base + 2u] = change;
	hddagi_irradiance_cache_temporal[temporal_base + 3u] = residual;
	return history_weight;
}

void hddagi_irradiance_cache_resolve_guide(uint entry_index, uint generation) {
	if (!hddagi_guide_enabled() || generation == 0u || !hddagi_irradiance_cache_geometry_current(entry_index)) {
		return;
	}
	uint base = entry_index * HDDAGI_IRRADIANCE_CACHE_GUIDE_STRIDE;
	vec4 meta = hddagi_irradiance_cache_guide[base + HDDAGI_IRRADIANCE_CACHE_GUIDE_META_OFFSET];
	if (meta.y > 0.0) {
		// Guiding adapts independently of progressive irradiance accumulation.
		// The guide is only a proposal; even an outdated distribution remains
		// correct because consumers retain cosine support and evaluate its PDF.
		bool animated = (hddagi_irradiance_cache_params.training.x & HDDAGI_IRRADIANCE_CACHE_ANIMATED_MATERIALS) != 0u;
		float history_limit = hddagi_irradiance_cache_params.training.w != 0u ? 64.0 : (animated ? 128.0 : 512.0);
		float history = min(meta.x, history_limit);
		float blend = meta.y / (history + meta.y);
		float row_mass[8];
		float total_mass = 0.0;
		for (uint row = 0u; row < 8u; row++) {
			row_mass[row] = 0.0;
			for (uint part = 0u; part < 2u; part++) {
				uint offset = row * 2u + part;
				vec4 batch = hddagi_irradiance_cache_guide[base + HDDAGI_IRRADIANCE_CACHE_GUIDE_BATCH_OFFSET + offset] / meta.y;
				vec4 mass = mix(hddagi_irradiance_cache_guide[base + offset], batch, blend);
				hddagi_irradiance_cache_guide[base + offset] = mass;
				hddagi_irradiance_cache_guide[base + HDDAGI_IRRADIANCE_CACHE_GUIDE_BATCH_OFFSET + offset] = vec4(0.0);
				row_mass[row] += dot(mass, vec4(1.0));
			}
			total_mass += row_mass[row];
		}
		meta.x = min(history + meta.y, history_limit);
		meta.w = min(meta.w + meta.y, 256.0);
		meta.y = 0.0;
		meta.z = total_mass > 1e-8 && !isnan(total_mass) && !isinf(total_mass) ? 1.0 : 0.0;
		float row_prefix = 0.0;
		uint cdf_base = base + HDDAGI_IRRADIANCE_CACHE_GUIDE_CDF_OFFSET;
		for (uint row = 0u; row < 8u; row++) {
			row_prefix += row_mass[row];
			hddagi_irradiance_cache_guide[cdf_base + row / 4u][row & 3u] = row == 7u ? 1.0 : clamp(row_prefix / max(total_mass, 1e-20), 0.0, 1.0);
			float column_prefix = 0.0;
			for (uint column = 0u; column < 8u; column++) {
				uint bin = row * 8u + column;
				column_prefix += hddagi_irradiance_cache_guide[base + bin / 4u][bin & 3u];
				uint offset = 8u + bin;
				hddagi_irradiance_cache_guide[cdf_base + offset / 4u][offset & 3u] = column == 7u ? 1.0 : clamp(column_prefix / max(row_mass[row], 1e-20), 0.0, 1.0);
			}
		}
		hddagi_irradiance_cache_guide[base + HDDAGI_IRRADIANCE_CACHE_GUIDE_META_OFFSET] = meta;
	}
	ivec4 cell = hddagi_irradiance_cache_entry_cells[entry_index];
	if (meta.z <= 0.0 || cell.w < 0) {
		return;
	}
	uint cascade = uint(cell.w) / uint(HDDAGI_IRRADIANCE_CACHE_GRID_CELL_COUNT);
	uint first_slot = hddagi_irradiance_cache_hwrt_slot(cascade, cell.xyz, uvec3(0u));
	for (uint candidate = 0u; candidate < HDDAGI_IRRADIANCE_CACHE_HWRT_BUCKET_SIZE; candidate++) {
		uint previous = atomicCompSwap(hddagi_irradiance_cache_guide_grid[first_slot + candidate], HDDAGI_IRRADIANCE_CACHE_EMPTY, entry_index);
		if (previous == HDDAGI_IRRADIANCE_CACHE_EMPTY || previous == entry_index) {
			break;
		}
	}
}

void hddagi_irradiance_cache_resolve(uint entry_index) {
	uint capacity = hddagi_irradiance_cache_capacity();
	if (entry_index >= capacity) {
		return;
	}

	uvec4 state = hddagi_irradiance_cache_entry_state[entry_index];
	hddagi_irradiance_cache_resolve_guide(entry_index, state.y);
	uint accumulation_base = entry_index * uint(HDDAGI_IRRADIANCE_CACHE_ACCUM_STRIDE);
	int signed_count = hddagi_irradiance_cache_accumulation[accumulation_base + 12u];
	if (state.y != 0u && signed_count > 0) {
		float inverse_weight = 1.0 / (HDDAGI_IRRADIANCE_CACHE_ACCUM_SCALE * float(signed_count));
		float update_weight = float(signed_count);
		vec3 radiance_estimate = vec3(float(hddagi_irradiance_cache_accumulation[accumulation_base + 0u]),
				float(hddagi_irradiance_cache_accumulation[accumulation_base + 4u]),
				float(hddagi_irradiance_cache_accumulation[accumulation_base + 8u])) * inverse_weight;
		float history_weight = hddagi_irradiance_cache_history_weight(entry_index, state.z, radiance_estimate, update_weight);
		float blend = update_weight / (history_weight + update_weight);
		uint sh_base = entry_index * 4u;
		for (uint channel = 0u; channel < 3u; channel++) {
			vec4 estimate = vec4(
									float(hddagi_irradiance_cache_accumulation[accumulation_base + channel * 4u + 0u]),
									float(hddagi_irradiance_cache_accumulation[accumulation_base + channel * 4u + 1u]),
									float(hddagi_irradiance_cache_accumulation[accumulation_base + channel * 4u + 2u]),
									float(hddagi_irradiance_cache_accumulation[accumulation_base + channel * 4u + 3u])) *
					inverse_weight;
			hddagi_irradiance_cache_sh[sh_base + channel] = history_weight == 0.0 ? estimate : mix(hddagi_irradiance_cache_sh[sh_base + channel], estimate, blend);
		}
		vec4 normalization_estimate = vec4(
				1.0,
				float(hddagi_irradiance_cache_accumulation[accumulation_base + 13u]) * inverse_weight,
				float(hddagi_irradiance_cache_accumulation[accumulation_base + 14u]) * inverse_weight,
				float(hddagi_irradiance_cache_accumulation[accumulation_base + 15u]) * inverse_weight);
		hddagi_irradiance_cache_sh[sh_base + 3u] = history_weight == 0.0 ? normalization_estimate : mix(hddagi_irradiance_cache_sh[sh_base + 3u], normalization_estimate, blend);
		uint added_samples = uint(signed_count);
		hddagi_irradiance_cache_entry_state[entry_index].z = state.z > 0xffffffffu - added_samples ? 0xffffffffu : state.z + added_samples;
		hddagi_irradiance_cache_spatial[entry_index * HDDAGI_IRRADIANCE_CACHE_SPATIAL_STRIDE + 2u].w = uintBitsToFloat(hddagi_irradiance_cache_params.control.x);
	}

	// Make RESOLVE idempotent even if AGE is skipped for a frame. AGE also
	// clears this storage before PROCESS as the normal pass ordering requires.
	for (uint coefficient = 0u; coefficient < uint(HDDAGI_IRRADIANCE_CACHE_ACCUM_STRIDE); coefficient++) {
		hddagi_irradiance_cache_accumulation[accumulation_base + coefficient] = 0;
	}
}

void main() {
	uint index = gl_GlobalInvocationID.x;
#if defined(MODE_CLEAR)
	// CLEAR must cover GRID_CAPACITY invocations; it explicitly initializes
	// every backing allocation, including the free stack and request records.
	hddagi_irradiance_cache_clear(index);
#elif defined(MODE_AGE)
	hddagi_irradiance_cache_age(index);
#elif defined(MODE_PROCESS)
	hddagi_irradiance_cache_process(index);
#elif defined(MODE_RESOLVE)
	hddagi_irradiance_cache_resolve(index);
#elif defined(MODE_RESET)
	if (index == 0u) {
		hddagi_irradiance_cache_meta[1] = 0u;
	}
#endif
}
