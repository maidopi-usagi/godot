/**************************************************************************/
/*  rendering_device_texture_table.cpp                                    */
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

#include "rendering_device.h"

#include "servers/rendering/rendering_device_binds.h"

RID RenderingDevice::texture_table_create(uint32_t p_capacity, TextureType p_texture_type) {
	ERR_FAIL_COND_V(render_thread_id != Thread::get_caller_id(), RID());
	_THREAD_SAFE_METHOD_
	ERR_FAIL_COND_V_MSG(!has_feature(SUPPORTS_TEXTURE_TABLE), RID(), "Texture tables are not supported by this rendering device.");
	ERR_FAIL_COND_V(p_capacity == 0 || p_capacity > INT32_MAX || p_capacity > limit_get(LIMIT_MAX_TEXTURE_TABLE_SIZE), RID());
	ERR_FAIL_INDEX_V(p_texture_type, TEXTURE_TYPE_MAX, RID());

	ShaderUniform uniform;
	uniform.type = UNIFORM_TYPE_TEXTURE;
	uniform.texture_table = true;
	uniform.length = p_capacity;
	uniform.texture_type = p_texture_type;
	uniform.stages = TEXTURE_TABLE_SHADER_STAGES;
	UniformSetFormat format;
	format.uniforms.push_back(uniform);
	RBMap<UniformSetFormat, uint32_t>::Element *existing = uniform_set_format_cache.find(format);
	TextureTable table;
	if (existing) {
		table.format = existing->get();
	} else {
		table.format = uniform_set_format_cache.size() + 1;
		uniform_set_format_cache.insert(format, table.format);
	}
	table.texture_type = p_texture_type;
	table.textures.resize(p_capacity);
	table.frames.resize(frames.size());
	return texture_table_owner.make_rid(table);
}

void RenderingDevice::_texture_table_set_texture(RID p_table, TextureTable &p_data, uint32_t p_index, RID p_texture) {
	RID previous = p_data.textures[p_index];
	if (previous == p_texture) {
		return;
	}
	if (previous.is_valid()) {
		HashSet<uint32_t> &slots = p_data.texture_slots[previous];
		slots.erase(p_index);
		if (slots.is_empty()) {
			p_data.texture_slots.erase(previous);
			HashSet<RID> &users = texture_table_users[previous];
			users.erase(p_table);
			if (users.is_empty()) {
				texture_table_users.erase(previous);
			}
		}
	}
	p_data.textures.write[p_index] = p_texture;
	if (p_texture.is_valid()) {
		p_data.texture_slots[p_texture].insert(p_index);
		texture_table_users[p_texture].insert(p_table);
	}
	for (TextureTable::Frame &table_frame : p_data.frames) {
		table_frame.dirty_slots.insert(p_index);
	}
}

Error RenderingDevice::texture_table_set_texture(RID p_table, uint32_t p_index, RID p_texture) {
	ERR_FAIL_COND_V(render_thread_id != Thread::get_caller_id(), ERR_UNAVAILABLE);
	TextureTable *table = texture_table_owner.get_or_null(p_table);
	ERR_FAIL_NULL_V(table, ERR_INVALID_PARAMETER);
	ERR_FAIL_UNSIGNED_INDEX_V(p_index, uint32_t(table->textures.size()), ERR_INVALID_PARAMETER);
	if (p_texture.is_valid()) {
		const Texture *texture = texture_owner.get_or_null(p_texture);
		ERR_FAIL_NULL_V(texture, ERR_INVALID_PARAMETER);
		ERR_FAIL_COND_V(texture->type != table->texture_type || !(texture->usage_flags & TEXTURE_USAGE_SAMPLING_BIT), ERR_INVALID_PARAMETER);
	}
	_texture_table_set_texture(p_table, *table, p_index, p_texture);
	return OK;
}

RID RenderingDevice::texture_table_get_texture(RID p_table, uint32_t p_index) {
	ERR_FAIL_COND_V(render_thread_id != Thread::get_caller_id(), RID());
	const TextureTable *table = texture_table_owner.get_or_null(p_table);
	ERR_FAIL_NULL_V(table, RID());
	ERR_FAIL_UNSIGNED_INDEX_V(p_index, uint32_t(table->textures.size()), RID());
	return table->textures[p_index];
}

