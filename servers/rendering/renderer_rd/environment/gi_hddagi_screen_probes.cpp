/**************************************************************************/
/*  gi_hddagi_screen_probes.cpp                                           */
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

#include "gi.h"

#include "core/object/callable_mp.h"
#include "core/templates/hashfuncs.h"
#include "servers/rendering/renderer_rd/renderer_scene_render_rd.h"
#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"
#include "servers/rendering/renderer_rd/storage_rd/render_scene_buffers_rd.h"
#include "servers/rendering/renderer_rd/storage_rd/texture_storage.h"
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"
#include "servers/rendering/rendering_server_globals.h"

using namespace RendererRD;

static constexpr uint32_t SCREEN_PROBE_HISTORY_SEQUENCE_MASK = 0x00ffffffu;
static constexpr uint32_t SCREEN_PROBE_GPU_STATS_FLAG = 128u;
static constexpr uint32_t SCREEN_PROBE_STAT_COUNT = 81u;
static constexpr uint32_t SCREEN_PROBE_STATS_READBACK_INTERVAL = 60u;
// Keep the worst-case 64-frame live set below 50% of the default 2^21-entry
// hash table so linear probing retains collision headroom.
static constexpr uint32_t SCREEN_PROBE_SHARC_UPDATE_BUDGET = 16384u;
static constexpr double SCREEN_PROBE_SHARC_RADIANCE_MAX = 64.0;

void GI::disable_hddagi_screen_probes(Ref<RenderSceneBuffersRD> p_render_buffers) {
	if (p_render_buffers.is_null()) {
		return;
	}

	Ref<HDDAGI> hddagi;
	if (p_render_buffers->has_custom_data(RB_SCOPE_HDDAGI)) {
		hddagi = p_render_buffers->get_custom_data(RB_SCOPE_HDDAGI);
	}
	Ref<RenderBuffersGI> rbgi;
	if (p_render_buffers->has_custom_data(RB_SCOPE_GI)) {
		rbgi = p_render_buffers->get_custom_data(RB_SCOPE_GI);
	}
	// SDK state is independent of the legacy HDDAGI history flags below, so
	// release it before any early return.
	if (rbgi.is_valid()) {
		rbgi->nrd_context.clear();
		rbgi->sharc_context.clear();
		if (rbgi->sharc_parameters_ubo.is_valid()) {
			RD::get_singleton()->free_rid(rbgi->sharc_parameters_ubo);
			rbgi->sharc_parameters_ubo = RID();
		}
	}
	const bool has_screen_textures = p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_RADIANCE) || p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES_DEBUG, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE1_DEBUG);
	if (hddagi.is_null()) {
		if (has_screen_textures) {
			p_render_buffers->clear_context(RB_SCOPE_HDDAGI_SCREEN_PROBES);
			p_render_buffers->clear_context(RB_SCOPE_HDDAGI_SCREEN_PROBES_DEBUG);
		}
		return;
	}

	const bool has_owned_buffers = hddagi->screen_probe_stats_buffer.is_valid();
	if (!has_screen_textures && !has_owned_buffers && !hddagi->screen_probe_history_initialized && !hddagi->screen_probe_previous_camera_valid && !hddagi->screen_probe_scheduler_feedback_active) {
		return;
	}

	p_render_buffers->clear_context(RB_SCOPE_HDDAGI_SCREEN_PROBES);
	p_render_buffers->clear_context(RB_SCOPE_HDDAGI_SCREEN_PROBES_DEBUG);
	auto free_buffer = [](RID &p_buffer) {
		if (p_buffer.is_valid()) {
			RD::get_singleton()->free_rid(p_buffer);
			p_buffer = RID();
		}
	};
	free_buffer(hddagi->screen_probe_stats_buffer);

	// Legacy query feedback must not keep changing the fixed HDDAGI scheduler
	// after the producer is disabled.
	if (!hddagi->cascades.is_empty()) {
		const uint32_t cascade_count = hddagi->cascades.size();
		if (hddagi->lightprobe_screen_probe_feedback.is_valid()) {
			RD::get_singleton()->texture_clear(hddagi->lightprobe_screen_probe_feedback, Color(0, 0, 0, 0), 0, 1, 0, cascade_count);
		}
		if (hddagi->lightprobe_screen_probe_last_used.is_valid()) {
			RD::get_singleton()->texture_clear(hddagi->lightprobe_screen_probe_last_used, Color(0, 0, 0, 0), 0, 1, 0, cascade_count);
		}
		if (hddagi->lightprobe_screen_probe_origin_vote.is_valid()) {
			RD::get_singleton()->texture_clear(hddagi->lightprobe_screen_probe_origin_vote, Color(0, 0, 0, 0), 0, 1, 0, cascade_count);
		}
	}
	hddagi->screen_probe_scheduler_feedback_active = false;

	hddagi->screen_probe_history_initialized = false;
	hddagi->screen_probe_previous_camera_valid = false;
	hddagi->screen_probe_history_configuration = 0;
	hddagi->screen_probe_history_slot = 0;
	hddagi->screen_probe_history_sequence = 0;
	hddagi->screen_probe_stats_accumulating = false;
	hddagi->screen_probe_history_generation = (hddagi->screen_probe_history_generation + 1u) & SCREEN_PROBE_HISTORY_SEQUENCE_MASK;
	if (hddagi->screen_probe_history_generation == 0u) {
		hddagi->screen_probe_history_generation = 1u;
	}
}

void GI::_process_hddagi_screen_probes_phase1(Ref<RenderSceneBuffersRD> p_render_buffers, Ref<RenderBuffersGI> p_rbgi, Ref<HDDAGI> p_hddagi, const RID *p_normal_roughness_slices, RID p_environment, uint32_t p_view_count, Size2i p_gi_size, const Projection *p_projections, const Vector2 &p_taa_jitter, const Transform3D &p_cam_transform, bool p_camera_attributes_valid, float p_exposure_normalization, float p_ibl_exposure_normalization, int p_probe_size, float p_normal_bias, float p_history_blend_hit, float p_history_distance_tolerance, float p_history_direction_threshold, float p_history_sample_count_max, int p_candidate_count, bool p_debug_counters, uint32_t p_debug_counter_tag, bool p_reference_mode, bool p_temporal_restir, bool p_spatial_restir, int p_spatial_reuse_radius, float p_spatial_normal_threshold, float p_spatial_depth_tolerance_min, float p_spatial_depth_tolerance_scale, bool p_restir_temporal_robust_mode, int p_restir_temporal_m_cap_multiplier, int p_restir_temporal_maximum_age, float p_restir_temporal_jacobian_max) {
	ERR_FAIL_COND(p_view_count == 0 || p_view_count > 2);
#ifdef NVIDIA_NRD_ENABLED
	const bool nrd_available = NrdContextRD::is_available();
	const bool nrd_requested = nrd_available && !p_rbgi->nrd_permanently_disabled && !p_reference_mode && p_view_count == 1;
	if (p_view_count > 1 && nrd_available) {
		// CameraData folds each eye transform into p_projections for multiview.
		// NRD must instead receive a pure per-eye projection plus a matching
		// world-to-view matrix, because it decomposes viewToClip internally.
		WARN_PRINT_ONCE("HDDAGI NRD currently supports mono views only; multiview uses the unfiltered signal.");
	}
	const bool nrd_resources_need_release = !nrd_requested &&
			(p_rbgi->nrd_context.has_view(0) ||
					p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_NRD_NORMAL_ROUGHNESS) ||
					p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_NRD_VIEWZ) ||
					p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_NRD_MOTION) ||
					p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_NRD_INPUT) ||
					p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_NRD_OUTPUT));
	if (nrd_resources_need_release) {
		// Reference/multiview operation and the sticky failure fuse do not consume
		// NRD. Release both its large internal pools and the named guide/output
		// textures; rebuilding the shared screen-probe scope also makes the related
		// temporal reset explicit if mono NRD is requested again later.
		p_rbgi->nrd_context.clear();
		p_render_buffers->clear_context(RB_SCOPE_HDDAGI_SCREEN_PROBES);
	}
#endif

	const int probe_size = CLAMP(p_probe_size, 1, 32);
	const Size2i internal_size = p_render_buffers->get_internal_size();
	const Size2i probe_atlas_size((p_gi_size.x + probe_size - 1) / probe_size, (p_gi_size.y + probe_size - 1) / probe_size);
	const float normal_bias = CLAMP(p_normal_bias, -8.0f, 8.0f);
	const uint32_t candidate_count = CLAMP(p_candidate_count, 1, 8);
	const bool reservoir_restir = p_temporal_restir || p_spatial_restir;
	const uint32_t spatial_candidate_count = 4u;
	const uint32_t algorithm_mode = p_reference_mode ? SCREEN_PROBE_ALGORITHM_PHASE1_REFERENCE : (p_spatial_restir ? SCREEN_PROBE_ALGORITHM_PHASE3_SPATIAL : (p_temporal_restir ? SCREEN_PROBE_ALGORITHM_PHASE2_TEMPORAL : SCREEN_PROBE_ALGORITHM_PHASE1));
	const bool algorithm_changed = !p_hddagi->screen_probe_history_initialized || p_hddagi->screen_probe_history_algorithm != algorithm_mode;

	RendererSceneRenderRD *scene_render = RendererSceneRenderRD::get_singleton();
	uint32_t transport_configuration = hash_murmur3_one_64(p_environment.get_id());
	transport_configuration = hash_murmur3_one_32(p_hddagi->reads_sky ? 1u : 0u, transport_configuration);
	transport_configuration = hash_murmur3_one_float(p_hddagi->energy, transport_configuration);
	transport_configuration = hash_murmur3_one_float(p_hddagi->y_mult, transport_configuration);
	transport_configuration = hash_murmur3_one_float(p_exposure_normalization, transport_configuration);
	transport_configuration = hash_murmur3_one_float(p_ibl_exposure_normalization, transport_configuration);
	transport_configuration = hash_murmur3_one_32(p_hddagi->cascades.size(), transport_configuration);
	for (const HDDAGI::Cascade &cascade : p_hddagi->cascades) {
		const float cascade_exposure_normalization = p_camera_attributes_valid ? p_exposure_normalization / cascade.baked_exposure_normalization : 1.0f;
		transport_configuration = hash_murmur3_one_float(cascade_exposure_normalization, transport_configuration);
	}
	transport_configuration = hash_murmur3_one_32(p_hddagi->version, transport_configuration);
	if (p_environment.is_valid()) {
		const RSE::EnvironmentBG background = scene_render->environment_get_background(p_environment);
		transport_configuration = hash_murmur3_one_32(uint32_t(background), transport_configuration);
		transport_configuration = hash_murmur3_one_float(scene_render->environment_get_bg_energy_multiplier(p_environment), transport_configuration);
		transport_configuration = hash_murmur3_one_float(scene_render->environment_get_bg_intensity(p_environment), transport_configuration);

		const Basis sky_orientation = scene_render->environment_get_sky_orientation(p_environment);
		for (int row = 0; row < 3; row++) {
			for (int column = 0; column < 3; column++) {
				transport_configuration = hash_murmur3_one_float(sky_orientation[row][column], transport_configuration);
			}
		}

		if (background == RSE::ENV_BG_CLEAR_COLOR || background == RSE::ENV_BG_COLOR) {
			const Color color = background == RSE::ENV_BG_CLEAR_COLOR ? RSG::texture_storage->get_default_clear_color() : scene_render->environment_get_bg_color(p_environment);
			transport_configuration = hash_murmur3_one_float(color.r, transport_configuration);
			transport_configuration = hash_murmur3_one_float(color.g, transport_configuration);
			transport_configuration = hash_murmur3_one_float(color.b, transport_configuration);
			transport_configuration = hash_murmur3_one_float(color.a, transport_configuration);
		} else if (background == RSE::ENV_BG_SKY && sky) {
			const RID sky_rid = scene_render->environment_get_sky(p_environment);
			transport_configuration = hash_murmur3_one_64(sky_rid.get_id(), transport_configuration);
			if (sky_rid.is_valid()) {
				transport_configuration = hash_murmur3_one_64(sky->sky_get_radiance_texture_rd(sky_rid).get_id(), transport_configuration);
				transport_configuration = hash_murmur3_one_float(sky->sky_get_uv_border_size(sky_rid), transport_configuration);
			}
		}
	}
	transport_configuration = hash_fmix32(transport_configuration);

	uint32_t configuration = hash_murmur3_one_32(p_spatial_restir ? 0x50335303u : (p_temporal_restir ? 0x50325202u : 0x50483101u), algorithm_mode);
	configuration = hash_murmur3_one_32(candidate_count, configuration);
	configuration = hash_murmur3_one_32(transport_configuration, configuration);
