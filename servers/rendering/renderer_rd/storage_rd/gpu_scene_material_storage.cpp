/**************************************************************************/
/*  gpu_scene_material_storage.cpp                                        */
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

#include "gpu_scene_material_storage.h"

#include "servers/rendering/renderer_rd/storage_rd/texture_storage.h"

using namespace RendererRD;

uint32_t GPUSceneMaterialStorage::get_texture_capacity() {
	RD *rd = RD::get_singleton();
	if (!rd || !rd->has_feature(RD::SUPPORTS_TEXTURE_TABLE) || rd->limit_get(RD::LIMIT_MAX_BOUND_UNIFORM_SETS) <= TEXTURE_SET) {
		return 0;
	}
	// Update-after-bind pipeline limits also count the ordinary scene, sky and
	// irradiance-cache descriptors. Keep room for those alongside the table.
	constexpr uint32_t reserved_descriptors = 128;
	const uint32_t limit = rd->limit_get(RD::LIMIT_MAX_TEXTURE_TABLE_SIZE);
	return limit > reserved_descriptors ? MIN(16384u, limit - reserved_descriptors) : 0;
}

bool GPUSceneMaterialStorage::initialize() {
	if (texture_table.is_valid()) {
		return true;
	}
	const uint32_t capacity = get_texture_capacity();
	if (capacity == 0) {
		return false;
	}
	texture_table = RD::get_singleton()->texture_table_create(capacity);
	return texture_table.is_valid();
}

uint32_t GPUSceneMaterialStorage::_acquire_texture(RID p_texture) {
	Texture *existing = textures.getptr(p_texture);
	if (existing) {
		// RD clears a freed/replaced view from a table. Restore the descriptor even
		// when the engine preserved the RID during a proxy or streamed image swap.
		if (RD::get_singleton()->texture_table_set_texture(texture_table, existing->index, p_texture) != OK) {
			return INVALID_INDEX;
		}
		existing->references++;
		return existing->index;
	}
	uint32_t index;
	if (!free_textures.is_empty()) {
		index = free_textures[free_textures.size() - 1];
		free_textures.resize(free_textures.size() - 1);
	} else {
		if (texture_count == get_texture_capacity()) {
			return INVALID_INDEX;
		}
		index = texture_count++;
	}
	if (RD::get_singleton()->texture_table_set_texture(texture_table, index, p_texture) != OK) {
		free_textures.push_back(index);
		return INVALID_INDEX;
	}
	textures.insert(p_texture, { index, 1 });
	return index;
}

void GPUSceneMaterialStorage::_release_texture(RID p_texture) {
	if (p_texture.is_null()) {
		return;
	}
	Texture *texture = textures.getptr(p_texture);
	DEV_ASSERT(texture);
	if (--texture->references == 0) {
		RD::get_singleton()->texture_table_set_texture(texture_table, texture->index, RID());
		free_textures.push_back(texture->index);
		textures.erase(p_texture);
	}
}

