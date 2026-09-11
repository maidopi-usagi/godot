#ifndef HDDAGI_SCREEN_PROBE_HWRT_INC_GLSL
#define HDDAGI_SCREEN_PROBE_HWRT_INC_GLSL

layout(set = 0, binding = 45) uniform accelerationStructureEXT screen_probe_hwrt_scene;
layout(set = 0, binding = 46, std430) restrict readonly buffer HWRTInstances {
	uvec4 data[]; // Triangle-normal offset, material sample offset, reserved.
}
screen_probe_hwrt_instances;
layout(set = 0, binding = 47, std430) restrict readonly buffer HWRTNormals {
	vec4 data[];
}
screen_probe_hwrt_normals;

layout(set = 0, binding = 48, std430) restrict readonly buffer HWRTMaterials {
	uvec2 data[];
}
screen_probe_hwrt_materials;

struct HWRTLight {
	vec3 color;
	float energy;
	vec3 direction;
	bool has_shadow;
	vec3 position;
	float attenuation;
	uint type;
	float cos_spot_angle;
	float inv_spot_attenuation;
	float radius;
	vec4 area_width;
	vec4 area_height;
	vec4 area_projector_rect;
};
layout(set = 0, binding = 49, std140) restrict readonly buffer HWRTLights {
	HWRTLight data[];
}
screen_probe_hwrt_lights;
layout(set = 0, binding = 50, std140) uniform HWRTScene {
	uint light_count;
	float exposure;
	float max_distance;
	float bounce_feedback;
}
hwrt_scene;
layout(set = 0, binding = 51) uniform texture2D hwrt_area_light_atlas;
layout(set = 0, binding = 52) uniform sampler hwrt_area_light_sampler;

#include "../area_lights_inc.glsl"

vec3 hwrt_offset_reconstructed_origin(vec3 origin_world, vec3 normal_world) {
	// Orthographic depth reconstruction subtracts values on the scale of the
	// far plane. Its float rounding error can exceed the world-space ray epsilon.
	if (abs(scene_data.projection[params.view_index][3][3]) > 0.5) {
		origin_world += normal_world * abs(scene_data.inv_projection[params.view_index][2][2]) * 1.1920928955078125e-7;
	}
	return origin_world;
}

float hwrt_ray_epsilon(vec3 position) {
	return max(0.0001, max(abs(position.x), max(abs(position.y), abs(position.z))) * 2e-7);
}

void hwrt_material_sample(uint base, uvec2 texel, out vec3 albedo, out vec3 emission) {
	uvec2 packed = screen_probe_hwrt_materials.data[base + texel.x + texel.y * 4u];
	vec4 color = vec4((uvec4(packed.x) >> uvec4(0, 8, 16, 24)) & 255u) / 255.0;
	albedo = color.rgb * (1.0 - color.a);
	uvec4 channels = (uvec4(packed.y) >> uvec4(0, 9, 18, 27)) & uvec4(511, 511, 511, 31);
	emission = vec3(channels.xyz) * exp2(float(channels.w) - 24.0);
}

void hwrt_material(uint base, vec2 barycentric, out vec3 albedo, out vec3 emission) {
	// Interpolate within the triangular 4x4 chart, never across primitive edges.
	vec2 uv = clamp(barycentric * 3.0, vec2(0.0), vec2(2.9999));
	uvec2 cell = uvec2(uv);
	vec2 fraction = fract(uv);
	bool upper = fraction.x + fraction.y > 1.0 && cell.x + cell.y < 2u;
	vec3 weights = upper ? vec3(fraction.x + fraction.y - 1.0, 1.0 - fraction.y, 1.0 - fraction.x) : vec3(1.0 - fraction.x - fraction.y, fraction.x, fraction.y);
	vec3 a0, a1, a2, e0, e1, e2;
	hwrt_material_sample(base, cell + (upper ? uvec2(1) : uvec2(0)), a0, e0);
	hwrt_material_sample(base, cell + uvec2(1, 0), a1, e1);
	hwrt_material_sample(base, cell + uvec2(0, 1), a2, e2);
	albedo = clamp(a0 * weights.x + a1 * weights.y + a2 * weights.z, vec3(0.0), vec3(1.0));
	emission = max(e0 * weights.x + e1 * weights.y + e2 * weights.z, vec3(0.0));
}