#ifdef NVIDIA_NRD_ENABLED
	configuration = hash_murmur3_one_32(nrd_requested ? 1u : 0u, configuration);
#endif
	configuration = hash_murmur3_one_float(normal_bias, configuration);
	configuration = hash_murmur3_one_float(p_history_blend_hit, configuration);
	configuration = hash_murmur3_one_float(p_history_distance_tolerance, configuration);
	configuration = hash_murmur3_one_float(p_history_direction_threshold, configuration);
	configuration = hash_murmur3_one_float(p_history_sample_count_max, configuration);
	if (reservoir_restir) {
		configuration = hash_murmur3_one_32(p_restir_temporal_robust_mode ? 1u : 0u, configuration);
		configuration = hash_murmur3_one_32(uint32_t(CLAMP(p_restir_temporal_m_cap_multiplier, 1, 64)), configuration);
		configuration = hash_murmur3_one_float(CLAMP(p_restir_temporal_jacobian_max, 1.0f, 64.0f), configuration);
	}
	if (p_temporal_restir) {
		configuration = hash_murmur3_one_32(uint32_t(CLAMP(p_restir_temporal_maximum_age, 1, 1024)), configuration);
	}
	if (p_spatial_restir) {
		configuration = hash_murmur3_one_32(p_temporal_restir ? 1u : 0u, configuration);
		configuration = hash_murmur3_one_32(uint32_t(CLAMP(p_spatial_reuse_radius, 0, 4)), configuration);
		configuration = hash_murmur3_one_32(spatial_candidate_count, configuration);
		configuration = hash_murmur3_one_float(CLAMP(p_spatial_normal_threshold, 0.0f, 1.0f), configuration);
		configuration = hash_murmur3_one_float(MAX(p_spatial_depth_tolerance_min, 0.0f), configuration);
		configuration = hash_murmur3_one_float(MAX(p_spatial_depth_tolerance_scale, 0.0f), configuration);
	}
	configuration = hash_fmix32(configuration);

	Projection raster_correction;
	raster_correction.set_depth_correction(true);
	raster_correction.add_jitter_offset(p_taa_jitter);
	Projection temporal_correction;
	temporal_correction.set_depth_correction(true);
#ifdef NVIDIA_NRD_ENABLED
	Projection nrd_correction;
	nrd_correction.set_depth_correction(false, true, true);
#endif

	bool camera_cut = false;
	if (p_hddagi->screen_probe_previous_camera_valid) {
		const float translation = p_hddagi->screen_probe_previous_cam_transform.origin.distance_to(p_cam_transform.origin);
		const float translation_limit = MAX(4.0f, p_hddagi->min_cell_size * 16.0f);
		const float rotation = p_hddagi->screen_probe_previous_cam_transform.basis.get_rotation_quaternion().angle_to(p_cam_transform.basis.get_rotation_quaternion());
		camera_cut = translation > translation_limit || rotation > Math::deg_to_rad(55.0f);
		for (uint32_t v = 0; v < p_view_count && !camera_cut; v++) {
			const Projection current_temporal_projection = temporal_correction * p_projections[v];
			if (current_temporal_projection.is_orthogonal() != p_hddagi->screen_probe_previous_temporal_projection[v].is_orthogonal()) {
				camera_cut = true;
				break;
			}
			for (int column = 0; column < 4 && !camera_cut; column++) {
				for (int row = 0; row < 4; row++) {
					if (Math::abs(current_temporal_projection.columns[column][row] - p_hddagi->screen_probe_previous_temporal_projection[v].columns[column][row]) > 0.35f) {
						camera_cut = true;
						break;
					}
				}
			}
		}
	}

	const bool phase2_resources_present = !reservoir_restir ||
			(p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE2_RESERVOIR_OWNER) &&
					p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE2_RESERVOIR_SAMPLE) &&
					p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE2_RESERVOIR_ENDPOINT) &&
					p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE2_RESERVOIR_RADIANCE) &&
					p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE2_RESERVOIR_IDENTITY) &&
					p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE2_RESERVOIR_META) &&
					p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE2_RESERVOIR_VERSION));
	const bool phase3_spatial_resources_present = !p_spatial_restir ||
			(p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE3_SPATIAL_OWNER) &&
					p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE3_SPATIAL_SAMPLE) &&
					p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE3_SPATIAL_ENDPOINT) &&
					p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE3_SPATIAL_RADIANCE) &&
					p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE3_SPATIAL_IDENTITY) &&
					p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE3_SPATIAL_META) &&
					p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE3_SPATIAL_VERSION));
#ifdef NVIDIA_NRD_ENABLED
	const bool nrd_resources_present = !nrd_requested ||
			(p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_NRD_NORMAL_ROUGHNESS) &&
					p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_NRD_VIEWZ) &&
					p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_NRD_MOTION) &&
					p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_NRD_INPUT) &&
					p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_NRD_OUTPUT));
#else
	const bool nrd_resources_present = true;
#endif

	const bool named_resources_present =
			p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_RADIANCE) &&
			p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE1_PROBE_SURFACE) &&
			p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE1_FULLRES_RAW) &&
			p_render_buffers->has_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE1_FULLRES_SURFACE) &&
			phase2_resources_present &&
			phase3_spatial_resources_present &&
			nrd_resources_present;
	const bool resources_valid = named_resources_present && p_hddagi->screen_probe_history_initialized && p_hddagi->screen_probe_history_algorithm == algorithm_mode && p_hddagi->screen_probe_history_probe_size == probe_size && p_hddagi->screen_probe_history_gi_size == p_gi_size && p_hddagi->screen_probe_history_screen_size == internal_size && p_hddagi->screen_probe_history_view_count == p_view_count;
	const bool configuration_valid = resources_valid && p_hddagi->screen_probe_history_configuration == configuration;
	const bool history_valid = !p_reference_mode && configuration_valid && p_hddagi->screen_probe_previous_camera_valid && !camera_cut;
	const bool reset_generation = !resources_valid || !configuration_valid || camera_cut;
	if (!resources_valid) {
		p_render_buffers->clear_context(RB_SCOPE_HDDAGI_SCREEN_PROBES);
	}
	if (reset_generation) {
		p_hddagi->screen_probe_history_slot = 0;
		p_hddagi->screen_probe_history_sequence = 0;
		p_hddagi->screen_probe_history_generation = (p_hddagi->screen_probe_history_generation + 1u) & SCREEN_PROBE_HISTORY_SEQUENCE_MASK;
		if (p_hddagi->screen_probe_history_generation == 0u) {
			p_hddagi->screen_probe_history_generation = 1u;
		}
	} else {
		p_hddagi->screen_probe_history_slot ^= 1u;
		p_hddagi->screen_probe_history_sequence = (p_hddagi->screen_probe_history_sequence + 1u) & SCREEN_PROBE_HISTORY_SEQUENCE_MASK;
	}

	p_hddagi->screen_probe_history_initialized = true;
	p_hddagi->screen_probe_history_algorithm = algorithm_mode;
	p_hddagi->screen_probe_history_probe_size = probe_size;
	p_hddagi->screen_probe_history_normal_bias = normal_bias;
	p_hddagi->screen_probe_history_gi_size = p_gi_size;
	p_hddagi->screen_probe_history_screen_size = internal_size;
	p_hddagi->screen_probe_history_view_count = p_view_count;
	p_hddagi->screen_probe_history_configuration = configuration;

	// Query feedback is a later phase. Clear any legacy scheduler influence once
	// when entering the fresh-only graph; candidate-count sweeps then observe the
	// same underlying HDDAGI update policy.
	if (algorithm_changed && !p_hddagi->cascades.is_empty()) {
		const uint32_t cascade_count = p_hddagi->cascades.size();
		RD::get_singleton()->texture_clear(p_hddagi->lightprobe_screen_probe_feedback, Color(0, 0, 0, 0), 0, 1, 0, cascade_count);
		RD::get_singleton()->texture_clear(p_hddagi->lightprobe_screen_probe_last_used, Color(0, 0, 0, 0), 0, 1, 0, cascade_count);
		RD::get_singleton()->texture_clear(p_hddagi->lightprobe_screen_probe_origin_vote, Color(0, 0, 0, 0), 0, 1, 0, cascade_count);
	}
	if (algorithm_changed) {
		p_hddagi->screen_probe_scheduler_feedback_active = false;
	}

	const uint32_t usage_bits = RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_CAN_COPY_FROM_BIT | RD::TEXTURE_USAGE_CAN_COPY_TO_BIT;
	const RD::DataFormat radiance_format = reservoir_restir ? RD::DATA_FORMAT_R32G32B32A32_SFLOAT : RD::DATA_FORMAT_R16G16B16A16_SFLOAT;
	p_render_buffers->create_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_RADIANCE, radiance_format, usage_bits, RD::TEXTURE_SAMPLES_1, probe_atlas_size, p_view_count);
	p_render_buffers->create_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE1_PROBE_SURFACE, RD::DATA_FORMAT_R32G32B32A32_UINT, usage_bits, RD::TEXTURE_SAMPLES_1, probe_atlas_size, reservoir_restir ? p_view_count * 2 : p_view_count);
	p_render_buffers->create_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE1_FULLRES_RAW, radiance_format, usage_bits, RD::TEXTURE_SAMPLES_1, internal_size, p_view_count);
	p_render_buffers->create_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE1_FULLRES_SURFACE, RD::DATA_FORMAT_R32G32_UINT, usage_bits, RD::TEXTURE_SAMPLES_1, internal_size, p_view_count);