bool GPUSceneMaterialStorage::_update_material(RID p_material, Material &r_material) {
	MaterialStorage *storage = MaterialStorage::get_singleton();
	const uint64_t version = storage->material_get_data_version(p_material);
	const bool parameters_changed = !r_material.valid || version != r_material.version;
	if (parameters_changed && !storage->material_get_raytracing_data(p_material, r_material.source)) {
		return false;
	}
	if (!r_material.source.program_code.is_empty()) {
		if (!_update_program(r_material, parameters_changed)) {
			return false;
		}
		r_material.version = version;
		return true;
	}
	_release_program(r_material);
	TextureStorage *texture_storage = TextureStorage::get_singleton();
	RID resolved[3];
	bool textures_changed = !r_material.valid;
	for (uint32_t i = 0; i < 3; i++) {
		// Viewport textures can be the current render target; leave those materials
		// on the capture path rather than introduce a read/write feedback loop.
		if (texture_storage->texture_is_render_target(r_material.source.textures[i]) || texture_storage->texture_get_type(r_material.source.textures[i]) != TextureStorage::TYPE_2D) {
			return false;
		}
		resolved[i] = texture_storage->texture_get_rd_texture(r_material.source.textures[i], i != 1);
		if (resolved[i].is_null()) {
			resolved[i] = texture_storage->texture_rd_get_default(i == 2 ? TextureStorage::DEFAULT_RD_TEXTURE_BLACK : TextureStorage::DEFAULT_RD_TEXTURE_WHITE);
		}
		textures_changed |= resolved[i] != r_material.textures[i];
		const uint64_t texture_version = texture_storage->texture_get_data_version(r_material.source.textures[i]);
		changed |= texture_version != r_material.texture_versions[i];
		r_material.texture_versions[i] = texture_version;
	}
	if (!parameters_changed && !textures_changed) {
		// Native replacement may retain the RD RID but clear its table slot.
		for (uint32_t i = 0; i < 3; i++) {
			const uint32_t slot = data[r_material.index].textures_sampler[i];
			if (RD::get_singleton()->texture_table_get_texture(texture_table, slot) != resolved[i]) {
				RD::get_singleton()->texture_table_set_texture(texture_table, slot, resolved[i]);
				changed = true;
			}
		}
		return true;
	}
	uint32_t slots[3];
	for (uint32_t i = 0; i < 3; i++) {
		slots[i] = _acquire_texture(resolved[i]);
		if (slots[i] == INVALID_INDEX) {
			for (uint32_t j = 0; j < i; j++) {
				_release_texture(resolved[j]);
			}
			WARN_PRINT_ONCE("GPU scene texture table is full; using material capture for additional materials.");
			return false;
		}
	}
	for (uint32_t i = 0; i < 3; i++) {
		_release_texture(r_material.textures[i]);
		r_material.textures[i] = resolved[i];
	}
	MaterialData &gpu = data[r_material.index];
	gpu = MaterialData();
	const MaterialStorage::RayTracingMaterialData &source = r_material.source;
	for (uint32_t i = 0; i < 3; i++) {
		gpu.albedo_metallic[i] = source.albedo[i];
		gpu.emission_energy[i] = source.emission[i];
		gpu.textures_sampler[i] = slots[i];
	}
	gpu.albedo_metallic[3] = source.metallic;
	gpu.emission_energy[3] = source.emission_energy;
	gpu.uv_scale_offset[0] = source.uv_scale.x;
	gpu.uv_scale_offset[1] = source.uv_scale.y;
	gpu.uv_scale_offset[2] = source.uv_offset.x;
	gpu.uv_scale_offset[3] = source.uv_offset.y;
	for (uint32_t i = 0; i < 4; i++) {
		gpu.metallic_channel[i] = source.metallic_channel[i];
	}
	gpu.textures_sampler[3] = source.sampler;
	gpu.flags[0] = source.emission_multiply ? 1 : 0;
	r_material.version = version;
	changed = true;
	dirty_materials.insert(r_material.index);
	return true;
}

void GPUSceneMaterialStorage::_release_program(Material &r_material) {
	for (RID texture : r_material.program_textures) {
		_release_texture(texture);
	}
	r_material.program_textures.clear();
	r_material.program_texture_versions.clear();
	if (!r_material.program_code.is_empty()) {
		Program *program = programs.getptr(r_material.program_code);
		DEV_ASSERT(program);
		if (--program->references == 0) {
			programs.erase(r_material.program_code);
			programs_version++;
		}
		r_material.program_code = String();
	}
	if (r_material.parameters.count) {
		free_parameters.push_back(r_material.parameters);
		free_parameters.sort();
		// Merge adjacent blocks so editing a shader's uniform layout does not
		// continually grow the parameter buffer.
		for (uint32_t i = 1; i < free_parameters.size();) {
			ParameterRange &previous = free_parameters[i - 1];
			if (previous.offset + previous.count == free_parameters[i].offset) {
				previous.count += free_parameters[i].count;
				free_parameters.remove_at(i);
			} else {
				i++;
			}
		}
		r_material.parameters = ParameterRange();
	}
}