void RenderingDevice::_texture_tables_replace_texture(RID p_old_texture, RID p_new_texture) {
	const HashSet<RID> *users = texture_table_users.getptr(p_old_texture);
	if (!users) {
		return;
	}
	// The reverse index is mutated by each replacement. Copy before iterating.
	HashSet<RID> tables(*users);
	for (RID table_rid : tables) {
		TextureTable *table = texture_table_owner.get_or_null(table_rid);
		DEV_ASSERT(table);
		HashSet<uint32_t> slots(table->texture_slots[p_old_texture]);
		RID replacement = p_new_texture;
		if (replacement.is_valid()) {
			const Texture *texture = texture_owner.get_or_null(replacement);
			if (!texture || texture->type != table->texture_type || !(texture->usage_flags & TEXTURE_USAGE_SAMPLING_BIT)) {
				replacement = RID();
			}
		}
		for (uint32_t index : slots) {
			_texture_table_set_texture(table_rid, *table, index, replacement);
		}
	}
}

RID RenderingDevice::_texture_table_prepare(RID p_table, VectorView<uint32_t> p_used_indices, UniformSet &r_resources) {
	TextureTable *table = texture_table_owner.get_or_null(p_table);
	ERR_FAIL_NULL_V(table, RID());
	// Validate the complete declaration before publishing a descriptor snapshot.
	for (uint32_t i = 0; i < p_used_indices.size(); i++) {
		uint32_t index = p_used_indices[i];
		ERR_FAIL_UNSIGNED_INDEX_V(index, uint32_t(table->textures.size()), RID());
		ERR_FAIL_COND_V_MSG(table->textures[index].is_null(), RID(), "A declared texture table slot is empty.");
		const Texture *texture = texture_owner.get_or_null(table->textures[index]);
		ERR_FAIL_NULL_V(texture, RID());
		if (draw_list.active) {
			RID attachment = texture->owner.is_valid() ? texture->owner : table->textures[index];
			ERR_FAIL_COND_V_MSG(draw_list_bound_textures.has(attachment), RID(), "A texture table cannot sample an active framebuffer attachment.");
		}
	}

	TextureTable::Frame &table_frame = table->frames[frame];
	if (table_frame.last_used_frame != frames_drawn) {
		// This frame slot's fence has already been waited by _begin_frame().
		for (RID retired : table_frame.retired_uniform_sets) {
			free_rid(retired);
		}
		table_frame.retired_uniform_sets.clear();
	} else if (!table_frame.dirty_slots.is_empty() && table_frame.uniform_set.is_valid()) {
		// A command already captured this version. Keep its RID as well as its
		// driver set alive, since another binding can still refer to it this frame.
		table_frame.retired_uniform_sets.push_back(table_frame.uniform_set);
		table_frame.uniform_set = RID();
	}

	bool initialize = table_frame.uniform_set.is_null();
	if (initialize) {
		UniformSet snapshot;
		snapshot.format = table->format;
		snapshot.driver_id = driver->texture_table_create(table->textures.size());
		ERR_FAIL_COND_V(!snapshot.driver_id, RID());
		table_frame.uniform_set = uniform_set_owner.make_rid(snapshot);
	}
	UniformSet *snapshot = uniform_set_owner.get_or_null(table_frame.uniform_set);
	LocalVector<RDD::TextureTableUpdate> updates;
	auto append_update = [&](uint32_t index) {
		RID texture_rid = table->textures[index];
		if (texture_rid.is_null()) {
			// PARTIALLY_BOUND permits unused slots to remain uninitialized. Do not
			// write null descriptors, which require a separate device feature.
			return;
		}
		Texture *texture = texture_owner.get_or_null(texture_rid);
		DEV_ASSERT(texture);
		RDD::TextureID driver_id = texture->driver_id;
		if (texture->shared_fallback != nullptr && texture->shared_fallback->texture) {
			driver_id = texture->shared_fallback->texture;
		}
		updates.push_back({ index, driver_id });
	};
	if (initialize) {
		for (const KeyValue<RID, HashSet<uint32_t>> &entry : table->texture_slots) {
			for (uint32_t index : entry.value) {
				append_update(index);
			}
		}
	} else {
		for (uint32_t index : table_frame.dirty_slots) {
			append_update(index);
		}
	}
	if (!updates.is_empty()) {
		driver->texture_table_update(snapshot->driver_id, VectorView(updates.ptr(), updates.size()));
	}
	table_frame.dirty_slots.clear();
	table_frame.last_used_frame = frames_drawn;

	HashSet<RID> resources;
	for (uint32_t i = 0; i < p_used_indices.size(); i++) {
		uint32_t index = p_used_indices[i];
		RID texture_rid = table->textures[index];
		if (resources.has(texture_rid)) {
			continue;
		}
		resources.insert(texture_rid);
		Texture *texture = texture_owner.get_or_null(texture_rid);
		// Indirect reads must be tracked even when the texture was previously
		// immutable: a later upload needs to depend on this list's reads.
		if (_texture_make_mutable(texture, texture_rid)) {
			draw_graph.add_synchronization();
		}
		RDG::ResourceTracker *tracker = texture->draw_tracker;
		if (texture->shared_fallback != nullptr && texture->shared_fallback->texture) {
			tracker = texture->shared_fallback->texture_tracker;
			r_resources.shared_textures_to_update.push_back({ false, texture_rid });
		}
		if (texture->pending_clear) {
			r_resources.pending_clear_textures.push_back(texture_rid);
		}
		DEV_ASSERT(tracker);
		r_resources.draw_trackers.push_back(tracker);
		r_resources.draw_trackers_usage.push_back(RDG::RESOURCE_USAGE_TEXTURE_SAMPLE);
		_check_transfer_worker_texture(texture);
	}
	_uniform_set_update_shared(&r_resources);
	_uniform_set_update_clears(&r_resources);
	return table_frame.uniform_set;
}

