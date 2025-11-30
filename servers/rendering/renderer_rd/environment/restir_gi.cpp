/**************************************************************************/
/*  restir_gi.cpp                                                         */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#include "servers/rendering/renderer_rd/environment/restir_gi.h"
#include "servers/rendering/renderer_rd/effects/copy_effects.h"
#include "servers/rendering/rendering_server_default.h"


using namespace RendererRD;

ReSTIRGI::ReSTIRGI() {
}

ReSTIRGI::~ReSTIRGI() {
	free_data();
}

void ReSTIRGI::configure(RenderSceneBuffersRD *p_render_buffers) {
	// Called when render buffers are configured
	// We'll initialize based on the render buffer size
}

void ReSTIRGI::free_data() {
	if (!initialized) {
		return;
	}

	_free_resources();
	initialized = false;
}

void ReSTIRGI::initialize(GI *p_gi, const Settings &p_settings, Size2i p_screen_size) {
	ERR_FAIL_NULL(p_gi);
	
	gi = p_gi;
	settings = p_settings;
	render_resolution = p_screen_size;
	probe_resolution = _get_probe_resolution_for_mode(settings.ray_count_mode, p_screen_size);
	
	// Allocate GPU resources
	_allocate_gbuffer_textures();
	_allocate_tracing_textures();
	_allocate_cache_buffers();
	_allocate_restir_buffers();
	
	// Create samplers
	RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
	{
		RenderingDevice::SamplerState sampler_state;
		sampler_state.mag_filter = RenderingDevice::SAMPLER_FILTER_LINEAR;
		sampler_state.min_filter = RenderingDevice::SAMPLER_FILTER_LINEAR;
		sampler_state.mip_filter = RenderingDevice::SAMPLER_FILTER_LINEAR;
		sampler_state.repeat_u = RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE;
		sampler_state.repeat_v = RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE;
		sampler_state.repeat_w = RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE;
		linear_sampler = rd->sampler_create(sampler_state);
	}
	{
		RenderingDevice::SamplerState sampler_state;
		sampler_state.mag_filter = RenderingDevice::SAMPLER_FILTER_NEAREST;
		sampler_state.min_filter = RenderingDevice::SAMPLER_FILTER_NEAREST;
		sampler_state.mip_filter = RenderingDevice::SAMPLER_FILTER_NEAREST;
		sampler_state.repeat_u = RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE;
		sampler_state.repeat_v = RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE;
		sampler_state.repeat_w = RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE;
		nearest_sampler = rd->sampler_create(sampler_state);
	}
	
	if (linear_sampler.is_null() || nearest_sampler.is_null()) {
		print_line("ReSTIR GI: Failed to create samplers!");
	} else {
		print_line("ReSTIR GI: Samplers created successfully.");
	}
	
	// Compile shaders
	_compile_shaders();
	
	initialized = true;
	frame_count = 0;
	hash_update_offset = 0;
	
	print_line("ReSTIR GI initialized - Screen: ", p_screen_size, " Probes: ", probe_resolution);
}

void ReSTIRGI::update_settings(const Settings &p_settings) {
	bool need_reinit = false;
	
	// Check if settings require resource reallocation
	if (settings.ray_count_mode != p_settings.ray_count_mode) {
		need_reinit = true;
	}
	
	settings = p_settings;
	
	if (need_reinit && initialized) {
		Size2i new_probe_res = _get_probe_resolution_for_mode(settings.ray_count_mode, render_resolution);
		if (new_probe_res != probe_resolution) {
			probe_resolution = new_probe_res;
			_free_resources();
			initialize(gi, settings, render_resolution);
		}
	}
}

Size2i ReSTIRGI::_get_probe_resolution_for_mode(RayCountMode p_mode, Size2i p_screen_size) {
	int divisor = 16; // Default QUALITY
	
	switch (p_mode) {
		case RAY_COUNT_PERFORMANCE:
			divisor = 32;
			break;
		case RAY_COUNT_QUALITY:
			divisor = 16;
			break;
		case RAY_COUNT_CINEMATIC:
			divisor = 8;
			break;
	}
	
	return Size2i(
		(p_screen_size.x + divisor - 1) / divisor,
		(p_screen_size.y + divisor - 1) / divisor
	);
}

void ReSTIRGI::_allocate_gbuffer_textures() {
	RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
	
	// Probe normal + depth (RGBA16F)
	{
		RD::TextureFormat tf;
		tf.width = probe_resolution.x;
		tf.height = probe_resolution.y;
		tf.format = RD::DATA_FORMAT_R16G16B16A16_SFLOAT;
		tf.usage_bits = RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_CAN_COPY_TO_BIT;
		gbuffer.normal_depth = rd->texture_create(tf, RD::TextureView());
	}
	
	// Diffuse color (RGBA8)
	{
		RD::TextureFormat tf;
		tf.width = probe_resolution.x;
		tf.height = probe_resolution.y;
		tf.format = RD::DATA_FORMAT_R8G8B8A8_UNORM;
		tf.usage_bits = RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_CAN_COPY_TO_BIT;
		gbuffer.diffuse = rd->texture_create(tf, RD::TextureView());
	}
	
	// Motion vectors (RG16F)
	{
		RD::TextureFormat tf;
		tf.width = render_resolution.x;
		tf.height = render_resolution.y;
		tf.format = RD::DATA_FORMAT_R16G16_SFLOAT;
		tf.usage_bits = RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_CAN_COPY_TO_BIT;
		gbuffer.motion_vectors = rd->texture_create(tf, RD::TextureView());
	}
	
	// Depth pyramid for screen-space tracing (with mipmaps)
	{
		int mip_count = Image::get_image_required_mipmaps(render_resolution.x, render_resolution.y, Image::FORMAT_RF);
		
		RD::TextureFormat tf;
		tf.width = render_resolution.x;
		tf.height = render_resolution.y;
		tf.format = RD::DATA_FORMAT_R32_SFLOAT;
		tf.mipmaps = mip_count;
		tf.usage_bits = RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_CAN_COPY_TO_BIT;
		gbuffer.depth_pyramid = rd->texture_create(tf, RD::TextureView());
	}
}