#ifdef NVIDIA_NRD_ENABLED
	if (nrd_requested) {
		p_render_buffers->create_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_NRD_NORMAL_ROUGHNESS, RD::DATA_FORMAT_R8G8B8A8_UNORM, usage_bits, RD::TEXTURE_SAMPLES_1, internal_size, p_view_count);
		p_render_buffers->create_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_NRD_VIEWZ, RD::DATA_FORMAT_R32_SFLOAT, usage_bits, RD::TEXTURE_SAMPLES_1, internal_size, p_view_count * 2);
		p_render_buffers->create_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_NRD_MOTION, RD::DATA_FORMAT_R16G16B16A16_SFLOAT, usage_bits, RD::TEXTURE_SAMPLES_1, internal_size, p_view_count);
		p_render_buffers->create_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_NRD_INPUT, RD::DATA_FORMAT_R16G16B16A16_SFLOAT, usage_bits, RD::TEXTURE_SAMPLES_1, internal_size, p_view_count);
		p_render_buffers->create_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_NRD_OUTPUT, RD::DATA_FORMAT_R16G16B16A16_SFLOAT, usage_bits, RD::TEXTURE_SAMPLES_1, internal_size, p_view_count);
	}
#endif
	if (reservoir_restir) {
		const uint32_t reservoir_layers = p_view_count * 2;
		p_render_buffers->create_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE2_RESERVOIR_OWNER, RD::DATA_FORMAT_R32G32B32A32_SFLOAT, usage_bits, RD::TEXTURE_SAMPLES_1, probe_atlas_size, reservoir_layers);
		p_render_buffers->create_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE2_RESERVOIR_SAMPLE, RD::DATA_FORMAT_R32G32B32A32_SFLOAT, usage_bits, RD::TEXTURE_SAMPLES_1, probe_atlas_size, reservoir_layers);
		p_render_buffers->create_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE2_RESERVOIR_ENDPOINT, RD::DATA_FORMAT_R32G32B32A32_SFLOAT, usage_bits, RD::TEXTURE_SAMPLES_1, probe_atlas_size, reservoir_layers);
		p_render_buffers->create_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE2_RESERVOIR_RADIANCE, RD::DATA_FORMAT_R32G32B32A32_SFLOAT, usage_bits, RD::TEXTURE_SAMPLES_1, probe_atlas_size, reservoir_layers);
		p_render_buffers->create_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE2_RESERVOIR_IDENTITY, RD::DATA_FORMAT_R32G32B32A32_UINT, usage_bits, RD::TEXTURE_SAMPLES_1, probe_atlas_size, reservoir_layers);
		p_render_buffers->create_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE2_RESERVOIR_META, RD::DATA_FORMAT_R32G32B32A32_UINT, usage_bits, RD::TEXTURE_SAMPLES_1, probe_atlas_size, reservoir_layers);
		p_render_buffers->create_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE2_RESERVOIR_VERSION, RD::DATA_FORMAT_R32G32_UINT, usage_bits, RD::TEXTURE_SAMPLES_1, probe_atlas_size, reservoir_layers);
	}
	if (p_spatial_restir) {
		const uint32_t spatial_layers = p_view_count * 2;
		p_render_buffers->create_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE3_SPATIAL_OWNER, RD::DATA_FORMAT_R32G32B32A32_SFLOAT, usage_bits, RD::TEXTURE_SAMPLES_1, probe_atlas_size, spatial_layers);
		p_render_buffers->create_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE3_SPATIAL_SAMPLE, RD::DATA_FORMAT_R32G32B32A32_SFLOAT, usage_bits, RD::TEXTURE_SAMPLES_1, probe_atlas_size, spatial_layers);
		p_render_buffers->create_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE3_SPATIAL_ENDPOINT, RD::DATA_FORMAT_R32G32B32A32_SFLOAT, usage_bits, RD::TEXTURE_SAMPLES_1, probe_atlas_size, spatial_layers);
		p_render_buffers->create_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE3_SPATIAL_RADIANCE, RD::DATA_FORMAT_R32G32B32A32_SFLOAT, usage_bits, RD::TEXTURE_SAMPLES_1, probe_atlas_size, spatial_layers);
		p_render_buffers->create_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE3_SPATIAL_IDENTITY, RD::DATA_FORMAT_R32G32B32A32_UINT, usage_bits, RD::TEXTURE_SAMPLES_1, probe_atlas_size, spatial_layers);
		p_render_buffers->create_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE3_SPATIAL_META, RD::DATA_FORMAT_R32G32B32A32_UINT, usage_bits, RD::TEXTURE_SAMPLES_1, probe_atlas_size, spatial_layers);
		p_render_buffers->create_texture(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE3_SPATIAL_VERSION, RD::DATA_FORMAT_R32G32_UINT, usage_bits, RD::TEXTURE_SAMPLES_1, probe_atlas_size, spatial_layers);
	}
	p_render_buffers->clear_context(RB_SCOPE_HDDAGI_SCREEN_PROBES_DEBUG);

	RID screen_probe_stats_buffer = hddagi_shader.screen_probe_stats_dummy_buffer;
	if (p_debug_counters) {
		bool reset_stats_accumulation = reset_generation || !p_hddagi->screen_probe_stats_accumulating;
		if (!p_hddagi->screen_probe_stats_buffer.is_valid()) {
			p_hddagi->screen_probe_stats_buffer = RD::get_singleton()->storage_buffer_create(sizeof(uint32_t) * SCREEN_PROBE_STAT_COUNT);
			RD::get_singleton()->set_resource_name(p_hddagi->screen_probe_stats_buffer, "HDDAGI Screen Probe GPU Stats");
			reset_stats_accumulation = true;
		}
		if (reset_stats_accumulation) {
			RD::get_singleton()->buffer_clear(p_hddagi->screen_probe_stats_buffer, 0, sizeof(uint32_t) * SCREEN_PROBE_STAT_COUNT);
		} else {
			// Transport/history/cache counters retain their original one-frame
			// semantics. Raw HDR slots 16..31 accumulate the complete 60-frame
			// readback window so every rotating lattice phase contributes.
			RD::get_singleton()->buffer_clear(p_hddagi->screen_probe_stats_buffer, 0, sizeof(uint32_t) * 16u);
			RD::get_singleton()->buffer_clear(p_hddagi->screen_probe_stats_buffer, sizeof(uint32_t) * 32u, sizeof(uint32_t) * (SCREEN_PROBE_STAT_COUNT - 32u));
		}
		p_hddagi->screen_probe_stats_accumulating = true;
		screen_probe_stats_buffer = p_hddagi->screen_probe_stats_buffer;
	} else {
		p_hddagi->screen_probe_stats_accumulating = false;
	}

	HDDAGIShader::ScreenProbePhase2PushConstant phase2_push_constant = {};
	HDDAGIShader::ScreenProbePhase1PushConstant &push_constant = phase2_push_constant.base;
	push_constant.gi_size[0] = p_gi_size.x;
	push_constant.gi_size[1] = p_gi_size.y;
	push_constant.screen_size[0] = internal_size.x;
	push_constant.screen_size[1] = internal_size.y;
	push_constant.probe_size = probe_size;
	push_constant.frame_index = RSG::rasterizer->get_frame_number();
	// Generation is an owner-side layer key. A reset dispatch disables history
	// before fully overwriting the current slot; only that new slot can become
	// previous on the next locally rendered frame.
	push_constant.flags = (history_valid ? 1u : 0u) | (p_reference_mode ? 2u : 0u) | (p_debug_counters ? 4u : 0u) | ((p_temporal_restir && history_valid) ? 8u : 0u);
	push_constant.normal_bias = normal_bias;
	push_constant.history_blend = CLAMP(p_history_blend_hit, 0.0f, 1.0f);
	push_constant.history_depth_tolerance = MAX(p_history_distance_tolerance, 0.0f);
	push_constant.history_normal_threshold = CLAMP(p_history_direction_threshold, 0.0f, 1.0f);
	push_constant.candidate_count = candidate_count;
	push_constant.sky_mode = HDDAGIShader::SCREEN_PROBE_PHASE1_SKY_DISABLED;
	push_constant.sky_energy = 0.0f;
	push_constant.history_sample_count_max = CLAMP(p_history_sample_count_max, 1.0f, 1024.0f);
	push_constant.debug_mode = 0;
	push_constant.output_radiance_scale = 1.0f;
	phase2_push_constant.history_generation = p_hddagi->screen_probe_history_generation;
	phase2_push_constant.algorithm_version = p_spatial_restir ? 3u : 2u;
	phase2_push_constant.robust_mode = p_restir_temporal_robust_mode ? 1u : 0u;
	phase2_push_constant.history_m_cap = candidate_count * uint32_t(CLAMP(p_restir_temporal_m_cap_multiplier, 1, 64));
	phase2_push_constant.local_sequence = p_hddagi->screen_probe_history_sequence;
	phase2_push_constant.maximum_age = uint32_t(CLAMP(p_restir_temporal_maximum_age, 1, 1024));
	phase2_push_constant.jacobian_max = CLAMP(p_restir_temporal_jacobian_max, 1.0f, 64.0f);

	RendererRD::TextureStorage *texture_storage = RendererRD::TextureStorage::get_singleton();
	RID sky_texture = texture_storage->texture_rd_get_default(sky && sky->sky_use_octmap_array ? RendererRD::TextureStorage::DEFAULT_RD_TEXTURE_2D_ARRAY_BLACK : RendererRD::TextureStorage::DEFAULT_RD_TEXTURE_BLACK);
	if (p_hddagi->reads_sky && p_environment.is_valid()) {
		const RSE::EnvironmentBG background = scene_render->environment_get_background(p_environment);
		if (background == RSE::ENV_BG_CLEAR_COLOR || background == RSE::ENV_BG_COLOR) {
			Color color = background == RSE::ENV_BG_CLEAR_COLOR ? RSG::texture_storage->get_default_clear_color() : scene_render->environment_get_bg_color(p_environment);
			color = color.srgb_to_linear();
			push_constant.sky_color[0] = color.r;
			push_constant.sky_color[1] = color.g;
			push_constant.sky_color[2] = color.b;
			push_constant.sky_energy = scene_render->environment_get_bg_energy_multiplier(p_environment) * scene_render->environment_get_bg_intensity(p_environment) * p_exposure_normalization;
			push_constant.sky_mode = HDDAGIShader::SCREEN_PROBE_PHASE1_SKY_COLOR;
		} else if (background == RSE::ENV_BG_SKY && sky) {
			const RID sky_rid = scene_render->environment_get_sky(p_environment);
			if (sky_rid.is_valid()) {
				const RID environment_radiance = sky->sky_get_radiance_texture_rd(sky_rid);
				if (environment_radiance.is_valid()) {
					sky_texture = environment_radiance;
					push_constant.sky_color[3] = sky->sky_get_uv_border_size(sky_rid);
					// Match the Forward+ IBL domain. The octmap may have been baked
					// under a different exposure/luminance multiplier, so sampling it
					// requires the same current-to-baked normalization as scene IBL.
					push_constant.sky_energy = scene_render->environment_get_bg_energy_multiplier(p_environment) * p_ibl_exposure_normalization;
					push_constant.sky_mode = HDDAGIShader::SCREEN_PROBE_PHASE1_SKY_TEXTURE;
				}
			}
		}
	}

	HDDAGIShader::ScreenProbePhase2PushConstant phase3_spatial_push_constant = phase2_push_constant;
	phase3_spatial_push_constant.base.history_blend = MAX(p_spatial_depth_tolerance_scale, 0.0f);
	phase3_spatial_push_constant.base.history_depth_tolerance = MAX(p_spatial_depth_tolerance_min, 0.0f);
	phase3_spatial_push_constant.base.history_normal_threshold = CLAMP(p_spatial_normal_threshold, 0.0f, 1.0f);
	phase3_spatial_push_constant.base.candidate_count = spatial_candidate_count;
	phase3_spatial_push_constant.history_m_cap = candidate_count * uint32_t(CLAMP(p_restir_temporal_m_cap_multiplier, 1, 64));
	phase3_spatial_push_constant.maximum_age = uint32_t(CLAMP(p_spatial_reuse_radius, 0, 4));
	SceneData scene_data = {};
	const Transform3D previous_cam_inv_transform = history_valid ? p_hddagi->screen_probe_previous_cam_transform.affine_inverse() : p_cam_transform.affine_inverse();
	for (uint32_t v = 0; v < p_view_count; v++) {
		const Projection current_raster_projection = raster_correction * p_projections[v];
		const Projection previous_raster_projection = history_valid ? p_hddagi->screen_probe_previous_projection[v] : current_raster_projection;
		const Projection current_temporal_projection = temporal_correction * p_projections[v];
		const Projection previous_temporal_projection = history_valid ? p_hddagi->screen_probe_previous_temporal_projection[v] : current_temporal_projection;
		RendererRD::MaterialStorage::store_camera(current_raster_projection, scene_data.projection[v]);
		RendererRD::MaterialStorage::store_camera(current_raster_projection.inverse(), scene_data.inv_projection[v]);
		RendererRD::MaterialStorage::store_camera(previous_raster_projection, scene_data.previous_projection[v]);
		RendererRD::MaterialStorage::store_camera(previous_raster_projection.inverse(), scene_data.previous_inv_projection[v]);
		RendererRD::MaterialStorage::store_camera(current_temporal_projection, scene_data.temporal_projection[v]);
		RendererRD::MaterialStorage::store_camera(previous_temporal_projection, scene_data.previous_temporal_projection[v]);
	}
	RendererRD::MaterialStorage::store_transform(p_cam_transform, scene_data.cam_transform);
	RendererRD::MaterialStorage::store_transform(previous_cam_inv_transform, scene_data.previous_cam_inv_transform);
	scene_data.screen_size[0] = internal_size.x;
	scene_data.screen_size[1] = internal_size.y;
	Basis radiance_transform;
	if (p_environment.is_valid()) {
		radiance_transform = RendererSceneRenderRD::get_singleton()->environment_get_sky_orientation(p_environment).inverse() * p_cam_transform.basis;
	} else {
		radiance_transform = p_cam_transform.basis;
	}
	RendererRD::MaterialStorage::store_transform_3x3(radiance_transform, scene_data.radiance_inverse_xform);
	RD::get_singleton()->buffer_update(p_rbgi->scene_data_ubo, 0, sizeof(SceneData), &scene_data);

	const RID linear_sampler = RendererRD::MaterialStorage::get_singleton()->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
	const RID linear_mipmap_sampler = RendererRD::MaterialStorage::get_singleton()->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR_WITH_MIPMAPS, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
	const RID nearest_sampler = RendererRD::MaterialStorage::get_singleton()->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
	const uint32_t current_history_index = p_reference_mode ? 0u : p_hddagi->screen_probe_history_slot;
	const uint32_t previous_history_index = current_history_index ^ 1u;