void RenderingDevice::_texture_table_free(RID p_table) {
	TextureTable *table = texture_table_owner.get_or_null(p_table);
	DEV_ASSERT(table);
	for (const KeyValue<RID, HashSet<uint32_t>> &entry : table->texture_slots) {
		HashSet<RID> &users = texture_table_users[entry.key];
		users.erase(p_table);
		if (users.is_empty()) {
			texture_table_users.erase(entry.key);
		}
	}
	for (const TextureTable::Frame &table_frame : table->frames) {
		if (table_frame.uniform_set.is_valid()) {
			free_rid(table_frame.uniform_set);
		}
		for (RID retired : table_frame.retired_uniform_sets) {
			free_rid(retired);
		}
	}
	texture_table_owner.free(p_table);
}

void RenderingDevice::draw_list_bind_texture_table(DrawListID p_list, RID p_table, uint32_t p_set, VectorView<uint32_t> p_used_indices) {
	ERR_FAIL_COND(render_thread_id != Thread::get_caller_id());
	ERR_FAIL_COND(!draw_list.active || p_list != (int64_t(ID_TYPE_DRAW_LIST) << ID_BASE_SHIFT));
	ERR_FAIL_COND(p_set >= MAX_UNIFORM_SETS || p_set >= limit_get(LIMIT_MAX_BOUND_UNIFORM_SETS));
	UniformSet resources;
	RID snapshot = _texture_table_prepare(p_table, p_used_indices, resources);
	ERR_FAIL_COND(snapshot.is_null());
	draw_list_bind_uniform_set(p_list, snapshot, p_set);
	draw_graph.add_draw_list_usages(resources.draw_trackers, resources.draw_trackers_usage);
}

void RenderingDevice::compute_list_bind_texture_table(ComputeListID p_list, RID p_table, uint32_t p_set, VectorView<uint32_t> p_used_indices) {
	ERR_FAIL_COND(render_thread_id != Thread::get_caller_id());
	ERR_FAIL_COND(!compute_list.active || p_list != ID_TYPE_COMPUTE_LIST);
	ERR_FAIL_COND(p_set >= MAX_UNIFORM_SETS || p_set >= limit_get(LIMIT_MAX_BOUND_UNIFORM_SETS));
	UniformSet resources;
	RID snapshot = _texture_table_prepare(p_table, p_used_indices, resources);
	ERR_FAIL_COND(snapshot.is_null());
	compute_list_bind_uniform_set(p_list, snapshot, p_set);
	draw_graph.add_compute_list_usages(resources.draw_trackers, resources.draw_trackers_usage);
}

