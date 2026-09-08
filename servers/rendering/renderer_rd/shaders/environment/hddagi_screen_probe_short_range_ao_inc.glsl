// One horizon slice, three depth samples per side. The budget is independent
// of screen-probe spacing and detail-trace traversal iterations.
float screen_probe_short_range_visibility(ivec2 output_position, ivec2 output_size
#ifdef MODE_SHORT_RANGE_GI
		,
		float radiance_limit, out vec3 r_bounce
#endif
) {
#ifdef MODE_SHORT_RANGE_GI
	r_bounce = vec3(0.0);
#endif
	if (!(params.short_range_ao.y > 0.0)) {
		return 1.0;
	}
	ivec2 pixel = clamp(ivec2((vec2(output_position) + 0.5) * vec2(params.screen_size) / vec2(output_size)), ivec2(0), params.screen_size - 1);
	vec3 position;
	vec3 normal;
	if (!detail_trace_load_view_position(pixel, position) ||
			!decode_normal(texelFetch(sampler2D(detail_normal_roughness_buffer, nearest_sampler), pixel, 0).xyz, normal)) {
		return 1.0;
	}
	bool orthogonal = abs(scene_data.projection[params.view_index][3][3]) > 0.5;
	vec3 view_direction = orthogonal ? vec3(0.0, 0.0, 1.0) : normalize(-position);
	if (!(dot(normal, view_direction) > 1e-4)) {
		return 1.0;
	}
	float radius = params.short_range_ao.x;
	vec3 screen_position;
	if (!(radius > 0.0) || !detail_trace_project(position, screen_position)) {
		return 1.0;
	}
	// TAA integrates changing slice angles and radial strata after scene lighting.
	// Freeze the sequence without TAA; probe placement/history never sets its phase.
	uint sequence_index = params.short_range_ao.z > 0.5 ? params.frame_index : 0u;
	vec2 jitter = sample_temporally_permuted_r2_sequence(uvec2(output_position), sequence_index, 0x414f6a09u);
	float angle = jitter.x * 3.141592653589793;
	vec3 direction = vec3(cos(angle), sin(angle), 0.0);
	vec3 screen_endpoint;
	if (!detail_trace_project(position + direction * radius, screen_endpoint)) {
		return 1.0;
	}
	vec2 screen_offset = (screen_endpoint.xy - screen_position.xy) * vec2(params.screen_size);
	float projected_radius = length(screen_offset);
	if (!(projected_radius > 1.0)) {
		return 1.0;
	}
	// Bound only the search to the viewport. Shrinking the world-space falloff
	// to a fixed pixel radius makes the radius setting saturate near the camera.
	float screen_radius = min(projected_radius, length(vec2(params.screen_size)));
	vec2 screen_direction = screen_offset / projected_radius;
	vec3 slice_tangent = normalize(direction - view_direction * dot(direction, view_direction));
	vec3 slice_axis = cross(slice_tangent, view_direction);
	vec3 projected_normal = normal - slice_axis * dot(normal, slice_axis);
	float normal_length = length(projected_normal);
	if (!(normal_length > 1e-4)) {
		return 1.0;
	}
	float cosine_normal = clamp(dot(projected_normal, view_direction) / normal_length, 0.0, 1.0);
	float sine_normal = clamp(dot(projected_normal, slice_tangent) / normal_length, -1.0, 1.0);
	float normal_angle = atan(sine_normal, cosine_normal);
	vec2 open_horizons = vec2(-sine_normal, sine_normal);
	vec2 horizons = open_horizons;
#ifdef MODE_SHORT_RANGE_GI
	vec2 candidate_weights = vec2(0.0);
	vec2 previous_arcs = vec2(short_range_gi_arc(horizons.x, 0, cosine_normal, sine_normal, normal_angle), short_range_gi_arc(horizons.y, 1, cosine_normal, sine_normal, normal_angle));
#ifdef SHORT_RANGE_GI_FULL_SAMPLES
	// Validation reference only: evaluate every candidate with the same weights.
	vec3 weighted_radiance = vec3(0.0);
#else
	ivec2 selected_pixels[2];
	vec3 selected_positions[2];
	uint selection_rng = hash_uvec3(uvec3(uvec2(output_position), sequence_index ^ 0x67496231u));
#endif
#endif
	for (int step = 0; step < 3; step++) {
		float fraction = (float(step) + jitter.y) / 3.0;
		float sample_radius = min(1.0 + fraction * fraction * screen_radius, screen_radius);
		ivec2 offset = ivec2(round(screen_direction * sample_radius));
		for (int side = 0; side < 2; side++) {
			vec3 sample_position;
			ivec2 sample_pixel = pixel + (side == 0 ? offset : -offset);
			// Background and out-of-screen samples leave the horizon unoccluded.
			if (!detail_trace_load_view_position(sample_pixel, sample_position)) {
				continue;
			}
			vec3 delta = sample_position - position;
			float distance_squared = dot(delta, delta);
			float radius_squared = radius * radius;
			if (!(distance_squared > 1e-8) || distance_squared >= radius_squared) {
				continue;
			}
			// Rounded screen offsets need not lie exactly in the slice plane.
			// Coplanar samples must not raise the horizon on sloped receivers.
			float height = dot(delta, normal);
			if (height <= 1e-4 || height * height <= distance_squared * 0.0004) {
				continue;
			}
			float falloff = 1.0 - distance_squared / radius_squared;
			falloff *= falloff;
			// A small angular bias suppresses depth quantization self-occlusion.
			float sample_horizon = dot(delta, view_direction) * inversesqrt(distance_squared) - 0.02;
#ifdef MODE_SHORT_RANGE_GI
			float previous_horizon = horizons[side];
#endif
			horizons[side] = max(horizons[side], mix(open_horizons[side], sample_horizon, falloff));
#ifdef MODE_SHORT_RANGE_GI
			if (horizons[side] <= previous_horizon || !(params.short_range_ao.w > 0.0)) {
				continue;
			}
			float arc = short_range_gi_arc(horizons[side], side, cosine_normal, sine_normal, normal_angle);
			float weight = max(previous_arcs[side] - arc, 0.0);
			previous_arcs[side] = arc;
			if (weight > 0.0) {
				candidate_weights[side] += weight;
#ifdef SHORT_RANGE_GI_FULL_SAMPLES
				weighted_radiance += weight * short_range_gi_radiance(sample_pixel, sample_position, position, radiance_limit);
#else
				// One weighted sample per side, held only in registers this frame.
				// Total weight compensates the selection probability; no dark bias
				// from dropping the other candidates or persistent reservoir/history.
				selection_rng = selection_rng * 1664525u + 1013904223u;
				float random_value = float(selection_rng >> 8u) * (1.0 / 16777216.0);
				if (random_value * candidate_weights[side] < weight) {
					selected_pixels[side] = sample_pixel;
					selected_positions[side] = sample_position;
				}
#endif
			}
#endif
		}
	}
	vec2 angles = acos(clamp(horizons, vec2(-1.0), vec2(1.0))) * vec2(1.0, -1.0);
	vec2 arcs = vec2(cosine_normal) + 2.0 * angles * sine_normal - cos(2.0 * angles - normal_angle);
	float visible_integral = normal_length * 0.25 * (arcs.x + arcs.y);
	// Normalize by the open hemisphere, including grazing receiver normals.
	float unoccluded_integral = normal_length * (normal_angle * sine_normal + cosine_normal);
	if (!(unoccluded_integral > 1e-4) || isnan(visible_integral) || isinf(visible_integral)) {
		return 1.0;
	}
	// This is a bounded detail correction to GI, which already includes occlusion.
	float visibility = clamp(visible_integral / unoccluded_integral, 0.35, 1.0);
#ifdef MODE_SHORT_RANGE_GI
	float total_weight = candidate_weights.x + candidate_weights.y;
	if (total_weight > 1e-6 && params.short_range_ao.w > 0.0) {
#ifndef SHORT_RANGE_GI_FULL_SAMPLES
		vec3 weighted_radiance = vec3(0.0);
		for (int side = 0; side < 2; side++) {
			if (candidate_weights[side] > 0.0) {
				weighted_radiance += candidate_weights[side] * short_range_gi_radiance(selected_pixels[side], selected_positions[side], position, radiance_limit);
			}
		}
#endif
		// Replace only part of the AO-removed energy with nearby outgoing light.
		// The feedback coefficient is at most 0.65 * AO intensity * GI intensity.
		r_bounce = weighted_radiance * ((1.0 - visibility) * clamp(params.short_range_ao.y, 0.0, 1.0) * clamp(params.short_range_ao.w, 0.0, 1.0) / total_weight);
	}
#endif
	return mix(1.0, visibility, clamp(params.short_range_ao.y, 0.0, 1.0));
}
