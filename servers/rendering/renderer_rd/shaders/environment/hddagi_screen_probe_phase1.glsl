#[compute]

#version 450

#VERSION_DEFINES

#if defined(NVIDIA_SHARC_ENABLED) && (defined(MODE_SHARC_UPDATE) || defined(MODE_SHARC_RESOLVE) || defined(MODE_SHARC_QUERY))
#define HDDAGI_SHARC_ACTIVE 1
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_buffer_reference_uvec2 : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
#extension GL_EXT_shader_atomic_int64 : require
#extension GL_EXT_shader_explicit_arithmetic_types_float16 : require
#extension GL_EXT_shader_16bit_storage : require
#extension GL_EXT_control_flow_attributes : require

#define SHARC_ENABLE_GLSL 1
#if defined(MODE_SHARC_UPDATE)
#define SHARC_UPDATE 1
#else
#define SHARC_UPDATE 0
#endif
#if defined(MODE_SHARC_QUERY)
#define SHARC_QUERY 1
#else
#define SHARC_QUERY 0
#endif
#define SHARC_ENABLE_RESPONSIVE_LIGHTING 0
#define SHARC_ENABLE_SH_ENCODING 0
#define SHARC_MATERIAL_DEMODULATION 0
#define SHARC_SEPARATE_EMISSIVE 0
#define SHARC_ENABLE_CACHE_RESAMPLING 0
#define SHARC_USE_FP16 0
#define HASH_GRID_ENABLE_64_BIT_ATOMICS 1
#define HASH_GRID_COMPACT 0
#define HASH_GRID_USE_NORMALS 1

#include_external "SharcGlslHelpers.h"
#include_external "SharcCommon.h"

#if SHARC_VERSION_MAJOR != 1 || SHARC_VERSION_MINOR != 8 || SHARC_VERSION_BUILD != 3 || SHARC_VERSION_REVISION != 0
#error "HDDAGI SHARC integration requires SHARC 1.8.3.0 exactly"
#endif
#endif

#include "../oct_inc.glsl"

#ifdef MODE_SHARC_RESOLVE
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
#else
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
#endif

// Each compile variant declares only the resources it consumes. Persistent
// radiance reuse is provided exclusively by the optional SHARC set 2; the
// removed experimental world-cache descriptors never enter this layout.
const uint PHASE1_FLAG_HISTORY_VALID = 1u;
const uint PHASE1_FLAG_REFERENCE_MODE = 2u;
const uint PHASE1_FLAG_GPU_STATS = 4u;
const uint PHASE1_FLAG_RESERVOIR_HISTORY_VALID = 8u;
const uint PHASE1_FLAG_SHARC_UPDATE_SURFACE = 16u;

const uint PHASE1_SKY_DISABLED = 0u;
const uint PHASE1_SKY_COLOR = 1u;
const uint PHASE1_SKY_TEXTURE = 2u;
const float SHARC_CACHE_RADIANCE_MAX = 64.0;

const uint PHASE1_STAT_FRESH_CANDIDATES = 0u;
const uint PHASE1_STAT_HDDA_RAYS = 3u;
const uint PHASE1_STAT_HDDA_STEPS = 4u;
const uint PHASE1_STAT_HDDA_HITS = 5u;
const uint PHASE1_STAT_HDDA_MISSES = 6u;
const uint PHASE1_STAT_HISTORY_ACCEPTS = 7u;
const uint PHASE1_STAT_HISTORY_REJECTS = 8u;
const uint PHASE1_STAT_SHARC_QUERY_ATTEMPTS = 9u;
const uint PHASE1_STAT_SHARC_QUERY_HITS = 10u;
const uint PHASE1_STAT_SHARC_QUERY_INELIGIBLE = 11u;
const uint PHASE1_STAT_SHARC_QUERY_MISSES = 12u;
const uint PHASE1_STAT_SHARC_UPDATE_RAYS = 13u;
const uint PHASE1_STAT_SHARC_UPDATE_MISSES = 14u;
const uint PHASE1_STAT_SHARC_UPDATE_REJECTS = 15u;
const uint PHASE1_STAT_RAW_SAMPLE_COUNT = 16u;
const uint PHASE1_STAT_RAW_SUM_R = 17u;
const uint PHASE1_STAT_RAW_SUM_G = 18u;
const uint PHASE1_STAT_RAW_SUM_B = 19u;
const uint PHASE1_STAT_RAW_OVERFLOW_OR_NONFINITE = 20u;
const uint PHASE1_STAT_RAW_ACCUMULATED_FRAMES = 21u;
const uint PHASE1_STAT_RAW_PHASE_MASK_BASE = 24u;

const uint PHASE2_STAT_VALID_SURFACES = 32u;
const uint PHASE2_STAT_FRESH_VALID = 33u;
const uint PHASE2_STAT_FRESH_INVALID = 34u;
const uint PHASE2_STAT_TEMPORAL_ATTEMPTS = 35u;
const uint PHASE2_STAT_TEMPORAL_ACCEPTED = 36u;
const uint PHASE2_STAT_REJECT_NO_HISTORY = 37u;
const uint PHASE2_STAT_REJECT_REPROJECTION_OR_OWNER = 38u;
const uint PHASE2_STAT_REJECT_GENERATION_OR_ALGORITHM = 39u;
const uint PHASE2_STAT_REJECT_ENDPOINT_IDENTITY_OR_VERSION = 40u;
const uint PHASE2_STAT_REJECT_VISIBILITY = 41u;
const uint PHASE2_STAT_REJECT_JACOBIAN = 42u;
const uint PHASE2_STAT_REJECT_AGE = 43u;
const uint PHASE2_STAT_VISIBILITY_RAYS = 44u;
const uint PHASE2_STAT_VISIBILITY_VISIBLE = 45u;
const uint PHASE2_STAT_VISIBILITY_OCCLUDED = 46u;
const uint PHASE2_STAT_M_CAP_APPLIED = 47u;
const uint PHASE2_STAT_SELECTED_FRESH = 48u;
const uint PHASE2_STAT_SELECTED_HISTORY = 49u;
const uint PHASE2_STAT_FINAL_VALID = 50u;
const uint PHASE2_STAT_FINAL_INVALID = 51u;
const uint PHASE2_STAT_NONFINITE = 52u;
const uint PHASE2_STAT_ROBUST_JACOBIAN_CLAMP = 53u;
const uint PHASE2_STAT_MAX_M = 54u;
const uint PHASE2_STAT_MAX_AGE = 55u;
const uint PHASE2_STAT_SUM_M = 56u;
const uint PHASE2_STAT_PACKING_INVALID = 57u;
const uint PHASE2_STAT_HIT_REUSE = 58u;
const uint PHASE2_STAT_SKY_REUSE = 59u;
const uint PHASE2_STAT_GPU_GOLDEN_DIGEST_BASE = 60u;
const uint PHASE2_STAT_ROBUST_FLAG_FINAL_FRESH = 64u;
const uint PHASE2_STAT_ROBUST_FLAG_FINAL_HISTORY = 65u;
const uint PHASE2_STAT_ZERO_TARGET_MASS_ONLY = 66u;
const uint PHASE2_STAT_GPU_ZERO_TARGET_BRANCH_GOLDEN = 67u;

const uint PHASE3_STAT_SPATIAL_STREAMS = 68u;
const uint PHASE3_STAT_SPATIAL_ACCEPTED = 69u;
const uint PHASE3_STAT_SPATIAL_EDGE_REJECT = 70u;
const uint PHASE3_STAT_SPATIAL_IDENTITY_REJECT = 71u;
const uint PHASE3_STAT_SPATIAL_VISIBILITY_RAYS = 72u;
const uint PHASE3_STAT_SPATIAL_VISIBLE = 73u;
const uint PHASE3_STAT_SPATIAL_OCCLUDED = 74u;
const uint PHASE3_STAT_SPATIAL_M_CAP = 75u;
const uint PHASE3_STAT_SPATIAL_ZERO_TARGET = 76u;
const uint PHASE3_STAT_SPATIAL_SELECTED_CENTER = 77u;
const uint PHASE3_STAT_SPATIAL_SELECTED_NEIGHBOR = 78u;
const uint PHASE3_STAT_SPATIAL_NONFINITE = 79u;
const uint PHASE3_STAT_SPATIAL_MAX_M = 80u;

const uint PHASE2_ALGORITHM_VERSION = 2u;
const uint PHASE2_RESERVOIR_VALID = 1u << 0u;
const uint PHASE2_RESERVOIR_HIT = 1u << 1u;
const uint PHASE2_RESERVOIR_SKY = 1u << 2u;
const uint PHASE2_RESERVOIR_SELECTED_HISTORY = 1u << 3u;
const uint PHASE2_RESERVOIR_ROBUST_CLAMPED = 1u << 4u;
const uint PHASE2_RESERVOIR_ENDPOINT_REUSABLE = 1u << 5u;
const uint PHASE2_RESERVOIR_SELECTED_SPATIAL = 1u << 6u;

const int HDDAGI_REGION_SIZE = 8;
const int HDDAGI_HDDA_FP_BITS = 10;
const float TAU = 6.283185307179586;

// Shared 96-byte ABI. debug_mode is reserved padding kept for the established
// host/shader layout. sky_color.w stores the octahedral sky border in UV.
layout(push_constant, std430) uniform Params {
	ivec2 gi_size;
	ivec2 screen_size;

	int probe_size;
	uint view_index;
	uint frame_index;
	uint flags;

	float normal_bias;
	float history_blend;
	float history_depth_tolerance;
	float history_normal_threshold;

	uint candidate_count;
	uint sky_mode;
	float sky_energy;
	float history_sample_count_max;

	vec4 sky_color;

	int debug_mode;
	float output_radiance_scale;
	uint pad1;
	uint pad2;
#ifdef MODE_PHASE2
	uint history_generation;
	uint algorithm_version;
	uint robust_mode;
	uint history_m_cap;

	uint local_sequence;
	uint maximum_age;
	float jacobian_max;
	uint phase2_pad;
#endif
}
params;

struct Phase1ProbeCascadeData {
	vec3 position;
	float to_probe;

	ivec3 region_world_offset;
	float to_cell;

	vec3 pad;
	float exposure_normalization;

	uvec4 pad2;
};

struct Phase1SceneData {
	mat4 inv_projection[2];
	mat4 cam_transform;
	vec4 eye_offset[2];

	ivec2 scene_screen_size;
	float scene_pad1;
	float scene_pad2;

	mat4 projection[2];
	mat4 previous_projection[2];
	mat4 previous_cam_inv_transform;

	// std140 mat3 occupies three vec4 columns. The host appends 12 floats.
	mat3 radiance_inverse_xform;
	mat4 previous_inv_projection[2];
	// Temporal association uses the same jitter-neutral motion domain as the
	// final Forward+ TAA. G-buffer reconstruction still uses inv_projection.
	mat4 temporal_projection[2];
	mat4 previous_temporal_projection[2];

};

#ifdef HDDAGI_SHARC_ACTIVE

// These descriptor aliases make RenderingDevice's draw graph aware of the
// buffers accessed through physical addresses. The actual SDK accesses use the
// BDA values below; the unreachable atomic keeps all three aliases reflected.
layout(set = 2, binding = 0, std430) coherent restrict buffer SharcHashAlias {
	uint sharc_hash_alias[];
};
layout(set = 2, binding = 2, std430) coherent restrict buffer SharcAccumulationAlias {
	uint sharc_accumulation_alias[];
};
layout(set = 2, binding = 3, std430) coherent restrict buffer SharcResolvedAlias {
	uint sharc_resolved_alias[];
};
layout(set = 2, binding = 4, std140) uniform SharcHostParameters {
	uvec4 hash_lock_addresses;
	uvec4 accumulation_resolved_addresses;
	vec4 camera_position_logarithm_base;
	vec4 previous_camera_position_scene_scale;
	vec4 tuning;
	uvec4 resolve;
	uvec4 control;
}
sharc_host;

void hddagi_sharc_track_aliases() {
	if (sharc_host.control.w == 0xffffffffu) {
		atomicOr(sharc_hash_alias[0], 0u);
		atomicOr(sharc_accumulation_alias[0], 0u);
		atomicOr(sharc_resolved_alias[0], 0u);
	}
}

SharcParameters hddagi_sharc_parameters() {
	SharcParameters sharc_parameters;
	sharc_parameters.hashGridParameters.cameraPosition = sharc_host.camera_position_logarithm_base.xyz;
	sharc_parameters.hashGridParameters.logarithmBase = sharc_host.camera_position_logarithm_base.w;
	sharc_parameters.hashGridParameters.sceneScale = sharc_host.previous_camera_position_scene_scale.w;
	sharc_parameters.hashGridParameters.levelBias = sharc_host.tuning.x;
	sharc_parameters.hashGridData.capacity = sharc_host.resolve.x;
	sharc_parameters.hashGridData.hashEntriesBuffer = RWStructuredBuffer_uint64_t(sharc_host.hash_lock_addresses.xy);
#if !HASH_GRID_ENABLE_64_BIT_ATOMICS && !HASH_GRID_COMPACT
	sharc_parameters.hashGridData.lockBuffer = RWStructuredBuffer_uint(sharc_host.hash_lock_addresses.zw);
#endif
	sharc_parameters.radianceScale = sharc_host.tuning.y;
	sharc_parameters.accumulationBuffer = RWStructuredBuffer_SharcAccumulationData(sharc_host.accumulation_resolved_addresses.xy);
	sharc_parameters.resolvedBuffer = RWStructuredBuffer_SharcPackedData(sharc_host.accumulation_resolved_addresses.zw);
	return sharc_parameters;
}

SharcResolveParameters hddagi_sharc_resolve_parameters() {
	SharcResolveParameters resolve_parameters;
	resolve_parameters.cameraPositionPrev = sharc_host.previous_camera_position_scene_scale.xyz;
	resolve_parameters.accumulationFrameNum = sharc_host.resolve.z;
	resolve_parameters.responsiveFrameNum = sharc_host.resolve.w;
	resolve_parameters.staleFrameNumMax = sharc_host.control.x;
	resolve_parameters.frameIndex = sharc_host.resolve.y;
	return resolve_parameters;
}

#ifdef MODE_SHARC_RESOLVE

void hddagi_sharc_resolve_main() {
	if (sharc_host.control.y == 0u) {
		return;
	}
	hddagi_sharc_track_aliases();
	SharcResolveEntry(gl_GlobalInvocationID.x, hddagi_sharc_parameters(), hddagi_sharc_resolve_parameters());
}

#endif

#endif

#ifdef MODE_SURFACE

layout(set = 0, binding = 0) uniform texture2D depth_buffer;
layout(set = 0, binding = 1) uniform texture2D normal_roughness_buffer;
layout(set = 0, binding = 2) uniform sampler nearest_sampler;
layout(rgba32ui, set = 0, binding = 3) uniform restrict writeonly uimage2D probe_surface_output;

#endif

#if defined(MODE_TRACE) || defined(MODE_SHARC_UPDATE) || defined(MODE_PHASE2_FRESH) || defined(MODE_PHASE2_TEMPORAL) || defined(MODE_PHASE3_SPATIAL)

#if defined(MODE_TRACE) || defined(MODE_SHARC_UPDATE)
layout(rgba32ui, set = 0, binding = 0) uniform restrict readonly uimage2D probe_surface_input;
#ifdef MODE_TRACE
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D raw_probe_output;
#endif
layout(rg32ui, set = 0, binding = 2) uniform restrict readonly uimage3D hddagi_voxel_cascades;
layout(r8ui, set = 0, binding = 3) uniform restrict readonly uimage3D hddagi_voxel_region_cascades;
layout(r32ui, set = 0, binding = 6) uniform restrict readonly uimage3D hddagi_voxel_neighbours;
layout(r8ui, set = 0, binding = 8) uniform restrict readonly uimage3D hddagi_voxel_disocclusion;
#else
layout(set = 0, binding = 0) uniform utexture2D probe_surface_input;
layout(rgba32f, set = 0, binding = 1) uniform coherent image2D phase2_current_owner;
layout(set = 0, binding = 2) uniform utexture3D hddagi_voxel_cascades;
layout(set = 0, binding = 3) uniform utexture3D hddagi_voxel_region_cascades;
layout(set = 0, binding = 6) uniform utexture3D hddagi_voxel_neighbours;
layout(set = 0, binding = 8) uniform utexture3D hddagi_voxel_disocclusion;
#endif
layout(set = 0, binding = 4) uniform texture3D hddagi_light_cascades;
layout(set = 0, binding = 5) uniform sampler linear_sampler;
layout(set = 0, binding = 7, std140) uniform HDDAGIData {
	ivec3 grid_size;
	int max_cascades;

	float normal_bias;
	float energy;
	float y_mult;
	float reflection_bias;

	ivec3 probe_axis_size;
	float esm_strength;

	ivec4 screen_probe_previous_region_world_offset;

	Phase1ProbeCascadeData cascades[8];
}
hddagi;
layout(set = 0, binding = 9, std140) uniform SceneDataBuffer {
	Phase1SceneData scene_data;
};
layout(set = 0, binding = 10, std430) coherent restrict buffer ScreenProbeStatsBuffer {
	uint screen_probe_stats[];
};

#ifdef MODE_PHASE2
layout(set = 0, binding = 11) uniform utexture3D hddagi_region_versions;
layout(rgba32f, set = 0, binding = 12) uniform coherent image2D phase2_current_sample;
layout(rgba32f, set = 0, binding = 13) uniform coherent image2D phase2_current_endpoint;
layout(rgba32f, set = 0, binding = 14) uniform coherent image2D phase2_current_radiance;
layout(rgba32ui, set = 0, binding = 15) uniform coherent uimage2D phase2_current_identity;
layout(rgba32ui, set = 0, binding = 16) uniform coherent uimage2D phase2_current_meta;
layout(rg32ui, set = 0, binding = 17) uniform coherent uimage2D phase2_current_version;
layout(set = 0, binding = 18) uniform utexture2D phase2_previous_surface;
layout(set = 0, binding = 19) uniform texture2D phase2_previous_owner;
layout(set = 0, binding = 20) uniform texture2D phase2_previous_sample;
layout(set = 0, binding = 21) uniform texture2D phase2_previous_endpoint;
layout(set = 0, binding = 22) uniform texture2D phase2_previous_radiance;
layout(set = 0, binding = 23) uniform utexture2D phase2_previous_identity;
layout(set = 0, binding = 24) uniform utexture2D phase2_previous_meta;
layout(set = 0, binding = 25) uniform utexture2D phase2_previous_version;
layout(rgba32f, set = 0, binding = 26) uniform restrict writeonly image2D phase2_raw_probe_output;
layout(set = 0, binding = 27) uniform sampler nearest_sampler;
#endif

#ifdef USE_CUBEMAP_ARRAY
layout(set = 1, binding = 0) uniform texture2DArray sky_radiance;
#else
layout(set = 1, binding = 0) uniform texture2D sky_radiance;
#endif
layout(set = 1, binding = 1) uniform sampler sky_sampler;

#endif

#ifdef MODE_RESOLVE

layout(rgba32ui, set = 0, binding = 0) uniform restrict readonly uimage2D probe_surface_input;
layout(set = 0, binding = 1) uniform texture2D raw_probe_input;
layout(set = 0, binding = 2) uniform texture2D depth_buffer;
layout(set = 0, binding = 3) uniform texture2D normal_roughness_buffer;
layout(set = 0, binding = 4) uniform sampler nearest_sampler;
#ifdef MODE_PHASE2_RESOLVE
layout(rgba32f, set = 0, binding = 5) uniform restrict writeonly image2D fullres_raw_output;
#else
layout(rgba16f, set = 0, binding = 5) uniform restrict writeonly image2D fullres_raw_output;
#endif
layout(rg32ui, set = 0, binding = 6) uniform restrict writeonly uimage2D fullres_surface_output;
layout(set = 0, binding = 7, std140) uniform SceneDataBuffer {
	Phase1SceneData scene_data;
};
layout(set = 0, binding = 8, std430) coherent restrict buffer ScreenProbeStatsBuffer {
	uint screen_probe_stats[];
};