bool GPUSceneMaterialStorage::_update_program(Material &r_material, bool p_parameters_changed) {
	const MaterialStorage::RayTracingMaterialData &source = r_material.source;
	TextureStorage *texture_storage = TextureStorage::get_singleton();
	bool supported = true;
	auto resolve_texture = [&](const MaterialStorage::RayTracingMaterialData::Texture &p_texture) {
		if (p_texture.texture.is_valid() && (texture_storage->texture_is_render_target(p_texture.texture) || texture_storage->texture_get_type(p_texture.texture) != TextureStorage::TYPE_2D)) {
			supported = false;
			return RID();
		}
		RID texture = texture_storage->texture_get_rd_texture(p_texture.texture, p_texture.srgb);
		return texture.is_valid() ? texture : p_texture.fallback;
	};
	const int program_texture_count = source.program_textures.size();
	bool views_changed = r_material.program_textures.size() != program_texture_count;
	bool contents_changed = false;
	for (int i = 0; i < program_texture_count; i++) {
		const RID texture = resolve_texture(source.program_textures[i]);
		if (!supported) {
			return false;
		}
		views_changed |= i >= r_material.program_textures.size() || texture != r_material.program_textures[i];
		const uint64_t version = texture_storage->texture_get_data_version(source.program_textures[i].texture);
		contents_changed |= i >= r_material.program_texture_versions.size() || version != r_material.program_texture_versions[i];
	}
	if (!p_parameters_changed && !views_changed) {
		// Texture content and proxy/view replacement are independent of material
		// parameter versions. Warm frames need no allocations or parameter upload.
		for (int i = 0; i < program_texture_count; i++) {
			const uint32_t slot = parameter_data[r_material.parameters.offset + source.program_texture_word + i * 2];
			if (RD::get_singleton()->texture_table_get_texture(texture_table, slot) != r_material.program_textures[i]) {
				if (RD::get_singleton()->texture_table_set_texture(texture_table, slot, r_material.program_textures[i]) != OK) {
					return false;
				}
				contents_changed = true;
			}
			r_material.program_texture_versions.write[i] = texture_storage->texture_get_data_version(source.program_textures[i].texture);
		}
		changed |= contents_changed;
		return true;
	}
	Vector<RID> resolved;
	LocalVector<uint32_t> slots;
	ERR_FAIL_COND_V(r_material.program_code != source.program_code && !programs.has(source.program_code) && next_program == UINT32_MAX, false);
	for (int i = 0; i < program_texture_count; i++) {
		const RID texture = resolve_texture(source.program_textures[i]);
		const uint32_t slot = _acquire_texture(texture);
		if (slot == INVALID_INDEX) {
			for (RID acquired : resolved) {
				_release_texture(acquired);
			}
			WARN_PRINT_ONCE("GPU scene texture table is full; procedural texture materials use capture when eligible.");
			return false;
		}
		resolved.push_back(texture);
		slots.push_back(slot);
	}
	const uint32_t words = source.program_parameters.size() / sizeof(uint32_t);
	if (r_material.program_code != source.program_code) {
		_release_program(r_material);
		Program *program = programs.getptr(source.program_code);
		if (!program) {
			ERR_FAIL_COND_V(next_program == UINT32_MAX, false);
			Program next;
			next.code = source.program_code;
			next.function = source.program_function;
			next.index = next_program++;
			programs.insert(next.code, next);
			program = programs.getptr(source.program_code);
			programs_version++;
		}
		program->references++;
		r_material.program_code = source.program_code;
	} else {
		for (RID texture : r_material.program_textures) {
			_release_texture(texture);
		}
	}
	r_material.program_textures = resolved;
	r_material.program_texture_versions.resize(program_texture_count);
	if (words && !r_material.parameters.count) {
		for (uint32_t i = 0; i < free_parameters.size(); i++) {
			ParameterRange &range = free_parameters[i];
			if (range.count >= words) {
				r_material.parameters = { range.offset, words };
				range.offset += words;
				range.count -= words;
				if (!range.count) {
					free_parameters.remove_at(i);
				}
				break;
			}
		}
		if (!r_material.parameters.count) {
			ERR_FAIL_COND_V(uint64_t(parameter_data.size()) + words > UINT32_MAX / sizeof(uint32_t), false);
			r_material.parameters = { parameter_data.size(), words };
			parameter_data.resize(parameter_data.size() + words);
		}
	}
	DEV_ASSERT(r_material.parameters.count == words);
	if (words) {
		memcpy(parameter_data.ptr() + r_material.parameters.offset, source.program_parameters.ptr(), words * sizeof(uint32_t));
		for (int i = 0; i < program_texture_count; i++) {
			const uint32_t word = r_material.parameters.offset + source.program_texture_word + i * 2;
			parameter_data[word] = slots[i];
			parameter_data[word + 1] = source.program_textures[i].sampler;
			r_material.program_texture_versions.write[i] = texture_storage->texture_get_data_version(source.program_textures[i].texture);
		}
		dirty_parameters.push_back(r_material.parameters);
	}
	for (RID &texture : r_material.textures) {
		_release_texture(texture);
		texture = RID();
	}
	memset(r_material.texture_versions, 0, sizeof(r_material.texture_versions));
	MaterialData &gpu = data[r_material.index];
	gpu = MaterialData();
	gpu.flags[1] = programs[source.program_code].index;
	gpu.flags[2] = r_material.parameters.offset;
	gpu.flags[3] = source.program_uses_time ? 1 : 0;
	gpu.textures_sampler[0] = r_material.parameters.offset + source.program_texture_word;
	gpu.textures_sampler[1] = program_texture_count;
	dirty_materials.insert(r_material.index);
	changed = true;
	return true;
}