bool hwrt_trace(vec3 origin_world, vec3 direction_world, vec3 receiver_normal_world, out vec3 position, out vec3 normal, out vec3 albedo, out vec3 emission) {
	position = vec3(0.0);
	normal = vec3(0.0, 0.0, 1.0);
	albedo = vec3(0.0);
	emission = vec3(0.0);
	float epsilon = hwrt_ray_epsilon(origin_world);
	vec3 origin = origin_world + receiver_normal_world * epsilon;
	rayQueryEXT query;
	rayQueryInitializeEXT(query, screen_probe_hwrt_scene, gl_RayFlagsOpaqueEXT, 0xff, origin, epsilon, direction_world, hwrt_scene.max_distance);
	while (rayQueryProceedEXT(query)) {
	}
	if (rayQueryGetIntersectionTypeEXT(query, true) != gl_RayQueryCommittedIntersectionTriangleEXT) {
		return false;
	}
	uvec4 instance = screen_probe_hwrt_instances.data[rayQueryGetIntersectionInstanceCustomIndexEXT(query, true)];
	uint primitive = rayQueryGetIntersectionPrimitiveIndexEXT(query, true);
	vec3 normal_object = screen_probe_hwrt_normals.data[instance.x + primitive].xyz;
	normal = normalize(transpose(mat3(rayQueryGetIntersectionWorldToObjectEXT(query, true))) * normal_object);
	if (dot(normal, direction_world) > 0.0) {
		normal = -normal;
	}
	position = origin + direction_world * rayQueryGetIntersectionTEXT(query, true);
	hwrt_material(instance.y + primitive * 16u, rayQueryGetIntersectionBarycentricsEXT(query, true), albedo, emission);
	return true;
}

bool hwrt_shadowed(vec3 position, vec3 normal, vec3 direction, float distance) {
	float epsilon = hwrt_ray_epsilon(position);
	if (distance <= epsilon * 2.0) {
		return false;
	}
	rayQueryEXT query;
	rayQueryInitializeEXT(query, screen_probe_hwrt_scene, gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT, 0xff,
			position + normal * epsilon, epsilon, direction, distance - epsilon);
	while (rayQueryProceedEXT(query)) {
	}
	return rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionTriangleEXT;
}

float hwrt_attenuation(float distance, float radius, float decay) {
	float normalized = distance / max(radius, 0.0001);
	float falloff = max(1.0 - pow(normalized, 4.0), 0.0);
	return falloff * falloff * pow(max(distance, 0.0001), -decay);
}

vec3 hwrt_direct_lighting(vec3 position, vec3 normal, vec3 albedo, vec3 emission) {
	vec3 radiance = emission;
	for (uint i = 0u; i < hwrt_scene.light_count; i++) {
		HWRTLight light = screen_probe_hwrt_lights.data[i];
		vec3 direction = -light.direction;
		float distance = hwrt_scene.max_distance;
		float attenuation = 1.0;
		vec3 texture_color = vec3(1.0);
		if (light.type != 0u) {
			vec3 vector = light.position - position;
			distance = length(vector);
			direction = vector / max(distance, 0.0001);
			attenuation = hwrt_attenuation(distance, light.radius, light.attenuation);
			if (light.type == 2u) {
				float cone = max(dot(-direction, light.direction), light.cos_spot_angle);
				float rim = (1.0 - cone) / max(1.0 - light.cos_spot_angle, 0.0001);
				attenuation *= 1.0 - pow(rim, light.inv_spot_attenuation);
			} else if (light.type == 3u) {
				vec3 width = light.area_width.xyz * 0.5;
				vec3 height = light.area_height.xyz * 0.5;
				vec3 points[4] = vec3[](vector - width - height, vector + width - height, vector + width + height, vector - width + height);
				float diffuse;
				ltc_evaluate_diff(normal, points, light.area_projector_rect, light.cos_spot_angle, hwrt_area_light_atlas, hwrt_area_light_sampler, diffuse, texture_color);
				attenuation = hwrt_attenuation(distance, light.radius, light.attenuation - 2.0) * diffuse;
			}
		}
		if (light.type != 3u) {
			attenuation *= max(dot(normal, direction), 0.0);
		}
		if (attenuation > 0.0 && (!light.has_shadow || !hwrt_shadowed(position, normal, direction, min(distance, hwrt_scene.max_distance)))) {
			radiance += albedo * light.color * texture_color * light.energy * attenuation;
		}
	}
	return max(radiance, vec3(0.0)) * hwrt_scene.exposure;
}