#ifdef NVIDIA_NRD_ENABLED
	ERR_FAIL_COND_MSG(nrd_requested && !p_render_buffers->has_velocity_buffer(false), "HDDAGI NRD requires the Forward+ velocity prepass.");
#endif

	bool sharc_active = false;
#ifdef NVIDIA_SHARC_ENABLED
	RID sharc_update_parameters_set;
	RID sharc_resolve_parameters_set;
	RID sharc_trace_parameters_set;
	RID sharc_phase2_fresh_parameters_set;
	RID sharc_phase2_temporal_parameters_set;
	RID sharc_phase3_spatial_parameters_set;
	auto release_sharc_resources = [&]() {
		p_rbgi->sharc_context.clear();
		if (p_rbgi->sharc_parameters_ubo.is_valid()) {
			RD::get_singleton()->free_rid(p_rbgi->sharc_parameters_ubo);
			p_rbgi->sharc_parameters_ubo = RID();
		}
	};
	auto disable_sharc = [&](const String &p_reason) {
		WARN_PRINT_ONCE("HDDAGI SHARC disabled for this render buffer: " + p_reason);
		p_rbgi->sharc_permanently_disabled = true;
		release_sharc_resources();
	};

	if (!SharcContextRD::is_supported()) {
		p_rbgi->sharc_permanently_disabled = true;
	}
	if (p_reference_mode || p_rbgi->sharc_permanently_disabled) {
		// Reference mode bypasses SHARC, and a sticky failure cannot recover for
		// this render buffer. Do not retain the 80 MiB cache or its parameter UBO.
		release_sharc_resources();
	} else {
		auto mode_is_ready = [&](HDDAGIShader::ScreenProbePhase1Mode p_mode) {
			return hddagi_shader.screen_probe_phase1_shader_version[p_mode].is_valid() && hddagi_shader.screen_probe_phase1_pipeline[p_mode].is_valid();
		};
		bool modes_ready = mode_is_ready(HDDAGIShader::SCREEN_PROBE_SHARC_UPDATE) && mode_is_ready(HDDAGIShader::SCREEN_PROBE_SHARC_RESOLVE);
		if (reservoir_restir) {
			modes_ready = modes_ready && mode_is_ready(HDDAGIShader::SCREEN_PROBE_PHASE2_FRESH_SHARC);
			if (p_temporal_restir) {
				modes_ready = modes_ready && mode_is_ready(HDDAGIShader::SCREEN_PROBE_PHASE2_TEMPORAL_SHARC);
			}
			if (p_spatial_restir) {
				modes_ready = modes_ready && mode_is_ready(HDDAGIShader::SCREEN_PROBE_PHASE3_SPATIAL_SHARC);
			}
		} else {
			modes_ready = modes_ready && mode_is_ready(HDDAGIShader::SCREEN_PROBE_PHASE1_TRACE_SHARC);
		}

		if (!modes_ready) {
			disable_sharc("one or more compute shader variants failed to initialize");
		} else {
			const bool had_camera_history = p_rbgi->sharc_context.has_camera_history();
			const Error configure_error = p_rbgi->sharc_context.configure();
			const Error frame_error = configure_error == OK ? p_rbgi->sharc_context.begin_frame(p_cam_transform.origin, reset_generation && had_camera_history) : configure_error;
			if (frame_error != OK) {
				disable_sharc(vformat("resource or frame setup failed (error %d)", frame_error));
			} else {
				if (!p_rbgi->sharc_parameters_ubo.is_valid()) {
					p_rbgi->sharc_parameters_ubo = RD::get_singleton()->uniform_buffer_create(sizeof(HDDAGIShader::ScreenProbeSharcParameters));
					if (p_rbgi->sharc_parameters_ubo.is_valid()) {
						RD::get_singleton()->set_resource_name(p_rbgi->sharc_parameters_ubo, "HDDAGI SHARC Parameters");
					}
				}

				if (!p_rbgi->sharc_parameters_ubo.is_valid()) {
					disable_sharc("parameter buffer allocation failed");
				} else {
					HDDAGIShader::ScreenProbeSharcParameters sharc_parameters = {};
					const SharcContextRD::Resources &sharc_resources = p_rbgi->sharc_context.get_resources();
					auto store_address = [](uint64_t p_address, uint32_t *r_words) {
						r_words[0] = uint32_t(p_address);
						r_words[1] = uint32_t(p_address >> 32u);
					};
					store_address(sharc_resources.hash.device_address, &sharc_parameters.hash_lock_addresses[0]);
					store_address(sharc_resources.accumulation.device_address, &sharc_parameters.accumulation_resolved_addresses[0]);
					store_address(sharc_resources.resolved.device_address, &sharc_parameters.accumulation_resolved_addresses[2]);
					const Vector3 &sharc_camera = p_rbgi->sharc_context.get_camera_position();
					const Vector3 &sharc_previous_camera = p_rbgi->sharc_context.get_previous_camera_position();
					sharc_parameters.camera_position_logarithm_base[0] = sharc_camera.x;
					sharc_parameters.camera_position_logarithm_base[1] = sharc_camera.y;
					sharc_parameters.camera_position_logarithm_base[2] = sharc_camera.z;
					sharc_parameters.camera_position_logarithm_base[3] = 2.0f;
					sharc_parameters.previous_camera_position_scene_scale[0] = sharc_previous_camera.x;
					sharc_parameters.previous_camera_position_scene_scale[1] = sharc_previous_camera.y;
					sharc_parameters.previous_camera_position_scene_scale[2] = sharc_previous_camera.z;
					sharc_parameters.previous_camera_position_scene_scale[3] = 50.0f;
					sharc_parameters.tuning[0] = 0.0f;
					// Update at most one bounded scene-linear sample for 16K probes per
					// frame. This gives the official uint accumulator a hard global
					// no-wrap bound while retaining <= 0.001 quantization steps.
					const uint64_t sharc_probe_count = uint64_t(probe_atlas_size.x) * uint64_t(probe_atlas_size.y) * uint64_t(p_view_count);
					const uint32_t sharc_update_stride = uint32_t(MAX(uint64_t(1), (sharc_probe_count + SCREEN_PROBE_SHARC_UPDATE_BUDGET - 1u) / SCREEN_PROBE_SHARC_UPDATE_BUDGET));
					const uint64_t sharc_update_count = (sharc_probe_count + sharc_update_stride - 1u) / sharc_update_stride;
					sharc_parameters.tuning[1] = float(MIN(1000.0, (double(UINT32_MAX) * 0.5) / (double(sharc_update_count) * SCREEN_PROBE_SHARC_RADIANCE_MAX)));
					// trace_hddagi_sample already returns the current pre-exposed
					// Forward+ domain. Manual exposure changes reset this cache through
					// transport_configuration, so no second exposure transform belongs here.
					sharc_parameters.tuning[2] = 1.0f;
					sharc_parameters.tuning[3] = 1.0f;
					sharc_parameters.resolve[0] = sharc_resources.entry_count;
					sharc_parameters.resolve[1] = p_rbgi->sharc_context.get_frame_index();
					sharc_parameters.resolve[2] = 32u;
					sharc_parameters.resolve[3] = 4u;
					sharc_parameters.control[0] = 64u;
					sharc_parameters.control[1] = 1u;
					sharc_parameters.control[2] = sharc_update_stride;
					const Error update_error = RD::get_singleton()->buffer_update(p_rbgi->sharc_parameters_ubo, 0, sizeof(sharc_parameters), &sharc_parameters);
					if (update_error != OK) {
						disable_sharc(vformat("parameter upload failed (error %d)", update_error));
					} else {
						auto get_sharc_parameters_set = [&](HDDAGIShader::ScreenProbePhase1Mode p_mode) {
							return UniformSetCacheRD::get_singleton()->get_cache(
									hddagi_shader.screen_probe_phase1_shader_version[p_mode], 2,
									RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 0, sharc_resources.hash.rid),
									RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 2, sharc_resources.accumulation.rid),
									RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 3, sharc_resources.resolved.rid),
									RD::Uniform(RD::UNIFORM_TYPE_UNIFORM_BUFFER, 4, p_rbgi->sharc_parameters_ubo));
						};
						sharc_update_parameters_set = get_sharc_parameters_set(HDDAGIShader::SCREEN_PROBE_SHARC_UPDATE);
						sharc_resolve_parameters_set = get_sharc_parameters_set(HDDAGIShader::SCREEN_PROBE_SHARC_RESOLVE);
						bool sets_valid = sharc_update_parameters_set.is_valid() && sharc_resolve_parameters_set.is_valid();
						if (reservoir_restir) {
							sharc_phase2_fresh_parameters_set = get_sharc_parameters_set(HDDAGIShader::SCREEN_PROBE_PHASE2_FRESH_SHARC);
							sets_valid = sets_valid && sharc_phase2_fresh_parameters_set.is_valid();
							if (p_temporal_restir) {
								sharc_phase2_temporal_parameters_set = get_sharc_parameters_set(HDDAGIShader::SCREEN_PROBE_PHASE2_TEMPORAL_SHARC);
								sets_valid = sets_valid && sharc_phase2_temporal_parameters_set.is_valid();
							}
							if (p_spatial_restir) {
								sharc_phase3_spatial_parameters_set = get_sharc_parameters_set(HDDAGIShader::SCREEN_PROBE_PHASE3_SPATIAL_SHARC);
								sets_valid = sets_valid && sharc_phase3_spatial_parameters_set.is_valid();
							}
						} else {
							sharc_trace_parameters_set = get_sharc_parameters_set(HDDAGIShader::SCREEN_PROBE_PHASE1_TRACE_SHARC);
							sets_valid = sets_valid && sharc_trace_parameters_set.is_valid();
						}

						if (!sets_valid) {
							disable_sharc("BDA alias uniform-set creation failed");
						} else {
							sharc_active = true;
						}
					}
				}
			}
		}
	}