const String &GPUSceneMaterialStorage::get_program_source() {
	if (programs_version == source_version) {
		return program_source;
	}
	source_version = programs_version;
	program_source = String();
	if (programs.is_empty()) {
		return program_source;
	}
	LocalVector<Program> ordered;
	for (const KeyValue<String, Program> &entry : programs) {
		ordered.push_back(entry.value);
	}
	ordered.sort();
	String dispatch = "bool gpu_scene_evaluate_custom(GPUSceneMaterial material, vec2 uv, mat2 gradients, vec3 scene, out vec3 albedo, out vec3 emission) {\nswitch (material.flags.y) {\n";
	for (const Program &program : ordered) {
		program_source += program.code;
		dispatch += "case " + itos(program.index) + "u: " + program.function + "(material.flags.z, uv, gradients, scene, albedo, emission); return true;\n";
	}
	program_source += dispatch + "default: return false;\n}\n}\n";
	return program_source;
}

uint32_t GPUSceneMaterialStorage::acquire_material(RID p_material) {
	Material *existing = materials.getptr(p_material);
	if (existing) {
		if (!existing->valid) {
			return INVALID_INDEX;
		}
		existing->references++;
		return existing->index;
	}
	Material material;
	if (!free_materials.is_empty()) {
		material.index = free_materials[free_materials.size() - 1];
		free_materials.resize(free_materials.size() - 1);
	} else {
		material.index = data.size();
		data.push_back(MaterialData());
	}
	if (!_update_material(p_material, material)) {
		_release_program(material);
		free_materials.push_back(material.index);
		return INVALID_INDEX;
	}
	material.valid = true;
	material.references = 1;
	materials.insert(p_material, material);
	invalid_materials.erase(material.index);
	return material.index;
}