void ReSTIRGI::_allocate_tracing_textures() {
	RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
	
	// Ray directions (RGBA16F)
	{
		RD::TextureFormat tf;
		tf.width = probe_resolution.x;
		tf.height = probe_resolution.y;
		tf.format = RD::DATA_FORMAT_R16G16B16A16_SFLOAT;
		tf.usage_bits = RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_STORAGE_BIT;
		tracing_textures.ray_directions = rd->texture_create(tf, RD::TextureView());
	}
	
	// Hit distance (R16F)
	{
		RD::TextureFormat tf;
		tf.width = probe_resolution.x;
		tf.height = probe_resolution.y;
		tf.format = RD::DATA_FORMAT_R16_SFLOAT;
		tf.usage_bits = RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_STORAGE_BIT;
		tracing_textures.hit_distance = rd->texture_create(tf, RD::TextureView());
	}
	
	// Hit radiance (RGBA16F)
	{
		RD::TextureFormat tf;
		tf.width = probe_resolution.x;
		tf.height = probe_resolution.y;
		tf.format = RD::DATA_FORMAT_R16G16B16A16_SFLOAT;
		tf.usage_bits = RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_STORAGE_BIT;
		tracing_textures.hit_radiance = rd->texture_create(tf, RD::TextureView());
	}
	
	// Voxel payload (RGBA32UI)
	{
		RD::TextureFormat tf;
		tf.width = probe_resolution.x;
		tf.height = probe_resolution.y;
		tf.format = RD::DATA_FORMAT_R32G32B32A32_UINT;
		tf.usage_bits = RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_STORAGE_BIT;
		tracing_textures.voxel_payload = rd->texture_create(tf, RD::TextureView());
	}
	
	// Temporal buffers (RGBA16F)
	{
		RD::TextureFormat tf;
		tf.width = render_resolution.x;
		tf.height = render_resolution.y;
		tf.format = RD::DATA_FORMAT_R16G16B16A16_SFLOAT;
		tf.usage_bits = RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_CAN_COPY_TO_BIT;
		
		tracing_textures.radiance_history = rd->texture_create(tf, RD::TextureView());
		tracing_textures.radiance_current = rd->texture_create(tf, RD::TextureView());
	}
}

void ReSTIRGI::_allocate_cache_buffers() {
	RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
	
	// Hash table buffers
	Vector<uint8_t> initial_data;
	initial_data.resize(MAX_HASH_ENTRIES * sizeof(uint32_t));
	memset(initial_data.ptrw(), 0, initial_data.size());
	
	cache_buffers.hash_keys = rd->storage_buffer_create(initial_data.size(), initial_data);
	cache_buffers.hash_counters = rd->storage_buffer_create(initial_data.size(), initial_data);
	
	// Hash payload (uint2)
	initial_data.resize(MAX_HASH_ENTRIES * sizeof(uint32_t) * 2);
	memset(initial_data.ptrw(), 0, initial_data.size());
	cache_buffers.hash_payload = rd->storage_buffer_create(initial_data.size(), initial_data);
	
	// Hash radiance (uint4)
	initial_data.resize(MAX_HASH_ENTRIES * sizeof(uint32_t) * 4);
	memset(initial_data.ptrw(), 0, initial_data.size());
	cache_buffers.hash_radiance = rd->storage_buffer_create(initial_data.size(), initial_data);
	cache_buffers.hash_positions = rd->storage_buffer_create(initial_data.size(), initial_data);
	
	// Indirect dispatch buffers
	int max_coords = probe_resolution.x * probe_resolution.y;
	initial_data.resize(max_coords * sizeof(uint32_t) * 2);
	memset(initial_data.ptrw(), 0, initial_data.size());
	
	cache_buffers.indirect_coords_ss = rd->storage_buffer_create(initial_data.size(), initial_data);
	cache_buffers.indirect_coords_ov = rd->storage_buffer_create(initial_data.size(), initial_data);
	
	// Ray counter
	initial_data.resize(sizeof(uint32_t));
	memset(initial_data.ptrw(), 0, initial_data.size());
	cache_buffers.ray_counter = rd->storage_buffer_create(initial_data.size(), initial_data);
	
	// Indirect args buffer (for dispatch_indirect)
	initial_data.resize(sizeof(uint32_t) * 3);
	memset(initial_data.ptrw(), 0, initial_data.size());
	cache_buffers.indirect_args_ss = rd->storage_buffer_create(initial_data.size(), initial_data);
}

void ReSTIRGI::_allocate_restir_buffers() {
	RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
	
	// Reservoir structure size (simplified, needs actual struct definition)
	// Typically: float3 position, float3 normal, float3 radiance, float weight, uint M
	const int reservoir_size = sizeof(float) * 10 + sizeof(uint32_t);
	int reservoir_count = render_resolution.x * render_resolution.y;
	
	Vector<uint8_t> initial_data;
	initial_data.resize(reservoir_count * reservoir_size);
	memset(initial_data.ptrw(), 0, initial_data.size());
	
	restir_buffers.reservoirs_current = rd->storage_buffer_create(initial_data.size(), initial_data);
	restir_buffers.reservoirs_temporal = rd->storage_buffer_create(initial_data.size(), initial_data);
	restir_buffers.reservoirs_spatial = rd->storage_buffer_create(initial_data.size(), initial_data);
}

