#[compute]

#version 450

#VERSION_DEFINES

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(push_constant, std430) uniform Params {
	ivec2 screen_size;
	uint view_index;
	uint history_valid;

	float denoising_range;
	float radiance_scale;
	vec2 current_jitter_pixels;
	vec2 previous_jitter_pixels;
	uvec2 pad;
}
params;

// This prefix deliberately matches GI::SceneData. The guide conversion runs
// immediately after the screen-probe resolve and reuses the same camera UBO.
struct NrdSceneData {
	mat4 inv_projection[2];
	mat4 cam_transform;
	vec4 eye_offset[2];

	ivec2 scene_screen_size;
	float scene_pad1;
	float scene_pad2;
};

layout(set = 0, binding = 0) uniform texture2D depth_buffer;
layout(set = 0, binding = 1) uniform texture2D normal_roughness_buffer;
layout(set = 0, binding = 2) uniform texture2D velocity_buffer;
layout(set = 0, binding = 3) uniform texture2D previous_viewz_buffer;
layout(set = 0, binding = 4) uniform sampler nearest_sampler;
layout(set = 0, binding = 5, std140) uniform SceneDataBuffer {
	NrdSceneData scene_data;
};

// The external NRD library used by this integration is required to be built
// with NRD_NORMAL_ENCODING=0 (RGBA8_UNORM) and NRD_ROUGHNESS_ENCODING=1
// (linear roughness). NrdContextRD validates that contract at runtime.
layout(rgba8, set = 0, binding = 6) uniform restrict writeonly image2D normal_roughness_output;
layout(r32f, set = 0, binding = 7) uniform restrict writeonly image2D viewz_output;
layout(rgba16f, set = 0, binding = 8) uniform restrict writeonly image2D motion_output;
layout(set = 0, binding = 9) uniform texture2D raw_signal_buffer;
layout(rgba16f, set = 0, binding = 10) uniform restrict writeonly image2D nrd_signal_output;

bool finite_float(float value) {
	return !isnan(value) && !isinf(value);
}

bool finite_vec3(vec3 value) {
	return !any(isnan(value)) && !any(isinf(value));
}

vec3 reconstruct_view_position(vec2 uv, float device_depth) {
	vec4 position = scene_data.inv_projection[params.view_index] * vec4(uv * 2.0 - 1.0, device_depth, 1.0);
	return position.xyz / position.w;
}

float decode_linear_roughness(float packed_roughness) {
	// Forward+ reserves the upper half of UNORM8 to mark dynamic geometry.
	bool dynamic_surface = packed_roughness > 0.5;
	float half_range_roughness = dynamic_surface ? 1.0 - packed_roughness : packed_roughness;
	return clamp(half_range_roughness * (255.0 / 127.0), 0.0, 1.0);
}

vec4 pack_nrd_normal_roughness(vec3 world_normal, float linear_roughness) {
	// Mirrors NRD_FrontEnd_PackNormalAndRoughness for
	// NRD_NORMAL_ENCODING_RGBA8_UNORM. Best-fit normalization makes maximum use
	// of the 8-bit cube while NRD normalizes it again on unpack.
	float maximum_component = max(abs(world_normal.x), max(abs(world_normal.y), abs(world_normal.z)));
	world_normal /= max(maximum_component, 1e-6);
	return vec4(world_normal * 0.5 + 0.5, linear_roughness);
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pixel, params.screen_size))) {
		return;
	}

	vec2 uv = (vec2(pixel) + 0.5) / vec2(params.screen_size);
	float device_depth = texelFetch(sampler2D(depth_buffer, nearest_sampler), pixel, 0).r;
	vec4 packed_normal_roughness = texelFetch(sampler2D(normal_roughness_buffer, nearest_sampler), pixel, 0);
	vec2 velocity = texelFetch(sampler2D(velocity_buffer, nearest_sampler), pixel, 0).xy;
	vec4 raw_signal = texelFetch(sampler2D(raw_signal_buffer, nearest_sampler), pixel, 0);

	// Godot Forward+ uses reversed depth, where zero is the background. NRD
	// requires a finite view-Z outside denoisingRange for sky pixels.
	bool valid_surface = device_depth > 0.0;
	vec3 view_position = valid_surface ? reconstruct_view_position(uv, device_depth) : vec3(0.0, 0.0, -params.denoising_range - 1.0);
	valid_surface = valid_surface && finite_vec3(view_position) && finite_float(view_position.z) && abs(view_position.z) <= params.denoising_range;
	// NRD's validity test is viewZ < denoisingRange, so feed a positive linear
	// distance for Godot's right-handed (-Z forward) camera space.
	float view_z = valid_surface ? abs(view_position.z) : params.denoising_range + 1.0;

	vec3 view_normal = packed_normal_roughness.xyz * 2.0 - 1.0;
	float normal_length_squared = dot(view_normal, view_normal);
	valid_surface = valid_surface && finite_vec3(view_normal) && normal_length_squared > 1e-6;
	view_normal = valid_surface ? view_normal * inversesqrt(max(normal_length_squared, 1e-6)) : vec3(0.0, 0.0, 1.0);
	vec3 world_normal = normalize(mat3(scene_data.cam_transform) * view_normal);
	if (!finite_vec3(world_normal)) {
		world_normal = vec3(0.0, 1.0, 0.0);
	}
	float linear_roughness = valid_surface ? decode_linear_roughness(packed_normal_roughness.w) : 1.0;

	float motion_z = 0.0;
	// XY motion is deliberately jitter-neutral, while previous_viewz_buffer is
	// stored on the previous frame's jittered raster grid. Convert the NRD sample
	// jitter delta from pixels to UV so Z is read at the same reprojected surface.
	vec2 jitter_delta_uv = (params.current_jitter_pixels - params.previous_jitter_pixels) / vec2(params.screen_size);
	vec2 previous_uv = uv + velocity + jitter_delta_uv;
	if (params.history_valid != 0u && valid_surface && all(greaterThanEqual(previous_uv, vec2(0.0))) && all(lessThan(previous_uv, vec2(1.0)))) {
		ivec2 previous_pixel = clamp(ivec2(previous_uv * vec2(params.screen_size)), ivec2(0), params.screen_size - ivec2(1));
		float previous_view_z = texelFetch(sampler2D(previous_viewz_buffer, nearest_sampler), previous_pixel, 0).r;
		if (finite_float(previous_view_z) && abs(previous_view_z) <= params.denoising_range) {
			motion_z = previous_view_z - view_z;
		}
	}
	if (!finite_float(velocity.x) || !finite_float(velocity.y)) {
		velocity = vec2(0.0);
	}
	if (any(isnan(raw_signal)) || any(isinf(raw_signal))) {
		raw_signal = vec4(0.0);
	}
	// RELAX tracks second moments in FP16. Keep RGB in a stable scene-linear
	// range and restore it after denoising; alpha remains an unscaled hit distance.
	raw_signal = clamp(raw_signal, vec4(0.0), vec4(65504.0));
	raw_signal.rgb = min(raw_signal.rgb * params.radiance_scale, vec3(128.0));

	imageStore(normal_roughness_output, pixel, pack_nrd_normal_roughness(world_normal, linear_roughness));
	imageStore(viewz_output, pixel, vec4(view_z, 0.0, 0.0, 0.0));
	imageStore(motion_output, pixel, vec4(velocity, motion_z, 0.0));
	imageStore(nrd_signal_output, pixel, raw_signal);
}
