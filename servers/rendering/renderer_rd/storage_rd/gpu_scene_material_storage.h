/**************************************************************************/
/*  gpu_scene_material_storage.h                                          */
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

#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"

namespace RendererRD {

// Stable, shared material indices for ray queries and SBT hit shaders. Geometry
// owns references, while texture residency and parameter uploads are independent.
class GPUSceneMaterialStorage {
public:
	static constexpr uint32_t INVALID_INDEX = UINT32_MAX;
	static constexpr uint32_t TEXTURE_SET = 4;
	static uint32_t get_texture_capacity();
	struct MaterialData {
		float albedo_metallic[4] = {};
		float emission_energy[4] = {};
		float uv_scale_offset[4] = {};
		float metallic_channel[4] = {};
		uint32_t textures_sampler[4] = {};
		uint32_t flags[4] = {};
	};
	static_assert(sizeof(MaterialData) == 96);

private:
	struct ParameterRange {
		uint32_t offset = 0;
		uint32_t count = 0;
		bool operator<(const ParameterRange &p_other) const { return offset < p_other.offset; }
	};
	struct Program {
		String code;
		String function;
		uint32_t index = 0;
		uint32_t references = 0;
		bool operator<(const Program &p_other) const { return index < p_other.index; }
	};
	struct Material {
		MaterialStorage::RayTracingMaterialData source;
		RID textures[3]; // Resolved RD views, including sRGB and proxy replacements.
		uint64_t texture_versions[3] = {};
		uint32_t index = INVALID_INDEX;
		uint32_t references = 0;
		uint64_t version = 0;
		bool valid = false;
		String program_code;
		ParameterRange parameters;
		Vector<RID> program_textures;
		Vector<uint64_t> program_texture_versions;
	};
	struct Texture {
		uint32_t index = INVALID_INDEX;
		uint32_t references = 0;
	};
	HashMap<RID, Material> materials;
	HashMap<String, Program> programs;
	LocalVector<uint32_t> parameter_data;
	LocalVector<ParameterRange> free_parameters;
	LocalVector<ParameterRange> dirty_parameters;
	uint32_t next_program = 1; // Zero selects the built-in material evaluator.
	uint64_t programs_version = 0;
	uint64_t source_version = 0;
	String program_source;
	RID parameter_buffer;
	uint32_t parameter_capacity = 0;
	bool used_time = false;
	HashMap<RID, Texture> textures;
	LocalVector<MaterialData> data;
	LocalVector<uint32_t> free_materials;
	LocalVector<uint32_t> free_textures;
	LocalVector<uint32_t> used_textures;
	HashSet<uint32_t> used_texture_set;
	HashSet<uint32_t> invalid_materials;
	HashSet<uint32_t> dirty_materials;
	uint32_t texture_count = 0;
	uint32_t buffer_capacity = 0;
	RID buffer;
	RID texture_table;
	bool changed = false;
	bool buffer_dirty = false;
	uint32_t _acquire_texture(RID p_texture);
	void _release_texture(RID p_texture);
	bool _update_material(RID p_material, Material &r_material);
	void _release_program(Material &r_material);
	bool _update_program(Material &r_material, bool p_parameters_changed);

public:
	bool initialize();
	uint32_t acquire_material(RID p_material);
	void release_material(RID p_material);
	bool is_material_valid(uint32_t p_index) const { return p_index == INVALID_INDEX || !invalid_materials.has(p_index); }
	void update();
	void mark_used(uint32_t p_index);
	Error flush(bool &r_changed);
	RID get_buffer() const { return buffer; }
	RID get_parameter_buffer() const { return parameter_buffer; }
	const String &get_program_source();
	bool uses_time() const { return used_time; }
	void append_samplers(LocalVector<RD::Uniform> &r_uniforms, uint32_t p_binding, const MaterialStorage::Samplers &p_samplers) const;
	void bind(RD::ComputeListID p_list) const;
	void bind_raytracing(RD::RaytracingListID p_list) const;
	void free();
};

} // namespace RendererRD