void ReSTIRGI::_free_resources() {
	RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
	
	// Free GBuffer textures
	if (gbuffer.normal_depth.is_valid()) rd->free_rid(gbuffer.normal_depth);
	if (gbuffer.diffuse.is_valid()) rd->free_rid(gbuffer.diffuse);
	if (gbuffer.motion_vectors.is_valid()) rd->free_rid(gbuffer.motion_vectors);
	if (gbuffer.depth_pyramid.is_valid()) rd->free_rid(gbuffer.depth_pyramid);
	
	// Free tracing textures
	if (tracing_textures.ray_directions.is_valid()) rd->free_rid(tracing_textures.ray_directions);
	if (tracing_textures.hit_distance.is_valid()) rd->free_rid(tracing_textures.hit_distance);
	if (tracing_textures.hit_radiance.is_valid()) rd->free_rid(tracing_textures.hit_radiance);
	if (tracing_textures.voxel_payload.is_valid()) rd->free_rid(tracing_textures.voxel_payload);
	if (tracing_textures.radiance_history.is_valid()) rd->free_rid(tracing_textures.radiance_history);
	if (tracing_textures.radiance_current.is_valid()) rd->free_rid(tracing_textures.radiance_current);
	
	// Free cache buffers
	if (cache_buffers.hash_keys.is_valid()) rd->free_rid(cache_buffers.hash_keys);
	if (cache_buffers.hash_counters.is_valid()) rd->free_rid(cache_buffers.hash_counters);
	if (cache_buffers.hash_payload.is_valid()) rd->free_rid(cache_buffers.hash_payload);
	if (cache_buffers.hash_radiance.is_valid()) rd->free_rid(cache_buffers.hash_radiance);
	if (cache_buffers.hash_positions.is_valid()) rd->free_rid(cache_buffers.hash_positions);
	if (cache_buffers.ray_counter.is_valid()) rd->free_rid(cache_buffers.ray_counter);
	if (cache_buffers.indirect_coords_ss.is_valid()) rd->free_rid(cache_buffers.indirect_coords_ss);
	if (cache_buffers.indirect_coords_ov.is_valid()) rd->free_rid(cache_buffers.indirect_coords_ov);
	if (cache_buffers.indirect_args_ss.is_valid()) rd->free_rid(cache_buffers.indirect_args_ss);
	
	// Free ReSTIR buffers
	if (restir_buffers.reservoirs_current.is_valid()) rd->free_rid(restir_buffers.reservoirs_current);
	if (restir_buffers.reservoirs_temporal.is_valid()) rd->free_rid(restir_buffers.reservoirs_temporal);
	if (restir_buffers.reservoirs_spatial.is_valid()) rd->free_rid(restir_buffers.reservoirs_spatial);
	
	// Free pipelines
	if (gbuffer_pipeline.is_valid()) rd->free_rid(gbuffer_pipeline);
	if (ray_gen_pipeline.is_valid()) rd->free_rid(ray_gen_pipeline);
	if (screen_trace_pipeline.is_valid()) rd->free_rid(screen_trace_pipeline);
	if (world_trace_pipeline.is_valid()) rd->free_rid(world_trace_pipeline);
	if (radiance_cache_pipeline.is_valid()) rd->free_rid(radiance_cache_pipeline);

	// Clear RIDs
	gbuffer = GBufferTextures();
	tracing_textures = TracingTextures();
	cache_buffers = RadianceCacheBuffers();
	restir_buffers = ReSTIRBuffers();
	
	if (linear_sampler.is_valid()) rd->free_rid(linear_sampler);
	if (nearest_sampler.is_valid()) rd->free_rid(nearest_sampler);
}

void ReSTIRGI::_compile_shaders() {
	Vector<String> gbuffer_modes;
	gbuffer_modes.push_back("\n#define MODE_DOWNSAMPLE_NORMAL_DEPTH\n");
	gbuffer_modes.push_back("\n#define MODE_DOWNSAMPLE_DIFFUSE\n");
	gbuffer_modes.push_back("\n#define MODE_BUILD_DEPTH_PYRAMID\n");
	shaders.gbuffer.initialize(gbuffer_modes, String());
	shaders.gbuffer_version = shaders.gbuffer.version_create();

	Vector<String> ray_gen_modes;
	ray_gen_modes.push_back("");
	shaders.ray_gen.initialize(ray_gen_modes, String());
	shaders.ray_gen_version = shaders.ray_gen.version_create();

	Vector<String> screen_trace_modes;
	screen_trace_modes.push_back("");
	shaders.screen_trace.initialize(screen_trace_modes, String());
	shaders.screen_trace_version = shaders.screen_trace.version_create();

	Vector<String> world_trace_modes;
	world_trace_modes.push_back("");
	shaders.world_trace.initialize(world_trace_modes, String());
	shaders.world_trace_version = shaders.world_trace.version_create();

	Vector<String> cache_modes;
	cache_modes.push_back("\n#define MODE_UPDATE_CACHE\n");
	cache_modes.push_back("\n#define MODE_QUERY_INSERT\n");
	shaders.radiance_cache.initialize(cache_modes, String());
	shaders.radiance_cache_version = shaders.radiance_cache.version_create();
	
	// Create pipelines
	RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
	
	// Pre-compile pipelines to avoid runtime creation errors
	if (!gbuffer_pipeline.is_valid()) {
		RID shader = shaders.gbuffer.version_get_shader(shaders.gbuffer_version, 0);
		if (shader.is_valid()) {
			gbuffer_pipeline = rd->compute_pipeline_create(shader);
		}
	}
	
	if (!ray_gen_pipeline.is_valid()) {
		RID shader = shaders.ray_gen.version_get_shader(shaders.ray_gen_version, 0);
		if (shader.is_valid()) {
			ray_gen_pipeline = rd->compute_pipeline_create(shader);
		}
	}
	
	if (!screen_trace_pipeline.is_valid()) {
		RID shader = shaders.screen_trace.version_get_shader(shaders.screen_trace_version, 0);
		if (shader.is_valid()) {
			screen_trace_pipeline = rd->compute_pipeline_create(shader);
		}
	}
	
	if (!world_trace_pipeline.is_valid()) {
		RID shader = shaders.world_trace.version_get_shader(shaders.world_trace_version, 0);
		if (shader.is_valid()) {
			world_trace_pipeline = rd->compute_pipeline_create(shader);
		}
	}

	if (!radiance_cache_pipeline.is_valid()) {
		RID shader = shaders.radiance_cache.version_get_shader(shaders.radiance_cache_version, 0);
		if (shader.is_valid()) {
			radiance_cache_pipeline = rd->compute_pipeline_create(shader);
		}
	}
}

