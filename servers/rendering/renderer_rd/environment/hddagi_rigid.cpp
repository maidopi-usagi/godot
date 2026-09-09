/**************************************************************************/
/*  hddagi_rigid.cpp                                                       */
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

#include "hddagi_rigid.h"

#include "core/string/print_string.h"
#include "servers/rendering/renderer_rd/renderer_scene_render_rd.h"
#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"
#include "servers/rendering/renderer_rd/storage_rd/mesh_storage.h"
#include "servers/rendering/renderer_rd/storage_rd/render_scene_buffers_rd.h"
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"

using namespace RendererRD;

void HDDAGIRigid::Pool::reserve(uint32_t p_count) {
	if (p_count <= capacity) {
		return;
	}
	RD *rd = RD::get_singleton();
	uint32_t new_capacity = Math::nearest_power_of_2_templated(MAX(p_count, 16u));
	RID next = rd->storage_buffer_create(new_capacity * stride, {}, indirect ? RD::STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT : 0);
	rd->buffer_clear(next, 0, new_capacity * stride);
	if (buffer.is_valid()) {
		rd->buffer_copy(buffer, next, 0, 0, capacity * stride);
		rd->free_rid(buffer);
	}
	buffer = next;
	capacity = new_capacity;
}

HDDAGIRigid::Range HDDAGIRigid::Pool::allocate(uint32_t p_count) {
	for (uint32_t i = 0; i < free_ranges.size(); i++) {
		if (free_ranges[i].count >= p_count) {
			Range result{ free_ranges[i].offset, p_count };
			free_ranges[i].offset += p_count;
			free_ranges[i].count -= p_count;
			if (free_ranges[i].count == 0) {
				free_ranges.remove_at(i);
			}
			RD::get_singleton()->buffer_clear(buffer, result.offset * stride, result.count * stride);
			return result;
		}
	}
	Range result{ used, p_count };
	reserve(used + p_count);
	used += p_count;
	return result;
}

void HDDAGIRigid::Pool::release(Range p_range) {
	if (p_range.count == 0) {
		return;
	}
	for (uint32_t i = 0; i < free_ranges.size();) {
		const Range &other = free_ranges[i];
		if (other.offset + other.count == p_range.offset) {
			p_range.offset = other.offset;
			p_range.count += other.count;
			free_ranges.remove_at(i);
			i = 0;
		} else if (p_range.offset + p_range.count == other.offset) {
			p_range.count += other.count;
			free_ranges.remove_at(i);
			i = 0;
		} else {
			i++;
		}
	}
	free_ranges.push_back(p_range);
}

void HDDAGIRigid::Pool::free() {
	if (buffer.is_valid()) {
		RD::get_singleton()->free_rid(buffer);
		buffer = RID();
	}
	capacity = 0;
	used = 0;
	free_ranges.clear();
}

uint32_t HDDAGIRigid::AssetKeyHasher::hash(const AssetKey &p_key) {
	uint32_t hash = HASH_MURMUR3_SEED;
	for (uint64_t value : p_key.values) {
		hash = hash_murmur3_one_64(value, hash);
	}
	return hash_fmix32(hash);
}

HDDAGIRigid::AssetKey HDDAGIRigid::_asset_key(RenderGeometryInstance *p_instance) const {
	const RenderGeometryInstanceBase *geometry = static_cast<RenderGeometryInstanceBase *>(p_instance);
	MeshStorage *mesh_storage = MeshStorage::get_singleton();
	MaterialStorage *material_storage = MaterialStorage::get_singleton();
	AssetKey key;
	RID mesh = p_instance->get_hddagi_mesh();
	key.values.push_back(mesh.get_id());
	key.values.push_back(mesh_storage->mesh_get_data_version(mesh));
	key.values.push_back(p_instance->get_hddagi_rigid_cache_resolution());
	// Per-instance uniforms cannot be shared with a different instance, even
	// when it uses the same mesh/material resource.
	key.values.push_back(geometry->shader_uniforms_offset >= 0 ? p_instance->get_hddagi_instance_id() : 0);
	key.values.push_back(geometry->shader_uniforms_offset >= 0 ? p_instance->get_hddagi_capture_version() : 0);
	auto append_material = [&](RID p_material) {
		while (p_material.is_valid()) {
			key.values.push_back(p_material.get_id());
			key.values.push_back(material_storage->material_get_data_version(p_material));
			p_material = material_storage->material_get_next_pass(p_material);
		}
		key.values.push_back(0);
	};
	append_material(geometry->data->material_overlay);
	if (geometry->data->material_override.is_valid()) {
		append_material(geometry->data->material_override);
	} else {
		int surface_count = mesh_storage->mesh_get_surface_count(mesh);
		for (int i = 0; i < surface_count; i++) {
			RID material = i < geometry->data->surface_materials.size() ? geometry->data->surface_materials[i] : RID();
			append_material(material.is_valid() ? material : mesh_storage->mesh_surface_get_material(mesh, i));
		}
	}
	return key;
}

