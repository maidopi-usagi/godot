// Shared screen-space geometry access for detail tracing and short-range AO.
bool detail_trace_project(vec3 view_position, out vec3 r_screen_position) {
	vec4 clip = scene_data.projection[params.view_index] * vec4(view_position, 1.0);
	if (!(clip.w > 1e-6) || any(isnan(clip)) || any(isinf(clip))) {
		r_screen_position = vec3(0.0);
		return false;
	}
	r_screen_position = vec3(clip.xy / clip.w * 0.5 + 0.5, clip.z / clip.w);
	return !any(isnan(r_screen_position)) && !any(isinf(r_screen_position));
}

bool detail_trace_load_view_position(ivec2 pixel, out vec3 r_view_position) {
	if (any(lessThan(pixel, ivec2(0))) || any(greaterThanEqual(pixel, params.screen_size))) {
		r_view_position = vec3(0.0);
		return false;
	}
	float depth = texelFetch(sampler2D(detail_hiz_buffer, SCREEN_PROBE_DEPTH_SAMPLER), pixel, 0).r;
	if (!(depth > 0.0)) {
		r_view_position = vec3(0.0);
		return false;
	}
	vec2 uv = (vec2(pixel) + 0.5) / vec2(params.screen_size);
	r_view_position = compute_view_position(vec3(uv, depth));
	return !any(isnan(r_view_position)) && !any(isinf(r_view_position));
}