#endif

	if (p_reference_mode) {
		RD::get_singleton()->draw_command_begin_label("HDDAGI Screen Probes Phase 1 Reference");
	} else if (p_spatial_restir) {
		RD::get_singleton()->draw_command_begin_label("HDDAGI Screen Probes Phase 3 Spatial ReSTIR");
	} else if (p_temporal_restir) {
		RD::get_singleton()->draw_command_begin_label("HDDAGI Screen Probes Phase 2 Temporal ReSTIR");
	} else {
		RD::get_singleton()->draw_command_begin_label("HDDAGI Screen Probes Phase 1");
	}
	RD::ComputeListID compute_list = RD::get_singleton()->compute_list_begin();
#ifdef NVIDIA_SHARC_ENABLED
	if (sharc_active) {
		RENDER_TIMESTAMP("HDDAGI SHARC Update");
		push_constant.flags |= 16u; // PHASE1_FLAG_SHARC_UPDATE_SURFACE.
		for (uint32_t v = 0; v < p_view_count; v++) {
			push_constant.view_index = v;
			const uint32_t probe_surface_layer = reservoir_restir ? v * 2u + current_history_index : v;
			RID probe_surface = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE1_PROBE_SURFACE, probe_surface_layer, 0);

			RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, hddagi_shader.screen_probe_phase1_pipeline[HDDAGIShader::SCREEN_PROBE_PHASE1_SURFACE]);
			RID surface_set = UniformSetCacheRD::get_singleton()->get_cache(
					hddagi_shader.screen_probe_phase1_shader_version[HDDAGIShader::SCREEN_PROBE_PHASE1_SURFACE], 0,
					RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 0, p_render_buffers->get_depth_texture(v)),
					RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 1, p_normal_roughness_slices[v]),
					RD::Uniform(RD::UNIFORM_TYPE_SAMPLER, 2, linear_sampler),
					RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 3, probe_surface));
			RD::get_singleton()->compute_list_bind_uniform_set(compute_list, surface_set, 0);
			RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(push_constant));
			RD::get_singleton()->compute_list_dispatch_threads(compute_list, probe_atlas_size.x, probe_atlas_size.y, 1);
			RD::get_singleton()->compute_list_add_barrier(compute_list);

			RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, hddagi_shader.screen_probe_phase1_pipeline[HDDAGIShader::SCREEN_PROBE_SHARC_UPDATE]);
			RID update_set = UniformSetCacheRD::get_singleton()->get_cache(
					hddagi_shader.screen_probe_phase1_shader_version[HDDAGIShader::SCREEN_PROBE_SHARC_UPDATE], 0,
					RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 0, probe_surface),
					RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 2, p_hddagi->voxel_bits_tex),
					RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 3, p_hddagi->voxel_region_tex),
					RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 4, p_hddagi->voxel_light_tex),
					RD::Uniform(RD::UNIFORM_TYPE_SAMPLER, 5, linear_sampler),
					RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 6, p_hddagi->voxel_light_neighbour_data),
					RD::Uniform(RD::UNIFORM_TYPE_UNIFORM_BUFFER, 7, hddagi_ubo),
					RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 8, p_hddagi->voxel_disocclusion_tex),
					RD::Uniform(RD::UNIFORM_TYPE_UNIFORM_BUFFER, 9, p_rbgi->scene_data_ubo),
					RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 10, screen_probe_stats_buffer));
			RID update_sky_set = UniformSetCacheRD::get_singleton()->get_cache(
					hddagi_shader.screen_probe_phase1_shader_version[HDDAGIShader::SCREEN_PROBE_SHARC_UPDATE], 1,
					RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 0, sky_texture),
					RD::Uniform(RD::UNIFORM_TYPE_SAMPLER, 1, linear_mipmap_sampler));
			RD::get_singleton()->compute_list_bind_uniform_set(compute_list, update_set, 0);
			RD::get_singleton()->compute_list_bind_uniform_set(compute_list, update_sky_set, 1);
			RD::get_singleton()->compute_list_bind_uniform_set(compute_list, sharc_update_parameters_set, 2);
			RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(push_constant));
			RD::get_singleton()->compute_list_dispatch_threads(compute_list, probe_atlas_size.x, probe_atlas_size.y, 1);
			RD::get_singleton()->compute_list_add_barrier(compute_list);
		}

		RENDER_TIMESTAMP("HDDAGI SHARC Resolve");
		RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, hddagi_shader.screen_probe_phase1_pipeline[HDDAGIShader::SCREEN_PROBE_SHARC_RESOLVE]);
		RD::get_singleton()->compute_list_bind_uniform_set(compute_list, sharc_resolve_parameters_set, 2);
		// The shared phase-1 shader declares this range even though Resolve only
		// consumes SHARC's set 2 parameters.
		RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(push_constant));
		RD::get_singleton()->compute_list_dispatch_threads(compute_list, p_rbgi->sharc_context.get_resources().entry_count, 1, 1);
		RD::get_singleton()->compute_list_add_barrier(compute_list);
		push_constant.flags &= ~16u;
	}