HDDAGIRigid::Asset HDDAGIRigid::_create_asset(RenderGeometryInstance *p_instance) {
	Asset asset;
	AABB bounds = MeshStorage::get_singleton()->mesh_get_aabb(p_instance->get_hddagi_mesh());
	const int cache_resolution = p_instance->get_hddagi_rigid_cache_resolution();
	// Keep two exterior cells on either side and the existing 7-bit coordinates.
	// Rectangular dimensions are essential for thin doors and walls.
	float cell_size = MAX(0.02f, float(bounds.size[bounds.size.max_axis_index()]) / float(cache_resolution - 8));
	for (int axis = 0; axis < 3; axis++) {
		asset.grid[axis] = MIN(cache_resolution, (int(Math::ceil(bounds.size[axis] / cell_size)) + 4 + 7) & ~7);
	}
	asset.bounds.size = Vector3(asset.grid) * cell_size;
	asset.bounds.position = bounds.get_center() - asset.bounds.size * 0.5f;
	uint32_t cells = asset.grid.x * asset.grid.y * asset.grid.z;
	uint32_t regions = cells / 512;
	uint32_t block_words = cells / 32;
	asset.geometry = geometry_pool.allocate(regions + block_words + 4 + cells);
	asset.block_offset = asset.geometry.offset + regions;
	asset.task_offset = asset.block_offset + block_words;
	asset.surface = surface_pool.allocate(cells);
	asset.dispatch = dispatch_pool.allocate(4);
	return asset;
}