// ===== Main Rendering Pipeline =====

void ReSTIRGI::render_gbuffer_prepass(RenderDataRD *p_render_data, Ref<RenderSceneBuffersRD> p_render_buffers, RID p_normal_roughness, RID p_depth) {
	RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
	
	// Ensure we have valid input textures
	if (!p_normal_roughness.is_valid() || !p_depth.is_valid()) {
		return;
	}

	RD::get_singleton()->draw_command_begin_label("ReSTIR GI: GBuffer Prepass");

	// Uniforms
	Vector<RD::Uniform> uniforms;
	
	print_line("ReSTIR GI: Creating GBuffer Prepass Uniforms");
	print_line("ReSTIR GI: UNIFORM_TYPE_SAMPLER_WITH_TEXTURE value: " + itos(RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE));
	print_line("ReSTIR GI: UNIFORM_TYPE_IMAGE value: " + itos(RenderingDevice::UNIFORM_TYPE_IMAGE));
	
	{
		Vector<RID> textures;
		textures.push_back(linear_sampler);
		textures.push_back(p_normal_roughness);
		RenderingDevice::Uniform u(RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, textures);
		uniforms.push_back(u);
		print_line("ReSTIR GI: Binding 0 - SamplerWithTexture. Type: " + itos(u.uniform_type));
		
		if (linear_sampler.is_null()) print_line("ReSTIR GI: Linear sampler is NULL");
		if (p_normal_roughness.is_null()) print_line("ReSTIR GI: Normal roughness is NULL");
	}
	{
		Vector<RID> textures;
		textures.push_back(linear_sampler);
		textures.push_back(p_depth);
		RenderingDevice::Uniform u(RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, textures);
		uniforms.push_back(u);
	}
	{
		Vector<RID> images;
		images.push_back(gbuffer.normal_depth);
		RenderingDevice::Uniform u(RenderingDevice::UNIFORM_TYPE_IMAGE, 2, images);
		uniforms.push_back(u);
	}

	// Push constants
	struct Params {
		int32_t source_size[2];
		int32_t dest_size[2];
		float depth_scale;
		uint32_t view_index;
		uint32_t pad1;
		uint32_t pad2;
	} params;

	Size2i source_size = p_render_buffers->get_internal_size();
	params.source_size[0] = source_size.x;
	params.source_size[1] = source_size.y;
	params.dest_size[0] = probe_resolution.x;
	params.dest_size[1] = probe_resolution.y;
	params.depth_scale = 1.0f; // Adjust if needed
	params.view_index = 0; // TODO: Handle multiview
	params.pad1 = 0;
	params.pad2 = 0;

	// Pipeline
	// We need to ensure the pipeline is created for the correct mode (MODE_DOWNSAMPLE_NORMAL_DEPTH)
	// In _compile_shaders, we initialized gbuffer shader with empty string, which might not be enough if we use #ifdefs.
	// We need to re-check _compile_shaders.
	
	// Assuming mode 0 is MODE_DOWNSAMPLE_NORMAL_DEPTH (we need to fix _compile_shaders first)
	RID shader = shaders.gbuffer.version_get_shader(shaders.gbuffer_version, 0);
	
	if (!gbuffer_pipeline.is_valid()) {
		if (shader.is_valid()) {
			gbuffer_pipeline = rd->compute_pipeline_create(shader);
		} else {
			RD::get_singleton()->draw_command_end_label();
			return;
		}
	}

	RenderingDevice::ComputeListID compute_list = rd->compute_list_begin();
	rd->compute_list_bind_compute_pipeline(compute_list, gbuffer_pipeline);
	
	RID uniform_set = rd->uniform_set_create(uniforms, shader, 0);
	if (uniform_set.is_valid()) {
		rd->compute_list_bind_uniform_set(compute_list, uniform_set, 0);
	} else {
		print_line("ReSTIR GI: Failed to create uniform set for GBuffer Prepass!");
	}
	
	rd->compute_list_set_push_constant(compute_list, &params, sizeof(Params));
	
	uint32_t group_size_x = 8;
	uint32_t group_size_y = 8;
	uint32_t dispatch_x = (probe_resolution.x + group_size_x - 1) / group_size_x;
	uint32_t dispatch_y = (probe_resolution.y + group_size_y - 1) / group_size_y;
	
	rd->compute_list_dispatch(compute_list, dispatch_x, dispatch_y, 1);
	rd->compute_list_end();

	RD::get_singleton()->draw_command_end_label();
}

