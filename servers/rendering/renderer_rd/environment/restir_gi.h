/**************************************************************************/
/*  restir_gi.h                                                           */
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

#pragma once

#include "core/templates/local_vector.h"
#include "servers/rendering/renderer_rd/environment/gi.h"
#include "servers/rendering/renderer_rd/shaders/environment/restir_gbuffer.glsl.gen.h"
#include "servers/rendering/renderer_rd/shaders/environment/restir_radiance_cache.glsl.gen.h"
#include "servers/rendering/renderer_rd/shaders/environment/restir_ray_gen.glsl.gen.h"
#include "servers/rendering/renderer_rd/shaders/environment/restir_resolve.glsl.gen.h"
#include "servers/rendering/renderer_rd/shaders/environment/restir_screen_trace.glsl.gen.h"
#include "servers/rendering/renderer_rd/shaders/environment/restir_spatial_resampling.glsl.gen.h"
#include "servers/rendering/renderer_rd/shaders/environment/restir_temporal_resampling.glsl.gen.h"
#include "servers/rendering/renderer_rd/shaders/environment/restir_world_trace.glsl.gen.h"
#include "servers/rendering/renderer_rd/storage_rd/render_buffer_custom_data_rd.h"
#include "servers/rendering/rendering_device.h"

// Forward declarations
class RenderDataRD;
class RenderSceneBuffersRD;

namespace RendererRD {

class CopyEffects;

class ReSTIRGI : public RenderBufferCustomDataRD {
	GDCLASS(ReSTIRGI, RenderBufferCustomDataRD)

public:
	enum {
		MAX_HASH_ENTRIES = 1024000,
		HASH_UPDATE_FRACTION = 10,
		OCTAHEDRAL_SIZE = 4,
		MAX_SHADOWMAP_SIZE = 2048,
	};

	enum RayCountMode {
		RAY_COUNT_PERFORMANCE, // 32x32 pixels per probe
		RAY_COUNT_QUALITY,     // 16x16 pixels per probe (recommended)
		RAY_COUNT_CINEMATIC,   // 8x8 pixels per probe
	};

	enum MultiBounceMode {
		MULTIBOUNCE_OFF,
		MULTIBOUNCE_CACHE,
		MULTIBOUNCE_APV,
	};

	enum DebugMode {
		DEBUG_NONE,
		DEBUG_MAIN_BUFFERS,
		DEBUG_GLOBAL_ILLUMINATION,
		DEBUG_GEOMETRY_NORMALS,
		DEBUG_SHADOWMAP,
		DEBUG_VOXEL_COLOR,
		DEBUG_VOXEL_LIGHTING,
	};

	struct Settings {
		// General settings
		bool enabled = false;
		RayCountMode ray_count_mode = RAY_COUNT_QUALITY;
		MultiBounceMode multibounce_mode = MULTIBOUNCE_CACHE;
		DebugMode debug_mode = DEBUG_GLOBAL_ILLUMINATION; // Enable debug by default for testing

		// Ray tracing settings
		float ray_length = 100.0f;
		bool use_hardware_tracing = false;
		bool enable_screen_space_tracing = true;
		bool enable_world_space_tracing = true;

		// Voxel settings (复用SDFGI或独立)
		bool use_sdfgi_voxels = true;
		int voxel_resolution = 256;
		float voxel_density = 0.5f;
		int voxel_bounds = 40; // meters

		// Lighting settings
		float directional_light_intensity = 1.0f;
		float surface_diffuse_intensity = 1.0f;
		float sky_light_intensity = 1.0f;
		float sky_occlusion_cone = 0.2f;

		// Cache settings
		bool freeze_cache = false;
		float temporal_weight = 0.95f;
		bool adaptive_temporal_weight = true;

		// Performance
	};

	struct GBufferTextures {
		RID normal_depth;      // RG16F for probe, RGB10_A2 for geometry
		RID diffuse;           // RGBA8
		RID motion_vectors;    // RG16F
		RID depth_pyramid;     // R32F with mipmaps for screen-space tracing
	};

	struct TracingTextures {
		RID ray_directions;    // RGBA16F
		RID hit_distance;      // R16F
		RID hit_radiance;      // RGBA16F
		RID voxel_payload;     // RGBA32UI
		
		// Temporal buffers
		RID radiance_history;  // RGBA16F
		RID radiance_current;  // RGBA16F
	};