#endif



#ifdef MODE_APPLY

layout(set = 0, binding = 0) uniform texture2D fullres_radiance_input;
layout(set = 0, binding = 1) uniform sampler nearest_sampler;
layout(r32ui, set = 0, binding = 2) uniform restrict writeonly uimage2D ambient_output;

#endif

uint hash_uvec3(uvec3 v) {
	v = v * 1664525u + 1013904223u;
	v.x += v.y * v.z;
	v.y += v.z * v.x;
	v.z += v.x * v.y;
	v ^= v >> 16u;
	v.x += v.y * v.z;
	return v.x ^ v.y ^ v.z;
}

float hash_float(uvec3 v) {
	return float(hash_uvec3(v) & 0x00ffffffu) / float(0x01000000u);
}

vec3 cosine_sample_hemisphere(vec2 u) {
	float r = sqrt(u.x);
	float phi = TAU * u.y;
	return vec3(r * cos(phi), r * sin(phi), sqrt(max(0.0, 1.0 - u.x)));
}

vec3 tangent_to_world(vec3 local_dir, vec3 normal) {
	vec3 up = abs(normal.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0);
	vec3 tangent = normalize(cross(up, normal));
	vec3 bitangent = cross(normal, tangent);
	return normalize(tangent * local_dir.x + bitangent * local_dir.y + normal * local_dir.z);
}

uint rgbe_encode(vec3 rgb) {
	const float rgbe_max = uintBitsToFloat(0x477F8000);
	const float rgbe_min = uintBitsToFloat(0x37800000);
	rgb = clamp(rgb, vec3(0.0), vec3(rgbe_max));
	float max_channel = max(max(rgbe_min, rgb.r), max(rgb.g, rgb.b));
	float bias = uintBitsToFloat((floatBitsToUint(max_channel) + 0x07804000) & 0x7F800000);
	uvec3 urgb = floatBitsToUint(rgb + bias);
	uint e = (floatBitsToUint(bias) << 4) + 0x10000000;
	return e | (urgb.b << 18) | (urgb.g << 9) | (urgb.r & 0x1FF);
}

#if defined(MODE_TRACE) || defined(MODE_SHARC_UPDATE) || defined(MODE_PHASE2_FRESH) || defined(MODE_PHASE2_TEMPORAL) || defined(MODE_PHASE3_SPATIAL) || defined(MODE_RESOLVE)

vec3 compute_view_pos(vec3 screen_pos) {
	vec4 pos = vec4(screen_pos.xy * 2.0 - 1.0, screen_pos.z, 1.0);
	pos = scene_data.inv_projection[params.view_index] * pos;
	return pos.xyz / pos.w;
}

#endif

bool decode_normal(vec3 encoded, out vec3 r_normal) {
	r_normal = encoded * 2.0 - 1.0;
	float length_squared = dot(r_normal, r_normal);
	if (length_squared < 0.001) {
		return false;
	}
	r_normal *= inversesqrt(length_squared);
	return true;
}

uint pack_surface_normal(vec3 normal, bool dynamic_surface) {
	float normal_length_squared = dot(normal, normal);
	if (any(isnan(normal)) || any(isinf(normal)) || !(normal_length_squared > 1e-10)) {
		normal = vec3(0.0, 0.0, 1.0);
	} else {
		normal *= inversesqrt(normal_length_squared);
	}
	vec2 octahedral = clamp(vec3_to_oct(normal), vec2(0.0), vec2(1.0));
	uvec2 packed = uvec2(roundEven(octahedral * vec2(65535.0, 32767.0)));
	return packed.x | (packed.y << 16u) | (dynamic_surface ? 0x80000000u : 0u);
}

vec3 unpack_surface_normal(uint packed) {
	vec2 octahedral = vec2(float(packed & 0xffffu) / 65535.0, float((packed >> 16u) & 0x7fffu) / 32767.0);
	return oct_to_vec3(octahedral * 2.0 - 1.0);
}

bool surface_is_dynamic(uint packed) {
	return (packed & 0x80000000u) != 0u;
}

// Full-resolution denoiser keys trade a little normal precision for a stable
// roughness/material class while retaining the existing 64-bit surface format:
// [depth fp32][oct x 12 | oct y 12 | roughness class 7 | dynamic 1].
uint pack_fullres_surface(vec3 normal, bool dynamic_surface, float roughness) {
	float normal_length_squared = dot(normal, normal);
	if (any(isnan(normal)) || any(isinf(normal)) || !(normal_length_squared > 1e-10)) {
		normal = vec3(0.0, 0.0, 1.0);
	} else {
		normal *= inversesqrt(normal_length_squared);
	}
	vec2 octahedral = clamp(vec3_to_oct(normal), vec2(0.0), vec2(1.0));
	uvec2 packed_normal = uvec2(roundEven(octahedral * 4095.0));
	uint material_class = uint(roundEven(clamp(roughness, 0.0, 1.0) * 127.0));
	return packed_normal.x | (packed_normal.y << 12u) | (material_class << 24u) | (dynamic_surface ? 0x80000000u : 0u);
}

vec3 unpack_fullres_surface_normal(uint packed) {
	vec2 octahedral = vec2(float(packed & 0xfffu), float((packed >> 12u) & 0xfffu)) / 4095.0;
	return oct_to_vec3(octahedral * 2.0 - 1.0);
}

uint fullres_surface_material_class(uint packed) {
	return (packed >> 24u) & 0x7fu;
}

#if defined(MODE_TRACE) || defined(MODE_SHARC_UPDATE) || defined(MODE_PHASE2_FRESH) || defined(MODE_PHASE2_TEMPORAL) || defined(MODE_PHASE3_SPATIAL) || defined(MODE_RESOLVE)

void phase1_stats_add(uint stat_index, uint value) {
	if ((params.flags & PHASE1_FLAG_GPU_STATS) != 0u && params.debug_mode == 0 && value != 0u) {
		atomicAdd(screen_probe_stats[stat_index], value);
	}
}

#endif

#ifdef MODE_PHASE2

// Match Forward+ motion vectors exactly: raster/depth reconstruction stays in
// the jittered sample domain, while temporal lookup applies only the motion
// between the current and previous unjittered projections. Consequently a
// static surface maps to the same history-grid texel for every TAA phase.
bool temporal_reproject_jitter_neutral(vec2 current_grid_uv, vec3 current_view_pos, vec3 world_pos, out vec2 r_previous_uv, out vec3 r_previous_view_pos) {
	vec4 current_stable_clip = scene_data.temporal_projection[params.view_index] * vec4(current_view_pos, 1.0);
	r_previous_view_pos = (scene_data.previous_cam_inv_transform * vec4(world_pos, 1.0)).xyz;
	vec4 previous_stable_clip = scene_data.previous_temporal_projection[params.view_index] * vec4(r_previous_view_pos, 1.0);
	if (current_stable_clip.w <= 1e-6 || previous_stable_clip.w <= 1e-6 ||
			any(isnan(current_stable_clip)) || any(isinf(current_stable_clip)) ||
			any(isnan(previous_stable_clip)) || any(isinf(previous_stable_clip))) {
		r_previous_uv = vec2(0.0);
		return false;
	}
	vec2 current_stable_uv = current_stable_clip.xy / current_stable_clip.w * 0.5 + 0.5;
	vec2 previous_stable_uv = previous_stable_clip.xy / previous_stable_clip.w * 0.5 + 0.5;
	r_previous_uv = current_grid_uv + (previous_stable_uv - current_stable_uv);
	return !any(isnan(r_previous_uv)) && !any(isinf(r_previous_uv));
}

#endif

#ifdef MODE_SURFACE

ivec2 gi_to_screen(ivec2 gi_pos) {
	return clamp(gi_pos * params.screen_size / params.gi_size, ivec2(0), params.screen_size - ivec2(1));
}

bool load_surface(ivec2 screen_pos, out float r_depth, out vec3 r_normal, out bool r_dynamic) {
	if (any(lessThan(screen_pos, ivec2(0))) || any(greaterThanEqual(screen_pos, params.screen_size))) {
		return false;
	}
	r_depth = texelFetch(sampler2D(depth_buffer, nearest_sampler), screen_pos, 0).r;
	if (r_depth <= 0.0) {
		return false;
	}
	vec4 normal_roughness = texelFetch(sampler2D(normal_roughness_buffer, nearest_sampler), screen_pos, 0);
	r_dynamic = normal_roughness.w > 0.5;
	return decode_normal(normal_roughness.xyz, r_normal);
}

void phase1_surface_main() {
	ivec2 probe_pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(probe_pos, imageSize(probe_surface_output)))) {
		return;
	}

	ivec2 gi_origin = probe_pos * params.probe_size;
	ivec2 gi_end = min(gi_origin + ivec2(params.probe_size), params.gi_size);
	ivec2 tile_extent = gi_end - gi_origin;
	// Production screen probes use the geometric center. SHARC's independent
	// prepass rotates the target through every pixel in the tile so its update
	// origins cover all receiver surfaces over time, as required by the SDK.
	ivec2 target_twice = tile_extent - ivec2(1);
	if (bool(params.flags & PHASE1_FLAG_SHARC_UPDATE_SURFACE)) {
		uint tile_area = uint(tile_extent.x * tile_extent.y);
		uint target_index = uint(hash_float(uvec3(uvec2(probe_pos), params.frame_index ^ 0x53484152u)) * float(tile_area));
		target_twice = ivec2(int(target_index % uint(tile_extent.x)), int(target_index / uint(tile_extent.x))) * 2;
	}
	ivec2 best_screen_pos = ivec2(0);
	ivec2 best_gi_pos = ivec2(0);
	float best_depth = 0.0;
	vec3 best_normal = vec3(0.0);
	bool best_dynamic = false;
	uint best_distance_squared = 0xffffffffu;
	bool found = false;

	for (int y = 0; y < tile_extent.y; y++) {
		for (int x = 0; x < tile_extent.x; x++) {
			ivec2 gi_pos = gi_origin + ivec2(x, y);
			ivec2 screen_pos = gi_to_screen(gi_pos);
			float depth;
			vec3 normal;
			bool dynamic_surface;
			if (!load_surface(screen_pos, depth, normal, dynamic_surface)) {
				continue;
			}
			ivec2 target_delta_twice = ivec2(x, y) * 2 - target_twice;
			uint distance_squared = uint(dot(target_delta_twice, target_delta_twice));
			bool wins_tie = distance_squared == best_distance_squared && (gi_pos.y < best_gi_pos.y || (gi_pos.y == best_gi_pos.y && gi_pos.x < best_gi_pos.x));
			if (!found || distance_squared < best_distance_squared || wins_tie) {
				found = true;
				best_distance_squared = distance_squared;
				best_gi_pos = gi_pos;
				best_screen_pos = screen_pos;
				best_depth = depth;
				best_normal = normal;
				best_dynamic = dynamic_surface;
			}
		}
	}

	if (!found) {
		imageStore(probe_surface_output, probe_pos, uvec4(0xffffffffu));
		return;
	}
	imageStore(probe_surface_output, probe_pos, uvec4(uvec2(best_screen_pos), floatBitsToUint(best_depth), pack_surface_normal(best_normal, best_dynamic)));
}

#endif

#if defined(MODE_TRACE) || defined(MODE_SHARC_UPDATE) || defined(MODE_PHASE2_FRESH) || defined(MODE_PHASE2_TEMPORAL) || defined(MODE_PHASE3_SPATIAL)

uvec4 trace_load_probe_surface(ivec2 position) {
#ifdef MODE_PHASE2
	return texelFetch(usampler2D(probe_surface_input, nearest_sampler), position, 0);
#else
	return imageLoad(probe_surface_input, position);
#endif
}

uvec4 trace_load_voxel_cascades(ivec3 position) {
#ifdef MODE_PHASE2
	return texelFetch(usampler3D(hddagi_voxel_cascades, nearest_sampler), position, 0);
#else
	return imageLoad(hddagi_voxel_cascades, position);
#endif
}

uint trace_load_voxel_region(ivec3 position) {
#ifdef MODE_PHASE2
	return texelFetch(usampler3D(hddagi_voxel_region_cascades, nearest_sampler), position, 0).r;
#else
	return imageLoad(hddagi_voxel_region_cascades, position).r;
#endif
}

uint trace_load_disocclusion(ivec3 position) {
#ifdef MODE_PHASE2
	return texelFetch(usampler3D(hddagi_voxel_disocclusion, nearest_sampler), position, 0).r;
#else
	return imageLoad(hddagi_voxel_disocclusion, position).r;
#endif
}

uint trace_load_neighbours(ivec3 position) {
#ifdef MODE_PHASE2
	return texelFetch(usampler3D(hddagi_voxel_neighbours, nearest_sampler), position, 0).r;
#else
	return imageLoad(hddagi_voxel_neighbours, position).r;
#endif
}

#ifdef MODE_PHASE2
uint phase2_load_region_version(ivec3 position) {
	return texelFetch(usampler3D(hddagi_region_versions, nearest_sampler), position, 0).r;
}
#endif

bool load_probe_surface(ivec2 probe_pos, out ivec2 r_screen_pos, out float r_depth, out vec3 r_normal) {
	uvec4 packed = trace_load_probe_surface(probe_pos);
	if (all(equal(packed.xy, uvec2(0xffffffffu)))) {
		return false;
	}
	r_screen_pos = ivec2(packed.xy);
	r_depth = uintBitsToFloat(packed.z);
	r_normal = unpack_surface_normal(packed.w);
	return r_depth > 0.0 && all(greaterThanEqual(r_screen_pos, ivec2(0))) && all(lessThan(r_screen_pos, params.screen_size));
}

float point_to_ray_distance(vec3 point, vec3 ray_origin, vec3 ray_direction) {
	vec3 point_to_ray = point - ray_origin;
	float t = dot(point_to_ray, normalize(ray_direction));
	vec3 projected = ray_origin + ray_direction * t;
	return length(point - projected);
}

bool trace_ray_hdda(vec3 ray_pos, vec3 ray_dir, int p_cascade, out ivec3 r_cell, out ivec3 r_side, out int r_cascade) {
	const int LEVEL_CASCADE = -1;
	const int LEVEL_REGION = 0;
	const int LEVEL_BLOCK = 1;
	const int LEVEL_VOXEL = 2;
	const int MAX_LEVEL = 3;
	const int fp_bits = HDDAGI_HDDA_FP_BITS;
	const int fp_block_bits = fp_bits + 2;
	const int fp_region_bits = fp_block_bits + 1;

	bvec3 limit_dir = greaterThan(ray_dir, vec3(0.0));
	ivec3 step = mix(ivec3(0), ivec3(1), limit_dir);
	ivec3 ray_sign = ivec3(sign(ray_dir));
	bvec3 ray_zero = lessThan(abs(ray_dir), vec3(1.0 / 127.0));
	ivec3 ray_dir_fp = ivec3(ray_dir * float(1 << fp_bits));
	// Zero and near-zero axes are masked out below, but evaluating their
	// reciprocal first can still produce Inf and an undefined float-to-int
	// conversion. Give masked axes a finite divisor before constructing HDDA's
	// fixed-point reciprocal.
	vec3 reciprocal_divisor = mix(ray_dir, vec3(1.0), ray_zero);
	ivec3 inv_ray_dir_fp = ivec3(vec3(float(1 << fp_bits)) / reciprocal_divisor);
	const ivec3 level_masks[MAX_LEVEL] = ivec3[](
			ivec3(1 << fp_region_bits) - ivec3(1),
			ivec3(1 << fp_block_bits) - ivec3(1),
			ivec3(1 << fp_bits) - ivec3(1));

	ivec3 region_offset_mask = (hddagi.grid_size / HDDAGI_REGION_SIZE) - ivec3(1);
	ivec3 limits[MAX_LEVEL];
	limits[LEVEL_REGION] = ((hddagi.grid_size << fp_bits) - ivec3(1)) * step;
	int level = LEVEL_CASCADE;
	int cascade = p_cascade - 1;
	ivec3 cascade_base;
	ivec3 region_base;
	uvec2 block;
	bool hit = false;
	uint traversal_steps = 0u;
	ivec3 pos;
	phase1_stats_add(PHASE1_STAT_HDDA_RAYS, 1u);

	while (true) {
		if (level == LEVEL_VOXEL) {
			ivec3 block_local = (pos & level_masks[LEVEL_BLOCK]) >> fp_bits;
			uint block_index = uint(block_local.z * 16 + block_local.y * 4 + block_local.x);
			if (block_index < 32u) {
				if (bool(block.x & (1u << block_index))) {
					hit = true;
					break;
				}
			} else {
				block_index -= 32u;
				if (bool(block.y & (1u << block_index))) {
					hit = true;
					break;
				}
			}
		} else if (level == LEVEL_BLOCK) {
			ivec3 block_local = (pos & level_masks[LEVEL_REGION]) >> fp_block_bits;
			block = trace_load_voxel_cascades(region_base + block_local).rg;
			if (block != uvec2(0)) {
				level = LEVEL_VOXEL;
				limits[LEVEL_VOXEL] = pos - (pos & level_masks[LEVEL_BLOCK]) + step * (level_masks[LEVEL_BLOCK] + ivec3(1));
				continue;
			}
		} else if (level == LEVEL_REGION) {
			ivec3 region = pos >> fp_region_bits;
			region = (hddagi.cascades[cascade].region_world_offset + region) & region_offset_mask;
			region += cascade_base;
			if (trace_load_voxel_region(region) > 0u) {
				region_base = region << 1;
				level = LEVEL_BLOCK;
				limits[LEVEL_BLOCK] = pos - (pos & level_masks[LEVEL_REGION]) + step * (level_masks[LEVEL_REGION] + ivec3(1));
				continue;
			}
		} else if (level == LEVEL_CASCADE) {
			if (cascade >= p_cascade) {
				ray_pos = vec3(pos) / float(1 << fp_bits);
				ray_pos /= hddagi.cascades[cascade].to_cell;
				ray_pos += hddagi.cascades[cascade].position;
			}
			cascade++;
			if (cascade == hddagi.max_cascades) {
				break;
			}
			ray_pos -= hddagi.cascades[cascade].position;
			ray_pos *= hddagi.cascades[cascade].to_cell;
			pos = ivec3(ray_pos * float(1 << fp_bits));
			if (any(lessThan(pos, ivec3(0))) || any(greaterThanEqual(pos, hddagi.grid_size << fp_bits))) {
				continue;
			}
			cascade_base = ivec3(0, int(hddagi.grid_size.y / HDDAGI_REGION_SIZE) * cascade, 0);
			level = LEVEL_REGION;
			continue;
		}

		ivec3 mask = level_masks[level];
		ivec3 box = mask * step;
		ivec3 pos_diff = box - (pos & mask);
		ivec3 mul_res = (pos_diff * inv_ray_dir_fp) >> fp_bits;
		ivec3 tv = mix(mul_res, ivec3(0x7fffffff), ray_zero);
		int t = min(tv.x, min(tv.y, tv.z));
		ivec3 adv_box = pos_diff + ray_sign;
		ivec3 adv_t = (ray_dir_fp * t) >> fp_bits;
		pos += mix(adv_t, adv_box, equal(ivec3(t), tv));
		traversal_steps++;
		while (true) {
			bvec3 limit = lessThan(pos, limits[level]);
			if (all(equal(limit, limit_dir))) {
				break;
			}
			level--;
			if (level == LEVEL_CASCADE) {
				break;
			}
		}
	}

	if (hit) {
		ivec3 mask = level_masks[LEVEL_VOXEL];
		ivec3 box = mask * (step ^ ivec3(1));
		ivec3 pos_diff = box - (pos & mask);
		ivec3 mul_res = pos_diff * -inv_ray_dir_fp;
		ivec3 tv = mix(mul_res, ivec3(0x7fffffff), ray_zero);
		int m;
		if (tv.x < tv.y) {
			r_side = ivec3(1, 0, 0);
			m = tv.x;
		} else {
			r_side = ivec3(0, 1, 0);
			m = tv.y;
		}
		if (tv.z < m) {
			r_side = ivec3(0, 0, 1);
		}
		r_side *= -ray_sign;
		r_cell = pos >> fp_bits;
		r_cascade = cascade;
	}

	phase1_stats_add(PHASE1_STAT_HDDA_STEPS, traversal_steps);
	phase1_stats_add(hit ? PHASE1_STAT_HDDA_HITS : PHASE1_STAT_HDDA_MISSES, 1u);
	return hit;
}