void HDDAGIRigid::_capture_asset(const Asset &p_asset, RenderGeometryInstance *p_instance, uint32_t p_light_offset, const Ref<RenderSceneBuffersRD> &p_render_buffers) {
	RD *rd = RD::get_singleton();
	if (preprocess_version.is_null()) {
		Vector<String> modes = { "\n#define MODE_REGION_STORE\n", "\n#define MODE_LIGHT_STORE\n" };
		preprocess.initialize(modes);
		preprocess_version = preprocess.version_create();
		for (int i = 0; i < 2; i++) {
			preprocess_shaders[i] = preprocess.version_get_shader(preprocess_version, i);
			preprocess_pipelines[i] = rd->compute_pipeline_create(preprocess_shaders[i]);
		}
	}

	rd->draw_command_begin_label("HDDAGI Capture Rigid Asset");
	RD::TextureFormat format;
	format.texture_type = RD::TEXTURE_TYPE_3D;
	format.width = p_asset.grid.x / 2;
	format.height = p_asset.grid.y / 2;
	format.depth = p_asset.grid.z / 2;
	format.format = RD::DATA_FORMAT_R32_UINT;
	format.usage_bits = RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_CAN_COPY_TO_BIT;
	auto create_texture = [&]() {
		RID texture = rd->texture_create(format, RD::TextureView());
		rd->texture_clear(texture, Color(0, 0, 0, 0), 0, 1, 0, 1);
		return texture;
	};
	RID emission = create_texture();
	RID emission_aniso = create_texture();
	format.format = RD::DATA_FORMAT_R16_UINT;
	format.depth *= 6;
	RID albedo = create_texture();
	format.width = p_asset.grid.x;
	format.height = p_asset.grid.y;
	format.depth = p_asset.grid.z;
	format.format = RD::DATA_FORMAT_R32_UINT;
	format.usage_bits |= RD::TEXTURE_USAGE_STORAGE_ATOMIC_BIT;
	RID normals = create_texture();

	PagedArray<RenderGeometryInstance *> capture_instances;
	capture_instances.set_page_pool(&capture_instance_pool);
	capture_instances.push_back(p_instance);
	Transform3D capture_transform = p_instance->get_transform();
	RendererSceneRenderRD::get_singleton()->_render_hddagi(p_render_buffers, Vector3i(), p_asset.grid, p_asset.bounds, capture_instances, albedo, emission, emission_aniso, normals, 1.0f, &capture_transform);

	struct PushConstant {
		uint32_t grid[4];
		uint32_t offsets[4];
	} push_constant = {};
	for (int i = 0; i < 3; i++) {
		push_constant.grid[i] = p_asset.grid[i];
	}
	push_constant.grid[3] = p_asset.block_offset;
	push_constant.offsets[0] = p_asset.geometry.offset;
	push_constant.offsets[1] = p_asset.surface.offset;
	push_constant.offsets[2] = p_light_offset;
	push_constant.offsets[3] = p_asset.task_offset;

	RD::ComputeListID list = rd->compute_list_begin();
	for (int mode = 0; mode < 2; mode++) {
		LocalVector<RD::Uniform> uniforms;
		if (mode == 1) {
			uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 1, albedo));
			uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 2, emission));
			uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 3, emission_aniso));
			uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 42, surface_pool.buffer));
			uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 43, lighting_pool.buffer));
		}
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 4, normals));
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 41, geometry_pool.buffer));
		RID uniform_set = UniformSetCacheRD::get_singleton()->get_cache_vec(preprocess_shaders[mode], 0, uniforms);
		rd->compute_list_bind_compute_pipeline(list, preprocess_pipelines[mode]);
		rd->compute_list_bind_uniform_set(list, uniform_set, 0);
		rd->compute_list_set_push_constant(list, &push_constant, sizeof(push_constant));
		rd->compute_list_dispatch_threads(list, p_asset.grid.x, p_asset.grid.y, p_asset.grid.z);
		if (mode == 0) {
			rd->compute_list_add_barrier(list);
		}
	}
	rd->compute_list_end();
	// RD tracks one usage per buffer within a compute list. Keep the indirect
	// header separate from geometry, which the lighting shader reads as storage.
	rd->buffer_copy(geometry_pool.buffer, dispatch_pool.buffer, p_asset.task_offset * sizeof(uint32_t), p_asset.dispatch.offset * sizeof(uint32_t), 4 * sizeof(uint32_t));
	rd->free_rid(albedo);
	rd->free_rid(emission);
	rd->free_rid(emission_aniso);
	rd->free_rid(normals);
	rd->draw_command_end_label();
	capture_count++;
	print_verbose(vformat("HDDAGI rigid asset capture %d: %s cells", capture_count, p_asset.grid));
}

void HDDAGIRigid::_release_instance(const Instance &p_instance) {
	lighting_pool.release(p_instance.light);
	Asset &asset = assets[p_instance.key];
	asset.users--;
	if (asset.users == 0) {
		geometry_pool.release(asset.geometry);
		surface_pool.release(asset.surface);
		dispatch_pool.release(asset.dispatch);
		assets.erase(p_instance.key);
	}
}

void HDDAGIRigid::_mark_changed(const AABB &p_bounds) {
	if (dirty_frames == 0) {
		dirty_bounds = p_bounds;
	} else {
		dirty_bounds.merge_with(p_bounds);
	}
	dirty_frames = history_frames;
	changed_this_frame = true;
}

