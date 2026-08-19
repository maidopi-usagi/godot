/**************************************************************************/
/*  nrd_context_rd.h                                                      */
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

#ifndef NRD_CONTEXT_RD_H
#define NRD_CONTEXT_RD_H

#include "servers/rendering/rendering_device.h"

// RenderingDevice-only integration of NVIDIA NRD. This class intentionally
// does not expose NRD types, so callers and non-NRD builds use the same ABI.
// One NrdContextRD owns any number of independent view histories.
class NrdContextRD {
public:
	enum class AccumulationMode : uint8_t {
		CONTINUE,
		RESTART,
		CLEAR_AND_RESTART,
	};

	enum class CheckerboardMode : uint8_t {
		OFF,
		BLACK,
		WHITE,
	};

	enum class HitDistanceReconstructionMode : uint8_t {
		OFF,
		AREA_3X3,
		AREA_5X5,
	};

	struct CommonSettings {
		// NRD matrices are column-major, non-jittered and multiply column vectors.
		float view_to_clip[16] = {};
		float view_to_clip_prev[16] = {};
		float world_to_view[16] = {};
		float world_to_view_prev[16] = {};

		float motion_vector_scale[3] = { 1.0f, 1.0f, 1.0f };
		float camera_jitter[2] = {};
		float camera_jitter_prev[2] = {};

		// Zero sizes are filled from the view allocation by denoise(). Rect sizes
		// may be smaller than resource sizes for dynamic resolution.
		uint16_t resource_size[2] = {};
		uint16_t resource_size_prev[2] = {};
		uint16_t rect_size[2] = {};
		uint16_t rect_size_prev[2] = {};

		float view_z_scale = 1.0f;
		float time_delta_between_frames_ms = 0.0f;
		float denoising_range = 500000.0f;
		float disocclusion_threshold = 0.01f;
		float disocclusion_threshold_alternate = 0.05f;
		float split_screen = 0.0f;

		uint32_t frame_index = 0;
		AccumulationMode accumulation_mode = AccumulationMode::CONTINUE;
		bool motion_vectors_in_world_space = false;
		bool enable_validation = false;
	};

	struct RelaxSettings {
		float antilag_acceleration_amount = 0.3f;
		float antilag_spatial_sigma_scale = 4.5f;
		float antilag_temporal_sigma_scale = 0.5f;
		float antilag_reset_amount = 0.5f;

		uint32_t diffuse_max_accumulated_frame_num = 30;
		uint32_t diffuse_max_fast_accumulated_frame_num = 6;
		uint32_t history_fix_frame_num = 3;
		uint32_t history_fix_base_pixel_stride = 14;
		uint32_t history_fix_alternate_pixel_stride = 14;
		float history_fix_edge_stopping_normal_power = 8.0f;
		float fast_history_clamping_sigma_scale = 2.0f;
		float diffuse_prepass_blur_radius = 30.0f;
		float min_hit_distance_weight = 0.1f;
		uint32_t spatial_variance_estimation_history_threshold = 3;
		float diffuse_phi_luminance = 2.0f;
		float lobe_angle_fraction = 0.5f;
		float roughness_fraction = 0.15f;
		uint32_t atrous_iteration_num = 5;
		float diffuse_min_luminance_weight = 0.0f;
		float depth_threshold = 0.003f;
		float confidence_driven_relaxation_multiplier = 0.0f;
		float confidence_driven_luminance_edge_stopping_relaxation = 0.0f;
		float confidence_driven_normal_edge_stopping_relaxation = 0.0f;
		CheckerboardMode checkerboard_mode = CheckerboardMode::OFF;
		HitDistanceReconstructionMode hit_distance_reconstruction_mode = HitDistanceReconstructionMode::OFF;
		float min_material_for_diffuse = 4.0f;
		bool enable_anti_firefly = false;
		bool enable_roughness_edge_stopping = true;
	};

	struct ExternalResources {
		// RGBA16F, prev-current. Z is previous viewZ-current viewZ.
		RID motion_vectors;
		// RGBA8_UNORM packed through NRD_FrontEnd_PackNormalAndRoughness.
		RID normal_roughness;
		// R32F positive linear view depth. Sky pixels must be greater than the
		// configured denoising range.
		RID view_z;
		// RGBA16F or RGBA32F: demodulated diffuse radiance in rgb and raw
		// RELAX hit distance in alpha.
		RID diffuse_radiance_hitdist;
		// RGBA16F sampled + storage output (rgb = denoised signal, a = RELAX hit
		// distance). RELAX writes this texture and reads it again in later passes.
		// It must not alias an input-only texture view.
		RID output_diffuse_radiance_hitdist;
		// Optional RGBA8_UNORM storage output used when validation is enabled.
		RID validation;
	};

	static bool is_available();

	// Existing views retain their size-independent instance and pipelines. If
	// pool allocation runs out of memory, the view remains available for a
	// later resize retry but cannot denoise until that retry succeeds.
	Error resize_view(uint32_t p_view_id, const Size2i &p_size);
	void remove_view(uint32_t p_view_id);
	void clear();

	bool has_view(uint32_t p_view_id) const;
	Size2i get_view_size(uint32_t p_view_id) const;

	Error set_common_settings(uint32_t p_view_id, const CommonSettings &p_settings);
	Error set_relax_settings(uint32_t p_view_id, const RelaxSettings &p_settings);
	void reset_history(uint32_t p_view_id, bool p_clear_resources = false);

	// Uploads all per-dispatch constants before opening its private compute list,
	// records the complete RELAX_DIFFUSE graph and closes the list before return.
	// Must be called while no draw or compute list is active.
	Error denoise(uint32_t p_view_id, const ExternalResources &p_resources);

	NrdContextRD();
	~NrdContextRD();

	NrdContextRD(const NrdContextRD &) = delete;
	NrdContextRD &operator=(const NrdContextRD &) = delete;

private:
	struct Implementation;
	Implementation *implementation = nullptr;
};

#endif // NRD_CONTEXT_RD_H