#ifdef MODE_SHARC_QUERY

bool hddagi_sharc_query_hit(vec3 position_world, vec3 normal_world, float segment_length, inout vec3 r_radiance) {
	phase1_stats_add(PHASE1_STAT_SHARC_QUERY_ATTEMPTS, 1u);
	if (sharc_host.control.y == 0u) {
		phase1_stats_add(PHASE1_STAT_SHARC_QUERY_INELIGIBLE, 1u);
		return false;
	}

	hddagi_sharc_track_aliases();
	SharcParameters sharc_parameters = hddagi_sharc_parameters();
	uint grid_level = HashGridGetLevel(position_world, sharc_parameters.hashGridParameters);
	float voxel_size = HashGridGetVoxelSize(grid_level, sharc_parameters.hashGridParameters);
	// SHARC explicitly disallows terminating a segment shorter than its cache
	// voxel: the cached value cannot represent the local transport at that scale.
	if (isnan(segment_length) || isinf(segment_length) || segment_length < voxel_size) {
		phase1_stats_add(PHASE1_STAT_SHARC_QUERY_INELIGIBLE, 1u);
		return false;
	}
	SharcHitData hit_data;
	hit_data.positionWorld = position_world;
	hit_data.normalWorld = normal_world;
	vec3 cached_radiance;
	if (!SharcGetCachedRadiance(sharc_parameters, hit_data, cached_radiance, true) ||
			any(isnan(cached_radiance)) || any(isinf(cached_radiance)) || any(lessThan(cached_radiance, vec3(0.0))) ||
			any(greaterThanEqual(cached_radiance, vec3(SHARC_CACHE_RADIANCE_MAX)))) {
		phase1_stats_add(PHASE1_STAT_SHARC_QUERY_MISSES, 1u);
		return false;
	}

	// The cache stays in the same bounded pre-exposed domain as Forward+.
	r_radiance = cached_radiance * sharc_host.tuning.w;
	return true;
}

#endif

bool trace_hddagi_sample(ivec2 origin_pos, float origin_depth, vec3 origin_normal, vec3 ray_dir, out vec3 r_radiance, out ivec3 r_absolute_geometry_cell, out int r_hit_cascade, out ivec3 r_hit_face, out uint r_region_version, out vec3 r_endpoint_world, out vec3 r_endpoint_normal_world) {
	r_radiance = vec3(0.0);
	r_absolute_geometry_cell = ivec3(0);
	r_hit_cascade = -1;
	r_hit_face = ivec3(0);
	r_region_version = 0u;
	r_endpoint_world = vec3(0.0);
	r_endpoint_normal_world = vec3(0.0, 0.0, 1.0);
	vec2 origin_uv = (vec2(origin_pos) + 0.5) / vec2(params.screen_size);
	vec3 ray_pos = compute_view_pos(vec3(origin_uv, origin_depth));
	mat3 camera_basis = mat3(scene_data.cam_transform);
	ray_pos = camera_basis * ray_pos;
	vec3 trace_origin_world = ray_pos + scene_data.cam_transform[3].xyz;
	ray_dir = normalize(camera_basis * ray_dir);
	vec3 hddagi_normal = normalize(camera_basis * origin_normal);
	ray_pos.y *= hddagi.y_mult;
	ray_dir.y *= hddagi.y_mult;
	hddagi_normal.y *= hddagi.y_mult;
	ray_dir = normalize(ray_dir);
	hddagi_normal = normalize(hddagi_normal);

	int cascade = 0x7fffffff;
	for (int i = 0; i < hddagi.max_cascades; i++) {
		vec3 cascade_pos = (ray_pos - hddagi.cascades[i].position) * hddagi.cascades[i].to_cell;
		if (all(greaterThanEqual(cascade_pos, vec3(0.0))) && all(lessThan(cascade_pos, vec3(hddagi.grid_size)))) {
			cascade = i;
			break;
		}
	}
	if (cascade >= hddagi.max_cascades) {
		// Candidates outside all cascades are still traced samples whose HDDA
		// result is a miss; keep ray conservation exact for diagnostics.
		phase1_stats_add(PHASE1_STAT_HDDA_RAYS, 1u);
		phase1_stats_add(PHASE1_STAT_HDDA_MISSES, 1u);
		return false;
	}

	vec3 start_cell = (ray_pos - hddagi.cascades[cascade].position) * hddagi.cascades[cascade].to_cell;
	vec3 abs_normal = abs(hddagi_normal);
	vec3 ray_bias = hddagi_normal / max(abs_normal.x, max(abs_normal.y, abs_normal.z));
	start_cell += ray_bias * params.normal_bias;
	ray_pos = start_cell / hddagi.cascades[cascade].to_cell + hddagi.cascades[cascade].position;

	ivec3 hit_cell;
	ivec3 hit_face;
	int hit_cascade;
	if (!trace_ray_hdda(ray_pos, ray_dir, cascade, hit_cell, hit_face, hit_cascade)) {
		return false;
	}

	// A hit in the biased start cell takes the legacy synthetic-disocclusion
	// lookup below. It is useful for a fresh radiance estimate, but it was not
	// produced by a second HDDA traversal and therefore cannot identify a stable
	// temporal endpoint.
	bool reconnectable_endpoint = !(hit_cascade == cascade && ivec3(start_cell) == hit_cell);
	bool disoccluded = false;
	if (!reconnectable_endpoint) {
		ivec3 read_cell = (hit_cell + hddagi.cascades[hit_cascade].region_world_offset * HDDAGI_REGION_SIZE) & (hddagi.grid_size - 1);
		uint disocclusion = trace_load_disocclusion(read_cell + ivec3(0, hddagi.grid_size.y * hit_cascade, 0));
		if (disocclusion == 0u) {
			vec3 local = fract(start_cell) - 0.5;
			vec3 abs_origin_normal = abs(hddagi_normal);
			int closest_axis = abs_origin_normal.y > abs_origin_normal.x ? 1 : 0;
			if (abs_origin_normal.z > abs_origin_normal[closest_axis]) {
				closest_axis = 2;
			}
			const vec3 axes[5] = vec3[](vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, 1), vec3(1, 0, 0), vec3(0, 1, 0));
			vec3 axis_a = axes[closest_axis + 1];
			vec3 axis_b = axes[closest_axis + 2];
			vec3 advance = abs(dot(axis_a, local)) > abs(dot(axis_b, local)) ? axis_a * sign(local) : axis_b * sign(local);
			start_cell += advance;
			hit_cell += ivec3(advance);
			read_cell = (hit_cell + hddagi.cascades[hit_cascade].region_world_offset * HDDAGI_REGION_SIZE) & (hddagi.grid_size - 1);
			disocclusion = trace_load_disocclusion(read_cell + ivec3(0, hddagi.grid_size.y * hit_cascade, 0));
		}
		if (disocclusion != 0u) {
			vec3 local = fract(start_cell) - 0.5;
			const vec3 directions[6] = vec3[](vec3(-1, 0, 0), vec3(1, 0, 0), vec3(0, -1, 0), vec3(0, 1, 0), vec3(0, 0, -1), vec3(0, 0, 1));
			int best_axis = 0;
			float best_distance = -20.0;
			for (int i = 0; i < 6; i++) {
				if (bool(disocclusion & (1u << uint(i)))) {
					float distance = dot(local, directions[i]);
					if (distance > best_distance) {
						best_axis = i;
						best_distance = distance;
					}
				}
			}
			hit_face = ivec3(directions[best_axis]);
			disoccluded = true;
		}
	}

	// Keep the occupied geometry cell distinct from the neighbouring light cell.
	// The latter is an implementation detail of HDDAGI radiance lookup and is not
	// a stable surface identity for temporal reconnection.
	ivec3 geometry_hit_cell = hit_cell;
	ivec3 wrapped_geometry_cell = (geometry_hit_cell + hddagi.cascades[hit_cascade].region_world_offset * HDDAGI_REGION_SIZE) & (hddagi.grid_size - 1);
	if (reconnectable_endpoint && dot(vec3(hit_face), vec3(hit_face)) == 1.0) {
		r_absolute_geometry_cell = geometry_hit_cell + hddagi.cascades[hit_cascade].region_world_offset * HDDAGI_REGION_SIZE - hddagi.grid_size / 2;
		r_hit_cascade = hit_cascade;
		r_hit_face = hit_face;
		r_endpoint_normal_world = normalize(vec3(hit_face));
#ifdef MODE_PHASE2
		ivec3 region_coord = wrapped_geometry_cell / HDDAGI_REGION_SIZE + ivec3(0, (hddagi.grid_size.y / HDDAGI_REGION_SIZE) * hit_cascade, 0);
		r_region_version = phase2_load_region_version(region_coord);
#endif
		vec3 face_point_scaled = hddagi.cascades[hit_cascade].position + (vec3(geometry_hit_cell) + vec3(0.5) + vec3(hit_face) * 0.5) / hddagi.cascades[hit_cascade].to_cell;
		float face_denominator = dot(ray_dir, vec3(hit_face));
		if (abs(face_denominator) > 1e-6) {
			float face_t = dot(face_point_scaled - ray_pos, vec3(hit_face)) / face_denominator;
			vec3 endpoint_relative_scaled = ray_pos + ray_dir * face_t;
			endpoint_relative_scaled.y /= max(abs(hddagi.y_mult), 1e-6);
			r_endpoint_world = endpoint_relative_scaled + scene_data.cam_transform[3].xyz;
		} else {
			// This should be unreachable for the face selected by HDDA. Leave a
			// non-finite marker so Phase 2 rejects it instead of inventing an endpoint.
			r_endpoint_world = vec3(uintBitsToFloat(0x7fc00000u));
		}
	}

#ifdef MODE_SHARC_QUERY
	if (r_hit_cascade >= 0 && !any(isnan(r_endpoint_world)) && !any(isinf(r_endpoint_world)) &&
			!any(isnan(r_endpoint_normal_world)) && !any(isinf(r_endpoint_normal_world))) {
		const bool sharc_query_hit = hddagi_sharc_query_hit(r_endpoint_world, r_endpoint_normal_world, length(r_endpoint_world - trace_origin_world), r_radiance);
		if (sharc_query_hit) {
			// Count actual early terminations in the caller. Together with the
			// helper's other outcomes this preserves attempts=hits+ineligible+misses
			// and catches an accidentally inverted query condition.
			phase1_stats_add(PHASE1_STAT_SHARC_QUERY_HITS, 1u);
			return true;
		}
	}
#endif

	hit_cell += hit_face;
	ivec3 read_cell = (hit_cell + hddagi.cascades[hit_cascade].region_world_offset * HDDAGI_REGION_SIZE) & (hddagi.grid_size - 1);
	vec3 light = texelFetch(sampler3D(hddagi_light_cascades, linear_sampler), read_cell + ivec3(0, hddagi.grid_size.y * hit_cascade, 0), 0).rgb;
	uint neighbour_bits = disoccluded ? 0u : trace_load_neighbours(read_cell + ivec3(0, hddagi.grid_size.y * hit_cascade, 0));
	// The texture currently stores a 26-neighbour mask. Keep flag/reserved bits
	// from ever becoming an out-of-range index into the direction table.
	neighbour_bits &= (1u << 26u) - 1u;
	vec3 cascade_offset = hddagi.cascades[hit_cascade].position;
	float to_cell = hddagi.cascades[hit_cascade].to_cell;
	float cell_size = 1.0 / to_cell;
	const ivec3 directions[26] = ivec3[](ivec3(-1, 0, 0), ivec3(1, 0, 0), ivec3(0, -1, 0), ivec3(0, 1, 0), ivec3(0, 0, -1), ivec3(0, 0, 1), ivec3(-1, -1, -1), ivec3(-1, -1, 0), ivec3(-1, -1, 1), ivec3(-1, 0, -1), ivec3(-1, 0, 1), ivec3(-1, 1, -1), ivec3(-1, 1, 0), ivec3(-1, 1, 1), ivec3(0, -1, -1), ivec3(0, -1, 1), ivec3(0, 1, -1), ivec3(0, 1, 1), ivec3(1, -1, -1), ivec3(1, -1, 0), ivec3(1, -1, 1), ivec3(1, 0, -1), ivec3(1, 0, 1), ivec3(1, 1, -1), ivec3(1, 1, 0), ivec3(1, 1, 1));
	vec3 light_cell_pos = (vec3(hit_cell) + 0.5) * cell_size + cascade_offset;
	vec4 light_accum = vec4(light, 1.0) * max(0.0, 1.0 - point_to_ray_distance(light_cell_pos, ray_pos, ray_dir) * to_cell);
	while (neighbour_bits != 0u) {
		uint bit = findLSB(neighbour_bits);
		vec3 neighbour_pos = light_cell_pos + vec3(directions[bit]) * cell_size;
		float weight = max(0.0, 1.0 - point_to_ray_distance(neighbour_pos, ray_pos, ray_dir) * to_cell);
		if (weight > 0.0) {
			ivec3 neighbour_cell = hit_cell + directions[bit];
			read_cell = (neighbour_cell + hddagi.cascades[hit_cascade].region_world_offset * HDDAGI_REGION_SIZE) & (hddagi.grid_size - 1);
			vec3 neighbour_light = texelFetch(sampler3D(hddagi_light_cascades, linear_sampler), read_cell + ivec3(0, hddagi.grid_size.y * hit_cascade, 0), 0).rgb;
			light_accum += vec4(neighbour_light, 1.0) * weight;
		}
		neighbour_bits &= ~(1u << bit);
	}
	if (light_accum.a > 0.0) {
		light = light_accum.rgb / light_accum.a;
	}
	// HDDAGI voxel lighting may have been baked under a different camera
	// exposure. Bring it into the current pre-exposed Forward+ domain before the
	// shared dynamic-GI energy is applied once to both hit and miss candidates.
	r_radiance = light * hddagi.cascades[hit_cascade].exposure_normalization;
	return true;
}

bool trace_hddagi_radiance(ivec2 origin_pos, float origin_depth, vec3 origin_normal, vec3 ray_dir, out vec3 r_radiance, out float r_hit_distance) {
	ivec3 absolute_geometry_cell;
	int hit_cascade;
	ivec3 hit_face;
	uint region_version;
	vec3 endpoint_world;
	vec3 endpoint_normal_world;
	bool hit = trace_hddagi_sample(origin_pos, origin_depth, origin_normal, ray_dir, r_radiance, absolute_geometry_cell, hit_cascade, hit_face, region_version, endpoint_world, endpoint_normal_world);
	r_hit_distance = 0.0;
	if (hit && hit_cascade >= 0 && !any(isnan(endpoint_world)) && !any(isinf(endpoint_world))) {
		vec2 origin_uv = (vec2(origin_pos) + 0.5) / vec2(params.screen_size);
		vec3 origin_view = compute_view_pos(vec3(origin_uv, origin_depth));
		vec3 origin_world = (scene_data.cam_transform * vec4(origin_view, 1.0)).xyz;
		r_hit_distance = clamp(length(endpoint_world - origin_world), 0.0, 65504.0);
		if (isnan(r_hit_distance) || isinf(r_hit_distance)) {
			r_hit_distance = 0.0;
		}
	}
	return hit;
}

vec3 sample_environment(vec3 ray_dir_view) {
	if (params.sky_mode == PHASE1_SKY_COLOR) {
		return max(params.sky_color.rgb * params.sky_energy, vec3(0.0));
	}
	if (params.sky_mode != PHASE1_SKY_TEXTURE) {
		return vec3(0.0);
	}
	vec3 sky_direction = normalize(scene_data.radiance_inverse_xform * ray_dir_view);
	float border = clamp(params.sky_color.w, 0.0, 0.499);
	vec2 sky_uv = vec3_to_oct_with_border(sky_direction, vec2(border, 1.0 - border * 2.0));
#ifdef USE_CUBEMAP_ARRAY
	return max(textureLod(sampler2DArray(sky_radiance, sky_sampler), vec3(sky_uv, 0.0), 0.0).rgb * params.sky_energy, vec3(0.0));
#else
	return max(textureLod(sampler2D(sky_radiance, sky_sampler), sky_uv, 0.0).rgb * params.sky_energy, vec3(0.0));
#endif
}

#ifdef MODE_TRACE

void phase1_trace_main() {
	ivec2 probe_pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(probe_pos, imageSize(raw_probe_output)))) {
		return;
	}
	ivec2 origin_pos;
	float origin_depth;
	vec3 origin_normal;
	if (!load_probe_surface(probe_pos, origin_pos, origin_depth, origin_normal)) {
		imageStore(raw_probe_output, probe_pos, vec4(0.0));
		return;
	}

	uint trace_count = clamp(params.candidate_count, 1u, 8u);
	phase1_stats_add(PHASE1_STAT_FRESH_CANDIDATES, trace_count);
	float frame = float(params.frame_index & 0xffffu);
	vec3 radiance_sum = vec3(0.0);
	float hit_distance_sum = 0.0;
	for (uint candidate = 0u; candidate < trace_count; candidate++) {
		float candidate_f = float(candidate);
		// This sequence is mirrored exactly by phase1_reference.py::phase1_jitter.
		vec2 jitter = fract(vec2(
				hash_float(uvec3(uvec2(probe_pos), candidate)) + frame * (0.7548776662466927 + candidate_f * 0.1315423911),
				hash_float(uvec3(uint(probe_pos.y), uint(probe_pos.x), candidate + 1u)) + frame * (0.5698402909980532 + candidate_f * 0.1732050808)));
		vec3 ray_dir = tangent_to_world(cosine_sample_hemisphere(jitter), origin_normal);
		vec3 sample_radiance;
		float hit_distance;
		if (!trace_hddagi_radiance(origin_pos, origin_depth, origin_normal, ray_dir, sample_radiance, hit_distance)) {
			sample_radiance = sample_environment(ray_dir);
			// A real traced lobe that misses geometry has an effectively infinite
			// hit distance. RELAX reserves zero for a skipped/inward lobe.
			hit_distance = 65504.0;
		}
		radiance_sum += sample_radiance * hddagi.energy;
		hit_distance_sum += hit_distance;
	}
	// Cosine sampling has p(omega)=cos(theta)/pi, so the arithmetic mean of Li
	// estimates D=E/pi directly. Receiver albedo is applied later by Forward+.
	// RELAX_DIFFUSE consumes the unnormalized lobe hit distance in alpha. Real
	// environment misses contribute FP16_MAX; only skipped/inward lobes use zero.
	vec4 raw_radiance_hit_distance = vec4(radiance_sum, hit_distance_sum) / float(trace_count);
	if (any(isnan(raw_radiance_hit_distance)) || any(isinf(raw_radiance_hit_distance))) {
		raw_radiance_hit_distance = vec4(0.0);
	} else {
		raw_radiance_hit_distance = clamp(raw_radiance_hit_distance, vec4(0.0), vec4(65504.0));
	}
	imageStore(raw_probe_output, probe_pos, raw_radiance_hit_distance);
}