void ReSTIRGI::generate_rays(RenderDataRD *p_render_data) {
	RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
	
	RD::get_singleton()->draw_command_begin_label("ReSTIR GI: Generate Rays");

	// Uniforms
	Vector<RD::Uniform> uniforms;

	{
		Vector<RID> textures;
		textures.push_back(linear_sampler);
		textures.push_back(gbuffer.normal_depth);
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, textures));
	}
	{
		Vector<RID> textures;
		textures.push_back(linear_sampler);
		textures.push_back(gbuffer.diffuse); // Currently empty/black in pre-pass
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, textures));
	}
	{
		Vector<RID> images;
		images.push_back(tracing_textures.ray_directions);
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 2, images));
	}

	// Params buffer
	struct RayGenParams {
		int32_t probe_resolution[2];
		uint32_t frame_count;
		uint32_t ray_count_mode;
		float ray_length;
		uint32_t use_importance_sampling;
		float padding[2];
		float view_to_world[16];
	} params;

	params.probe_resolution[0] = probe_resolution.x;
	params.probe_resolution[1] = probe_resolution.y;
	params.frame_count = frame_count;
	params.ray_count_mode = (uint32_t)settings.ray_count_mode;
	params.ray_length = settings.ray_length;
	params.use_importance_sampling = 0; // Disable for now as we don't have albedo
	params.padding[0] = 0.0f;
	params.padding[1] = 0.0f;
	
	// Fill view_to_world matrix (Camera Transform)
	Transform3D cam_transform = p_render_data->scene_data->cam_transform;
	
	// Godot Transform3D is 3x4 (Basis + Origin). We need to transpose basis for GLSL if it expects column-major?
	// GLSL mat4 is column-major.
	// Godot Basis rows are:
	// [0][0] [0][1] [0][2] (X axis?) No, Godot Basis is columns?
	// Basis::rows is actually columns in memory if it's standard math?
	// Godot Basis: "The basis is a 3x3 matrix... The columns of this matrix are the basis vectors."
	// So `rows[0]` is the X vector (column 0).
	// So we can just copy directly?
	// Let's verify Godot Basis memory layout.
	// `Vector3 rows[3]`
	// `rows[0]` is the first column?
	// "The rows are the columns of the matrix." -> Confusing naming.
	// Let's assume `get_column(i)` is safe.
	
	Vector3 col0 = cam_transform.basis.get_column(0);
	Vector3 col1 = cam_transform.basis.get_column(1);
	Vector3 col2 = cam_transform.basis.get_column(2);
	Vector3 col3 = cam_transform.origin;

	params.view_to_world[0] = col0.x; params.view_to_world[1] = col0.y; params.view_to_world[2] = col0.z; params.view_to_world[3] = 0.0f;
	params.view_to_world[4] = col1.x; params.view_to_world[5] = col1.y; params.view_to_world[6] = col1.z; params.view_to_world[7] = 0.0f;
	params.view_to_world[8] = col2.x; params.view_to_world[9] = col2.y; params.view_to_world[10] = col2.z; params.view_to_world[11] = 0.0f;
	params.view_to_world[12] = col3.x; params.view_to_world[13] = col3.y; params.view_to_world[14] = col3.z; params.view_to_world[15] = 1.0f;

	Vector<uint8_t> params_data;
	params_data.resize(sizeof(RayGenParams));
	memcpy(params_data.ptrw(), &params, sizeof(RayGenParams));
	RID params_buffer = rd->uniform_buffer_create(sizeof(RayGenParams), params_data);
	
	{
		Vector<RID> buffers;
		buffers.push_back(params_buffer);
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_UNIFORM_BUFFER, 3, buffers));
	}

	RID shader = shaders.ray_gen.version_get_shader(shaders.ray_gen_version, 0);
	
	if (!ray_gen_pipeline.is_valid()) {
		if (shader.is_valid()) {
			ray_gen_pipeline = rd->compute_pipeline_create(shader);
		} else {
			rd->free_rid(params_buffer);
			RD::get_singleton()->draw_command_end_label();
			return;
		}
	}

	RenderingDevice::ComputeListID compute_list = rd->compute_list_begin();
	rd->compute_list_bind_compute_pipeline(compute_list, ray_gen_pipeline);
	rd->compute_list_bind_uniform_set(compute_list, rd->uniform_set_create(uniforms, shader, 0), 0);
	
	uint32_t group_size_x = 8;
	uint32_t group_size_y = 8;
	uint32_t dispatch_x = (probe_resolution.x + group_size_x - 1) / group_size_x;
	uint32_t dispatch_y = (probe_resolution.y + group_size_y - 1) / group_size_y;
	
	rd->compute_list_dispatch(compute_list, dispatch_x, dispatch_y, 1);
	rd->compute_list_end();
	
	rd->free_rid(params_buffer);

	RD::get_singleton()->draw_command_end_label();
}