void GPUSceneMaterialStorage::release_material(RID p_material) {
	Material *material = materials.getptr(p_material);
	DEV_ASSERT(material);
	if (--material->references == 0) {
		_release_program(*material);
		for (RID texture : material->textures) {
			_release_texture(texture);
		}
		free_materials.push_back(material->index);
		invalid_materials.erase(material->index);
		materials.erase(p_material);
	}
}

void GPUSceneMaterialStorage::update() {
	used_time = false;
	used_textures.clear();
	used_texture_set.clear();
	for (KeyValue<RID, Material> &entry : materials) {
		const bool was_valid = entry.value.valid;
		entry.value.valid = _update_material(entry.key, entry.value);
		changed |= was_valid != entry.value.valid;
		if (entry.value.valid) {
			invalid_materials.erase(entry.value.index);
		} else {
			invalid_materials.insert(entry.value.index);
		}
	}
}

void GPUSceneMaterialStorage::mark_used(uint32_t p_index) {
	if (p_index == INVALID_INDEX) {
		return;
	}
	DEV_ASSERT(is_material_valid(p_index));
	if (data[p_index].flags[1]) {
		used_time |= data[p_index].flags[3] != 0;
		for (uint32_t i = 0; i < data[p_index].textures_sampler[1]; i++) {
			const uint32_t slot = parameter_data[data[p_index].textures_sampler[0] + i * 2];
			if (!used_texture_set.has(slot)) {
				used_texture_set.insert(slot);
				used_textures.push_back(slot);
			}
		}
		return;
	}
	for (uint32_t i = 0; i < 3; i++) {
		const uint32_t slot = data[p_index].textures_sampler[i];
		if (!used_texture_set.has(slot)) {
			used_texture_set.insert(slot);
			used_textures.push_back(slot);
		}
	}
}

Error GPUSceneMaterialStorage::flush(bool &r_changed) {
	r_changed = false;
	RD *rd = RD::get_singleton();
	bool all_parameters = false;
	if (MAX(1u, parameter_data.size()) > parameter_capacity) {
		const uint64_t capacity = Math::nearest_power_of_2_templated(uint64_t(MAX(16u, parameter_data.size())));
		ERR_FAIL_COND_V(capacity * sizeof(uint32_t) > UINT32_MAX, ERR_OUT_OF_MEMORY);
		RID next = rd->storage_buffer_create(uint32_t(capacity) * sizeof(uint32_t));
		ERR_FAIL_COND_V(next.is_null(), ERR_OUT_OF_MEMORY);
		if (parameter_buffer.is_valid()) {
			rd->free_rid(parameter_buffer);
		}
		parameter_buffer = next;
		parameter_capacity = uint32_t(capacity);
		all_parameters = true;
		changed = true;
	}
	if (all_parameters && !parameter_data.is_empty()) {
		const Error error = rd->buffer_update(parameter_buffer, 0, parameter_data.size() * sizeof(uint32_t), parameter_data.ptr());
		ERR_FAIL_COND_V(error != OK, error);
	} else if (!dirty_parameters.is_empty()) {
		dirty_parameters.sort();
		for (uint32_t i = 0; i < dirty_parameters.size();) {
			const uint32_t first = dirty_parameters[i].offset;
			uint32_t end = first + dirty_parameters[i++].count;
			while (i < dirty_parameters.size() && dirty_parameters[i].offset <= end) {
				end = MAX(end, dirty_parameters[i].offset + dirty_parameters[i].count);
				i++;
			}
			const Error error = rd->buffer_update(parameter_buffer, first * sizeof(uint32_t), (end - first) * sizeof(uint32_t), parameter_data.ptr() + first);
			ERR_FAIL_COND_V(error != OK, error);
		}
	}
	dirty_parameters.clear();
	if (MAX(1u, data.size()) > buffer_capacity) {
		const uint64_t next_capacity = Math::nearest_power_of_2_templated(uint64_t(MAX(16u, data.size())));
		ERR_FAIL_COND_V(next_capacity * sizeof(MaterialData) > UINT32_MAX, ERR_OUT_OF_MEMORY);
		RID next = rd->storage_buffer_create(uint32_t(next_capacity) * sizeof(MaterialData));
		ERR_FAIL_COND_V(next.is_null(), ERR_OUT_OF_MEMORY);
		if (buffer.is_valid()) {
			rd->free_rid(buffer);
		}
		buffer = next;
		buffer_capacity = uint32_t(next_capacity);
		changed = true;
		buffer_dirty = true;
	}
	if (!changed) {
		return OK;
	}
	if (buffer_dirty && !data.is_empty()) {
		const Error error = rd->buffer_update(buffer, 0, data.size() * sizeof(MaterialData), data.ptr());
		ERR_FAIL_COND_V(error != OK, error);
	} else if (!dirty_materials.is_empty()) {
		LocalVector<uint32_t> indices;
		indices.reserve(dirty_materials.size());
		for (uint32_t index : dirty_materials) {
			indices.push_back(index);
		}
		indices.sort();
		// Upload adjacent dirty records together. An animated material should not
		// upload every retained material in a large scene on each frame.
		for (uint32_t i = 0; i < indices.size();) {
			const uint32_t first = indices[i++];
			uint32_t end = first + 1;
			while (i < indices.size() && indices[i] == end) {
				i++;
				end++;
			}
			const Error error = rd->buffer_update(buffer, first * sizeof(MaterialData), (end - first) * sizeof(MaterialData), data.ptr() + first);
			ERR_FAIL_COND_V(error != OK, error);
		}
	}
	dirty_materials.clear();
	changed = false;
	buffer_dirty = false;
	r_changed = true;
	return OK;
}