#endif

#ifdef MODE_SHARC_UPDATE

void hddagi_sharc_update_main() {
	ivec2 probe_pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(probe_pos, imageSize(probe_surface_input))) || sharc_host.control.y == 0u) {
		return;
	}
	uint update_stride = max(sharc_host.control.z, 1u);
	uvec2 atlas_size = uvec2(imageSize(probe_surface_input));
	uint global_probe_index = params.view_index * atlas_size.x * atlas_size.y + uint(probe_pos.y) * atlas_size.x + uint(probe_pos.x);
	if ((global_probe_index + sharc_host.resolve.y) % update_stride != 0u) {
		return;
	}

	ivec2 origin_pos;
	float origin_depth;
	vec3 origin_normal;
	if (!load_probe_surface(probe_pos, origin_pos, origin_depth, origin_normal)) {
		return;
	}

	hddagi_sharc_track_aliases();
	SharcParameters sharc_parameters = hddagi_sharc_parameters();
	// One update per selected probe is sufficient for the persistent cache and
	// makes the host-side global uint overflow bound exact.
	uint trace_count = 1u;
	float frame = float(params.frame_index & 0xffffu);
	for (uint candidate = 0u; candidate < trace_count; candidate++) {
		float candidate_f = float(candidate);
		vec2 jitter = fract(vec2(
				hash_float(uvec3(uvec2(probe_pos), candidate)) + frame * (0.7548776662466927 + candidate_f * 0.1315423911),
				hash_float(uvec3(uint(probe_pos.y), uint(probe_pos.x), candidate + 1u)) + frame * (0.5698402909980532 + candidate_f * 0.1732050808)));
		vec3 ray_dir = tangent_to_world(cosine_sample_hemisphere(jitter), origin_normal);
		vec3 sample_radiance;
		ivec3 absolute_geometry_cell;
		int hit_cascade;
		ivec3 hit_face;
		uint region_version;
		vec3 endpoint_world;
		vec3 endpoint_normal_world;
		SharcState sharc_state;
		SharcInit(sharc_state);
		phase1_stats_add(PHASE1_STAT_SHARC_UPDATE_RAYS, 1u);
		bool hit = trace_hddagi_sample(origin_pos, origin_depth, origin_normal, ray_dir, sample_radiance, absolute_geometry_cell, hit_cascade, hit_face, region_version, endpoint_world, endpoint_normal_world);
		bool stable_hit = hit && hit_cascade >= 0 && !any(isnan(endpoint_world)) && !any(isinf(endpoint_world)) &&
				!any(isnan(endpoint_normal_world)) && !any(isinf(endpoint_normal_world)) &&
				dot(endpoint_normal_world, endpoint_normal_world) > 0.5 &&
				!any(isnan(sample_radiance)) && !any(isinf(sample_radiance)) && !any(lessThan(sample_radiance, vec3(0.0)));
		if (stable_hit) {
			if (any(greaterThanEqual(sample_radiance, vec3(SHARC_CACHE_RADIANCE_MAX)))) {
				phase1_stats_add(PHASE1_STAT_SHARC_UPDATE_REJECTS, 1u);
				continue;
			}
			SharcHitData hit_data;
			hit_data.positionWorld = endpoint_world;
			hit_data.normalWorld = normalize(endpoint_normal_world);
			vec3 cache_radiance = sample_radiance * sharc_host.tuning.z;
			bool continue_tracing = SharcUpdateHit(sharc_parameters, sharc_state, hit_data, cache_radiance, hash_float(uvec3(uvec2(probe_pos), candidate + 0x53484152u)));
			// Cache resampling is disabled by this adapter, so false can only mean
			// that the fixed hash bucket rejected the insertion.
			if (!continue_tracing) {
				phase1_stats_add(PHASE1_STAT_SHARC_UPDATE_REJECTS, 1u);
			}
		} else if (!hit) {
			phase1_stats_add(PHASE1_STAT_SHARC_UPDATE_MISSES, 1u);
			// The state is empty for a primary miss, but keeping the canonical miss
			// call makes the one-segment adapter follow SHARC's path lifecycle.
			SharcUpdateMiss(sharc_parameters, sharc_state, min(sample_environment(ray_dir) * sharc_host.tuning.z, vec3(SHARC_CACHE_RADIANCE_MAX)));
		} else {
			phase1_stats_add(PHASE1_STAT_SHARC_UPDATE_REJECTS, 1u);
		}
	}
}

#endif

#ifdef MODE_PHASE2

const float PHASE2_PI = 3.14159265358979323846;

struct Phase2Reservoir {
	vec3 owner_position;
	float weight;
	vec3 direction_world;
	float proposal_pdf;
	vec3 endpoint_world;
	float endpoint_distance;
	vec3 radiance;
	float target;
	ivec3 absolute_geometry_cell;
	int hit_cascade;
	ivec3 hit_face;
	uint region_version;
	vec3 endpoint_normal_world;
	vec3 owner_normal_world;
	uint sample_count;
	uint age;
	uint generation;
	uint algorithm;
	uint flags;
};

bool phase2_finite(float value) {
	return !isnan(value) && !isinf(value);
}

bool phase2_finite3(vec3 value) {
	return !any(isnan(value)) && !any(isinf(value));
}

float phase2_luminance(vec3 value) {
	return dot(max(value, vec3(0.0)), vec3(0.2126, 0.7152, 0.0722));
}

void phase2_stats_max(uint stat_index, uint value) {
	if ((params.flags & PHASE1_FLAG_GPU_STATS) != 0u && params.debug_mode == 0) {
		atomicMax(screen_probe_stats[stat_index], value);
	}
}

float phase2_random(ivec2 probe_pos, uint dimension) {
	uint stream = params.local_sequence * 0x9e3779b9u + params.view_index * 0x85ebca6bu;
	return hash_float(uvec3(uvec2(probe_pos) ^ uvec2(stream, stream >> 16u), dimension * 0xc2b2ae35u + stream));
}

uint phase2_face_index(ivec3 face) {
	if (face.x < 0) {
		return 0u;
	}
	if (face.x > 0) {
		return 1u;
	}
	if (face.y < 0) {
		return 2u;
	}
	if (face.y > 0) {
		return 3u;
	}
	if (face.z < 0) {
		return 4u;
	}
	if (face.z > 0) {
		return 5u;
	}
	return 7u;
}

uint phase2_pack_identity(Phase2Reservoir reservoir) {
	uint face_index = phase2_face_index(reservoir.hit_face);
	return (uint(max(reservoir.hit_cascade, 0)) & 0xffu) | ((face_index & 0x7u) << 8u);
}

uint phase2_pack_version(Phase2Reservoir reservoir) {
	return (reservoir.algorithm & 0xffu) | ((reservoir.flags & 0xffu) << 8u) | ((reservoir.region_version & 0xffffu) << 16u);
}

ivec3 phase2_face_from_index(uint face_index) {
	const ivec3 faces[6] = ivec3[](ivec3(-1, 0, 0), ivec3(1, 0, 0), ivec3(0, -1, 0), ivec3(0, 1, 0), ivec3(0, 0, -1), ivec3(0, 0, 1));
	return face_index < 6u ? faces[face_index] : ivec3(0);
}

Phase2Reservoir phase2_empty_reservoir() {
	Phase2Reservoir reservoir;
	reservoir.owner_position = vec3(0.0);
	reservoir.weight = 0.0;
	reservoir.direction_world = vec3(0.0);
	reservoir.proposal_pdf = 0.0;
	reservoir.endpoint_world = vec3(0.0);
	reservoir.endpoint_distance = 0.0;
	reservoir.radiance = vec3(0.0);
	reservoir.target = 0.0;
	reservoir.absolute_geometry_cell = ivec3(0);
	reservoir.hit_cascade = -1;
	reservoir.hit_face = ivec3(0);
	reservoir.region_version = 0u;
	reservoir.endpoint_normal_world = vec3(0.0, 0.0, 1.0);
	reservoir.owner_normal_world = vec3(0.0, 0.0, 1.0);
	reservoir.sample_count = 0u;
	reservoir.age = 0u;
	reservoir.generation = params.history_generation;
	reservoir.algorithm = params.algorithm_version;
	reservoir.flags = 0u;
	return reservoir;
}

// Shared by production fresh RIS and the deterministic GPU/CPU conformance
// stream below. Inputs have already passed the production finite/proposal
// checks. M therefore advances for every represented candidate, including a
// finite zero-mass candidate, while only positive mass may replace the sample.
bool phase2_weighted_reservoir_update(inout float weight_sum, inout uint represented_count, float candidate_weight, float random_value) {
	represented_count++;
	weight_sum += candidate_weight;
	return candidate_weight > 0.0 && random_value * weight_sum < candidate_weight;
}

struct Phase2CompressedStreamMerge {
	uint merged_count;
	float history_mass;
	float merged_mass;
	float output_weight;
	bool select_history;
	bool mass_valid;
	bool output_valid;
};

uint phase2_effective_history_count(uint history_count, uint history_m_cap, out bool r_cap_applied) {
	uint effective_count = min(history_count, history_m_cap);
	r_cap_applied = effective_count < history_count;
	return effective_count;
}

float phase2_compressed_stream_mass(float target, float weight, uint represented_count) {
	return target * weight * float(represented_count);
}

// Shared by production temporal reuse and the deterministic GPU/CPU golden.
// Mapping/identity/visibility decisions are made by the caller; this helper is
// the single implementation of compressed-stream mass, selection, represented
// M merge, and final W reconstruction.
Phase2CompressedStreamMerge phase2_merge_compressed_stream(float fresh_mass, uint fresh_count, float fresh_target, float history_weight, uint effective_history_count, float current_target, float jacobian, bool history_visible, float selection_random) {
	Phase2CompressedStreamMerge result;
	result.history_mass = history_visible ? phase2_compressed_stream_mass(current_target * jacobian, history_weight, effective_history_count) : 0.0;
	result.merged_count = fresh_count + effective_history_count;
	result.merged_mass = fresh_mass + result.history_mass;
	result.mass_valid = phase2_finite(fresh_mass) && fresh_mass >= 0.0 && phase2_finite(result.history_mass) && result.history_mass >= 0.0 && phase2_finite(result.merged_mass) && result.merged_mass >= fresh_mass;
	result.select_history = result.mass_valid && result.history_mass > 0.0 && selection_random * result.merged_mass < result.history_mass;
	float selected_target = result.select_history ? current_target : fresh_target;
	result.output_weight = 0.0;
	result.output_valid = result.mass_valid && result.merged_mass > 0.0 && selected_target > 0.0 && result.merged_count > 0u;
	if (result.output_valid) {
		result.output_weight = result.merged_mass / (float(result.merged_count) * selected_target);
		result.output_valid = phase2_finite(result.output_weight) && result.output_weight >= 0.0;
	}
	return result;
}

void phase2_pack_reservoir_words(Phase2Reservoir reservoir, out uint words[26]) {
	words[0] = floatBitsToUint(reservoir.owner_position.x);
	words[1] = floatBitsToUint(reservoir.owner_position.y);
	words[2] = floatBitsToUint(reservoir.owner_position.z);
	words[3] = floatBitsToUint(reservoir.weight);
	words[4] = floatBitsToUint(reservoir.direction_world.x);
	words[5] = floatBitsToUint(reservoir.direction_world.y);
	words[6] = floatBitsToUint(reservoir.direction_world.z);
	words[7] = floatBitsToUint(reservoir.proposal_pdf);
	words[8] = floatBitsToUint(reservoir.endpoint_world.x);
	words[9] = floatBitsToUint(reservoir.endpoint_world.y);
	words[10] = floatBitsToUint(reservoir.endpoint_world.z);
	words[11] = floatBitsToUint(reservoir.endpoint_distance);
	words[12] = floatBitsToUint(reservoir.radiance.x);
	words[13] = floatBitsToUint(reservoir.radiance.y);
	words[14] = floatBitsToUint(reservoir.radiance.z);
	words[15] = floatBitsToUint(reservoir.target);
	words[16] = uint(reservoir.absolute_geometry_cell.x);
	words[17] = uint(reservoir.absolute_geometry_cell.y);
	words[18] = uint(reservoir.absolute_geometry_cell.z);
	words[19] = phase2_pack_identity(reservoir);
	words[20] = reservoir.sample_count;
	words[21] = reservoir.age;
	words[22] = pack_surface_normal(reservoir.endpoint_normal_world, false);
	words[23] = pack_surface_normal(reservoir.owner_normal_world, false);
	words[24] = reservoir.generation;
	words[25] = phase2_pack_version(reservoir);
}

uvec4 phase2_digest_reservoir_words(uint words[26]) {
	uvec4 digest = uvec4(0x811c9dc5u, 0x9e3779b9u, 0x243f6a88u, 0xb7e15162u);
	const uvec4 primes = uvec4(0x01000193u, 0x85ebca6bu, 0xc2b2ae35u, 0x27d4eb2fu);
	for (uint index = 0u; index < 26u; index++) {
		uint mixed_word = words[index] + index * 0x9e3779b9u;
		digest = (digest ^ uvec4(mixed_word)) * primes;
	}
	digest ^= digest >> 16u;
	digest *= uvec4(0x85ebca6bu);
	digest ^= digest >> 13u;
	digest *= uvec4(0xc2b2ae35u);
	digest ^= digest >> 16u;
	return digest;
}

void phase2_store_current(ivec2 probe_pos, Phase2Reservoir reservoir);
Phase2Reservoir phase2_load_current(ivec2 probe_pos);
bool phase2_receiver_is_zero_target(vec3 owner_normal_world, vec3 direction_world);

// This runs on one invocation only when the existing GPU-statistics QA path is
// enabled. It executes the production fresh and compressed-temporal primitives,
// round-trips the synthetic final reservoir through the real current seven-atlas
// storage, and returns a digest of the reloaded 26-word logical ABI. The normal
// production fresh write immediately overwrites probe (0,0), so neither output
// nor history is polluted. Previous sampled descriptors are not part of this
// bitwise round-trip. No resource or readback is added to production.
void phase2_write_gpu_golden_digest(ivec2 probe_pos) {
	if ((params.flags & PHASE1_FLAG_GPU_STATS) == 0u || params.debug_mode != 0 || params.view_index != 0u || any(notEqual(probe_pos, ivec2(0)))) {
		return;
	}

	Phase2Reservoir reservoir = phase2_empty_reservoir();
	reservoir.owner_position = vec3(1.0, 2.0, 3.0);
	reservoir.owner_normal_world = vec3(0.0, 0.0, 1.0);
	float weight_sum = 0.0;
	uint selected_sample_id = 0u;
	const float candidate_weights[3] = float[](1.0, 3.0, 6.0);
	const float random_values[3] = float[](0.0, 0.2, 0.8);
	for (uint candidate = 0u; candidate < 3u; candidate++) {
		if (phase2_weighted_reservoir_update(weight_sum, reservoir.sample_count, candidate_weights[candidate], random_values[candidate])) {
			selected_sample_id = 10u + candidate;
			reservoir.target = candidate_weights[candidate];
		}
	}

	reservoir.weight = weight_sum / (float(reservoir.sample_count) * reservoir.target);
	reservoir.direction_world = vec3(0.0, 0.0, 1.0);
	reservoir.proposal_pdf = 1.0;
	reservoir.endpoint_world = vec3(1.0, 2.0, 5.0 + float(selected_sample_id - 10u));
	reservoir.endpoint_distance = reservoir.endpoint_world.z - reservoir.owner_position.z;
	reservoir.radiance = vec3(reservoir.target);
	reservoir.absolute_geometry_cell = ivec3(-int(selected_sample_id), int(selected_sample_id * 2u), int(selected_sample_id * 3u));
	reservoir.hit_cascade = 2;
	reservoir.hit_face = ivec3(0, 0, -1);
	reservoir.region_version = 0x2345u;
	reservoir.endpoint_normal_world = vec3(0.0, 0.0, -1.0);
	reservoir.age = selected_sample_id - 10u;
	reservoir.generation = 0x00313233u;
	reservoir.algorithm = PHASE2_ALGORITHM_VERSION;
	reservoir.flags = PHASE2_RESERVOIR_VALID | PHASE2_RESERVOIR_HIT | PHASE2_RESERVOIR_ENDPOINT_REUSABLE;

	float fresh_mass = phase2_compressed_stream_mass(reservoir.target, reservoir.weight, reservoir.sample_count);
	bool cap_applied;
	uint effective_history_count = phase2_effective_history_count(9u, 4u, cap_applied);
	Phase2CompressedStreamMerge merge = phase2_merge_compressed_stream(fresh_mass, reservoir.sample_count, reservoir.target, 0.5, effective_history_count, 2.0, 1.5, true, 0.25);
	Phase2CompressedStreamMerge zero_target_merge = phase2_merge_compressed_stream(fresh_mass, reservoir.sample_count, reservoir.target, 0.5, effective_history_count, 0.0, 1.5, true, 0.25);
	bool zero_target_branch_valid = phase2_receiver_is_zero_target(vec3(0.0, 0.0, 1.0), vec3(0.0, 0.0, -1.0)) && !phase2_receiver_is_zero_target(vec3(0.0, 0.0, 1.0), vec3(0.0, 0.0, 1.0));
	bool zero_target_valid = zero_target_branch_valid && zero_target_merge.mass_valid && zero_target_merge.output_valid && !zero_target_merge.select_history && zero_target_merge.history_mass == 0.0 && zero_target_merge.merged_count == reservoir.sample_count + effective_history_count;
	if (cap_applied && merge.mass_valid && merge.output_valid && merge.select_history && zero_target_valid) {
		reservoir.direction_world = vec3(0.0, 0.0, 1.0);
		reservoir.proposal_pdf = 0.25;
		reservoir.endpoint_world = vec3(1.0, 2.0, 7.0);
		reservoir.endpoint_distance = 4.0;
		reservoir.radiance = vec3(2.0);
		reservoir.target = 2.0;
		reservoir.absolute_geometry_cell = ivec3(-7, 8, 9);
		reservoir.hit_cascade = 3;
		reservoir.hit_face = ivec3(0, 0, -1);
		reservoir.region_version = 0x1234u;
		reservoir.endpoint_normal_world = vec3(0.0, 0.0, -1.0);
		reservoir.age = 6u;
		reservoir.flags = PHASE2_RESERVOIR_VALID | PHASE2_RESERVOIR_HIT | PHASE2_RESERVOIR_SELECTED_HISTORY | PHASE2_RESERVOIR_ENDPOINT_REUSABLE;
		reservoir.sample_count = merge.merged_count;
		reservoir.weight = merge.output_weight;
		// Fold the zero-current-target fixture's reconstructed W and merged M into
		// the persisted ABI digest without making the synthetic payload invalid.
		reservoir.generation = (reservoir.generation ^ floatBitsToUint(zero_target_merge.output_weight) ^ zero_target_merge.merged_count) & 0x00ffffffu;
	} else {
		// A helper regression remains observable as a different digest instead of
		// silently falling back to the expected final history payload.
		reservoir.flags = 0u;
		reservoir.sample_count = merge.merged_count;
		reservoir.weight = 0.0;
	}

	phase2_store_current(probe_pos, reservoir);
	memoryBarrierImage();
	Phase2Reservoir round_tripped = phase2_load_current(probe_pos);
	uint words[26];
	phase2_pack_reservoir_words(round_tripped, words);
	uvec4 digest = phase2_digest_reservoir_words(words);
	for (uint lane = 0u; lane < 4u; lane++) {
		atomicExchange(screen_probe_stats[PHASE2_STAT_GPU_GOLDEN_DIGEST_BASE + lane], digest[lane]);
	}
	atomicExchange(screen_probe_stats[PHASE2_STAT_GPU_ZERO_TARGET_BRANCH_GOLDEN], zero_target_valid ? 1u : 0u);
}