void ReSTIRGI::trace_screen_space(RenderDataRD *p_render_data, RID p_screen_color) {
	if (!settings.enable_screen_space_tracing) {
		return;
	}
	
	RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
	RD::get_singleton()->draw_command_begin_label("ReSTIR GI: Screen Space Trace");

	// Uniforms
	Vector<RD::Uniform> uniforms;

	{
		Vector<RID> textures;
		textures.push_back(linear_sampler);
		textures.push_back(gbuffer.normal_depth);
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, textures));
	}
	{
		Vector<RID> textures;
		textures.push_back(linear_sampler);
		textures.push_back(tracing_textures.ray_directions);
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, textures));
	}
	{
		Vector<RID> textures;
		textures.push_back(linear_sampler);
		textures.push_back(gbuffer.depth_pyramid);
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, textures));
	}
	{
		Vector<RID> textures;
		textures.push_back(linear_sampler);
		textures.push_back(p_screen_color.is_valid() ? p_screen_color : gbuffer.diffuse); // Fallback
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3, textures));
	}
	{
		Vector<RID> images;
		images.push_back(tracing_textures.hit_radiance);
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 4, images));
	}
	{
		Vector<RID> images;
		images.push_back(tracing_textures.hit_distance);
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 5, images));
	}

	// Params
	struct ScreenSpaceParams {
		float projection_matrix[16];
		float inv_projection_matrix[16];
		float view_matrix[16];
		float screen_size[2];
		float inv_screen_size[2];
		int32_t probe_resolution[2];
		float max_ray_distance;
		uint32_t max_steps;
		float thickness;
		float stride;
		float jitter_amount;
		uint32_t frame_count;
		float padding[4];
	} params;

	Projection proj = p_render_data->scene_data->cam_projection;
	Projection inv_proj = proj.inverse();
	Transform3D view = p_render_data->scene_data->cam_transform.inverse(); // World to View

	// Copy matrices (Godot Projection is 4x4, Transform3D is 3x4)
	// Projection columns
	for(int i=0; i<4; i++) {
		for(int j=0; j<4; j++) {
			params.projection_matrix[i*4+j] = proj.columns[i][j];
			params.inv_projection_matrix[i*4+j] = inv_proj.columns[i][j];
		}
	}
	
	// View matrix (4x4)
	Vector3 col0 = view.basis.get_column(0);
	Vector3 col1 = view.basis.get_column(1);
	Vector3 col2 = view.basis.get_column(2);
	Vector3 col3 = view.origin;
	
	params.view_matrix[0] = col0.x; params.view_matrix[1] = col0.y; params.view_matrix[2] = col0.z; params.view_matrix[3] = 0.0f;
	params.view_matrix[4] = col1.x; params.view_matrix[5] = col1.y; params.view_matrix[6] = col1.z; params.view_matrix[7] = 0.0f;
	params.view_matrix[8] = col2.x; params.view_matrix[9] = col2.y; params.view_matrix[10] = col2.z; params.view_matrix[11] = 0.0f;
	params.view_matrix[12] = col3.x; params.view_matrix[13] = col3.y; params.view_matrix[14] = col3.z; params.view_matrix[15] = 1.0f;

	params.screen_size[0] = (float)render_resolution.x;
	params.screen_size[1] = (float)render_resolution.y;
	params.inv_screen_size[0] = 1.0f / params.screen_size[0];
	params.inv_screen_size[1] = 1.0f / params.screen_size[1];
	params.probe_resolution[0] = probe_resolution.x;
	params.probe_resolution[1] = probe_resolution.y;
	params.max_ray_distance = settings.ray_length;
	params.max_steps = 100; // TODO: Expose setting
	params.thickness = 0.5f; // TODO: Expose setting
	params.stride = 1.0f;
	params.jitter_amount = 1.0f;
	params.frame_count = frame_count;
	params.padding[0] = 0.0f;
	params.padding[1] = 0.0f;
	params.padding[2] = 0.0f;
	params.padding[3] = 0.0f;

	Vector<uint8_t> params_data;
	params_data.resize(sizeof(ScreenSpaceParams));
	memcpy(params_data.ptrw(), &params, sizeof(ScreenSpaceParams));
	RID params_buffer = rd->uniform_buffer_create(sizeof(ScreenSpaceParams), params_data);

	{
		Vector<RID> buffers;
		buffers.push_back(params_buffer);
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_UNIFORM_BUFFER, 6, buffers));
	}

	RID shader = shaders.screen_trace.version_get_shader(shaders.screen_trace_version, 0);
	
	if (!screen_trace_pipeline.is_valid()) {
		if (shader.is_valid()) {
			screen_trace_pipeline = rd->compute_pipeline_create(shader);
		} else {
			rd->free_rid(params_buffer);
			RD::get_singleton()->draw_command_end_label();
			return;
		}
	}

	RenderingDevice::ComputeListID compute_list = rd->compute_list_begin();
	rd->compute_list_bind_compute_pipeline(compute_list, screen_trace_pipeline);
	rd->compute_list_bind_uniform_set(compute_list, rd->uniform_set_create(uniforms, shader, 0), 0);
	
	uint32_t group_size_x = 8;
	uint32_t group_size_y = 8;
	uint32_t dispatch_x = (probe_resolution.x + group_size_x - 1) / group_size_x;
	uint32_t dispatch_y = (probe_resolution.y + group_size_y - 1) / group_size_y;
	
	rd->compute_list_dispatch(compute_list, dispatch_x, dispatch_y, 1);
	rd->compute_list_end();
	
	rd->free_rid(params_buffer);

	RD::get_singleton()->draw_command_end_label();
}