	struct RadianceCacheBuffers {
		// Hash table for radiance cache
		RID hash_keys;         // Buffer<uint>
		RID hash_counters;     // Buffer<uint>
		RID hash_payload;      // Buffer<uint2>
		RID hash_radiance;     // Buffer<uint4> - packed radiance
		RID hash_positions;    // Buffer<uint4> - packed positions

		// Indirect dispatch
		RID ray_counter;
		RID indirect_coords_ss;
		RID indirect_coords_ov;
		RID indirect_args_ss;
	};

	struct ReSTIRBuffers {
		// Reservoir buffers for ReSTIR sampling
		RID reservoirs_current;   // Buffer<Reservoir>
		RID reservoirs_temporal;  // Buffer<Reservoir>
		RID reservoirs_spatial;   // Buffer<Reservoir>
	};

private:
	GI *gi = nullptr;
	Settings settings;

	bool initialized = false;
	Size2i render_resolution;
	Size2i probe_resolution;
	uint32_t frame_count = 0;
	uint32_t hash_update_offset = 0;

	// Render resources
	GBufferTextures gbuffer;
	TracingTextures tracing_textures;
	RadianceCacheBuffers cache_buffers;
	ReSTIRBuffers restir_buffers;

	// Shader resources
	struct ReSTIRShaders {
		RestirGbufferShaderRD gbuffer;
		RID gbuffer_version;
		RestirRayGenShaderRD ray_gen;
		RID ray_gen_version;
		RestirScreenTraceShaderRD screen_trace;
		RID screen_trace_version;
		RestirWorldTraceShaderRD world_trace;
		RID world_trace_version;
		RestirRadianceCacheShaderRD radiance_cache;
		RID radiance_cache_version;
		RestirTemporalResamplingShaderRD temporal_resampling;
		RID temporal_resampling_version;
		RestirSpatialResamplingShaderRD spatial_resampling;
		RID spatial_resampling_version;
		RestirResolveShaderRD resolve;
		RID resolve_version;
	} shaders;

	// Pipelines
	RID gbuffer_pipeline;
	RID gbuffer_diffuse_pipeline;
	RID ray_gen_pipeline;
	RID screen_trace_pipeline;
	RID world_trace_pipeline;
	RID radiance_cache_pipeline;
	RID temporal_resampling_pipeline;
	RID spatial_resampling_pipeline;
	RID resolve_pipeline;

	// Uniform sets
	RID linear_sampler;
	RID nearest_sampler;

	// Helper methods
	void _allocate_gbuffer_textures();
	void _allocate_tracing_textures();
	void _allocate_cache_buffers();
	void _allocate_restir_buffers();
	void _free_resources();

	void _compile_shaders();
	Size2i _get_probe_resolution_for_mode(RayCountMode p_mode, Size2i p_screen_size);

public:
	ReSTIRGI();
	~ReSTIRGI();

	virtual void configure(RenderSceneBuffersRD *p_render_buffers) override;
	virtual void free_data() override;

	// Initialization
	void initialize(GI *p_gi, const Settings &p_settings, Size2i p_screen_size);
	void update_settings(const Settings &p_settings);

	// Main rendering pipeline
	void render_gbuffer_prepass(RenderDataRD *p_render_data, Ref<RenderSceneBuffersRD> p_render_buffers, RID p_normal_roughness, RID p_depth);
	void generate_rays(RenderDataRD *p_render_data);
	void trace_screen_space(RenderDataRD *p_render_data, RID p_screen_color, Ref<GI::SDFGI> p_sdfgi);
	void trace_world_space(RenderDataRD *p_render_data, Ref<GI::SDFGI> p_sdfgi);
	void update_radiance_cache(RenderDataRD *p_render_data);
	void perform_restir_sampling(RenderDataRD *p_render_data);
	void temporal_denoise(RenderDataRD *p_render_data);
	void composite_gi(RenderDataRD *p_render_data, RID p_render_target, CopyEffects *p_copy_effects);
	void capture_screen_color(RenderDataRD *p_render_data, RID p_source_color);

	// Debug visualization
	void debug_draw(const RenderDataRD *p_render_data, RID p_render_target, CopyEffects *p_copy_effects, RS::ViewportDebugDraw p_debug_draw);

	// Getters
	Settings get_settings() const { return settings; }
	bool is_initialized() const { return initialized; }
	GBufferTextures get_gbuffer_textures() const { return gbuffer; }
	RID get_gi_output() const { return tracing_textures.radiance_current; }
};

} // namespace RendererRD