void phase2_store_current(ivec2 probe_pos, Phase2Reservoir reservoir) {
	uint packed_identity = phase2_pack_identity(reservoir);
	uint packed_version = phase2_pack_version(reservoir);
	imageStore(phase2_current_owner, probe_pos, vec4(reservoir.owner_position, reservoir.weight));
	imageStore(phase2_current_sample, probe_pos, vec4(reservoir.direction_world, reservoir.proposal_pdf));
	imageStore(phase2_current_endpoint, probe_pos, vec4(reservoir.endpoint_world, reservoir.endpoint_distance));
	imageStore(phase2_current_radiance, probe_pos, vec4(reservoir.radiance, reservoir.target));
	imageStore(phase2_current_identity, probe_pos, uvec4(uvec3(reservoir.absolute_geometry_cell), packed_identity));
	imageStore(phase2_current_meta, probe_pos, uvec4(reservoir.sample_count, reservoir.age, pack_surface_normal(reservoir.endpoint_normal_world, false), pack_surface_normal(reservoir.owner_normal_world, false)));
	imageStore(phase2_current_version, probe_pos, uvec4(reservoir.generation, packed_version, 0u, 0u));
}

Phase2Reservoir phase2_load_current(ivec2 probe_pos) {
	Phase2Reservoir reservoir = phase2_empty_reservoir();
	vec4 owner = imageLoad(phase2_current_owner, probe_pos);
	vec4 sample_data = imageLoad(phase2_current_sample, probe_pos);
	vec4 endpoint = imageLoad(phase2_current_endpoint, probe_pos);
	vec4 radiance = imageLoad(phase2_current_radiance, probe_pos);
	uvec4 identity = imageLoad(phase2_current_identity, probe_pos);
	uvec4 meta = imageLoad(phase2_current_meta, probe_pos);
	uvec2 version = imageLoad(phase2_current_version, probe_pos).rg;
	reservoir.owner_position = owner.xyz;
	reservoir.weight = owner.w;
	reservoir.direction_world = sample_data.xyz;
	reservoir.proposal_pdf = sample_data.w;
	reservoir.endpoint_world = endpoint.xyz;
	reservoir.endpoint_distance = endpoint.w;
	reservoir.radiance = radiance.xyz;
	reservoir.target = radiance.w;
	reservoir.absolute_geometry_cell = ivec3(identity.xyz);
	reservoir.hit_cascade = int(identity.w & 0xffu);
	reservoir.hit_face = phase2_face_from_index((identity.w >> 8u) & 0x7u);
	reservoir.region_version = version.y >> 16u;
	reservoir.endpoint_normal_world = unpack_surface_normal(meta.z);
	reservoir.owner_normal_world = unpack_surface_normal(meta.w);
	reservoir.sample_count = meta.x;
	reservoir.age = meta.y;
	reservoir.generation = version.x;
	reservoir.algorithm = version.y & 0xffu;
	reservoir.flags = (version.y >> 8u) & 0xffu;
	return reservoir;
}

Phase2Reservoir phase2_load_previous(ivec2 probe_pos) {
	Phase2Reservoir reservoir = phase2_empty_reservoir();
	vec4 owner = texelFetch(sampler2D(phase2_previous_owner, nearest_sampler), probe_pos, 0);
	vec4 sample_data = texelFetch(sampler2D(phase2_previous_sample, nearest_sampler), probe_pos, 0);
	vec4 endpoint = texelFetch(sampler2D(phase2_previous_endpoint, nearest_sampler), probe_pos, 0);
	vec4 radiance = texelFetch(sampler2D(phase2_previous_radiance, nearest_sampler), probe_pos, 0);
	uvec4 identity = texelFetch(usampler2D(phase2_previous_identity, nearest_sampler), probe_pos, 0);
	uvec4 meta = texelFetch(usampler2D(phase2_previous_meta, nearest_sampler), probe_pos, 0);
	uvec2 version = texelFetch(usampler2D(phase2_previous_version, nearest_sampler), probe_pos, 0).rg;
	reservoir.owner_position = owner.xyz;
	reservoir.weight = owner.w;
	reservoir.direction_world = sample_data.xyz;
	reservoir.proposal_pdf = sample_data.w;
	reservoir.endpoint_world = endpoint.xyz;
	reservoir.endpoint_distance = endpoint.w;
	reservoir.radiance = radiance.xyz;
	reservoir.target = radiance.w;
	reservoir.absolute_geometry_cell = ivec3(identity.xyz);
	reservoir.hit_cascade = int(identity.w & 0xffu);
	reservoir.hit_face = phase2_face_from_index((identity.w >> 8u) & 0x7u);
	reservoir.region_version = version.y >> 16u;
	reservoir.endpoint_normal_world = unpack_surface_normal(meta.z);
	reservoir.owner_normal_world = unpack_surface_normal(meta.w);
	reservoir.sample_count = meta.x;
	reservoir.age = meta.y;
	reservoir.generation = version.x;
	reservoir.algorithm = version.y & 0xffu;
	reservoir.flags = (version.y >> 8u) & 0xffu;
	return reservoir;
}

bool phase2_decode_surface(uvec4 packed, out ivec2 r_screen_pos, out float r_depth, out vec3 r_normal, out bool r_dynamic) {
	if (all(equal(packed.xy, uvec2(0xffffffffu)))) {
		return false;
	}
	r_screen_pos = ivec2(packed.xy);
	r_depth = uintBitsToFloat(packed.z);
	r_normal = unpack_surface_normal(packed.w);
	r_dynamic = surface_is_dynamic(packed.w);
	return r_depth > 0.0 && phase2_finite(r_depth) && all(greaterThanEqual(r_screen_pos, ivec2(0))) && all(lessThan(r_screen_pos, params.screen_size));
}

float phase2_probe_axis_texel(float grid_uv, int gi_extent, int probe_extent) {
	int safe_probe_extent = max(probe_extent, 1);
	int atlas_extent = max((gi_extent + safe_probe_extent - 1) / safe_probe_extent, 1);
	float grid_pixel = grid_uv * float(gi_extent);
	float last_origin = float((atlas_extent - 1) * safe_probe_extent);
	float last_center = (last_origin + float(gi_extent)) * 0.5;
	if (atlas_extent <= 1) {
		float only_tile_extent = float(max(min(safe_probe_extent, gi_extent), 1));
		return (grid_pixel - last_center) / only_tile_extent;
	}

	// Full tiles have centers separated by probe_size. The clipped edge tile
	// has its real center closer to the preceding tile, so preserve that final
	// interval instead of pretending an off-screen full tile exists.
	float previous_center = (float(atlas_extent) - 1.5) * float(safe_probe_extent);
	float previous_texel = float(atlas_extent - 2);
	if (grid_pixel >= previous_center) {
		float last_spacing = max(last_center - previous_center, 1e-6);
		return previous_texel + (grid_pixel - previous_center) / last_spacing;
	}
	return grid_pixel / float(safe_probe_extent) - 0.5;
}

vec2 phase2_grid_uv_to_probe_texel(vec2 grid_uv) {
	return vec2(
			phase2_probe_axis_texel(grid_uv.x, params.gi_size.x, params.probe_size),
			phase2_probe_axis_texel(grid_uv.y, params.gi_size.y, params.probe_size));
}

bool phase2_reproject_owner(ivec2 probe_pos, vec3 current_receiver_view, vec3 receiver_world, out vec2 r_previous_probe_texel) {
	ivec2 gi_origin = probe_pos * params.probe_size;
	ivec2 gi_end = min(gi_origin + ivec2(params.probe_size), params.gi_size);
	vec2 current_grid_uv = (vec2(gi_origin) + vec2(gi_end)) * 0.5 / vec2(params.gi_size);
	vec2 previous_grid_uv;
	vec3 previous_receiver_view;
	if (!temporal_reproject_jitter_neutral(current_grid_uv, current_receiver_view, receiver_world, previous_grid_uv, previous_receiver_view)) {
		r_previous_probe_texel = vec2(0.0);
		return false;
	}
	if (any(lessThan(previous_grid_uv, vec2(0.0))) || any(greaterThanEqual(previous_grid_uv, vec2(1.0)))) {
		r_previous_probe_texel = vec2(0.0);
		return false;
	}
	r_previous_probe_texel = phase2_grid_uv_to_probe_texel(previous_grid_uv);
	return !any(isnan(r_previous_probe_texel)) && !any(isinf(r_previous_probe_texel));
}

vec3 phase2_previous_surface_world(ivec2 screen_pos, float depth, mat4 previous_cam_transform) {
	vec2 uv = (vec2(screen_pos) + 0.5) / vec2(params.screen_size);
	vec4 previous_view = scene_data.previous_inv_projection[params.view_index] * vec4(uv * 2.0 - 1.0, depth, 1.0);
	previous_view /= previous_view.w;
	return (previous_cam_transform * vec4(previous_view.xyz, 1.0)).xyz;
}

float phase2_geometry_term(vec3 owner_world, vec3 endpoint_world, vec3 endpoint_normal_world) {
	vec3 to_owner = owner_world - endpoint_world;
	float distance_squared = dot(to_owner, to_owner);
	if (!phase2_finite(distance_squared) || distance_squared <= 1e-10) {
		return 0.0;
	}
	float endpoint_cosine = max(dot(endpoint_normal_world, to_owner * inversesqrt(distance_squared)), 0.0);
	return endpoint_cosine / distance_squared;
}

float phase2_target(vec3 radiance, vec3 owner_normal_world, vec3 direction_world) {
	float cosine = max(dot(owner_normal_world, direction_world), 0.0);
	return phase2_luminance(radiance * (cosine / PHASE2_PI));
}

bool phase2_receiver_is_zero_target(vec3 owner_normal_world, vec3 direction_world) {
	return dot(owner_normal_world, direction_world) <= 0.0;
}

bool phase2_transport_origin(vec3 receiver_world, vec3 receiver_normal_world, out vec3 r_transport_origin, out int r_start_cascade) {
	r_transport_origin = receiver_world;
	r_start_cascade = -1;
	vec3 receiver_scaled = receiver_world;
	receiver_scaled.y *= hddagi.y_mult;
	for (int cascade = 0; cascade < hddagi.max_cascades; cascade++) {
		vec3 absolute_cascade_origin_scaled = vec3(hddagi.cascades[cascade].region_world_offset * HDDAGI_REGION_SIZE - hddagi.grid_size / 2) / hddagi.cascades[cascade].to_cell;
		vec3 receiver_cell = (receiver_scaled - absolute_cascade_origin_scaled) * hddagi.cascades[cascade].to_cell;
		if (all(greaterThanEqual(receiver_cell, vec3(0.0))) && all(lessThan(receiver_cell, vec3(hddagi.grid_size)))) {
			vec3 normal_scaled = receiver_normal_world;
			normal_scaled.y *= hddagi.y_mult;
			normal_scaled = normalize(normal_scaled);
			vec3 abs_normal = abs(normal_scaled);
			vec3 ray_bias = normal_scaled / max(abs_normal.x, max(abs_normal.y, abs_normal.z));
			vec3 transport_scaled = absolute_cascade_origin_scaled + (receiver_cell + ray_bias * params.normal_bias) / hddagi.cascades[cascade].to_cell;
			transport_scaled.y /= max(abs(hddagi.y_mult), 1e-6);
			r_transport_origin = transport_scaled;
			r_start_cascade = cascade;
			return phase2_finite3(r_transport_origin);
		}
	}
	return false;
}

void phase2_current_receiver_state(ivec2 screen_pos, float depth, vec3 normal_view, out vec3 r_receiver_view, out vec3 r_receiver_world, out vec3 r_normal_world, out vec3 r_transport_origin) {
	vec2 uv = (vec2(screen_pos) + 0.5) / vec2(params.screen_size);
	r_receiver_view = compute_view_pos(vec3(uv, depth));
	r_receiver_world = (scene_data.cam_transform * vec4(r_receiver_view, 1.0)).xyz;
	r_normal_world = normalize(mat3(scene_data.cam_transform) * normal_view);
	int start_cascade;
	phase2_transport_origin(r_receiver_world, r_normal_world, r_transport_origin, start_cascade);
}

float phase2_endpoint_tolerance(int cascade) {
	if (cascade < 0 || cascade >= hddagi.max_cascades) {
		return 1e-4;
	}
	float cell_size = 1.0 / hddagi.cascades[cascade].to_cell;
	float physical_cell_size = cell_size * max(1.0, 1.0 / max(abs(hddagi.y_mult), 1e-6));
	return max(physical_cell_size * 0.01, 1e-4);
}

bool phase2_endpoint_on_recorded_face(int cascade, ivec3 absolute_cell, ivec3 face, vec3 endpoint_world) {
	if (cascade < 0 || cascade >= hddagi.max_cascades ||
			abs(face.x) + abs(face.y) + abs(face.z) != 1 || !phase2_finite3(endpoint_world)) {
		return false;
	}
	float cell_size = 1.0 / hddagi.cascades[cascade].to_cell;
	float scaled_tolerance = max(cell_size * 0.01, 1e-4);
	vec3 endpoint_scaled = endpoint_world;
	endpoint_scaled.y *= hddagi.y_mult;
	vec3 cell_min = vec3(absolute_cell) * cell_size;
	vec3 cell_max = cell_min + vec3(cell_size);
	int axis = face.x != 0 ? 0 : (face.y != 0 ? 1 : 2);
	float face_plane = face[axis] < 0 ? cell_min[axis] : cell_max[axis];
	if (abs(endpoint_scaled[axis] - face_plane) > scaled_tolerance) {
		return false;
	}
	for (int component = 0; component < 3; component++) {
		if (component != axis && (endpoint_scaled[component] < cell_min[component] - scaled_tolerance || endpoint_scaled[component] > cell_max[component] + scaled_tolerance)) {
			return false;
		}
	}
	return true;
}

void phase2_fresh_main() {
	ivec2 probe_pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(probe_pos, imageSize(phase2_current_owner)))) {
		return;
	}
	phase2_write_gpu_golden_digest(probe_pos);

	Phase2Reservoir reservoir = phase2_empty_reservoir();
	ivec2 origin_pos;
	float origin_depth;
	vec3 origin_normal;
	bool dynamic_surface;
	bool surface_valid = phase2_decode_surface(trace_load_probe_surface(probe_pos), origin_pos, origin_depth, origin_normal, dynamic_surface);
	if (!surface_valid) {
		phase2_store_current(probe_pos, reservoir);
		phase1_stats_add(PHASE2_STAT_FRESH_INVALID, 1u);
		return;
	}

	phase1_stats_add(PHASE2_STAT_VALID_SURFACES, 1u);
	vec3 receiver_world;
	vec3 receiver_view;
	phase2_current_receiver_state(origin_pos, origin_depth, origin_normal, receiver_view, receiver_world, reservoir.owner_normal_world, reservoir.owner_position);
	uint trace_count = clamp(params.candidate_count, 1u, 8u);
	phase1_stats_add(PHASE1_STAT_FRESH_CANDIDATES, trace_count);
	float weight_sum = 0.0;
	for (uint candidate = 0u; candidate < trace_count; candidate++) {
		vec2 jitter = vec2(phase2_random(probe_pos, candidate * 3u), phase2_random(probe_pos, candidate * 3u + 1u));
		vec3 local_direction = cosine_sample_hemisphere(jitter);
		vec3 direction_view = tangent_to_world(local_direction, origin_normal);
		vec3 direction_world = normalize(mat3(scene_data.cam_transform) * direction_view);
		float proposal_pdf = max(dot(origin_normal, direction_view), 0.0) / PHASE2_PI;
		if (!phase2_finite(proposal_pdf) || proposal_pdf <= 0.0 || !phase2_finite3(direction_world)) {
			continue;
		}

		vec3 sample_radiance;
		ivec3 absolute_geometry_cell;
		int hit_cascade;
		ivec3 hit_face;
		uint region_version;
		vec3 endpoint_world;
		vec3 endpoint_normal_world;
		bool hit = trace_hddagi_sample(origin_pos, origin_depth, origin_normal, direction_view, sample_radiance, absolute_geometry_cell, hit_cascade, hit_face, region_version, endpoint_world, endpoint_normal_world);
		if (!hit) {
			sample_radiance = sample_environment(direction_view);
		}
		sample_radiance *= hddagi.energy;
		if (!phase2_finite3(sample_radiance) || any(lessThan(sample_radiance, vec3(0.0)))) {
			phase1_stats_add(PHASE2_STAT_NONFINITE, 1u);
			continue;
		}

		vec3 contribution = sample_radiance * (max(dot(reservoir.owner_normal_world, direction_world), 0.0) / PHASE2_PI);
		float target = phase2_luminance(contribution);
		float candidate_weight = target / proposal_pdf;
		if (!phase2_finite(candidate_weight) || candidate_weight < 0.0) {
			phase1_stats_add(PHASE2_STAT_NONFINITE, 1u);
			continue;
		}
		// M counts every well-defined candidate, including finite zero-weight
		// candidates, but never malformed/non-finite proposals.
		if (phase2_weighted_reservoir_update(weight_sum, reservoir.sample_count, candidate_weight, phase2_random(probe_pos, candidate * 3u + 2u))) {
			reservoir.direction_world = direction_world;
			reservoir.proposal_pdf = proposal_pdf;
			reservoir.radiance = sample_radiance;
			reservoir.target = target;
			reservoir.flags = PHASE2_RESERVOIR_VALID | (hit ? PHASE2_RESERVOIR_HIT : PHASE2_RESERVOIR_SKY);
			if (hit) {
				if (phase2_endpoint_on_recorded_face(hit_cascade, absolute_geometry_cell, hit_face, endpoint_world)) {
					reservoir.absolute_geometry_cell = absolute_geometry_cell;
					reservoir.hit_cascade = hit_cascade;
					reservoir.hit_face = hit_face;
					reservoir.region_version = region_version;
					reservoir.endpoint_normal_world = endpoint_normal_world;
					reservoir.endpoint_world = endpoint_world;
					reservoir.endpoint_distance = length(endpoint_world - reservoir.owner_position);
					reservoir.flags |= PHASE2_RESERVOIR_ENDPOINT_REUSABLE;
				} else {
					// Synthetic start-cell disocclusion hits remain valid fresh samples,
					// but deliberately carry no reusable endpoint identity.
					reservoir.absolute_geometry_cell = ivec3(0);
					reservoir.hit_cascade = -1;
					reservoir.hit_face = ivec3(0);
					reservoir.region_version = 0u;
					reservoir.endpoint_world = vec3(0.0);
					reservoir.endpoint_distance = 0.0;
					reservoir.endpoint_normal_world = vec3(0.0, 0.0, 1.0);
				}
			}
		}
	}

	if ((reservoir.flags & PHASE2_RESERVOIR_VALID) != 0u && reservoir.sample_count > 0u && reservoir.target > 0.0) {
		reservoir.weight = weight_sum / (float(reservoir.sample_count) * reservoir.target);
		if (!phase2_finite(reservoir.weight) || reservoir.weight < 0.0) {
			reservoir.flags = 0u;
			reservoir.weight = 0.0;
			phase1_stats_add(PHASE2_STAT_NONFINITE, 1u);
		}
	}
	phase1_stats_add((reservoir.flags & PHASE2_RESERVOIR_VALID) != 0u ? PHASE2_STAT_FRESH_VALID : PHASE2_STAT_FRESH_INVALID, 1u);
	phase2_store_current(probe_pos, reservoir);
}

