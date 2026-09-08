// The cosine-weighted visible arc of one side of the AO slice. Differences
// between successive horizons give the solid-angle weight of each candidate.
float short_range_gi_arc(float horizon, int side, float cosine_normal, float sine_normal, float normal_angle) {
	float angle = acos(clamp(horizon, -1.0, 1.0)) * (side == 0 ? 1.0 : -1.0);
	return 0.25 * (cosine_normal + 2.0 * angle * sine_normal - cos(2.0 * angle - normal_angle));
}

vec3 short_range_gi_radiance(ivec2 pixel, vec3 position, vec3 receiver_position, float radiance_limit) {
	vec4 encoded_normal = texelFetch(sampler2D(detail_normal_roughness_buffer, nearest_sampler), pixel, 0);
	vec3 normal;
	// Camera reprojection only: moving emitters cannot safely reuse SceneColor.
	if (encoded_normal.a > 0.5 || !decode_normal(encoded_normal.xyz, normal)) {
		return vec3(0.0);
	}
	float roughness = clamp(encoded_normal.a / (127.0 / 255.0), 0.0, 1.0);
	float source_facing = dot(normal, normalize(receiver_position - position));
	float source_weight = smoothstep(0.1, 0.4, roughness);
	// The horizon arc already measures a cosine-weighted angular region.
	// Diffuse outgoing radiance is direction-independent on its front side;
	// a second emitter cosine here darkens a constant-radiance environment.
	if (!(source_facing > 0.0) || !(source_weight > 0.0)) {
		return vec3(0.0);
	}
	vec4 world_position = scene_data.cam_transform * vec4(position, 1.0);
	vec3 previous_position = (scene_data.previous_cam_inv_transform * world_position).xyz;
	vec4 clip = scene_data.previous_projection[params.view_index] * vec4(previous_position, 1.0);
	if (!(clip.w > 1e-6) || any(isnan(clip)) || any(isinf(clip))) {
		return vec3(0.0);
	}
	vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
	float projected_depth = clip.z / clip.w;
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThanEqual(uv, vec2(1.0))) || !(projected_depth > 0.0) || projected_depth > 1.0) {
		return vec3(0.0);
	}
	ivec2 history_size = textureSize(sampler2D(short_range_previous_depth, nearest_sampler), 0);
	ivec2 history_pixel = ivec2(uv * vec2(history_size));
	float depth = texelFetch(sampler2D(short_range_previous_depth, nearest_sampler), history_pixel, 0).r;
	if (!(depth > 0.0) || depth > 1.0) {
		return vec3(0.0);
	}
	vec2 history_uv = (vec2(history_pixel) + 0.5) / vec2(history_size);
	vec4 actual_position = scene_data.previous_inv_projection[params.view_index] * vec4(history_uv * 2.0 - 1.0, depth, 1.0);
	vec3 separation = actual_position.xyz / actual_position.w - previous_position;
	vec3 previous_normal = mat3(scene_data.previous_cam_inv_transform) * (mat3(scene_data.cam_transform) * normal);
	// World-space plane distance tolerates raster jitter on a sloped surface,
	// while the depth bound rejects distant, nearly coplanar grazing surfaces.
	float tolerance = max(0.003, params.short_range_ao.x * 0.03);
	if (any(isnan(separation)) || any(isinf(separation)) || abs(dot(separation, previous_normal)) > tolerance ||
			abs(separation.z) > max(params.short_range_ao.x, abs(previous_position.z) * 0.02)) {
		return vec3(0.0);
	}
	vec2 edge_texels = min(uv, vec2(1.0) - uv) * vec2(history_size);
	source_weight *= smoothstep(0.5, 2.0, min(edge_texels.x, edge_texels.y));
	// Point color/depth use the same validated texel; no unvalidated bilinear taps.
	vec3 radiance = texelFetch(sampler2D(short_range_previous_color, nearest_sampler), history_pixel, 0).rgb;
	if (any(isnan(radiance)) || any(isinf(radiance))) {
		return vec3(0.0);
	}
	radiance = max(radiance, vec3(0.0)) * clamp(scene_data.previous_exposure_scale.x, 1.0 / 16.0, 16.0);
	// SceneColor already contains surface albedo, exposure and GI. Preserve hue
	// when limiting bright sources and do not apply HDDAGI energy a second time.
	float peak = max(radiance.r, max(radiance.g, radiance.b));
	return radiance * (source_weight * min(1.0, radiance_limit / max(peak, 1e-6)));
}
// Limit already-exposed SceneColor independently of the receiver's GI, in the
// same HDR range as directional gather. A dark receiver can still see a bright
// neighbor; using its existing irradiance as the limit suppresses that bounce.
const float SCREEN_PROBE_SHORT_RANGE_GI_RADIANCE_MAX = 10.0;