#endif
	for (uint32_t v = 0; v < p_view_count; v++) {
		push_constant.view_index = v;
		push_constant.output_radiance_scale = 1.0f;
		phase3_spatial_push_constant.base.view_index = v;
		const uint32_t probe_surface_layer = reservoir_restir ? v * 2u + current_history_index : v;
		const uint32_t previous_probe_surface_layer = reservoir_restir ? v * 2u + previous_history_index : probe_surface_layer;
		const uint32_t current_fullres_surface_layer = v;
		RID probe_surface = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE1_PROBE_SURFACE, probe_surface_layer, 0);
		RID previous_probe_surface = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE1_PROBE_SURFACE, previous_probe_surface_layer, 0);
		RID raw_probe = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_RADIANCE, v, 0);
		RID fullres_raw = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE1_FULLRES_RAW, v, 0);
		RID current_fullres_surface = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE1_FULLRES_SURFACE, current_fullres_surface_layer, 0);

		// SHARC uses a randomized surface in its earlier private update pass.
		// Always overwrite it with the stable center selection before ReSTIR/Trace.
		RENDER_TIMESTAMP("HDDAGI Screen Probe Surface Select");
		RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, hddagi_shader.screen_probe_phase1_pipeline[HDDAGIShader::SCREEN_PROBE_PHASE1_SURFACE]);
		RID surface_set = UniformSetCacheRD::get_singleton()->get_cache(
				hddagi_shader.screen_probe_phase1_shader_version[HDDAGIShader::SCREEN_PROBE_PHASE1_SURFACE], 0,
				RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 0, p_render_buffers->get_depth_texture(v)),
				RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 1, p_normal_roughness_slices[v]),
				RD::Uniform(RD::UNIFORM_TYPE_SAMPLER, 2, linear_sampler),
				RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 3, probe_surface));
		RD::get_singleton()->compute_list_bind_uniform_set(compute_list, surface_set, 0);
		RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(push_constant));
		RD::get_singleton()->compute_list_dispatch_threads(compute_list, probe_atlas_size.x, probe_atlas_size.y, 1);
		RD::get_singleton()->compute_list_add_barrier(compute_list);

		if (reservoir_restir) {
			const uint32_t current_reservoir_layer = v * 2u + current_history_index;
			const uint32_t previous_reservoir_layer = v * 2u + previous_history_index;
			RID current_owner = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE2_RESERVOIR_OWNER, current_reservoir_layer, 0);
			RID current_sample = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE2_RESERVOIR_SAMPLE, current_reservoir_layer, 0);
			RID current_endpoint = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE2_RESERVOIR_ENDPOINT, current_reservoir_layer, 0);
			RID current_radiance = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE2_RESERVOIR_RADIANCE, current_reservoir_layer, 0);
			RID current_identity = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE2_RESERVOIR_IDENTITY, current_reservoir_layer, 0);
			RID current_meta = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE2_RESERVOIR_META, current_reservoir_layer, 0);
			RID current_version = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE2_RESERVOIR_VERSION, current_reservoir_layer, 0);
			RID previous_owner = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE2_RESERVOIR_OWNER, previous_reservoir_layer, 0);
			RID previous_sample = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE2_RESERVOIR_SAMPLE, previous_reservoir_layer, 0);
			RID previous_endpoint = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE2_RESERVOIR_ENDPOINT, previous_reservoir_layer, 0);
			RID previous_radiance = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE2_RESERVOIR_RADIANCE, previous_reservoir_layer, 0);
			RID previous_identity = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE2_RESERVOIR_IDENTITY, previous_reservoir_layer, 0);
			RID previous_meta = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE2_RESERVOIR_META, previous_reservoir_layer, 0);
			RID previous_version = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE2_RESERVOIR_VERSION, previous_reservoir_layer, 0);

			auto get_phase2_set = [&](HDDAGIShader::ScreenProbePhase1Mode p_mode) -> RID {
				return UniformSetCacheRD::get_singleton()->get_cache(
						hddagi_shader.screen_probe_phase1_shader_version[p_mode], 0,
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 0, probe_surface),
						RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 1, current_owner),
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 2, p_hddagi->voxel_bits_tex),
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 3, p_hddagi->voxel_region_tex),
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 4, p_hddagi->voxel_light_tex),
						RD::Uniform(RD::UNIFORM_TYPE_SAMPLER, 5, linear_sampler),
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 6, p_hddagi->voxel_light_neighbour_data),
						RD::Uniform(RD::UNIFORM_TYPE_UNIFORM_BUFFER, 7, hddagi_ubo),
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 8, p_hddagi->voxel_disocclusion_tex),
						RD::Uniform(RD::UNIFORM_TYPE_UNIFORM_BUFFER, 9, p_rbgi->scene_data_ubo),
						RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 10, screen_probe_stats_buffer),
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 11, p_hddagi->region_version_data),
						RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 12, current_sample),
						RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 13, current_endpoint),
						RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 14, current_radiance),
						RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 15, current_identity),
						RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 16, current_meta),
						RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 17, current_version),
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 18, previous_probe_surface),
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 19, previous_owner),
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 20, previous_sample),
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 21, previous_endpoint),
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 22, previous_radiance),
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 23, previous_identity),
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 24, previous_meta),
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 25, previous_version),
						RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 26, raw_probe),
						RD::Uniform(RD::UNIFORM_TYPE_SAMPLER, 27, nearest_sampler));
			};
			auto get_phase2_sky_set = [&](HDDAGIShader::ScreenProbePhase1Mode p_mode) -> RID {
				return UniformSetCacheRD::get_singleton()->get_cache(
						hddagi_shader.screen_probe_phase1_shader_version[p_mode], 1,
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 0, sky_texture),
						RD::Uniform(RD::UNIFORM_TYPE_SAMPLER, 1, linear_mipmap_sampler));
			};

			RENDER_TIMESTAMP("HDDAGI Screen Probe Phase 2 Fresh Reservoir");
			HDDAGIShader::ScreenProbePhase1Mode phase2_fresh_mode = HDDAGIShader::SCREEN_PROBE_PHASE2_FRESH;
#ifdef NVIDIA_SHARC_ENABLED
			if (sharc_active) {
				phase2_fresh_mode = HDDAGIShader::SCREEN_PROBE_PHASE2_FRESH_SHARC;
			}
#endif
			RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, hddagi_shader.screen_probe_phase1_pipeline[phase2_fresh_mode]);
			RD::get_singleton()->compute_list_bind_uniform_set(compute_list, get_phase2_set(phase2_fresh_mode), 0);
			RD::get_singleton()->compute_list_bind_uniform_set(compute_list, get_phase2_sky_set(phase2_fresh_mode), 1);
#ifdef NVIDIA_SHARC_ENABLED
			if (sharc_active) {
				RD::get_singleton()->compute_list_bind_uniform_set(compute_list, sharc_phase2_fresh_parameters_set, 2);
			}
#endif
			RD::get_singleton()->compute_list_set_push_constant(compute_list, &phase2_push_constant, sizeof(phase2_push_constant));
			RD::get_singleton()->compute_list_dispatch_threads(compute_list, probe_atlas_size.x, probe_atlas_size.y, 1);
			RD::get_singleton()->compute_list_add_barrier(compute_list);

			if (p_temporal_restir) {
				RENDER_TIMESTAMP("HDDAGI Screen Probe Phase 2 Temporal Stream Merge");
				HDDAGIShader::ScreenProbePhase1Mode phase2_temporal_mode = HDDAGIShader::SCREEN_PROBE_PHASE2_TEMPORAL;
#ifdef NVIDIA_SHARC_ENABLED
				if (sharc_active) {
					phase2_temporal_mode = HDDAGIShader::SCREEN_PROBE_PHASE2_TEMPORAL_SHARC;
				}
#endif
				RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, hddagi_shader.screen_probe_phase1_pipeline[phase2_temporal_mode]);
				RD::get_singleton()->compute_list_bind_uniform_set(compute_list, get_phase2_set(phase2_temporal_mode), 0);
				RD::get_singleton()->compute_list_bind_uniform_set(compute_list, get_phase2_sky_set(phase2_temporal_mode), 1);
#ifdef NVIDIA_SHARC_ENABLED
				if (sharc_active) {
					RD::get_singleton()->compute_list_bind_uniform_set(compute_list, sharc_phase2_temporal_parameters_set, 2);
				}
#endif
				RD::get_singleton()->compute_list_set_push_constant(compute_list, &phase2_push_constant, sizeof(phase2_push_constant));
				RD::get_singleton()->compute_list_dispatch_threads(compute_list, probe_atlas_size.x, probe_atlas_size.y, 1);
				RD::get_singleton()->compute_list_add_barrier(compute_list);
			}
			if (p_spatial_restir) {
				const uint32_t spatial_layer = v * 2u;
				RID spatial_owner = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE3_SPATIAL_OWNER, spatial_layer, 0);
				RID spatial_sample = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE3_SPATIAL_SAMPLE, spatial_layer, 0);
				RID spatial_endpoint = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE3_SPATIAL_ENDPOINT, spatial_layer, 0);
				RID spatial_radiance = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE3_SPATIAL_RADIANCE, spatial_layer, 0);
				RID spatial_identity = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE3_SPATIAL_IDENTITY, spatial_layer, 0);
				RID spatial_meta = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE3_SPATIAL_META, spatial_layer, 0);
				RID spatial_version = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_SCREEN_PROBE_PHASE3_SPATIAL_VERSION, spatial_layer, 0);
				HDDAGIShader::ScreenProbePhase1Mode phase3_spatial_mode = HDDAGIShader::SCREEN_PROBE_PHASE3_SPATIAL;
#ifdef NVIDIA_SHARC_ENABLED
				if (sharc_active) {
					phase3_spatial_mode = HDDAGIShader::SCREEN_PROBE_PHASE3_SPATIAL_SHARC;
				}