bool phase2_validate_previous_receiver(Phase2Reservoir previous, ivec2 previous_probe_pos, vec3 current_receiver_world, vec3 current_normal_world, mat4 previous_cam_transform, out float r_association_score) {
	r_association_score = 0.0;
	ivec2 previous_screen_pos;
	float previous_depth;
	vec3 previous_normal_view;
	bool previous_dynamic;
	if (!phase2_decode_surface(texelFetch(usampler2D(phase2_previous_surface, nearest_sampler), previous_probe_pos, 0), previous_screen_pos, previous_depth, previous_normal_view, previous_dynamic) || previous_dynamic) {
		return false;
	}
	vec3 previous_surface_world = phase2_previous_surface_world(previous_screen_pos, previous_depth, previous_cam_transform);
	vec3 previous_normal_world = normalize(mat3(previous_cam_transform) * previous_normal_view);
	vec3 previous_transport_origin;
	int previous_start_cascade;
	bool transport_valid = phase2_transport_origin(previous_surface_world, previous_normal_world, previous_transport_origin, previous_start_cascade);
	float position_tolerance = max(params.history_depth_tolerance, 1e-4);
	float receiver_distance = distance(current_receiver_world, previous_surface_world);
	float owner_distance = distance(previous.owner_position, previous_transport_origin);
	float current_normal_similarity = dot(current_normal_world, previous_normal_world);
	float owner_normal_similarity = dot(previous.owner_normal_world, previous_normal_world);
	if (!transport_valid || !phase2_finite3(previous_surface_world) || !phase2_finite3(previous_transport_origin) ||
			!phase2_finite(receiver_distance) || !phase2_finite(owner_distance) ||
			receiver_distance > position_tolerance || owner_distance > position_tolerance ||
			current_normal_similarity < params.history_normal_threshold || owner_normal_similarity < params.history_normal_threshold) {
		return false;
	}
	float receiver_score = 1.0 - clamp(receiver_distance / position_tolerance, 0.0, 1.0);
	float owner_score = 1.0 - clamp(owner_distance / position_tolerance, 0.0, 1.0);
	float normal_span = max(1.0 - params.history_normal_threshold, 1e-4);
	float current_normal_score = clamp((current_normal_similarity - params.history_normal_threshold) / normal_span, 0.0, 1.0);
	float owner_normal_score = clamp((owner_normal_similarity - params.history_normal_threshold) / normal_span, 0.0, 1.0);
	r_association_score = receiver_score * owner_score * current_normal_score * owner_normal_score;
	return true;
}

bool phase2_hit_encoding_valid(Phase2Reservoir previous);
bool phase2_hit_payload_valid(Phase2Reservoir previous);
bool phase2_validate_hit_identity(Phase2Reservoir previous);

bool phase2_candidate_intrinsic_valid(Phase2Reservoir candidate, out bool r_packing_invalid) {
	r_packing_invalid = false;
	bool candidate_hit = (candidate.flags & PHASE2_RESERVOIR_HIT) != 0u;
	bool candidate_sky = (candidate.flags & PHASE2_RESERVOIR_SKY) != 0u;
	bool endpoint_reusable = (candidate.flags & PHASE2_RESERVOIR_ENDPOINT_REUSABLE) != 0u;
	if (candidate_hit == candidate_sky || (candidate_sky && endpoint_reusable)) {
		r_packing_invalid = true;
		return false;
	}
	if (candidate_hit && !endpoint_reusable) {
		return false;
	}
	if (candidate_hit && !phase2_hit_encoding_valid(candidate)) {
		r_packing_invalid = true;
		return false;
	}
	if (candidate_hit && (!phase2_hit_payload_valid(candidate) || !phase2_validate_hit_identity(candidate))) {
		return false;
	}
	return true;
}

bool phase2_select_previous_reservoir(vec2 previous_probe_texel, vec3 current_receiver_world, vec3 current_normal_world, out Phase2Reservoir r_previous, out ivec2 r_previous_probe_pos, out uint r_rejection_stat) {
	r_previous = phase2_empty_reservoir();
	r_previous_probe_pos = ivec2(0);
	r_rejection_stat = PHASE2_STAT_REJECT_REPROJECTION_OR_OWNER;
	ivec2 atlas_size = textureSize(sampler2D(phase2_previous_owner, nearest_sampler), 0);
	ivec2 base = ivec2(floor(previous_probe_texel));
	vec2 fraction = fract(previous_probe_texel);
	mat4 previous_cam_transform = inverse(scene_data.previous_cam_inv_transform);
	bool footprint_present = false;
	bool generation_present = false;
	bool age_present = false;
	bool intrinsic_present = false;
	bool intrinsic_failure_present = false;
	float best_score = -1.0;
	float best_footprint_weight = -1.0;

	for (int y = 0; y < 2; y++) {
		for (int x = 0; x < 2; x++) {
			vec2 axis_weight = vec2(x == 0 ? 1.0 - fraction.x : fraction.x, y == 0 ? 1.0 - fraction.y : fraction.y);
			float footprint_weight = axis_weight.x * axis_weight.y;
			if (footprint_weight <= 1e-8) {
				continue;
			}
			ivec2 candidate_pos = base + ivec2(x, y);
			if (any(lessThan(candidate_pos, ivec2(0))) || any(greaterThanEqual(candidate_pos, atlas_size))) {
				continue;
			}
			footprint_present = true;
			Phase2Reservoir candidate = phase2_load_previous(candidate_pos);
			if ((candidate.flags & PHASE2_RESERVOIR_VALID) == 0u || candidate.generation != params.history_generation || candidate.algorithm != params.algorithm_version) {
				continue;
			}
			generation_present = true;
			if (candidate.age >= params.maximum_age) {
				continue;
			}
			age_present = true;
			if (candidate.sample_count == 0u || candidate.weight < 0.0 || !phase2_finite(candidate.weight) ||
					candidate.proposal_pdf <= 0.0 || !phase2_finite(candidate.proposal_pdf) ||
					!phase2_finite3(candidate.owner_position) || !phase2_finite3(candidate.owner_normal_world) || !phase2_finite3(candidate.direction_world)) {
				continue;
			}
			bool packing_invalid;
			if (!phase2_candidate_intrinsic_valid(candidate, packing_invalid)) {
				intrinsic_failure_present = true;
				if (packing_invalid) {
					phase1_stats_add(PHASE2_STAT_PACKING_INVALID, 1u);
				}
				continue;
			}
			intrinsic_present = true;
			float geometry_score;
			if (!phase2_validate_previous_receiver(candidate, candidate_pos, current_receiver_world, current_normal_world, previous_cam_transform, geometry_score)) {
				continue;
			}
			float association_score = footprint_weight * geometry_score;
			bool score_wins = association_score > best_score + 1e-8;
			bool weight_wins = abs(association_score - best_score) <= 1e-8 && footprint_weight > best_footprint_weight + 1e-8;
			bool coordinate_wins = abs(association_score - best_score) <= 1e-8 && abs(footprint_weight - best_footprint_weight) <= 1e-8 &&
					(candidate_pos.y < r_previous_probe_pos.y || (candidate_pos.y == r_previous_probe_pos.y && candidate_pos.x < r_previous_probe_pos.x));
			if (score_wins || weight_wins || coordinate_wins) {
				best_score = association_score;
				best_footprint_weight = footprint_weight;
				r_previous = candidate;
				r_previous_probe_pos = candidate_pos;
			}
		}
	}

	if (best_score >= 0.0) {
		return true;
	}
	if (footprint_present && !generation_present) {
		r_rejection_stat = PHASE2_STAT_REJECT_GENERATION_OR_ALGORITHM;
	} else if (generation_present && !age_present) {
		r_rejection_stat = PHASE2_STAT_REJECT_AGE;
	} else if (age_present && intrinsic_failure_present && !intrinsic_present) {
		r_rejection_stat = PHASE2_STAT_REJECT_ENDPOINT_IDENTITY_OR_VERSION;
	}
	return false;
}

bool phase2_hit_encoding_valid(Phase2Reservoir previous) {
	if (previous.hit_cascade < 0 || previous.hit_cascade >= hddagi.max_cascades ||
			phase2_face_index(previous.hit_face) >= 6u ||
			abs(previous.hit_face.x) + abs(previous.hit_face.y) + abs(previous.hit_face.z) != 1 ||
			!phase2_finite3(previous.owner_position) || !phase2_finite3(previous.direction_world) ||
			!phase2_finite3(previous.endpoint_world) || !phase2_finite3(previous.endpoint_normal_world) ||
			!phase2_finite(previous.endpoint_distance) || previous.endpoint_distance <= 0.0) {
		return false;
	}
	return true;
}

bool phase2_hit_payload_valid(Phase2Reservoir previous) {
	if (!phase2_endpoint_on_recorded_face(previous.hit_cascade, previous.absolute_geometry_cell, previous.hit_face, previous.endpoint_world) ||
			dot(previous.endpoint_normal_world, vec3(previous.hit_face)) <= 0.999) {
		return false;
	}
	vec3 owner_to_endpoint = previous.endpoint_world - previous.owner_position;
	float endpoint_distance = length(owner_to_endpoint);
	float distance_tolerance = max(phase2_endpoint_tolerance(previous.hit_cascade), max(endpoint_distance, previous.endpoint_distance) * 1e-4);
	return phase2_finite(endpoint_distance) && endpoint_distance > 0.0 &&
			abs(endpoint_distance - previous.endpoint_distance) <= distance_tolerance &&
			dot(normalize(owner_to_endpoint), normalize(previous.direction_world)) >= 0.9999;
}

bool phase2_validate_hit_identity(Phase2Reservoir previous) {
	ivec3 local_cell = previous.absolute_geometry_cell - hddagi.cascades[previous.hit_cascade].region_world_offset * HDDAGI_REGION_SIZE + hddagi.grid_size / 2;
	if (any(lessThan(local_cell, ivec3(0))) || any(greaterThanEqual(local_cell, hddagi.grid_size))) {
		return false;
	}
	ivec3 wrapped_cell = (local_cell + hddagi.cascades[previous.hit_cascade].region_world_offset * HDDAGI_REGION_SIZE) & (hddagi.grid_size - 1);
	ivec3 region_coord = wrapped_cell / HDDAGI_REGION_SIZE + ivec3(0, (hddagi.grid_size.y / HDDAGI_REGION_SIZE) * previous.hit_cascade, 0);
	return phase2_load_region_version(region_coord) == previous.region_version;
}

void phase2_finalize(ivec2 probe_pos, Phase2Reservoir reservoir, bool surface_valid) {
	vec4 output_value = vec4(0.0);
	bool reservoir_valid = surface_valid && (reservoir.flags & PHASE2_RESERVOIR_VALID) != 0u && reservoir.sample_count > 0u && reservoir.target > 0.0 && reservoir.weight >= 0.0 && phase2_finite(reservoir.weight) && phase2_finite3(reservoir.radiance);
	if (reservoir_valid) {
		vec3 contribution = reservoir.radiance * (max(dot(reservoir.owner_normal_world, reservoir.direction_world), 0.0) / PHASE2_PI);
		vec3 estimate = contribution * reservoir.weight;
		if (phase2_finite3(estimate) && all(greaterThanEqual(estimate, vec3(0.0)))) {
			output_value.rgb = estimate;
			if ((reservoir.flags & PHASE2_RESERVOIR_HIT) != 0u && phase2_finite(reservoir.endpoint_distance)) {
				output_value.a = max(reservoir.endpoint_distance, 0.0);
			} else if ((reservoir.flags & PHASE2_RESERVOIR_SKY) != 0u) {
				output_value.a = 65504.0;
			}
			phase1_stats_add(PHASE2_STAT_FINAL_VALID, 1u);
			if ((reservoir.flags & PHASE2_RESERVOIR_ROBUST_CLAMPED) != 0u) {
				phase1_stats_add((reservoir.flags & PHASE2_RESERVOIR_SELECTED_HISTORY) != 0u ? PHASE2_STAT_ROBUST_FLAG_FINAL_HISTORY : PHASE2_STAT_ROBUST_FLAG_FINAL_FRESH, 1u);
			}
		} else {
			reservoir.flags = 0u;
			reservoir.weight = 0.0;
			phase1_stats_add(PHASE2_STAT_NONFINITE, 1u);
			phase1_stats_add(PHASE2_STAT_FINAL_INVALID, 1u);
		}
	} else {
		phase1_stats_add(PHASE2_STAT_FINAL_INVALID, 1u);
	}
	phase2_stats_max(PHASE2_STAT_MAX_M, reservoir.sample_count);
	phase2_stats_max(PHASE2_STAT_MAX_AGE, reservoir.age);
	phase1_stats_add(PHASE2_STAT_SUM_M, reservoir.sample_count);
	phase2_store_current(probe_pos, reservoir);
	imageStore(phase2_raw_probe_output, probe_pos, output_value);
}

