#ifndef HDDAGI_SCREEN_PROBE_HWRT_INC_GLSL
#define HDDAGI_SCREEN_PROBE_HWRT_INC_GLSL

#include "../gpu_scene_geometry_inc.glsl"

#ifdef MODE_SPECULAR_TRACE
vec3 hwrt_specular_direct_radiance = vec3(0.0);
vec3 hwrt_specular_albedo = vec3(0.0);
#endif

layout(set = 0, binding = 45) uniform accelerationStructureEXT screen_probe_hwrt_scene;
layout(set = 0, binding = 46, std430) restrict readonly buffer HWRTInstances {
	uvec4 data[]; // Two records: triangle/sample offsets + surface version; UV offset + material index.
}
screen_probe_hwrt_instances;
layout(set = 0, binding = 47, std430) restrict readonly buffer HWRTTriangles {
	GPUSceneTriangle data[];
}
screen_probe_hwrt_triangles;

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
	vec4 animation;
}
hwrt_scene;
layout(set = 0, binding = 51) uniform texture2D hwrt_area_light_atlas;
layout(set = 0, binding = 52) uniform sampler hwrt_area_light_sampler;

#ifdef USE_BINDLESS_HWRT
layout(set = 4, binding = 0) uniform texture2D gpu_scene_textures[];
layout(set = 0, binding = 56) uniform sampler gpu_scene_samplers[12];
#include "../gpu_scene_material_inc.glsl"
layout(set = 0, binding = 54, std430) restrict readonly buffer GPUSceneMaterials {
	GPUSceneMaterial data[];
}
gpu_scene_materials;
layout(set = 0, binding = 55, std430) restrict readonly buffer HWRTUVs {
	vec2 data[];
}
screen_probe_hwrt_uvs;
layout(set = 0, binding = 57, std430) restrict readonly buffer GPUSceneCustomUniforms {
	uint data[];
}
gpu_scene_custom_uniforms;

#CODE : GPU_SCENE_CUSTOM
#endif

#include "../area_lights_inc.glsl"

#ifndef MODE_IRRADIANCE_CACHE_UPDATE_MULTIBOUNCE
vec2 hwrt_camera_ray_cone(vec3 origin_view) {
	bool orthogonal = abs(scene_data.projection[params.view_index][3][3]) > 0.5;
	vec2 pixel_size = 2.0 * abs(vec2(scene_data.inv_projection[params.view_index][0][0], scene_data.inv_projection[params.view_index][1][1])) / vec2(params.gi_size);
	float width = max(pixel_size.x, pixel_size.y) * (orthogonal ? 1.0 : abs(origin_view.z));
	// Rough reflections already sample the GGX lobe. Widening this cone by the
	// same roughness would filter the lobe twice and erase reflected detail.
	return vec2(width, orthogonal ? 0.0 : width / max(length(origin_view), 1e-6));
}

vec3 hwrt_offset_reconstructed_origin(vec3 origin_world, vec3 normal_world) {
	// Orthographic depth reconstruction subtracts values on the scale of the
	// far plane. Its float rounding error can exceed the world-space ray epsilon.
	if (abs(scene_data.projection[params.view_index][3][3]) > 0.5) {
		origin_world += normal_world * abs(scene_data.inv_projection[params.view_index][2][2]) * 1.1920928955078125e-7;
	}
	return origin_world;
}
#endif

float hwrt_ray_epsilon(vec3 position) {
	return max(0.0001, max(abs(position.x), max(abs(position.y), abs(position.z))) * 2e-7);
}