void RenderingDevice::raytracing_list_bind_texture_table(RaytracingListID p_list, RID p_table, uint32_t p_set, VectorView<uint32_t> p_used_indices) {
	ERR_FAIL_COND(render_thread_id != Thread::get_caller_id());
	ERR_FAIL_COND(!raytracing_list.active || p_list != ID_TYPE_RAYTRACING_LIST);
	ERR_FAIL_COND(p_set >= MAX_UNIFORM_SETS || p_set >= limit_get(LIMIT_MAX_BOUND_UNIFORM_SETS));
	UniformSet resources;
	RID snapshot = _texture_table_prepare(p_table, p_used_indices, resources);
	ERR_FAIL_COND(snapshot.is_null());
	raytracing_list_bind_uniform_set(p_list, snapshot, p_set);
	draw_graph.add_raytracing_list_usages(resources.draw_trackers, resources.draw_trackers_usage);
}

RID RenderingDevice::_shader_create_from_spirv_with_texture_table(const Ref<RDShaderSPIRV> &p_spirv, RID p_table, uint32_t p_set) {
	ERR_FAIL_COND_V(render_thread_id != Thread::get_caller_id(), RID());
	ERR_FAIL_COND_V(p_spirv.is_null(), RID());
	const TextureTable *table = texture_table_owner.get_or_null(p_table);
	ERR_FAIL_NULL_V(table, RID());
	Vector<ShaderStageSPIRVData> stages;
	for (int i = 0; i < SHADER_STAGE_MAX; i++) {
		ShaderStageSPIRVData stage;
		stage.shader_stage = ShaderStage(i);
		ERR_FAIL_COND_V_MSG(!p_spirv->get_stage_compile_error(stage.shader_stage).is_empty(), RID(), "Cannot create a shader from errored SPIR-V.");
		stage.spirv = p_spirv->get_stage_bytecode(stage.shader_stage);
		if (stage.spirv.is_empty()) {
			continue;
		}
		stage.texture_tables.push_back({ p_set, uint32_t(table->textures.size()), table->texture_type });
		stages.push_back(stage);
	}
	return shader_create_from_spirv(stages);
}

void RenderingDevice::_draw_list_bind_texture_table(DrawListID p_list, RID p_table, uint32_t p_set, const Vector<int32_t> &p_used_indices) {
	draw_list_bind_texture_table(p_list, p_table, p_set, VectorView(reinterpret_cast<const uint32_t *>(p_used_indices.ptr()), p_used_indices.size()));
}

void RenderingDevice::_compute_list_bind_texture_table(ComputeListID p_list, RID p_table, uint32_t p_set, const Vector<int32_t> &p_used_indices) {
	compute_list_bind_texture_table(p_list, p_table, p_set, VectorView(reinterpret_cast<const uint32_t *>(p_used_indices.ptr()), p_used_indices.size()));
}

void RenderingDevice::_raytracing_list_bind_texture_table(RaytracingListID p_list, RID p_table, uint32_t p_set, const Vector<int32_t> &p_used_indices) {
	raytracing_list_bind_texture_table(p_list, p_table, p_set, VectorView(reinterpret_cast<const uint32_t *>(p_used_indices.ptr()), p_used_indices.size()));
}

void RenderingDevice::_bind_texture_table_methods() {
	ClassDB::bind_method(D_METHOD("texture_table_create", "capacity", "texture_type"), &RenderingDevice::texture_table_create, DEFVAL(TEXTURE_TYPE_2D));
	ClassDB::bind_method(D_METHOD("texture_table_set_texture", "table", "index", "texture"), &RenderingDevice::texture_table_set_texture);
	ClassDB::bind_method(D_METHOD("texture_table_get_texture", "table", "index"), &RenderingDevice::texture_table_get_texture);
	ClassDB::bind_method(D_METHOD("shader_create_from_spirv_with_texture_table", "spirv_data", "table", "set"), &RenderingDevice::_shader_create_from_spirv_with_texture_table, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("draw_list_bind_texture_table", "draw_list", "table", "set", "used_indices"), &RenderingDevice::_draw_list_bind_texture_table);
	ClassDB::bind_method(D_METHOD("compute_list_bind_texture_table", "compute_list", "table", "set", "used_indices"), &RenderingDevice::_compute_list_bind_texture_table);
	ClassDB::bind_method(D_METHOD("raytracing_list_bind_texture_table", "raytracing_list", "table", "set", "used_indices"), &RenderingDevice::_raytracing_list_bind_texture_table);
	BIND_ENUM_CONSTANT(SUPPORTS_TEXTURE_TABLE);
	BIND_ENUM_CONSTANT(LIMIT_MAX_TEXTURE_TABLE_SIZE);
}