#endif
				RID spatial_set = UniformSetCacheRD::get_singleton()->get_cache(
						hddagi_shader.screen_probe_phase1_shader_version[phase3_spatial_mode], 0,
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 0, probe_surface),
						RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 1, spatial_owner),
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 2, p_hddagi->voxel_bits_tex),
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 3, p_hddagi->voxel_region_tex),
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 4, p_hddagi->voxel_light_tex),
						RD::Uniform(RD::UNIFORM_TYPE_SAMPLER, 5, linear_sampler),
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 6, p_hddagi->voxel_light_neighbour_data),
						RD::Uniform(RD::UNIFORM_TYPE_UNIFORM_BUFFER, 7, hddagi_ubo),
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 8, p_hddagi->voxel_disocclusion_tex),
						RD::Uniform(RD::UNIFORM_TYPE_UNIFORM_BUFFER, 9, p_rbgi->scene_data_ubo),
						RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 10, screen_probe_stats_buffer),
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 11, p_hddagi->region_version_data),
						RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 12, spatial_sample),
						RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 13, spatial_endpoint),
						RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 14, spatial_radiance),
						RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 15, spatial_identity),
						RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 16, spatial_meta),
						RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 17, spatial_version),
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 18, probe_surface),
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 19, current_owner),
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 20, current_sample),
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 21, current_endpoint),
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 22, current_radiance),
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 23, current_identity),
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 24, current_meta),
						RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 25, current_version),
						RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 26, raw_probe),
						RD::Uniform(RD::UNIFORM_TYPE_SAMPLER, 27, nearest_sampler));
				RENDER_TIMESTAMP("HDDAGI Screen Probe Phase 3 Spatial Stream Merge");
				RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, hddagi_shader.screen_probe_phase1_pipeline[phase3_spatial_mode]);
				RD::get_singleton()->compute_list_bind_uniform_set(compute_list, spatial_set, 0);
				RD::get_singleton()->compute_list_bind_uniform_set(compute_list, get_phase2_sky_set(phase3_spatial_mode), 1);
#ifdef NVIDIA_SHARC_ENABLED
				if (sharc_active) {
					RD::get_singleton()->compute_list_bind_uniform_set(compute_list, sharc_phase3_spatial_parameters_set, 2);
				}
#endif
				RD::get_singleton()->compute_list_set_push_constant(compute_list, &phase3_spatial_push_constant, sizeof(phase3_spatial_push_constant));
				RD::get_singleton()->compute_list_dispatch_threads(compute_list, probe_atlas_size.x, probe_atlas_size.y, 1);
				RD::get_singleton()->compute_list_add_barrier(compute_list);
			}
		} else {
			RENDER_TIMESTAMP("HDDAGI Screen Probe Fresh Trace");
			HDDAGIShader::ScreenProbePhase1Mode trace_mode = HDDAGIShader::SCREEN_PROBE_PHASE1_TRACE;
#ifdef NVIDIA_SHARC_ENABLED
			if (sharc_active) {
				trace_mode = HDDAGIShader::SCREEN_PROBE_PHASE1_TRACE_SHARC;
			}
#endif
			RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, hddagi_shader.screen_probe_phase1_pipeline[trace_mode]);
			RID trace_set = UniformSetCacheRD::get_singleton()->get_cache(
					hddagi_shader.screen_probe_phase1_shader_version[trace_mode], 0,
					RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 0, probe_surface),
					RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 1, raw_probe),
					RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 2, p_hddagi->voxel_bits_tex),
					RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 3, p_hddagi->voxel_region_tex),
					RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 4, p_hddagi->voxel_light_tex),
					RD::Uniform(RD::UNIFORM_TYPE_SAMPLER, 5, linear_sampler),
					RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 6, p_hddagi->voxel_light_neighbour_data),
					RD::Uniform(RD::UNIFORM_TYPE_UNIFORM_BUFFER, 7, hddagi_ubo),
					RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 8, p_hddagi->voxel_disocclusion_tex),
					RD::Uniform(RD::UNIFORM_TYPE_UNIFORM_BUFFER, 9, p_rbgi->scene_data_ubo),
					RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 10, screen_probe_stats_buffer));
			RID trace_sky_set = UniformSetCacheRD::get_singleton()->get_cache(
					hddagi_shader.screen_probe_phase1_shader_version[trace_mode], 1,
					RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 0, sky_texture),
					RD::Uniform(RD::UNIFORM_TYPE_SAMPLER, 1, linear_mipmap_sampler));
			RD::get_singleton()->compute_list_bind_uniform_set(compute_list, trace_set, 0);
			RD::get_singleton()->compute_list_bind_uniform_set(compute_list, trace_sky_set, 1);
#ifdef NVIDIA_SHARC_ENABLED
			if (sharc_active) {
				RD::get_singleton()->compute_list_bind_uniform_set(compute_list, sharc_trace_parameters_set, 2);
			}
#endif
			RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(push_constant));
			RD::get_singleton()->compute_list_dispatch_threads(compute_list, probe_atlas_size.x, probe_atlas_size.y, 1);
			RD::get_singleton()->compute_list_add_barrier(compute_list);
		}

		RENDER_TIMESTAMP("HDDAGI Screen Probe Raw Resolve");
		const HDDAGIShader::ScreenProbePhase1Mode resolve_mode = reservoir_restir ? HDDAGIShader::SCREEN_PROBE_PHASE2_RESOLVE : HDDAGIShader::SCREEN_PROBE_PHASE1_RESOLVE;
		RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, hddagi_shader.screen_probe_phase1_pipeline[resolve_mode]);
		RID resolve_set = UniformSetCacheRD::get_singleton()->get_cache(
				hddagi_shader.screen_probe_phase1_shader_version[resolve_mode], 0,
				RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 0, probe_surface),
				RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 1, raw_probe),
				RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 2, p_render_buffers->get_depth_texture(v)),
				RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 3, p_normal_roughness_slices[v]),
				RD::Uniform(RD::UNIFORM_TYPE_SAMPLER, 4, linear_sampler),
				RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 5, fullres_raw),
				RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 6, current_fullres_surface),
				RD::Uniform(RD::UNIFORM_TYPE_UNIFORM_BUFFER, 7, p_rbgi->scene_data_ubo),
				RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 8, screen_probe_stats_buffer));
		RD::get_singleton()->compute_list_bind_uniform_set(compute_list, resolve_set, 0);
		RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(push_constant));
		RD::get_singleton()->compute_list_dispatch_threads(compute_list, internal_size.x, internal_size.y, 1);
		RD::get_singleton()->compute_list_add_barrier(compute_list);

#ifdef NVIDIA_NRD_ENABLED
		RID nrd_normal_roughness;
		RID nrd_current_viewz;
		RID nrd_previous_viewz;
		RID nrd_motion;
		RID nrd_input;
		const float nrd_output_radiance_scale = MAX(p_exposure_normalization, 0.000001f) * 512.0f;
		const Vector2 nrd_current_jitter_pixels = -p_taa_jitter * Vector2(float(internal_size.x), float(internal_size.y)) * 0.5f;
		const Vector2 nrd_previous_jitter_pixels = history_valid ? -p_hddagi->screen_probe_previous_taa_jitter * Vector2(float(internal_size.x), float(internal_size.y)) * 0.5f : nrd_current_jitter_pixels;
		if (nrd_requested) {
			nrd_normal_roughness = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_NRD_NORMAL_ROUGHNESS, v, 0);
			nrd_current_viewz = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_NRD_VIEWZ, v * 2u + current_history_index, 0);
			nrd_previous_viewz = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_NRD_VIEWZ, v * 2u + previous_history_index, 0);
			nrd_motion = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_NRD_MOTION, v, 0);
			nrd_input = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_NRD_INPUT, v, 0);
			HDDAGIShader::NrdPreparePushConstant nrd_prepare_push_constant = {};
			nrd_prepare_push_constant.screen_size[0] = internal_size.x;
			nrd_prepare_push_constant.screen_size[1] = internal_size.y;
			nrd_prepare_push_constant.view_index = v;
			nrd_prepare_push_constant.history_valid = history_valid ? 1u : 0u;
			nrd_prepare_push_constant.denoising_range = 500000.0f;
			// Remove the common pre-exposure and reserve ample FP16 headroom for
			// RELAX's second moments. The Apply pass restores this exact factor.
			nrd_prepare_push_constant.radiance_scale = 1.0f / nrd_output_radiance_scale;
			nrd_prepare_push_constant.current_jitter_pixels[0] = nrd_current_jitter_pixels.x;
			nrd_prepare_push_constant.current_jitter_pixels[1] = nrd_current_jitter_pixels.y;
			nrd_prepare_push_constant.previous_jitter_pixels[0] = nrd_previous_jitter_pixels.x;
			nrd_prepare_push_constant.previous_jitter_pixels[1] = nrd_previous_jitter_pixels.y;

			RENDER_TIMESTAMP("HDDAGI NRD Guide Preparation");
			RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, hddagi_shader.nrd_prepare_pipeline);
			RID nrd_prepare_set = UniformSetCacheRD::get_singleton()->get_cache(
					hddagi_shader.nrd_prepare_shader_version, 0,
					RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 0, p_render_buffers->get_depth_texture(v)),
					RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 1, p_normal_roughness_slices[v]),
					RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 2, p_render_buffers->get_velocity_buffer(false, v)),
					RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 3, nrd_previous_viewz),
					RD::Uniform(RD::UNIFORM_TYPE_SAMPLER, 4, nearest_sampler),
					RD::Uniform(RD::UNIFORM_TYPE_UNIFORM_BUFFER, 5, p_rbgi->scene_data_ubo),
					RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 6, nrd_normal_roughness),
					RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 7, nrd_current_viewz),
					RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 8, nrd_motion),
					RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 9, fullres_raw),
					RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 10, nrd_input));
			RD::get_singleton()->compute_list_bind_uniform_set(compute_list, nrd_prepare_set, 0);
			RD::get_singleton()->compute_list_set_push_constant(compute_list, &nrd_prepare_push_constant, sizeof(nrd_prepare_push_constant));
			RD::get_singleton()->compute_list_dispatch_threads(compute_list, internal_size.x, internal_size.y, 1);
			RD::get_singleton()->compute_list_add_barrier(compute_list);
		}
#endif

		RID selected_fullres = fullres_raw;