uint32_t HDDAGIRigid::_build_bvh(uint32_t p_begin, uint32_t p_end) {
	uint32_t node_index = bvh_nodes.size();
	bvh_nodes.push_back(BVHNode());
	AABB bounds;
	for (uint32_t i = p_begin; i < p_end; i++) {
		const InstanceData &data = instance_data[bvh_indices[i]];
		Vector3 from(data.bounds_min[0], data.bounds_min[1], data.bounds_min[2]);
		Vector3 to(data.bounds_max[0], data.bounds_max[1], data.bounds_max[2]);
		AABB box(from, to - from);
		if (i == p_begin) {
			bounds = box;
		} else {
			bounds.merge_with(box);
		}
	}
	if (p_end - p_begin > 1) {
		int axis = bounds.size.max_axis_index();
		// Small object sets: insertion-sort the current range, then median split.
		for (uint32_t i = p_begin + 1; i < p_end; i++) {
			uint32_t value = bvh_indices[i];
			float center = instance_data[value].bounds_min[axis] + instance_data[value].bounds_max[axis];
			uint32_t j = i;
			while (j > p_begin) {
				const InstanceData &previous = instance_data[bvh_indices[j - 1]];
				if (previous.bounds_min[axis] + previous.bounds_max[axis] <= center) {
					break;
				}
				bvh_indices[j] = bvh_indices[j - 1];
				j--;
			}
			bvh_indices[j] = value;
		}
		uint32_t middle = (p_begin + p_end) / 2;
		_build_bvh(p_begin, middle);
		_build_bvh(middle, p_end);
	}
	BVHNode &node = bvh_nodes[node_index];
	for (int axis = 0; axis < 3; axis++) {
		node.bounds_min[axis] = bounds.position[axis];
		node.bounds_max[axis] = bounds.get_end()[axis];
	}
	node.instance = p_end - p_begin == 1 ? bvh_indices[p_begin] : UINT32_MAX;
	node.escape = bvh_nodes.size();
	return node_index;
}

void HDDAGIRigid::_publish() {
	RD *rd = RD::get_singleton();
	uint32_t count = MAX(1u, instance_data.size());
	if (instance_capacity < count) {
		if (instances_buffer.is_valid()) {
			rd->free_rid(instances_buffer);
		}
		instance_capacity = Math::nearest_power_of_2_templated(count);
		instances_buffer = rd->storage_buffer_create(sizeof(SceneData) + instance_capacity * sizeof(InstanceData));
	}
	scene_data.instance_count = instance_data.size();
	scene_data.node_count = bvh_nodes.size();
	scene_data.changed = (dirty_frames > 0 ? 1u : 0u) | (changed_this_frame ? 2u : 0u);
	for (int axis = 0; axis < 3; axis++) {
		scene_data.dirty_min[axis] = dirty_bounds.position[axis];
		scene_data.dirty_max[axis] = dirty_bounds.get_end()[axis];
	}
	rd->buffer_update(instances_buffer, 0, sizeof(SceneData), &scene_data);
	if (!instance_data.is_empty()) {
		rd->buffer_update(instances_buffer, sizeof(SceneData), instance_data.size() * sizeof(InstanceData), instance_data.ptr());
	}
	count = MAX(1u, bvh_nodes.size());
	if (bvh_capacity < count) {
		if (bvh_buffer.is_valid()) {
			rd->free_rid(bvh_buffer);
		}
		bvh_capacity = Math::nearest_power_of_2_templated(count);
		bvh_buffer = rd->storage_buffer_create(bvh_capacity * sizeof(BVHNode));
	}
	if (!bvh_nodes.is_empty()) {
		rd->buffer_update(bvh_buffer, 0, bvh_nodes.size() * sizeof(BVHNode), bvh_nodes.ptr());
	}
}

void HDDAGIRigid::initialize() {
	if (instances_buffer.is_valid()) {
		return;
	}
	dispatch_pool.indirect = true;
	surface_pool.stride = 16;
	geometry_pool.reserve(16);
	surface_pool.reserve(1);
	lighting_pool.reserve(16);
	dispatch_pool.reserve(16);
	_publish();
}