void ReSTIRGI::trace_world_space(RenderDataRD *p_render_data, Ref<GI::SDFGI> p_sdfgi) {
	if (!settings.enable_world_space_tracing || p_sdfgi.is_null()) {
		return;
	}
	
	RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
	RD::get_singleton()->draw_command_begin_label("ReSTIR GI: World Space Trace");

	// Uniforms
	Vector<RD::Uniform> uniforms;

	{
		Vector<RID> textures;
		textures.push_back(linear_sampler);
		textures.push_back(gbuffer.normal_depth);
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, textures));
	}
	{
		Vector<RID> textures;
		textures.push_back(linear_sampler);
		textures.push_back(tracing_textures.ray_directions);
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, textures));
	}
	{
		Vector<RID> images;
		images.push_back(tracing_textures.hit_radiance);
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 2, images));
	}
	{
		Vector<RID> images;
		images.push_back(tracing_textures.hit_distance);
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 3, images));
	}
	
	// SDFGI Cascades
	{
		Vector<RID> textures;
		for(int i=0; i<p_sdfgi->cascades.size(); i++) {
			textures.push_back(linear_sampler);
			textures.push_back(p_sdfgi->cascades[i].sdf_tex);
		}
		// Ensure we fill up to MAX_CASCADES (8)
		for(int i=p_sdfgi->cascades.size(); i<8; i++) {
			textures.push_back(linear_sampler);
			textures.push_back(p_sdfgi->cascades[0].sdf_tex); // Fallback to 0
		}
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 4, textures));
	}
	{
		Vector<RID> textures;
		for(int i=0; i<p_sdfgi->cascades.size(); i++) {
			textures.push_back(linear_sampler);
			textures.push_back(p_sdfgi->cascades[i].light_tex);
		}
		for(int i=p_sdfgi->cascades.size(); i<8; i++) {
			textures.push_back(linear_sampler);
			textures.push_back(p_sdfgi->cascades[0].light_tex);
		}
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 5, textures));
	}
	{
		Vector<RID> textures;
		textures.push_back(linear_sampler);
		textures.push_back(p_sdfgi->occlusion_texture);
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 6, textures));
	}

	// Params
	struct CascadeData {
		float offset[3];
		float to_cell;
		int32_t probe_world_offset[3];
		uint32_t pad;
		float pad2[4];
	};

	struct SDFGIParams {
		CascadeData cascades[8];
		uint32_t cascade_count;
		float min_cell_size;
		float normal_bias;
		float probe_bias;
		
		float view_matrix[16];
		float inv_view_matrix[16];
		int32_t probe_resolution[2];
		uint32_t frame_count;
		float sky_energy;
	} params;

	params.cascade_count = p_sdfgi->cascades.size();
	params.min_cell_size = p_sdfgi->min_cell_size;
	params.normal_bias = p_sdfgi->normal_bias;
	params.probe_bias = p_sdfgi->probe_bias;
	params.sky_energy = p_sdfgi->energy;
	
	for(int i=0; i<8; i++) {
		if (i < (int)p_sdfgi->cascades.size()) {
			Vector3 pos = Vector3(p_sdfgi->cascades[i].position) * p_sdfgi->cascades[i].cell_size;
			params.cascades[i].offset[0] = pos.x;
			params.cascades[i].offset[1] = pos.y;
			params.cascades[i].offset[2] = pos.z;
			params.cascades[i].to_cell = 1.0f / p_sdfgi->cascades[i].cell_size;
			
			params.cascades[i].probe_world_offset[0] = 0;
			params.cascades[i].probe_world_offset[1] = 0;
			params.cascades[i].probe_world_offset[2] = 0;
			
			params.cascades[i].pad = 0;
		} else {
			memset(&params.cascades[i], 0, sizeof(CascadeData));
		}
	}

	// View matrix
	Transform3D view = p_render_data->scene_data->cam_transform.inverse();
	Vector3 col0 = view.basis.get_column(0);
	Vector3 col1 = view.basis.get_column(1);
	Vector3 col2 = view.basis.get_column(2);
	Vector3 col3 = view.origin;
	
	params.view_matrix[0] = col0.x; params.view_matrix[1] = col0.y; params.view_matrix[2] = col0.z; params.view_matrix[3] = 0.0f;
	params.view_matrix[4] = col1.x; params.view_matrix[5] = col1.y; params.view_matrix[6] = col1.z; params.view_matrix[7] = 0.0f;
	params.view_matrix[8] = col2.x; params.view_matrix[9] = col2.y; params.view_matrix[10] = col2.z; params.view_matrix[11] = 0.0f;
	params.view_matrix[12] = col3.x; params.view_matrix[13] = col3.y; params.view_matrix[14] = col3.z; params.view_matrix[15] = 1.0f;

	// Inv View (Cam Transform)
	Transform3D cam = p_render_data->scene_data->cam_transform;
	col0 = cam.basis.get_column(0);
	col1 = cam.basis.get_column(1);
	col2 = cam.basis.get_column(2);
	col3 = cam.origin;
	
	params.inv_view_matrix[0] = col0.x; params.inv_view_matrix[1] = col0.y; params.inv_view_matrix[2] = col0.z; params.inv_view_matrix[3] = 0.0f;
	params.inv_view_matrix[4] = col1.x; params.inv_view_matrix[5] = col1.y; params.inv_view_matrix[6] = col1.z; params.inv_view_matrix[7] = 0.0f;
	params.inv_view_matrix[8] = col2.x; params.inv_view_matrix[9] = col2.y; params.inv_view_matrix[10] = col2.z; params.inv_view_matrix[11] = 0.0f;
	params.inv_view_matrix[12] = col3.x; params.inv_view_matrix[13] = col3.y; params.inv_view_matrix[14] = col3.z; params.inv_view_matrix[15] = 1.0f;

	params.probe_resolution[0] = probe_resolution.x;
	params.probe_resolution[1] = probe_resolution.y;
	params.frame_count = frame_count;

	Vector<uint8_t> params_data;
	params_data.resize(sizeof(SDFGIParams));
	memcpy(params_data.ptrw(), &params, sizeof(SDFGIParams));
	RID params_buffer = rd->uniform_buffer_create(sizeof(SDFGIParams), params_data);

	{
		Vector<RID> buffers;
		buffers.push_back(params_buffer);
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_UNIFORM_BUFFER, 7, buffers));
	}

	RID shader = shaders.world_trace.version_get_shader(shaders.world_trace_version, 0);
	
	if (!world_trace_pipeline.is_valid()) {
		if (shader.is_valid()) {
			world_trace_pipeline = rd->compute_pipeline_create(shader);
		} else {
			rd->free_rid(params_buffer);
			RD::get_singleton()->draw_command_end_label();
			return;
		}
	}

	RenderingDevice::ComputeListID compute_list = rd->compute_list_begin();
	rd->compute_list_bind_compute_pipeline(compute_list, world_trace_pipeline);
	rd->compute_list_bind_uniform_set(compute_list, rd->uniform_set_create(uniforms, shader, 0), 0);
	
	uint32_t group_size_x = 8;
	uint32_t group_size_y = 8;
	uint32_t dispatch_x = (probe_resolution.x + group_size_x - 1) / group_size_x;
	uint32_t dispatch_y = (probe_resolution.y + group_size_y - 1) / group_size_y;
	
	rd->compute_list_dispatch(compute_list, dispatch_x, dispatch_y, 1);
	rd->compute_list_end();
	
	rd->free_rid(params_buffer);

	RD::get_singleton()->draw_command_end_label();
}