#ifdef NVIDIA_NRD_ENABLED
		// NRD owns a private compute list because its dispatch constants must all be
		// uploaded before recording. Closing this producer list also establishes the
		// raw-signal/guide dependency before NRD reads them.
		RD::get_singleton()->compute_list_end();

		if (nrd_requested) {
			const Error resize_error = p_rbgi->nrd_context.resize_view(v, internal_size);
			if (resize_error == OK) {
				NrdContextRD::CommonSettings nrd_common;
				const Projection current_view_to_clip = nrd_correction * p_projections[v];
				const Projection previous_view_to_clip = history_valid ? p_hddagi->screen_probe_previous_nrd_projection[v] : current_view_to_clip;
				RendererRD::MaterialStorage::store_camera(current_view_to_clip, nrd_common.view_to_clip);
				RendererRD::MaterialStorage::store_camera(previous_view_to_clip, nrd_common.view_to_clip_prev);
				RendererRD::MaterialStorage::store_transform(p_cam_transform.affine_inverse(), nrd_common.world_to_view);
				RendererRD::MaterialStorage::store_transform(history_valid ? p_hddagi->screen_probe_previous_cam_transform.affine_inverse() : p_cam_transform.affine_inverse(), nrd_common.world_to_view_prev);
				nrd_common.resource_size[0] = internal_size.x;
				nrd_common.resource_size[1] = internal_size.y;
				nrd_common.resource_size_prev[0] = internal_size.x;
				nrd_common.resource_size_prev[1] = internal_size.y;
				nrd_common.rect_size[0] = internal_size.x;
				nrd_common.rect_size[1] = internal_size.y;
				nrd_common.rect_size_prev[0] = internal_size.x;
				nrd_common.rect_size_prev[1] = internal_size.y;
				// Godot stores jitter as a projection translation. NRD expects the
				// corresponding sample offset, which has the opposite sign.
				nrd_common.camera_jitter[0] = nrd_current_jitter_pixels.x;
				nrd_common.camera_jitter[1] = nrd_current_jitter_pixels.y;
				nrd_common.camera_jitter_prev[0] = nrd_previous_jitter_pixels.x;
				nrd_common.camera_jitter_prev[1] = nrd_previous_jitter_pixels.y;
				// NRD requires a per-view consecutive presentation index. The global
				// rasterizer frame can jump while an UPDATE_WHEN_VISIBLE viewport is idle.
				nrd_common.frame_index = p_hddagi->screen_probe_history_sequence;
				nrd_common.denoising_range = 500000.0f;
				nrd_common.accumulation_mode = history_valid ? NrdContextRD::AccumulationMode::CONTINUE : NrdContextRD::AccumulationMode::CLEAR_AND_RESTART;

				NrdContextRD::ExternalResources nrd_resources;
				nrd_resources.motion_vectors = nrd_motion;
				nrd_resources.normal_roughness = nrd_normal_roughness;
				nrd_resources.view_z = nrd_current_viewz;
				nrd_resources.diffuse_radiance_hitdist = nrd_input;
				nrd_resources.output_diffuse_radiance_hitdist = p_render_buffers->get_texture_slice(RB_SCOPE_HDDAGI_SCREEN_PROBES, RB_TEX_HDDAGI_NRD_OUTPUT, v, 0);

				NrdContextRD::RelaxSettings nrd_relax;
				const Error common_error = p_rbgi->nrd_context.set_common_settings(v, nrd_common);
				const Error relax_error = common_error == OK ? p_rbgi->nrd_context.set_relax_settings(v, nrd_relax) : common_error;
				const Error denoise_error = relax_error == OK ? p_rbgi->nrd_context.denoise(v, nrd_resources) : relax_error;
				if (denoise_error == OK) {
					selected_fullres = nrd_resources.output_diffuse_radiance_hitdist;
					push_constant.output_radiance_scale = nrd_output_radiance_scale;
				} else {
					p_rbgi->nrd_context.clear();
					p_rbgi->nrd_permanently_disabled = true;
					WARN_PRINT_ONCE(vformat("HDDAGI NRD dispatch failed (error %d); disabling NRD for this render buffer.", denoise_error));
				}
			} else {
				if (resize_error == ERR_OUT_OF_MEMORY) {
					/* resize_view() has already released both old pools and any
					 * partial replacements. Keep its size-independent instance and
					 * pipelines so a later frame can retry without recompilation. */
					WARN_PRINT_ONCE("HDDAGI NRD pool resize ran out of memory; using the unfiltered signal and retrying on a later frame.");
				} else {
					p_rbgi->nrd_context.clear();
					p_rbgi->nrd_permanently_disabled = true;
					WARN_PRINT_ONCE(vformat("HDDAGI NRD view setup failed (error %d); disabling NRD for this render buffer.", resize_error));
				}
			}
		}

		compute_list = RD::get_singleton()->compute_list_begin();
#endif
		RENDER_TIMESTAMP("HDDAGI Screen Probe Apply");
		RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, hddagi_shader.screen_probe_phase1_pipeline[HDDAGIShader::SCREEN_PROBE_PHASE1_APPLY]);
		RID apply_set = UniformSetCacheRD::get_singleton()->get_cache(
				hddagi_shader.screen_probe_phase1_shader_version[HDDAGIShader::SCREEN_PROBE_PHASE1_APPLY], 0,
				RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 0, selected_fullres),
				RD::Uniform(RD::UNIFORM_TYPE_SAMPLER, 1, linear_sampler),
				RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 2, p_render_buffers->get_texture_slice(RB_SCOPE_GI, RB_TEX_AMBIENT_U32, v, 0)));
		RD::get_singleton()->compute_list_bind_uniform_set(compute_list, apply_set, 0);
		RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(push_constant));
		RD::get_singleton()->compute_list_dispatch_threads(compute_list, p_gi_size.x, p_gi_size.y, 1);
	}
	RD::get_singleton()->compute_list_end();

	RD::get_singleton()->draw_command_end_label();

	const uint32_t feature_flags = 1u | (p_temporal_restir ? 2u : 0u) | (p_restir_temporal_robust_mode ? 4u : 0u) | ((candidate_count - 1u) << 3u) | (p_spatial_restir ? 64u : 0u);
	const bool stats_window_complete = ((p_hddagi->screen_probe_history_sequence + 1u) % SCREEN_PROBE_STATS_READBACK_INTERVAL) == 0u;
	if (p_debug_counters && (reservoir_restir || stats_window_complete)) {
		Callable callback = callable_mp_static(&GI::_screen_probe_stats_readback).bind(push_constant.frame_index, p_view_count, internal_size.x, internal_size.y, feature_flags, algorithm_mode, uint32_t(history_valid), uint32_t(reset_generation), uint32_t(camera_cut), uint32_t(!p_taa_jitter.is_zero_approx()), p_hddagi->screen_probe_history_generation, p_hddagi->screen_probe_history_sequence, p_debug_counter_tag);
		const Error error = RD::get_singleton()->buffer_get_data_async(p_hddagi->screen_probe_stats_buffer, callback, 0, sizeof(uint32_t) * SCREEN_PROBE_STAT_COUNT);
		if (error != OK) {
			WARN_PRINT(vformat("Unable to schedule HDDAGI screen-probe GPU stats readback (error %d).", error));
			p_hddagi->screen_probe_stats_accumulating = false;
		} else if (stats_window_complete) {
			// buffer_get_data_async inserts the copy in the draw graph now. Clearing
			// afterwards starts the next independent 60-rendered-frame window without
			// racing the asynchronous CPU callback. P2 also reads the per-frame slots
			// on intervening frames; those slots are cleared at the next frame start.
			RD::get_singleton()->buffer_clear(p_hddagi->screen_probe_stats_buffer, 0, sizeof(uint32_t) * SCREEN_PROBE_STAT_COUNT);
		}
	}

	for (uint32_t v = 0; v < p_view_count; v++) {
		p_hddagi->screen_probe_previous_projection[v] = raster_correction * p_projections[v];
		p_hddagi->screen_probe_previous_temporal_projection[v] = temporal_correction * p_projections[v];
#ifdef NVIDIA_NRD_ENABLED
		p_hddagi->screen_probe_previous_nrd_projection[v] = nrd_correction * p_projections[v];
#endif
	}
	p_hddagi->screen_probe_previous_cam_transform = p_cam_transform;
	p_hddagi->screen_probe_previous_taa_jitter = p_taa_jitter;
	p_hddagi->screen_probe_previous_camera_valid = true;
}

void GI::process_hddagi_screen_probes(Ref<RenderSceneBuffersRD> p_render_buffers, const RID *p_normal_roughness_slices, RID p_environment, uint32_t p_view_count, Size2i p_gi_size, const Projection *p_projections, const Vector2 &p_taa_jitter, const Transform3D &p_cam_transform, bool p_camera_attributes_valid, float p_exposure_normalization, float p_ibl_exposure_normalization, int p_probe_size, float p_normal_bias, float p_history_blend_hit, float p_history_distance_tolerance, float p_history_direction_threshold, int p_spatial_reuse_radius, float p_spatial_normal_threshold, float p_spatial_depth_tolerance_min, float p_spatial_depth_tolerance_scale, float p_history_sample_count_max, bool p_debug_counters, uint32_t p_debug_counter_tag, bool p_reference_mode, bool p_restir_temporal_guiding, bool p_restir_spatial_guiding, int p_restir_base_candidate_count, bool p_restir_temporal_robust_mode, int p_restir_temporal_m_cap_multiplier, int p_restir_temporal_maximum_age, float p_restir_temporal_jacobian_max) {
	ERR_FAIL_COND(p_render_buffers.is_null());
	ERR_FAIL_COND(p_gi_size.x <= 0 || p_gi_size.y <= 0);
	ERR_FAIL_NULL(p_projections);

	Ref<RenderBuffersGI> rbgi = p_render_buffers->get_custom_data(RB_SCOPE_GI);
	ERR_FAIL_COND(rbgi.is_null());
	Ref<HDDAGI> hddagi = p_render_buffers->get_custom_data(RB_SCOPE_HDDAGI);
	ERR_FAIL_COND(hddagi.is_null());

	const bool modern_temporal = !p_reference_mode && p_restir_temporal_guiding;
	const bool modern_spatial = !p_reference_mode && p_restir_spatial_guiding;
	_process_hddagi_screen_probes_phase1(p_render_buffers, rbgi, hddagi, p_normal_roughness_slices, p_environment, p_view_count, p_gi_size, p_projections, p_taa_jitter, p_cam_transform, p_camera_attributes_valid, p_exposure_normalization, p_ibl_exposure_normalization, p_probe_size, p_normal_bias, p_history_blend_hit, p_history_distance_tolerance, p_history_direction_threshold, p_history_sample_count_max, p_restir_base_candidate_count, p_debug_counters, p_debug_counter_tag, p_reference_mode, modern_temporal, modern_spatial, p_spatial_reuse_radius, p_spatial_normal_threshold, p_spatial_depth_tolerance_min, p_spatial_depth_tolerance_scale, p_restir_temporal_robust_mode, p_restir_temporal_m_cap_multiplier, p_restir_temporal_maximum_age, p_restir_temporal_jacobian_max);
}