void GPUSceneMaterialStorage::append_samplers(LocalVector<RD::Uniform> &r_uniforms, uint32_t p_binding, const MaterialStorage::Samplers &p_samplers) const {
	RD::Uniform uniform;
	uniform.uniform_type = RD::UNIFORM_TYPE_SAMPLER;
	uniform.binding = p_binding;
	for (uint32_t i = 0; i < 12; i++) {
		uniform.append_id(p_samplers.get_sampler(
				RSE::CanvasItemTextureFilter(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST + (i & 1) + (i / 4) * 2),
				i & 2 ? RSE::CANVAS_ITEM_TEXTURE_REPEAT_ENABLED : RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED));
	}
	r_uniforms.push_back(uniform);
}

void GPUSceneMaterialStorage::bind(RD::ComputeListID p_list) const {
	RD::get_singleton()->compute_list_bind_texture_table(p_list, texture_table, TEXTURE_SET, used_textures);
}

void GPUSceneMaterialStorage::bind_raytracing(RD::RaytracingListID p_list) const {
	RD::get_singleton()->raytracing_list_bind_texture_table(p_list, texture_table, TEXTURE_SET, used_textures);
}

void GPUSceneMaterialStorage::free() {
	for (RID resource : { buffer, texture_table, parameter_buffer }) {
		if (resource.is_valid()) {
			RD::get_singleton()->free_rid(resource);
		}
	}
	buffer = RID();
	texture_table = RID();
	parameter_buffer = RID();
	parameter_capacity = 0;
	parameter_data.clear();
	free_parameters.clear();
	dirty_parameters.clear();
	programs.clear();
	program_source = String();
	next_program = 1;
	programs_version = 0;
	source_version = 0;
	used_time = false;
	materials.clear();
	textures.clear();
	data.clear();
	free_materials.clear();
	free_textures.clear();
	used_textures.clear();
	used_texture_set.clear();
	invalid_materials.clear();
	dirty_materials.clear();
	texture_count = 0;
	buffer_capacity = 0;
	changed = false;
	buffer_dirty = false;
}