void phase2_temporal_main() {
	ivec2 probe_pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(probe_pos, imageSize(phase2_current_owner)))) {
		return;
	}

	Phase2Reservoir current = phase2_load_current(probe_pos);
	ivec2 current_screen_pos;
	float current_depth;
	vec3 current_normal_view;
	bool current_dynamic;
	bool surface_valid = phase2_decode_surface(trace_load_probe_surface(probe_pos), current_screen_pos, current_depth, current_normal_view, current_dynamic);
	if (!surface_valid) {
		phase1_stats_add(PHASE2_STAT_REJECT_REPROJECTION_OR_OWNER, 1u);
		phase2_finalize(probe_pos, current, false);
		return;
	}
	// The persisted owner is the post-bias transport origin. Reprojection and
	// receiver validation intentionally use the physical surface point instead.
	vec3 current_receiver_view;
	vec3 current_receiver_world;
	phase2_current_receiver_state(current_screen_pos, current_depth, current_normal_view, current_receiver_view, current_receiver_world, current.owner_normal_world, current.owner_position);
	if ((params.flags & PHASE1_FLAG_RESERVOIR_HISTORY_VALID) == 0u) {
		phase1_stats_add(PHASE2_STAT_REJECT_NO_HISTORY, 1u);
		phase1_stats_add(PHASE2_STAT_SELECTED_FRESH, 1u);
		phase2_finalize(probe_pos, current, true);
		return;
	}
	phase1_stats_add(PHASE2_STAT_TEMPORAL_ATTEMPTS, 1u);
	if (current_dynamic) {
		// Dynamic receivers still receive the fresh estimate generated this frame;
		// only cross-frame reuse is disabled for them.
		phase1_stats_add(PHASE2_STAT_REJECT_REPROJECTION_OR_OWNER, 1u);
		phase1_stats_add(PHASE2_STAT_SELECTED_FRESH, 1u);
		phase2_finalize(probe_pos, current, true);
		return;
	}

	vec2 previous_probe_texel;
	if (!phase2_reproject_owner(probe_pos, current_receiver_view, current_receiver_world, previous_probe_texel)) {
		phase1_stats_add(PHASE2_STAT_REJECT_REPROJECTION_OR_OWNER, 1u);
		phase1_stats_add(PHASE2_STAT_SELECTED_FRESH, 1u);
		phase2_finalize(probe_pos, current, true);
		return;
	}
	Phase2Reservoir previous;
	ivec2 previous_probe_pos;
	uint association_rejection_stat;
	if (!phase2_select_previous_reservoir(previous_probe_texel, current_receiver_world, current.owner_normal_world, previous, previous_probe_pos, association_rejection_stat)) {
		phase1_stats_add(association_rejection_stat, 1u);
		phase1_stats_add(PHASE2_STAT_SELECTED_FRESH, 1u);
		phase2_finalize(probe_pos, current, true);
		return;
	}

	bool previous_hit = (previous.flags & PHASE2_RESERVOIR_HIT) != 0u;
	bool previous_sky = (previous.flags & PHASE2_RESERVOIR_SKY) != 0u;
	bool endpoint_reusable = (previous.flags & PHASE2_RESERVOIR_ENDPOINT_REUSABLE) != 0u;
	if (previous_hit == previous_sky || (previous_sky && endpoint_reusable)) {
		phase1_stats_add(PHASE2_STAT_REJECT_ENDPOINT_IDENTITY_OR_VERSION, 1u);
		phase1_stats_add(PHASE2_STAT_PACKING_INVALID, 1u);
		phase1_stats_add(PHASE2_STAT_SELECTED_FRESH, 1u);
		phase2_finalize(probe_pos, current, true);
		return;
	}
	if (previous_hit && !endpoint_reusable) {
		phase1_stats_add(PHASE2_STAT_REJECT_ENDPOINT_IDENTITY_OR_VERSION, 1u);
		phase1_stats_add(PHASE2_STAT_SELECTED_FRESH, 1u);
		phase2_finalize(probe_pos, current, true);
		return;
	}
	if (previous_hit && !phase2_hit_encoding_valid(previous)) {
		phase1_stats_add(PHASE2_STAT_REJECT_ENDPOINT_IDENTITY_OR_VERSION, 1u);
		phase1_stats_add(PHASE2_STAT_PACKING_INVALID, 1u);
		phase1_stats_add(PHASE2_STAT_SELECTED_FRESH, 1u);
		phase2_finalize(probe_pos, current, true);
		return;
	}
	if (previous_hit && !phase2_hit_payload_valid(previous)) {
		// A finite decoded payload can cease to describe the same endpoint after
		// quantization or camera/cascade movement. This is a normal conservative
		// identity rejection, not an atlas encoding failure.
		phase1_stats_add(PHASE2_STAT_REJECT_ENDPOINT_IDENTITY_OR_VERSION, 1u);
		phase1_stats_add(PHASE2_STAT_SELECTED_FRESH, 1u);
		phase2_finalize(probe_pos, current, true);
		return;
	}
	if (previous_hit && !phase2_validate_hit_identity(previous)) {
		phase1_stats_add(PHASE2_STAT_REJECT_ENDPOINT_IDENTITY_OR_VERSION, 1u);
		phase1_stats_add(PHASE2_STAT_SELECTED_FRESH, 1u);
		phase2_finalize(probe_pos, current, true);
		return;
	}

	vec3 reconnect_vector_world = previous_sky ? previous.direction_world : previous.endpoint_world - current.owner_position;
	float reconnect_length_squared = dot(reconnect_vector_world, reconnect_vector_world);
	if (!phase2_finite3(reconnect_vector_world) || !phase2_finite(reconnect_length_squared) || reconnect_length_squared <= 1e-12) {
		phase1_stats_add(PHASE2_STAT_REJECT_REPROJECTION_OR_OWNER, 1u);
		phase1_stats_add(PHASE2_STAT_SELECTED_FRESH, 1u);
		phase2_finalize(probe_pos, current, true);
		return;
	}
	vec3 reconnect_direction_world = reconnect_vector_world * inversesqrt(reconnect_length_squared);
	vec3 reconnect_direction_view = normalize(inverse(mat3(scene_data.cam_transform)) * reconnect_direction_world);
	if (!phase2_finite3(reconnect_direction_world) || !phase2_finite3(reconnect_direction_view)) {
		phase1_stats_add(PHASE2_STAT_REJECT_REPROJECTION_OR_OWNER, 1u);
		phase1_stats_add(PHASE2_STAT_SELECTED_FRESH, 1u);
		phase2_finalize(probe_pos, current, true);
		return;
	}
	// A finite, identity-valid history direction can move behind the current
	// receiver after reprojection. Its current target is then exactly zero, but
	// the represented M_eff must still participate in the denominator. Treat it
	// as a mass-only stream instead of conditioning reuse on a positive cosine.
	bool zero_target_mass_only = phase2_receiver_is_zero_target(current.owner_normal_world, reconnect_direction_world);

	bool history_m_cap_applied;
	uint effective_history_count = phase2_effective_history_count(previous.sample_count, params.history_m_cap, history_m_cap_applied);
	if (history_m_cap_applied) {
		phase1_stats_add(PHASE2_STAT_M_CAP_APPLIED, 1u);
	}
	float fresh_mass = ((current.flags & PHASE2_RESERVOIR_VALID) != 0u) ? phase2_compressed_stream_mass(current.target, current.weight, current.sample_count) : 0.0;
	if (!phase2_finite(fresh_mass) || fresh_mass < 0.0) {
		phase1_stats_add(PHASE2_STAT_NONFINITE, 1u);
		phase1_stats_add(PHASE2_STAT_SELECTED_FRESH, 1u);
		phase2_finalize(probe_pos, current, true);
		return;
	}

	vec3 current_radiance = vec3(0.0);
	ivec3 current_absolute_cell = ivec3(0);
	int current_hit_cascade = -1;
	ivec3 current_hit_face = ivec3(0);
	uint current_region_version = 0u;
	vec3 current_endpoint_world = vec3(0.0);
	vec3 current_endpoint_normal_world = vec3(0.0, 0.0, 1.0);
	bool current_hit = false;
	float jacobian = 1.0;
	float current_target = 0.0;
	bool history_visible = false;
	bool robust_clamped = false;
	if (!zero_target_mass_only) {
		phase1_stats_add(PHASE2_STAT_VISIBILITY_RAYS, 1u);
		current_hit = trace_hddagi_sample(current_screen_pos, current_depth, current_normal_view, reconnect_direction_view, current_radiance, current_absolute_cell, current_hit_cascade, current_hit_face, current_region_version, current_endpoint_world, current_endpoint_normal_world);
		if (previous_hit) {
			bool same_endpoint = current_hit && current_hit_cascade == previous.hit_cascade &&
					all(equal(current_absolute_cell, previous.absolute_geometry_cell)) &&
					all(equal(current_hit_face, previous.hit_face)) &&
					current_region_version == previous.region_version &&
					phase2_endpoint_on_recorded_face(current_hit_cascade, current_absolute_cell, current_hit_face, current_endpoint_world) &&
					distance(current_endpoint_world, previous.endpoint_world) <= phase2_endpoint_tolerance(previous.hit_cascade);
			if (!same_endpoint) {
				phase1_stats_add(PHASE2_STAT_REJECT_VISIBILITY, 1u);
				phase1_stats_add(PHASE2_STAT_VISIBILITY_OCCLUDED, 1u);
			} else {
				phase1_stats_add(PHASE2_STAT_VISIBILITY_VISIBLE, 1u);
				float source_geometry = phase2_geometry_term(previous.owner_position, previous.endpoint_world, previous.endpoint_normal_world);
				float current_geometry = phase2_geometry_term(current.owner_position, previous.endpoint_world, previous.endpoint_normal_world);
				if (!phase2_finite(source_geometry) || source_geometry <= 0.0 || !phase2_finite(current_geometry)) {
					phase1_stats_add(PHASE2_STAT_REJECT_JACOBIAN, 1u);
					phase1_stats_add(PHASE2_STAT_SELECTED_FRESH, 1u);
					phase2_finalize(probe_pos, current, true);
					return;
				}
				if (current_geometry <= 0.0) {
					zero_target_mass_only = true;
					phase1_stats_add(PHASE2_STAT_HIT_REUSE, 1u);
				} else {
					jacobian = current_geometry / source_geometry;
					if (!phase2_finite(jacobian) || jacobian <= 0.0) {
						phase1_stats_add(PHASE2_STAT_REJECT_JACOBIAN, 1u);
						phase1_stats_add(PHASE2_STAT_SELECTED_FRESH, 1u);
						phase2_finalize(probe_pos, current, true);
						return;
					}
					if (params.robust_mode != 0u) {
						float clamped_jacobian = clamp(jacobian, 1.0 / params.jacobian_max, params.jacobian_max);
						if (clamped_jacobian != jacobian) {
							jacobian = clamped_jacobian;
							robust_clamped = true;
							phase1_stats_add(PHASE2_STAT_ROBUST_JACOBIAN_CLAMP, 1u);
						}
					}
					current_radiance *= hddagi.energy;
					history_visible = true;
					phase1_stats_add(PHASE2_STAT_HIT_REUSE, 1u);
				}
			}
		} else {
			if (current_hit) {
				phase1_stats_add(PHASE2_STAT_REJECT_VISIBILITY, 1u);
				phase1_stats_add(PHASE2_STAT_VISIBILITY_OCCLUDED, 1u);
			} else {
				history_visible = true;
				phase1_stats_add(PHASE2_STAT_VISIBILITY_VISIBLE, 1u);
				current_radiance = sample_environment(reconnect_direction_view) * hddagi.energy;
				phase1_stats_add(PHASE2_STAT_SKY_REUSE, 1u);
			}
		}
	}
	if (history_visible) {
		if (!phase2_finite3(current_radiance) || any(lessThan(current_radiance, vec3(0.0)))) {
			phase1_stats_add(PHASE2_STAT_NONFINITE, 1u);
			phase1_stats_add(PHASE2_STAT_SELECTED_FRESH, 1u);
			phase2_finalize(probe_pos, current, true);
			return;
		}
		current_target = phase2_target(current_radiance, current.owner_normal_world, reconnect_direction_world);
		zero_target_mass_only = current_target <= 0.0;
	}
	Phase2CompressedStreamMerge merge = phase2_merge_compressed_stream(fresh_mass, current.sample_count, current.target, previous.weight, effective_history_count, current_target, jacobian, history_visible, phase2_random(probe_pos, 0xfffffffdu));
	if (!merge.mass_valid) {
		phase1_stats_add(PHASE2_STAT_NONFINITE, 1u);
		phase1_stats_add(PHASE2_STAT_SELECTED_FRESH, 1u);
		phase2_finalize(probe_pos, current, true);
		return;
	}

	// Once reprojection and endpoint identity are valid, the compressed stream's
	// represented count participates even when current visibility is zero. In
	// that case history_mass remains zero; discarding M would condition on the
	// selected sample's visibility and introduce a bright bias.
	// The public attempt classes remain mutually exclusive: positive-target
	// visible streams are accepted, V=0 streams use the visibility-reject class,
	// and a valid zero-current-target stream uses its explicit mass-only class.
	if (zero_target_mass_only) {
		phase1_stats_add(PHASE2_STAT_ZERO_TARGET_MASS_ONLY, 1u);
	} else {
		phase1_stats_add(PHASE2_STAT_TEMPORAL_ACCEPTED, history_visible ? 1u : 0u);
	}
	uint merged_count = merge.merged_count;
	bool select_history = merge.select_history;
	if (select_history) {
		current.direction_world = reconnect_direction_world;
		current.proposal_pdf = previous.proposal_pdf;
		current.radiance = current_radiance;
		current.target = current_target;
		current.age = previous.age + 1u;
		current.flags = PHASE2_RESERVOIR_VALID | PHASE2_RESERVOIR_SELECTED_HISTORY | (previous_hit ? (PHASE2_RESERVOIR_HIT | PHASE2_RESERVOIR_ENDPOINT_REUSABLE) : PHASE2_RESERVOIR_SKY);
		if (previous_hit) {
			// The endpoint is the sample identity. Preserve the fixed historical
			// point after an exact reconnect instead of accumulating trace drift.
			current.absolute_geometry_cell = previous.absolute_geometry_cell;
			current.hit_cascade = previous.hit_cascade;
			current.hit_face = previous.hit_face;
			current.region_version = previous.region_version;
			current.endpoint_world = previous.endpoint_world;
			current.endpoint_distance = length(previous.endpoint_world - current.owner_position);
			current.endpoint_normal_world = previous.endpoint_normal_world;
		} else {
			current.endpoint_world = vec3(0.0);
			current.endpoint_distance = 0.0;
			current.absolute_geometry_cell = ivec3(0);
			current.hit_cascade = -1;
			current.hit_face = ivec3(0);
			current.region_version = 0u;
			current.endpoint_normal_world = vec3(0.0, 0.0, 1.0);
		}
		phase1_stats_add(PHASE2_STAT_SELECTED_HISTORY, 1u);
	} else {
		current.age = 0u;
		current.flags &= ~PHASE2_RESERVOIR_SELECTED_HISTORY;
		phase1_stats_add(PHASE2_STAT_SELECTED_FRESH, 1u);
	}
	if (robust_clamped) {
		current.flags |= PHASE2_RESERVOIR_ROBUST_CLAMPED;
	} else {
		current.flags &= ~PHASE2_RESERVOIR_ROBUST_CLAMPED;
	}
	current.sample_count = merged_count;
	current.generation = params.history_generation;
	current.algorithm = params.algorithm_version;
	if (merge.output_valid) {
		current.weight = merge.output_weight;
	} else {
		current.flags = 0u;
		current.weight = 0.0;
	}
	phase2_finalize(probe_pos, current, true);
}
#ifdef MODE_PHASE3_SPATIAL

struct Phase3SpatialAccumulator {
	float mass;
	uint represented_count;
	Phase2Reservoir selected;
	bool selected_valid;
	bool selected_neighbor;
};

Phase3SpatialAccumulator phase3_empty_accumulator() {
	Phase3SpatialAccumulator accumulator;
	accumulator.mass = 0.0;
	accumulator.represented_count = 0u;
	accumulator.selected = phase2_empty_reservoir();
	accumulator.selected_valid = false;
	accumulator.selected_neighbor = false;
	return accumulator;
}

bool phase3_basic_reservoir_valid(Phase2Reservoir reservoir) {
	return (reservoir.flags & PHASE2_RESERVOIR_VALID) != 0u &&
			reservoir.generation == params.history_generation &&
			reservoir.algorithm == params.algorithm_version &&
			reservoir.sample_count > 0u && reservoir.target > 0.0 && phase2_finite(reservoir.target) &&
			reservoir.weight > 0.0 && phase2_finite(reservoir.weight) &&
			reservoir.proposal_pdf > 0.0 && phase2_finite(reservoir.proposal_pdf) &&
			phase2_finite3(reservoir.owner_position) &&
			phase2_finite3(reservoir.owner_normal_world) &&
			phase2_finite3(reservoir.direction_world) &&
			phase2_finite3(reservoir.radiance);
}
// The center stream is already evaluated at this receiver. A synthetic
// start-cell hit is therefore a valid current-frame estimate even though Fresh
// deliberately omits ENDPOINT_REUSABLE. Only neighbor/temporal reconnection
// requires a reusable, fully versioned endpoint.
bool phase3_center_candidate_intrinsic_valid(Phase2Reservoir candidate, out bool r_packing_invalid) {
	r_packing_invalid = false;
	bool candidate_hit = (candidate.flags & PHASE2_RESERVOIR_HIT) != 0u;
	bool candidate_sky = (candidate.flags & PHASE2_RESERVOIR_SKY) != 0u;
	bool endpoint_reusable = (candidate.flags & PHASE2_RESERVOIR_ENDPOINT_REUSABLE) != 0u;
	if (candidate_hit == candidate_sky || (candidate_sky && endpoint_reusable)) {
		r_packing_invalid = true;
		return false;
	}
	if (candidate_hit && endpoint_reusable && !phase2_hit_encoding_valid(candidate)) {
		r_packing_invalid = true;
		return false;
	}
	if (candidate_hit && endpoint_reusable &&
			(!phase2_hit_payload_valid(candidate) || !phase2_validate_hit_identity(candidate))) {
		return false;
	}
	return true;
}


bool phase3_load_receiver(ivec2 probe_pos, out ivec2 r_screen_pos, out float r_depth, out vec3 r_normal_view, out vec3 r_receiver_view, out vec3 r_receiver_world, out vec3 r_normal_world, out vec3 r_transport_owner, out bool r_dynamic) {
	uvec4 packed_surface = texelFetch(usampler2D(phase2_previous_surface, nearest_sampler), probe_pos, 0);
	if (!phase2_decode_surface(packed_surface, r_screen_pos, r_depth, r_normal_view, r_dynamic)) {
		return false;
	}
	phase2_current_receiver_state(r_screen_pos, r_depth, r_normal_view, r_receiver_view, r_receiver_world, r_normal_world, r_transport_owner);
	return phase2_finite3(r_receiver_view) && phase2_finite3(r_receiver_world) &&
			phase2_finite3(r_normal_world) && phase2_finite3(r_transport_owner);
}

bool phase3_add_stream(inout Phase3SpatialAccumulator accumulator, Phase2Reservoir candidate, uint represented_count, float stream_mass, float random_value, bool neighbor_stream) {
	if (represented_count == 0u || !phase2_finite(stream_mass) || stream_mass < 0.0) {
		phase1_stats_add(PHASE3_STAT_SPATIAL_NONFINITE, 1u);
		return false;
	}
	float merged_mass = accumulator.mass + stream_mass;
	if (!phase2_finite(merged_mass) || merged_mass < accumulator.mass) {
		phase1_stats_add(PHASE3_STAT_SPATIAL_NONFINITE, 1u);
		return false;
	}
	if (represented_count > 0xffffffffu - accumulator.represented_count) {
		phase1_stats_add(PHASE3_STAT_SPATIAL_NONFINITE, 1u);
		return false;
	}
	accumulator.mass = merged_mass;
	accumulator.represented_count += represented_count;
	if (stream_mass > 0.0 && random_value * merged_mass < stream_mass) {
		accumulator.selected = candidate;
		accumulator.selected_valid = true;
		accumulator.selected_neighbor = neighbor_stream;
	}
	return true;
}

uint phase3_capped_count(uint sample_count) {
	uint capped_count = min(sample_count, params.history_m_cap);
	if (capped_count < sample_count) {
		phase1_stats_add(PHASE3_STAT_SPATIAL_M_CAP, 1u);
	}
	return capped_count;
}

bool phase3_source_receiver_matches(Phase2Reservoir source, vec3 source_transport_owner, vec3 source_normal_world) {
	float owner_tolerance = max(params.history_depth_tolerance, 1e-4);
	return distance(source.owner_position, source_transport_owner) <= owner_tolerance &&
			dot(source.owner_normal_world, source_normal_world) >= params.history_normal_threshold;
}