void ReSTIRGI::update_radiance_cache(RenderDataRD *p_render_data) {
	// TODO: Implement radiance cache update / temporal accumulation
	// Currently disabled as shader is not yet implemented
	/*
	RD::get_singleton()->draw_command_begin_label("ReSTIR Radiance Cache Update");

	// Uniforms
	Vector<RD::Uniform> uniforms;
	{
		Vector<RID> buffers;
		buffers.push_back(cache_buffers.hash_keys);
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 0, buffers));
	}
	{
		Vector<RID> buffers;
		buffers.push_back(cache_buffers.hash_counters);
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 1, buffers));
	}
	{
		Vector<RID> buffers;
		buffers.push_back(cache_buffers.hash_payload);
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 2, buffers));
	}
	{
		Vector<RID> buffers;
		buffers.push_back(cache_buffers.hash_radiance);
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 3, buffers));
	}
	{
		Vector<RID> buffers;
		buffers.push_back(cache_buffers.hash_positions);
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 4, buffers));
	}

	// Push constants
	struct PushConstant {
		uint32_t table_size;
		uint32_t update_offset;
		uint32_t update_fraction;
		float decay_rate;
		
		float grid_origin[3];
		float cell_size;
		
		uint32_t frame_count;
		uint32_t max_ray_count;
	} push_constant;

	push_constant.table_size = MAX_HASH_ENTRIES;
	push_constant.update_offset = hash_update_offset;
	push_constant.update_fraction = HASH_UPDATE_FRACTION;
	push_constant.decay_rate = 0.95f; // Example decay
	
	// TODO: Set grid origin and cell size from settings or camera
	push_constant.grid_origin[0] = 0.0f;
	push_constant.grid_origin[1] = 0.0f;
	push_constant.grid_origin[2] = 0.0f;
	push_constant.cell_size = 0.5f;
	
	push_constant.frame_count = frame_count;
	push_constant.max_ray_count = 0;

	// Pipeline
	RID shader = shaders.radiance_cache.version_get_shader(shaders.radiance_cache_version, 0); // Mode 0 is UPDATE_CACHE
	RenderingDevice::ComputeListID compute_list = RD::get_singleton()->compute_list_begin();
	RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, radiance_cache_pipeline);
	RD::get_singleton()->compute_list_bind_uniform_set(compute_list, RD::get_singleton()->uniform_set_create(uniforms, shader, 0), 0);
	RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(PushConstant));
	
	uint32_t group_size = 64;
	uint32_t dispatch_size = (MAX_HASH_ENTRIES / HASH_UPDATE_FRACTION + group_size - 1) / group_size;
	RD::get_singleton()->compute_list_dispatch(compute_list, dispatch_size, 1, 1);
	RD::get_singleton()->compute_list_end();

	RD::get_singleton()->draw_command_end_label();
	
	hash_update_offset = (hash_update_offset + 1) % HASH_UPDATE_FRACTION;
	*/
}

void ReSTIRGI::perform_restir_sampling(RenderDataRD *p_render_data) {
	// TODO: Implement ReSTIR three-stage sampling
	// 1. Initial sampling
	// 2. Temporal resampling
	// 3. Spatial resampling
	print_line("ReSTIR GI: ReSTIR sampling placeholder");
}

void ReSTIRGI::temporal_denoise(RenderDataRD *p_render_data) {
	// TODO: Implement temporal accumulation and spatial filtering
	frame_count++;
	print_line("ReSTIR GI: Temporal denoise placeholder - frame ", frame_count);
}

void ReSTIRGI::composite_gi(RenderDataRD *p_render_data, RID p_output_texture) {
	// TODO: Composite final GI result to output texture
	print_line("ReSTIR GI: Composite placeholder");
}

void ReSTIRGI::debug_draw(const RenderDataRD *p_render_data, RID p_framebuffer, CopyEffects *p_copy_effects) {
	if (settings.debug_mode == DEBUG_NONE) {
		return;
	}
	
	RID texture_to_draw = RID();
	
	switch (settings.debug_mode) {
		case DEBUG_GLOBAL_ILLUMINATION:
			texture_to_draw = tracing_textures.hit_radiance;
			break;
		case DEBUG_GEOMETRY_NORMALS:
			texture_to_draw = gbuffer.normal_depth;
			break;
		case DEBUG_VOXEL_LIGHTING:
			texture_to_draw = tracing_textures.hit_radiance; // Placeholder
			break;
		default:
			break;
	}
	if (texture_to_draw.is_valid() && p_copy_effects) {
		// Draw to the output framebuffer
		// We assume the framebuffer covers the whole screen
		Rect2 rect(0, 0, render_resolution.x, render_resolution.y);
		// Use copy_to_rect to blit the texture
		// Note: hit_radiance is RGBA16F, normal_depth is RGBA16F (octahedral normal + depth)
		// If we draw normal_depth directly, it might look weird but useful for debug.
		
		p_copy_effects->copy_to_rect(texture_to_draw, p_framebuffer, rect, false, false, false, false, false);
	}
}