void HDDAGIRigid::update(const Ref<RenderSceneBuffersRD> &p_render_buffers, const PagedArray<RenderGeometryInstance *> *p_instances, const AABB &p_gi_bounds, float p_exposure) {
	initialize();
	frame++;
	changed_this_frame = false;
	if (dirty_frames > 0) {
		dirty_frames--;
	}
	active_instances.clear();
	instance_data.clear();
	uint32_t count = p_instances ? p_instances->size() : 0;
	for (uint32_t i = 0; i < count; i++) {
		RenderGeometryInstance *geometry = (*p_instances)[i];
		Transform3D transform = geometry->get_transform();
		if (!p_gi_bounds.intersects(transform.xform(geometry->get_aabb())) || transform.basis.determinant() == 0) {
			continue;
		}
		uint64_t id = geometry->get_hddagi_instance_id();
		AssetKey key = _asset_key(geometry);
		HashMap<uint64_t, Instance>::Iterator entry = instances.find(id);
		if (entry && !(entry->value.key == key)) {
			_mark_changed(entry->value.bounds);
			_release_instance(entry->value);
			instances.erase(id);
			entry = instances.end();
		}
		if (!entry) {
			HashMap<AssetKey, Asset, AssetKeyHasher>::Iterator asset_entry = assets.find(key);
			bool capture = !asset_entry;
			if (capture) {
				asset_entry = assets.insert(key, _create_asset(geometry));
			}
			Asset &asset = asset_entry->value;
			asset.users++;
			Instance instance;
			instance.key = key;
			instance.light = lighting_pool.allocate(asset.surface.count);
			instance.transform = transform;
			instance.bounds = transform.xform(asset.bounds);
			entry = instances.insert(id, instance);
			if (capture) {
				_capture_asset(asset, geometry, instance.light.offset, p_render_buffers);
			}
			_mark_changed(instance.bounds);
		}
		Instance &instance = entry->value;
		const Asset &asset = assets[key];
		if (instance.transform != transform) {
			_mark_changed(instance.bounds);
			instance.transform = transform;
			instance.bounds = transform.xform(asset.bounds);
			_mark_changed(instance.bounds);
			instance.light_dirty = true;
		}
		instance.last_seen = frame;
		active_instances.push_back(id);
		InstanceData data = {};
		Transform3D cell_to_local;
		cell_to_local.basis.scale(asset.bounds.size / Vector3(asset.grid));
		cell_to_local.origin = asset.bounds.position;
		Transform3D cell_to_world = transform * cell_to_local;
		MaterialStorage::store_transform(cell_to_world, data.cell_to_world);
		MaterialStorage::store_transform(cell_to_world.affine_inverse(), data.world_to_cell);
		for (int axis = 0; axis < 3; axis++) {
			data.grid[axis] = asset.grid[axis];
			data.bounds_min[axis] = instance.bounds.position[axis];
			data.bounds_max[axis] = instance.bounds.get_end()[axis];
		}
		data.grid[3] = asset.block_offset;
		data.offsets[0] = asset.geometry.offset;
		data.offsets[1] = asset.surface.offset;
		data.offsets[2] = instance.light.offset;
		data.offsets[3] = asset.task_offset;
		data.bounds_min[3] = p_exposure;
		instance_data.push_back(data);
	}
	LocalVector<uint64_t> removed;
	for (const KeyValue<uint64_t, Instance> &entry : instances) {
		if (entry.value.last_seen != frame) {
			_mark_changed(entry.value.bounds);
			_release_instance(entry.value);
			removed.push_back(entry.key);
		}
	}
	for (uint64_t id : removed) {
		instances.erase(id);
	}
	if (changed_this_frame) {
		scene_data.lighting_revision++;
	}
	bvh_indices.resize(instance_data.size());
	for (uint32_t i = 0; i < bvh_indices.size(); i++) {
		bvh_indices[i] = i;
	}
	bvh_nodes.clear();
	if (!bvh_indices.is_empty()) {
		_build_bvh(0, bvh_indices.size());
	}
	_publish();
}

void HDDAGIRigid::append_uniforms(LocalVector<RD::Uniform> &r_uniforms) {
	initialize();
	r_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 40, instances_buffer));
	r_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 41, geometry_pool.buffer));
	r_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 42, surface_pool.buffer));
	r_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 43, lighting_pool.buffer));
	r_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 44, bvh_buffer));
}

void HDDAGIRigid::free() {
	geometry_pool.free();
	surface_pool.free();
	lighting_pool.free();
	dispatch_pool.free();
	if (instances_buffer.is_valid()) {
		RD::get_singleton()->free_rid(instances_buffer);
		instances_buffer = RID();
	}
	if (bvh_buffer.is_valid()) {
		RD::get_singleton()->free_rid(bvh_buffer);
		bvh_buffer = RID();
	}
	if (preprocess_version.is_valid()) {
		preprocess.version_free(preprocess_version);
		preprocess_version = RID();
	}
	assets.clear();
	instances.clear();
	active_instances.clear();
	instance_data.clear();
	bvh_nodes.clear();
	instance_capacity = 0;
	bvh_capacity = 0;
	frame = 0;
	dirty_frames = 0;
	dirty_bounds = AABB();
	scene_data = SceneData();
}