void hwrt_material_sample(uint base, uvec2 texel, out vec3 albedo, out vec3 emission) {
	// On the hypotenuse, interpolation can fetch an exterior point with zero
	// weight. Keep that fetch inside this primitive's ten stored chart samples.
	texel.x = min(texel.x, 3u - texel.y);
	uvec2 packed = screen_probe_hwrt_materials.data[base + texel.x + texel.y * (9u - texel.y) / 2u];
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

bool hwrt_trace(vec3 origin_world, vec3 direction_world, vec3 receiver_normal_world, vec2 ray_cone, out vec3 position, out vec3 normal, out vec3 geometric_normal, out vec3 albedo, out vec3 emission, out uvec3 surface_key) {
	position = vec3(0.0);
	normal = vec3(0.0, 0.0, 1.0);
	geometric_normal = normal;
	albedo = vec3(0.0);
	emission = vec3(0.0);
	surface_key = uvec3(0u);
	float epsilon = hwrt_ray_epsilon(origin_world);
	vec3 origin = origin_world + receiver_normal_world * epsilon;
	rayQueryEXT query;
	rayQueryInitializeEXT(query, screen_probe_hwrt_scene, gl_RayFlagsOpaqueEXT, 0xff, origin, epsilon, direction_world, hwrt_scene.max_distance);
	while (rayQueryProceedEXT(query)) {
	}
	if (rayQueryGetIntersectionTypeEXT(query, true) != gl_RayQueryCommittedIntersectionTriangleEXT) {
		return false;
	}
	uint instance_index = rayQueryGetIntersectionInstanceCustomIndexEXT(query, true);
	uvec4 instance = screen_probe_hwrt_instances.data[instance_index * 2u];
	surface_key = uvec3(instance_index, instance.zw);
	uint primitive = rayQueryGetIntersectionPrimitiveIndexEXT(query, true);
	GPUSceneTriangle triangle = screen_probe_hwrt_triangles.data[instance.x + primitive];
	mat3 object_to_world = mat3(rayQueryGetIntersectionObjectToWorldEXT(query, true));
	vec3 edge1 = object_to_world * triangle.edge1.xyz;
	vec3 edge2 = object_to_world * triangle.edge2.xyz;
	geometric_normal = gpu_scene_triangle_normal(edge1, edge2);
	if (dot(geometric_normal, direction_world) > 0.0) {
		geometric_normal = -geometric_normal;
	}
	float hit_distance = rayQueryGetIntersectionTEXT(query, true);
	position = origin + direction_world * hit_distance;
	vec2 barycentric = rayQueryGetIntersectionBarycentricsEXT(query, true);
	mat3 world_to_object = mat3(rayQueryGetIntersectionWorldToObjectEXT(query, true));
	normal = gpu_scene_triangle_shading_normal(triangle, barycentric, world_to_object, geometric_normal, direction_world);
#ifdef USE_BINDLESS_HWRT
	uvec4 attributes = screen_probe_hwrt_instances.data[instance_index * 2u + 1u];
	if (attributes.y != 0xffffffffu) {
		uint vertex = attributes.x + primitive * 3u;
		vec2 uv0 = screen_probe_hwrt_uvs.data[vertex];
		vec2 uv1 = screen_probe_hwrt_uvs.data[vertex + 1u] - uv0;
		vec2 uv2 = screen_probe_hwrt_uvs.data[vertex + 2u] - uv0;
		vec2 uv = uv0 + uv1 * barycentric.x + uv2 * barycentric.y;
		mat2 gradients = gpu_scene_ray_cone_gradients(edge1, edge2, uv1, uv2, direction_world, ray_cone.x + hit_distance * ray_cone.y);
		GPUSceneMaterial material = gpu_scene_materials.data[attributes.y];
#ifdef GPU_SCENE_CUSTOM_CODE_USED
		if (!gpu_scene_evaluate_custom(material, uv, gradients, hwrt_scene.animation.xyz, albedo, emission))
#endif
		{
			gpu_scene_sample_material(material, uv, gradients, albedo, emission);
		}
	} else
#endif
	{
		hwrt_material(instance.y + primitive * 10u, barycentric, albedo, emission);
	}
	return true;
}

bool hwrt_trace(vec3 origin_world, vec3 direction_world, vec3 receiver_normal_world, vec2 ray_cone, out vec3 position, out vec3 normal, out vec3 geometric_normal, out vec3 albedo, out vec3 emission) {
	uvec3 surface_key;
	return hwrt_trace(origin_world, direction_world, receiver_normal_world, ray_cone, position, normal, geometric_normal, albedo, emission, surface_key);
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

vec3 hwrt_direct_lighting(vec3 position, vec3 normal, vec3 geometric_normal, vec3 albedo, vec3 emission) {
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
		if (attenuation > 0.0 && dot(geometric_normal, direction) > 0.0 &&
				(!light.has_shadow || !hwrt_shadowed(position, geometric_normal, direction, min(distance, hwrt_scene.max_distance)))) {
			radiance += albedo * light.color * texture_color * light.energy * attenuation;
		}
	}
	return max(radiance, vec3(0.0)) * hwrt_scene.exposure;
}

#ifdef MODE_IRRADIANCE_CACHE_QUERY
vec3 hwrt_sample_guided_diffuse(uint guide_entry, vec3 normal, vec2 random_sample, out float r_pdf) {
	float guide_strength = hddagi_guide_strength(guide_entry);
	vec3 direction;
	if (random_sample.x < guide_strength) {
		random_sample.x /= guide_strength;
		direction = hddagi_guide_sample(guide_entry, random_sample);
	} else {
		random_sample.x = (random_sample.x - guide_strength) / (1.0 - guide_strength);
		direction = tangent_to_world(cosine_sample_hemisphere(random_sample), normal);
	}
	// Balance MIS for a single sample from the mixture. Both branches use
	// the complete solid-angle PDF, including the probability of the branch.
	float cosine_pdf = max(dot(normal, direction), 0.0) / HDDAGI_GUIDE_PI;
	float guide_pdf = guide_strength > 0.0 ? hddagi_guide_pdf(guide_entry, direction) : 0.0;
	r_pdf = (1.0 - guide_strength) * cosine_pdf + guide_strength * guide_pdf;
	return direction;
}
#endif

// A cosine-weighted estimate of incident irradiance / PI, independent of the
// root material. Recursive queries read only the previously resolved lighting.
vec3 hwrt_sample_incident(vec3 position, vec3 normal, vec3 geometric_normal, vec2 ray_cone, vec2 random_sample, bool request_surface) {
	vec3 direction = tangent_to_world(cosine_sample_hemisphere(random_sample), normal);
	// A smooth normal can sample below the physical triangle. Treat that sample
	// as occluded without resampling, which would renormalize and add energy.
	if (dot(direction, geometric_normal) <= 0.0) {
		return vec3(0.0);
	}
	vec3 next_position, next_normal, next_geometric_normal, next_albedo, next_emission;
	uvec3 surface_key;
	if (!hwrt_trace(position, direction, geometric_normal, ray_cone, next_position, next_normal, next_geometric_normal, next_albedo, next_emission, surface_key)) {
		return sample_environment(transpose(mat3(scene_data.cam_transform)) * direction);
	}
	vec3 incoming = hwrt_direct_lighting(next_position, next_normal, next_geometric_normal, next_albedo, next_emission);
#if defined(MODE_IRRADIANCE_CACHE_QUERY) || defined(MODE_IRRADIANCE_CACHE_UPDATE_MULTIBOUNCE)
	if (hddagi_irradiance_cache_multibounce_enabled() && any(greaterThan(next_albedo, vec3(0.0)))) {
		HDDAGIIrradianceCacheLookup next = hddagi_irradiance_cache_lookup(next_position, next_normal, position, request_surface, surface_key, next_geometric_normal);
		vec3 next_incident = next.radiance;
#ifdef MODE_IRRADIANCE_CACHE_UPDATE_MULTIBOUNCE
		if (!next.has_radiance) {
			// A cold or incompatible secondary surface still gets a short path
			// estimate. In particular, cells shared by a corner must not behave
			// like black termination surfaces in every recursive iteration.
			uvec2 seed = floatBitsToUint(next_position.xy) ^ uvec2(floatBitsToUint(next_position.z));
			vec2 secondary_sample = sample_r2_sequence(seed, hddagi_irradiance_cache_params.control.x);
			vec3 direction = tangent_to_world(cosine_sample_hemisphere(secondary_sample), next_normal);
			vec3 fallback_position, fallback_normal, fallback_geometric_normal, fallback_albedo, fallback_emission;
			vec2 next_cone = vec2(ray_cone.x + length(next_position - position) * ray_cone.y, ray_cone.y);
			if (dot(direction, next_geometric_normal) <= 0.0) {
				next_incident = vec3(0.0);
			} else if (hwrt_trace(next_position, direction, next_geometric_normal, next_cone, fallback_position, fallback_normal, fallback_geometric_normal, fallback_albedo, fallback_emission)) {
				next_incident = hwrt_direct_lighting(fallback_position, fallback_normal, fallback_geometric_normal, fallback_albedo, fallback_emission);
			} else {
				next_incident = sample_environment(transpose(mat3(scene_data.cam_transform)) * direction);
			}
		}
#else
		// Reconstruct the visible query, but keep spatial filtering out of the
		// recursive training feedback so each entry retains its own solution.
		hddagi_irradiance_cache_interpolate(next_position, next_normal, surface_key, next_incident);
#endif
		incoming += clamp(hwrt_scene.bounce_feedback, 0.0, 1.0) * next_albedo * next_incident;
	}
#endif
	return incoming;
}

#ifdef MODE_IRRADIANCE_CACHE_UPDATE_MULTIBOUNCE
void irradiance_cache_update_multibounce_hwrt() {
	uint entry_index = gl_GlobalInvocationID.x;
	uint stride = hddagi_irradiance_cache_training_stride();
	uint frame = hddagi_irradiance_cache_params.control.x;
	if ((entry_index + frame) % stride != 0u) {
		return;
	}
	HDDAGIIrradianceCacheLookup root = hddagi_irradiance_cache_load_entry(entry_index);
	if (!root.valid) {
		return;
	}
	// Amortize a denser estimate across all consumers. Publish one weighted
	// batch so training does not spend its budget contending on the request queue.
	const uint sample_count = 16u;
	vec3 incident = vec3(0.0);
	uint guide_base = entry_index * HDDAGI_IRRADIANCE_CACHE_GUIDE_STRIDE;
	bool train_guide = hddagi_guide_enabled();
	if (train_guide) {
		for (uint i = 0u; i < 16u; i++) {
			hddagi_irradiance_cache_guide[guide_base + HDDAGI_IRRADIANCE_CACHE_GUIDE_BATCH_OFFSET + i] = vec4(0.0);
		}
	}
	uint request_stratum = ((frame / stride) + entry_index) & (sample_count - 1u);
	for (uint sample_index = 0u; sample_index < sample_count; sample_index++) {
		// Give each stratum its own stream and advance it once per update.
		// Stepping one interleaved R2 sequence by 16 leaves large gaps within
		// bounded history, producing slowly moving patches in the cache.
		vec2 random_sample = sample_r2_sequence(uvec2(entry_index, root.generation ^ (sample_index * 0x9e3779b9u)), frame / stride);
		// Cover every stratum of the cosine-sampling domain in each update to
		// reduce variance from emissive surfaces without increasing the ray budget.
		random_sample = (vec2(sample_index & 3u, sample_index >> 2u) + random_sample) * 0.25;
		vec3 sample_incident = hwrt_sample_incident(root.sample_position, root.sample_normal, root.sample_geometric_normal, vec2(root.cell_size, 0.0), random_sample, sample_index == request_stratum);
		incident += sample_incident;
		// Cosine training samples already estimate L * cos(theta) / PI.
		// Accumulate their contribution into world-direction bins, retaining
		// information that the integrated irradiance coefficients cannot carry.
		if (train_guide) {
			vec3 direction = tangent_to_world(cosine_sample_hemisphere(random_sample), root.sample_normal);
			uint bin = hddagi_guide_bin(direction);
			float mass = dot(max(sample_incident, vec3(0.0)), vec3(0.2126, 0.7152, 0.0722));
			if (!isnan(mass) && !isinf(mass)) {
				hddagi_irradiance_cache_guide[guide_base + HDDAGI_IRRADIANCE_CACHE_GUIDE_BATCH_OFFSET + bin / 4u][bin & 3u] += min(mass, 1e12);
			}
		}
	}
	if (train_guide) {
		hddagi_irradiance_cache_guide[guide_base + HDDAGI_IRRADIANCE_CACHE_GUIDE_META_OFFSET].y = float(sample_count);
	}
	incident = min(incident / float(sample_count), vec3(HDDAGI_IRRADIANCE_CACHE_RADIANCE_CLAMP));
	hddagi_irradiance_cache_submit(root, root.sample_position, root.sample_normal, incident, sample_count);
}
#else
bool trace_screen_probe_hwrt(vec3 origin_world, vec3 direction_world, vec3 receiver_normal_world, vec2 ray_cone,
		out vec3 radiance, out int hit_cascade, out vec3 endpoint_world, out vec3 endpoint_normal_world) {
	radiance = vec3(0.0);
	hit_cascade = -1;
	endpoint_world = vec3(0.0);
	endpoint_normal_world = vec3(0.0, 0.0, 1.0);
	vec3 albedo;
	vec3 emission;
	vec3 geometric_normal;
	uvec3 surface_key;
	if (!hwrt_trace(origin_world, direction_world, receiver_normal_world, ray_cone, endpoint_world, endpoint_normal_world, geometric_normal, albedo, emission, surface_key)) {
		return false;
	}
	hit_cascade = HDDAGI_TRACE_HWRT_ENDPOINT;
	screen_probe_debug_set_source(SCREEN_PROBE_DEBUG_HWRT);
	radiance = hwrt_direct_lighting(endpoint_world, endpoint_normal_world, geometric_normal, albedo, emission);
#ifdef MODE_SPECULAR_TRACE
	hwrt_specular_direct_radiance = radiance;
	hwrt_specular_albedo = albedo;
#endif
#ifdef MODE_IRRADIANCE_CACHE_QUERY
	HDDAGIIrradianceCacheLookup lookup = hddagi_irradiance_cache_empty_lookup();
	// Rotate one writer per 8x8 tile. The other rays only read published entries
	// or shade their actual hit, avoiding per-pixel allocation/voting contention.
	uint writer_index = (gl_GlobalInvocationID.x & 7u) | ((gl_GlobalInvocationID.y & 7u) << 3u);
	bool cache_update = writer_index == (params.frame_index & 63u);
	if (hwrt_scene.bounce_feedback > 0.0 && any(greaterThan(albedo, vec3(0.0)))) {
		lookup = hddagi_irradiance_cache_lookup(endpoint_world, endpoint_normal_world, origin_world, cache_update, surface_key, geometric_normal);
		vec3 cached_incident;
		if (hddagi_irradiance_cache_interpolate(endpoint_world, endpoint_normal_world, surface_key, cached_incident)) {
			screen_probe_debug_set_source(SCREEN_PROBE_DEBUG_HWRT_IRRADIANCE_CACHE);
			radiance += hwrt_scene.bounce_feedback * albedo * cached_incident;
			return true;
		}
	}
#endif
	// Untrained surfaces keep the existing short HWRT estimate while their
	// world-space entries are requested and trained independently of the view.
	if (hwrt_scene.bounce_feedback > 0.0 && any(greaterThan(albedo, vec3(0.0)))) {
#ifdef MODE_SPECULAR_TRACE
		// Use a separate, temporally permuted stream for reflected indirect light.
		// A common R2 phase across the mirror produces coherent moving noise.
		vec2 random_sample = sample_temporally_permuted_r2_sequence(gl_GlobalInvocationID.xy, params.frame_index, 0x48575242u ^ (params.view_index * 0x9e3779b9u));
#else
		uvec2 seed = floatBitsToUint(origin_world.xy) ^ uvec2(floatBitsToUint(origin_world.z));
		vec2 random_sample = sample_r2_sequence(seed, params.frame_index);
#endif
		vec2 next_cone = vec2(ray_cone.x + length(endpoint_world - origin_world) * ray_cone.y, ray_cone.y);
		vec3 incoming = hwrt_sample_incident(endpoint_world, endpoint_normal_world, geometric_normal, next_cone, random_sample, false);
		radiance += hwrt_scene.bounce_feedback * albedo * incoming;
#ifdef MODE_IRRADIANCE_CACHE_QUERY
		if (cache_update && hddagi_irradiance_cache_should_submit_endpoint_sample(lookup)) {
			hddagi_irradiance_cache_submit(lookup, endpoint_world, endpoint_normal_world, incoming);
		}
#endif
	}
	if (any(isnan(radiance)) || any(isinf(radiance))) {
		radiance = vec3(0.0);
	}
	radiance = max(radiance, vec3(0.0));
	return true;
}
#endif

#endif // HDDAGI_SCREEN_PROBE_HWRT_INC_GLSL