bool trace_screen_probe_hwrt(vec3 origin_world, vec3 direction_world, vec3 receiver_normal_world,
		out vec3 radiance, out int hit_cascade, out vec3 endpoint_world, out vec3 endpoint_normal_world) {
	radiance = vec3(0.0);
	hit_cascade = -1;
	endpoint_world = vec3(0.0);
	endpoint_normal_world = vec3(0.0, 0.0, 1.0);
	vec3 albedo;
	vec3 emission;
	if (!hwrt_trace(origin_world, direction_world, receiver_normal_world, endpoint_world, endpoint_normal_world, albedo, emission)) {
		return false;
	}
	hit_cascade = HDDAGI_TRACE_HWRT_ENDPOINT;
	screen_probe_debug_set_source(SCREEN_PROBE_DEBUG_HWRT);
#ifdef MODE_IRRADIANCE_CACHE_QUERY
	HDDAGIIrradianceCacheLookup lookup = hddagi_irradiance_cache_empty_lookup();
	// A changed triangle scene invalidates cached lighting, including shadows on
	// static receivers. Do not populate a freshly cleared cache until the scene
	// has survived one frame unchanged; continuous animation cannot reuse it.
	bool cache_stable = hddagi_irradiance_cache_params.control.x != 0u;
	// Rotate one writer per 8x8 tile. The other rays only read published entries
	// or shade their actual hit, avoiding per-pixel allocation/voting contention.
	uint writer_index = (gl_GlobalInvocationID.x & 7u) | ((gl_GlobalInvocationID.y & 7u) << 3u);
	bool cache_update = cache_stable && writer_index == (params.frame_index & 63u);
	if (cache_stable) {
		lookup = hddagi_irradiance_cache_lookup(endpoint_world, endpoint_normal_world, origin_world, cache_update);
	}
	if (lookup.has_radiance && !lookup.needs_refresh) {
		radiance = lookup.radiance;
		return true;
	}
#endif
	radiance = hwrt_direct_lighting(endpoint_world, endpoint_normal_world, albedo, emission);
	// One optional extra diffuse bounce, using the same triangle scene. No world
	// probes or voxel-driven multibounce training are involved.
	if (hwrt_scene.bounce_feedback > 0.0 && any(greaterThan(albedo, vec3(0.0)))) {
#ifdef MODE_SPECULAR_TRACE
		// Use a separate, temporally permuted stream for reflected indirect light.
		// A common R2 phase across the mirror produces coherent moving noise.
		vec2 random_sample = sample_temporally_permuted_r2_sequence(gl_GlobalInvocationID.xy, params.frame_index, 0x48575242u ^ (params.view_index * 0x9e3779b9u));
#else
		uvec2 seed = floatBitsToUint(origin_world.xy) ^ uvec2(floatBitsToUint(origin_world.z));
		vec2 random_sample = sample_r2_sequence(seed, params.frame_index);
#endif
		vec3 direction = tangent_to_world(cosine_sample_hemisphere(random_sample), endpoint_normal_world);
		vec3 next_position, next_normal, next_albedo, next_emission;
		vec3 incoming;
		if (hwrt_trace(endpoint_world, direction, endpoint_normal_world, next_position, next_normal, next_albedo, next_emission)) {
			incoming = hwrt_direct_lighting(next_position, next_normal, next_albedo, next_emission);
		} else {
			incoming = sample_environment(transpose(mat3(scene_data.cam_transform)) * direction);
		}
		radiance += hwrt_scene.bounce_feedback * albedo * incoming;
	}
	if (any(isnan(radiance)) || any(isinf(radiance))) {
		radiance = vec3(0.0);
	}
	radiance = max(radiance, vec3(0.0));
#ifdef MODE_IRRADIANCE_CACHE_QUERY
	if (cache_update && hddagi_irradiance_cache_should_submit_endpoint_sample(lookup)) {
		hddagi_irradiance_cache_submit(lookup, endpoint_world, endpoint_normal_world, radiance);
	}
#endif
	return true;
}

#endif // HDDAGI_SCREEN_PROBE_HWRT_INC_GLSL