void phase3_spatial_main() {
	ivec2 probe_pos = ivec2(gl_GlobalInvocationID.xy);
	ivec2 atlas_size = imageSize(phase2_current_owner);
	if (any(greaterThanEqual(probe_pos, atlas_size))) {
		return;
	}

	ivec2 center_screen_pos;
	float center_depth;
	vec3 center_normal_view;
	vec3 center_receiver_view;
	vec3 center_receiver_world;
	vec3 center_normal_world;
	vec3 center_transport_owner;
	bool center_dynamic;
	bool center_surface_valid = phase3_load_receiver(probe_pos, center_screen_pos, center_depth, center_normal_view, center_receiver_view, center_receiver_world, center_normal_world, center_transport_owner, center_dynamic);
	Phase3SpatialAccumulator accumulator = phase3_empty_accumulator();
	if (!center_surface_valid) {
		phase2_store_current(probe_pos, phase2_empty_reservoir());
		imageStore(phase2_raw_probe_output, probe_pos, vec4(0.0));
		return;
	}

	Phase2Reservoir center_source = phase2_load_previous(probe_pos);
	bool center_packing_invalid = false;
	if (!phase3_basic_reservoir_valid(center_source) ||
			!phase3_center_candidate_intrinsic_valid(center_source, center_packing_invalid) ||
			!phase3_source_receiver_matches(center_source, center_transport_owner, center_normal_world)) {
		phase1_stats_add(PHASE3_STAT_SPATIAL_IDENTITY_REJECT, 1u);
		if (center_packing_invalid) {
			phase1_stats_add(PHASE2_STAT_PACKING_INVALID, 1u);
		}
		phase2_store_current(probe_pos, phase2_empty_reservoir());
		imageStore(phase2_raw_probe_output, probe_pos, vec4(0.0));
		return;
	}
	Phase2Reservoir center_candidate = center_source;
	center_candidate.owner_position = center_transport_owner;
	center_candidate.owner_normal_world = center_normal_world;
	center_candidate.target = phase2_target(center_candidate.radiance, center_normal_world, center_candidate.direction_world);
	if (!phase2_finite(center_candidate.target) || center_candidate.target <= 0.0) {
		phase1_stats_add(PHASE3_STAT_SPATIAL_NONFINITE, 1u);
		phase2_store_current(probe_pos, phase2_empty_reservoir());
		imageStore(phase2_raw_probe_output, probe_pos, vec4(0.0));
		return;
	}
	uint center_count = center_source.sample_count;
	float center_mass = phase2_compressed_stream_mass(center_candidate.target, center_source.weight, center_count);
	if (!phase3_add_stream(accumulator, center_candidate, center_count, center_mass, phase2_random(probe_pos, 0xffffffe0u), false)) {
		phase2_store_current(probe_pos, phase2_empty_reservoir());
		imageStore(phase2_raw_probe_output, probe_pos, vec4(0.0));
		return;
	}

	int spatial_radius = clamp(int(params.maximum_age), 0, 4);
	ivec2 neighbor_pool[80];
	int neighbor_pool_count = 0;
	for (int y = -4; y <= 4; y++) {
		for (int x = -4; x <= 4; x++) {
			if (abs(x) > spatial_radius || abs(y) > spatial_radius) {
				continue;
			}
			if (x == 0 && y == 0) {
				continue;
			}
			neighbor_pool[neighbor_pool_count++] = ivec2(x, y);
		}
	}
	uint neighbor_count = min(params.candidate_count, uint(neighbor_pool_count));
	uint proposal_trial = hash_uvec3(uvec3(uvec2(probe_pos), params.local_sequence ^ (params.view_index * 0x9e3779b9u)));
	if (!center_dynamic && spatial_radius > 0) {
		for (uint neighbor_index = 0u; neighbor_index < neighbor_count; neighbor_index++) {
			// Uniform square-domain proposal without replacement. Coordinates depend
			// only on probe/frame RNG; OOB taps are rejected, never clamped or wrapped.
			int selection = int(neighbor_index);
			int remaining = neighbor_pool_count - selection;
			float proposal_random = hash_float(uvec3(proposal_trial, neighbor_index, 0x6d2b79f5u));
			int relative_index = min(int(proposal_random * float(remaining)), remaining - 1);
			int swap_index = selection + relative_index;
			ivec2 source_offset = neighbor_pool[swap_index];
			neighbor_pool[swap_index] = neighbor_pool[selection];
			neighbor_pool[selection] = source_offset;
			ivec2 source_pos = probe_pos + source_offset;
			phase1_stats_add(PHASE3_STAT_SPATIAL_STREAMS, 1u);
			if (any(lessThan(source_pos, ivec2(0))) || any(greaterThanEqual(source_pos, atlas_size))) {
				phase1_stats_add(PHASE3_STAT_SPATIAL_EDGE_REJECT, 1u);
				continue;
			}

			ivec2 source_screen_pos;
			float source_depth;
			vec3 source_normal_view;
			vec3 source_receiver_view;
			vec3 source_receiver_world;
			vec3 source_normal_world;
			vec3 source_transport_owner;
			bool source_dynamic;
			if (!phase3_load_receiver(source_pos, source_screen_pos, source_depth, source_normal_view, source_receiver_view, source_receiver_world, source_normal_world, source_transport_owner, source_dynamic) || source_dynamic) {
				phase1_stats_add(PHASE3_STAT_SPATIAL_EDGE_REJECT, 1u);
				continue;
			}

			float receiver_separation = distance(source_receiver_world, center_receiver_world);
			float plane_distance = abs(dot(source_receiver_world - center_receiver_world, center_normal_world));
			float plane_tolerance = max(params.history_depth_tolerance + params.history_blend * receiver_separation, 1e-4);
			if (dot(center_normal_world, source_normal_world) < params.history_normal_threshold || plane_distance > plane_tolerance) {
				phase1_stats_add(PHASE3_STAT_SPATIAL_EDGE_REJECT, 1u);
				continue;
			}

			Phase2Reservoir source = phase2_load_previous(source_pos);
			bool packing_invalid = false;
			if (!phase3_basic_reservoir_valid(source) ||
					!phase2_candidate_intrinsic_valid(source, packing_invalid) ||
					!phase3_source_receiver_matches(source, source_transport_owner, source_normal_world)) {
				phase1_stats_add(PHASE3_STAT_SPATIAL_IDENTITY_REJECT, 1u);
				if (packing_invalid) {
					phase1_stats_add(PHASE2_STAT_PACKING_INVALID, 1u);
				}
				continue;
			}

			uint represented_count = phase3_capped_count(source.sample_count);
			if (represented_count == 0u) {
				continue;
			}

			bool source_hit = (source.flags & PHASE2_RESERVOIR_HIT) != 0u;
			bool source_sky = (source.flags & PHASE2_RESERVOIR_SKY) != 0u;
			vec3 reconnect_vector_world = source_sky ? source.direction_world : source.endpoint_world - center_transport_owner;
			float reconnect_length_squared = dot(reconnect_vector_world, reconnect_vector_world);
			if (!phase2_finite3(reconnect_vector_world) || !phase2_finite(reconnect_length_squared) || reconnect_length_squared <= 1e-12) {
				phase1_stats_add(PHASE3_STAT_SPATIAL_IDENTITY_REJECT, 1u);
				continue;
			}
			vec3 reconnect_direction_world = reconnect_vector_world * inversesqrt(reconnect_length_squared);
			Phase2Reservoir candidate = source;
			candidate.owner_position = center_transport_owner;
			candidate.owner_normal_world = center_normal_world;
			candidate.direction_world = reconnect_direction_world;
			candidate.endpoint_distance = source_hit ? sqrt(reconnect_length_squared) : 0.0;
			candidate.flags |= PHASE2_RESERVOIR_SELECTED_SPATIAL;

			float jacobian = 1.0;
			if (source_hit) {
				float source_geometry = phase2_geometry_term(source_transport_owner, source.endpoint_world, source.endpoint_normal_world);
				float center_geometry = phase2_geometry_term(center_transport_owner, source.endpoint_world, source.endpoint_normal_world);
				if (!phase2_finite(source_geometry) || !phase2_finite(center_geometry)) {
					phase1_stats_add(PHASE3_STAT_SPATIAL_NONFINITE, 1u);
					continue;
				}
				if (source_geometry <= 0.0 || center_geometry <= 0.0) {
					phase1_stats_add(PHASE3_STAT_SPATIAL_IDENTITY_REJECT, 1u);
					continue;
				}
				if (phase2_receiver_is_zero_target(center_normal_world, reconnect_direction_world)) {
					phase1_stats_add(PHASE3_STAT_SPATIAL_ZERO_TARGET, 1u);
					phase3_add_stream(accumulator, candidate, represented_count, 0.0, phase2_random(probe_pos, 0xfffffe00u + neighbor_index), true);
					continue;
				}
				jacobian = center_geometry / source_geometry;
				if (!phase2_finite(jacobian) || jacobian <= 0.0) {
					phase1_stats_add(PHASE3_STAT_SPATIAL_NONFINITE, 1u);
					continue;
				}
				if (params.robust_mode != 0u) {
					float clamped_jacobian = clamp(jacobian, 1.0 / params.jacobian_max, params.jacobian_max);
					if (clamped_jacobian != jacobian) {
						jacobian = clamped_jacobian;
						candidate.flags |= PHASE2_RESERVOIR_ROBUST_CLAMPED;
						phase1_stats_add(PHASE2_STAT_ROBUST_JACOBIAN_CLAMP, 1u);
					}
				}
			} else if (phase2_receiver_is_zero_target(center_normal_world, reconnect_direction_world)) {
				phase1_stats_add(PHASE3_STAT_SPATIAL_ZERO_TARGET, 1u);
				phase3_add_stream(accumulator, candidate, represented_count, 0.0, phase2_random(probe_pos, 0xfffffe00u + neighbor_index), true);
				continue;
			}

			vec3 reconnect_direction_view = normalize(inverse(mat3(scene_data.cam_transform)) * reconnect_direction_world);
			if (!phase2_finite3(reconnect_direction_view)) {
				phase1_stats_add(PHASE3_STAT_SPATIAL_NONFINITE, 1u);
				continue;
			}
			phase1_stats_add(PHASE3_STAT_SPATIAL_VISIBILITY_RAYS, 1u);
			vec3 current_radiance;
			ivec3 current_absolute_cell;
			int current_hit_cascade;
			ivec3 current_hit_face;
			uint current_region_version;
			vec3 current_endpoint_world;
			vec3 current_endpoint_normal_world;
			bool current_hit = trace_hddagi_sample(center_screen_pos, center_depth, center_normal_view, reconnect_direction_view, current_radiance, current_absolute_cell, current_hit_cascade, current_hit_face, current_region_version, current_endpoint_world, current_endpoint_normal_world);
			bool visible;
			if (source_hit) {
				visible = current_hit && current_hit_cascade == source.hit_cascade &&
						all(equal(current_absolute_cell, source.absolute_geometry_cell)) &&
						all(equal(current_hit_face, source.hit_face)) &&
						current_region_version == source.region_version &&
						phase2_endpoint_on_recorded_face(current_hit_cascade, current_absolute_cell, current_hit_face, current_endpoint_world) &&
						distance(current_endpoint_world, source.endpoint_world) <= phase2_endpoint_tolerance(source.hit_cascade);
				current_radiance *= hddagi.energy;
			} else {
				visible = !current_hit;
				current_radiance = visible ? sample_environment(reconnect_direction_view) * hddagi.energy : vec3(0.0);
			}
			if (!visible) {
				phase1_stats_add(PHASE3_STAT_SPATIAL_OCCLUDED, 1u);
				phase3_add_stream(accumulator, candidate, represented_count, 0.0, phase2_random(probe_pos, 0xfffffe00u + neighbor_index), true);
				continue;
			}
			phase1_stats_add(PHASE3_STAT_SPATIAL_VISIBLE, 1u);
			if (!phase2_finite3(current_radiance) || any(lessThan(current_radiance, vec3(0.0)))) {
				phase1_stats_add(PHASE3_STAT_SPATIAL_NONFINITE, 1u);
				continue;
			}
			candidate.radiance = current_radiance;
			candidate.target = phase2_target(current_radiance, center_normal_world, reconnect_direction_world);
			if (!phase2_finite(candidate.target)) {
				phase1_stats_add(PHASE3_STAT_SPATIAL_NONFINITE, 1u);
				continue;
			}
			if (candidate.target <= 0.0) {
				phase1_stats_add(PHASE3_STAT_SPATIAL_ZERO_TARGET, 1u);
				phase3_add_stream(accumulator, candidate, represented_count, 0.0, phase2_random(probe_pos, 0xfffffe00u + neighbor_index), true);
				continue;
			}
			float stream_mass = phase2_compressed_stream_mass(candidate.target * jacobian, source.weight, represented_count);
			if (phase3_add_stream(accumulator, candidate, represented_count, stream_mass, phase2_random(probe_pos, 0xfffffe00u + neighbor_index), true)) {
				phase1_stats_add(PHASE3_STAT_SPATIAL_ACCEPTED, 1u);
			}
		}
	}

	Phase2Reservoir output_reservoir = accumulator.selected_valid ? accumulator.selected : phase2_empty_reservoir();
	vec4 output_value = vec4(0.0);
	if (accumulator.selected_valid && accumulator.represented_count > 0u && accumulator.mass > 0.0 && output_reservoir.target > 0.0) {
		output_reservoir.sample_count = accumulator.represented_count;
		phase2_stats_max(PHASE3_STAT_SPATIAL_MAX_M, output_reservoir.sample_count);
		float normalization = float(accumulator.represented_count) * output_reservoir.target;
		output_reservoir.weight = phase2_finite(normalization) && normalization > 0.0 ? accumulator.mass / normalization : 0.0;
		output_reservoir.generation = params.history_generation;
		output_reservoir.algorithm = params.algorithm_version;
		output_reservoir.owner_position = center_transport_owner;
		output_reservoir.owner_normal_world = center_normal_world;
		if (phase2_finite(output_reservoir.weight) && output_reservoir.weight > 0.0) {
			vec3 contribution = output_reservoir.radiance * (max(dot(center_normal_world, output_reservoir.direction_world), 0.0) / PHASE2_PI);
			vec3 estimate = contribution * output_reservoir.weight;
			if (phase2_finite3(estimate) && all(greaterThanEqual(estimate, vec3(0.0)))) {
				output_value.rgb = estimate;
				if ((output_reservoir.flags & PHASE2_RESERVOIR_HIT) != 0u && phase2_finite(output_reservoir.endpoint_distance)) {
					output_value.a = max(output_reservoir.endpoint_distance, 0.0);
				} else if ((output_reservoir.flags & PHASE2_RESERVOIR_SKY) != 0u) {
					output_value.a = 65504.0;
				}
				phase1_stats_add(accumulator.selected_neighbor ? PHASE3_STAT_SPATIAL_SELECTED_NEIGHBOR : PHASE3_STAT_SPATIAL_SELECTED_CENTER, 1u);
			} else {
				output_reservoir.flags = 0u;
				output_reservoir.weight = 0.0;
				phase1_stats_add(PHASE3_STAT_SPATIAL_NONFINITE, 1u);
			}
		} else {
			output_reservoir.flags = 0u;
			output_reservoir.weight = 0.0;
			phase1_stats_add(PHASE3_STAT_SPATIAL_NONFINITE, 1u);
		}
	}
	phase2_store_current(probe_pos, output_reservoir);
	imageStore(phase2_raw_probe_output, probe_pos, output_value);
}

#endif

#endif

#endif

#ifdef MODE_RESOLVE

bool load_fullres_surface(ivec2 screen_pos, out float r_depth, out vec3 r_normal, out bool r_dynamic, out float r_roughness) {
	r_depth = texelFetch(sampler2D(depth_buffer, nearest_sampler), screen_pos, 0).r;
	if (r_depth <= 0.0) {
		return false;
	}
	vec4 normal_roughness = texelFetch(sampler2D(normal_roughness_buffer, nearest_sampler), screen_pos, 0);
	r_dynamic = normal_roughness.w > 0.5;
	float encoded_roughness = r_dynamic ? 1.0 - normal_roughness.w : normal_roughness.w;
	r_roughness = clamp(encoded_roughness / (127.0 / 255.0), 0.0, 1.0);
	return decode_normal(normal_roughness.xyz, r_normal);
}

bool load_resolve_probe_surface(ivec2 probe_pos, out ivec2 r_screen_pos, out float r_depth, out vec3 r_normal) {
	uvec4 packed = imageLoad(probe_surface_input, probe_pos);
	if (all(equal(packed.xy, uvec2(0xffffffffu)))) {
		return false;
	}
	r_screen_pos = ivec2(packed.xy);
	r_depth = uintBitsToFloat(packed.z);
	r_normal = unpack_surface_normal(packed.w);
	return true;
}

void stats_saturating_add(uint stat_index, uint value) {
	// Keep every access to a concurrently updated counter atomic. A plain SSBO
	// load racing the CAS loop is not a valid atomic-load substitute.
	uint previous = atomicAdd(screen_probe_stats[stat_index], 0u);
	while (true) {
		if (previous > 0xffffffffu - value) {
			uint observed = atomicCompSwap(screen_probe_stats[stat_index], previous, 0xffffffffu);
			if (observed == previous) {
				phase1_stats_add(PHASE1_STAT_RAW_OVERFLOW_OR_NONFINITE, 1u);
				return;
			}
			previous = observed;
			continue;
		}
		uint observed = atomicCompSwap(screen_probe_stats[stat_index], previous, previous + value);
		if (observed == previous) {
			return;
		}
		previous = observed;
	}
}

void record_raw_hdr_sample(ivec2 screen_pos, vec3 radiance) {
	// Raw-HDR validation is diagnostic-only. A rotating 16x16 lattice avoids
	// thousands of contended global CAS operations while covering every pixel
	// phase over a 256-frame cycle and retaining a deterministic spatial sample.
	uvec2 stats_phase = uvec2(params.frame_index & 15u, (params.frame_index >> 4u) & 15u);
	if ((params.flags & PHASE1_FLAG_GPU_STATS) == 0u || params.debug_mode != 0 || any(notEqual((uvec2(screen_pos) - stats_phase) & uvec2(15u), uvec2(0u)))) {
		return;
	}
	if (any(lessThan(radiance, vec3(0.0))) || any(greaterThan(radiance, vec3(64.0))) || any(isnan(radiance)) || any(isinf(radiance))) {
		phase1_stats_add(PHASE1_STAT_RAW_OVERFLOW_OR_NONFINITE, 1u);
	}
	phase1_stats_add(PHASE1_STAT_RAW_SAMPLE_COUNT, 1u);
	uvec3 fixed_radiance = uvec3(round(clamp(radiance, vec3(0.0), vec3(64.0)) * 1024.0));
	stats_saturating_add(PHASE1_STAT_RAW_SUM_R, fixed_radiance.r);
	stats_saturating_add(PHASE1_STAT_RAW_SUM_G, fixed_radiance.g);
	stats_saturating_add(PHASE1_STAT_RAW_SUM_B, fixed_radiance.b);
}

void record_raw_hdr_lattice_phase(ivec2 screen_pos) {
	if ((params.flags & PHASE1_FLAG_GPU_STATS) == 0u || params.debug_mode != 0 || params.view_index != 0u || any(notEqual(screen_pos, ivec2(0)))) {
		return;
	}
	uint phase = params.frame_index & 255u;
	phase1_stats_add(PHASE1_STAT_RAW_ACCUMULATED_FRAMES, 1u);
	atomicOr(screen_probe_stats[PHASE1_STAT_RAW_PHASE_MASK_BASE + (phase >> 5u)], 1u << (phase & 31u));
}

void phase1_resolve_main() {
	ivec2 screen_pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(screen_pos, imageSize(fullres_raw_output)))) {
		return;
	}
	record_raw_hdr_lattice_phase(screen_pos);

	float pixel_depth;
	vec3 pixel_normal;
	bool pixel_dynamic;
	float pixel_roughness;
	if (!load_fullres_surface(screen_pos, pixel_depth, pixel_normal, pixel_dynamic, pixel_roughness)) {
		imageStore(fullres_raw_output, screen_pos, vec4(0.0));
		imageStore(fullres_surface_output, screen_pos, uvec4(0xffffffffu));
		return;
	}
	vec2 pixel_uv = (vec2(screen_pos) + 0.5) / vec2(params.screen_size);
	float pixel_linear_depth = compute_view_pos(vec3(pixel_uv, pixel_depth)).z;
	imageStore(fullres_surface_output, screen_pos, uvec4(floatBitsToUint(pixel_linear_depth), pack_fullres_surface(pixel_normal, pixel_dynamic, pixel_roughness), 0u, 0u));

	ivec2 gi_pos = clamp(screen_pos * params.gi_size / params.screen_size, ivec2(0), params.gi_size - ivec2(1));
	ivec2 probe_base = gi_pos / max(params.probe_size, 1);
	ivec2 probe_count = textureSize(sampler2D(raw_probe_input, nearest_sampler), 0);
	vec2 probe_screen_extent = vec2(params.probe_size) * vec2(params.screen_size) / vec2(params.gi_size);
	float probe_extent = max((probe_screen_extent.x + probe_screen_extent.y) * 0.5, 1.0);
	vec4 radiance_hit_distance_sum = vec4(0.0);
	float weight_sum = 0.0;

	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			ivec2 probe_pos = probe_base + ivec2(x, y);
			if (any(lessThan(probe_pos, ivec2(0))) || any(greaterThanEqual(probe_pos, probe_count))) {
				continue;
			}
			ivec2 probe_screen_pos;
			float probe_depth;
			vec3 probe_normal;
			if (!load_resolve_probe_surface(probe_pos, probe_screen_pos, probe_depth, probe_normal)) {
				continue;
			}
			vec4 raw_radiance = texelFetch(sampler2D(raw_probe_input, nearest_sampler), probe_pos, 0);
			vec2 probe_uv = (vec2(probe_screen_pos) + 0.5) / vec2(params.screen_size);
			float probe_linear_depth = compute_view_pos(vec3(probe_uv, probe_depth)).z;
			float normal_similarity = max(dot(pixel_normal, probe_normal), 0.0);
			float normal_weight = pow(normal_similarity, 6.0);
			float depth_scale = max(0.015, abs(pixel_linear_depth) * mix(0.012, 0.04, smoothstep(0.75, 0.98, normal_similarity)));
			float depth_weight = 1.0 - smoothstep(0.0, depth_scale, abs(pixel_linear_depth - probe_linear_depth));
			float distance_weight = 1.0 / (1.0 + length(vec2(screen_pos - probe_screen_pos)) / probe_extent);
			float weight = normal_weight * depth_weight * distance_weight;
			radiance_hit_distance_sum += max(raw_radiance, vec4(0.0)) * weight;
			weight_sum += weight;
		}
	}

	vec4 resolved = weight_sum > 0.0 ? radiance_hit_distance_sum / weight_sum : vec4(0.0);
	if (any(isnan(resolved)) || any(isinf(resolved))) {
		phase1_stats_add(PHASE1_STAT_RAW_OVERFLOW_OR_NONFINITE, 1u);
		resolved = vec4(0.0);
	} else {
		resolved = max(resolved, vec4(0.0));
#ifndef MODE_PHASE2_RESOLVE
		// Phase 1 is RGBA16F; keep both radiance and RELAX hit distance finite
		// through the conversion instead of relying on implementation saturation.
		resolved = min(resolved, vec4(65504.0));
#endif
	}
	imageStore(fullres_raw_output, screen_pos, resolved);
	if (weight_sum > 0.0) {
		record_raw_hdr_sample(screen_pos, resolved.rgb);
	}
}

#endif


#ifdef MODE_APPLY

void phase1_apply_main() {
	ivec2 gi_pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(gi_pos, imageSize(ambient_output)))) {
		return;
	}
	ivec2 screen_pos = clamp(gi_pos * params.screen_size / params.gi_size, ivec2(0), params.screen_size - ivec2(1));
	vec4 radiance = texelFetch(sampler2D(fullres_radiance_input, nearest_sampler), screen_pos, 0);
	// Alpha is the RELAX raw hit distance, not a validity/confidence channel.
	// Environment misses carry FP16_MAX; zero is reserved for skipped lobes.
	vec3 diffuse_irradiance_over_pi = max(radiance.rgb, vec3(0.0)) * params.output_radiance_scale;
	// Forward+ multiplies this buffer by the current receiver albedo. Do not apply
	// receiver albedo here or the result would be squared.
	imageStore(ambient_output, gi_pos, uvec4(rgbe_encode(diffuse_irradiance_over_pi)));
}

#endif

void main() {
#ifdef MODE_SURFACE
	phase1_surface_main();
#elif defined(MODE_SHARC_UPDATE)
	hddagi_sharc_update_main();
#elif defined(MODE_SHARC_RESOLVE)
	hddagi_sharc_resolve_main();
#elif defined(MODE_TRACE)
	phase1_trace_main();
#elif defined(MODE_PHASE2_FRESH)
	phase2_fresh_main();
#elif defined(MODE_PHASE2_TEMPORAL)
	phase2_temporal_main();
#elif defined(MODE_PHASE3_SPATIAL)
	phase3_spatial_main();
#elif defined(MODE_RESOLVE)
	phase1_resolve_main();
#elif defined(MODE_APPLY)
	phase1_apply_main();
#endif
}
