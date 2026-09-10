/**************************************************************************/
/*  hddagi_rigid.h                                                         */
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

#include "core/templates/hash_map.h"
#include "core/templates/local_vector.h"
#include "core/templates/paged_array.h"
#include "servers/rendering/renderer_geometry_instance.h"
#include "servers/rendering/renderer_rd/shaders/environment/hddagi_rigid_preprocess.glsl.gen.h"
#include "servers/rendering/rendering_device.h"

class RenderSceneBuffersRD;

namespace RendererRD {

// Local geometry is shared by compatible instances. Lighting belongs to this
// render context, so different environments cannot overwrite each other's GI.
class HDDAGIRigid {
public:
	struct InstanceData {
		float world_to_cell[16];
		float cell_to_world[16];
		uint32_t grid[4];
		uint32_t offsets[4];
		float bounds_min[4];
		float bounds_max[4];
	};
	static_assert(sizeof(InstanceData) == 192);

	struct SceneData {
		uint32_t instance_count = 0;
		uint32_t node_count = 0;
		uint32_t lighting_revision = 0;
		uint32_t changed = 0;
		float dirty_min[4] = {};
		float dirty_max[4] = {};
	};
	static_assert(sizeof(SceneData) == 48);

	struct BVHNode {
		float bounds_min[3];
		uint32_t instance;
		float bounds_max[3];
		uint32_t escape;
	};
	static_assert(sizeof(BVHNode) == 32);

private:
	struct Range {
		uint32_t offset = 0;
		uint32_t count = 0;
	};

	// Suballocate continuous ranges. Addresses survive movement and pool growth;
	// RD retains copied/freed backing buffers until their GPU work completes.
	struct Pool {
		RID buffer;
		uint32_t capacity = 0;
		uint32_t used = 0;
		uint32_t stride = 4;
		bool indirect = false;
		LocalVector<Range> free_ranges;

		void reserve(uint32_t p_count);
		Range allocate(uint32_t p_count);
		void release(Range p_range);
		void free();
	};

	struct AssetKey {
		Vector<uint64_t> values;
		bool operator==(const AssetKey &p_other) const { return values == p_other.values; }
	};
	struct AssetKeyHasher {
		static uint32_t hash(const AssetKey &p_key);
	};
	struct Asset {
		Range geometry;
		Range surface;
		Range dispatch;
		Vector3i grid;
		AABB bounds;
		uint32_t block_offset = 0;
		uint32_t task_offset = 0;
		uint32_t users = 0;
	};
	struct Instance {
		AssetKey key;
		Range light;
		Transform3D transform;
		AABB bounds;
		uint64_t last_seen = 0;
		bool light_dirty = true;
	};

	Pool geometry_pool;
	Pool surface_pool;
	Pool lighting_pool;
	Pool dispatch_pool;
	HashMap<AssetKey, Asset, AssetKeyHasher> assets;
	HashMap<uint64_t, Instance> instances;
	LocalVector<uint64_t> active_instances;
	LocalVector<InstanceData> instance_data;
	LocalVector<BVHNode> bvh_nodes;
	LocalVector<uint32_t> bvh_indices;
	SceneData scene_data;
	RID instances_buffer;
	RID bvh_buffer;
	uint32_t instance_capacity = 0;
	uint32_t bvh_capacity = 0;
	uint64_t frame = 0;
	uint32_t dirty_frames = 0;
	uint32_t history_frames = 32;
	AABB dirty_bounds;
	bool changed_this_frame = false;
	uint32_t capture_count = 0;

	HddagiRigidPreprocessShaderRD preprocess;
	RID preprocess_version;
	RID preprocess_shaders[2];
	RID preprocess_pipelines[2];
	PagedArrayPool<RenderGeometryInstance *> capture_instance_pool{ 16 };

	AssetKey _asset_key(RenderGeometryInstance *p_instance) const;
	Asset _create_asset(RenderGeometryInstance *p_instance);
	void _capture_asset(const Asset &p_asset, RenderGeometryInstance *p_instance, uint32_t p_light_offset, const Ref<RenderSceneBuffersRD> &p_render_buffers);
	void _release_instance(const Instance &p_instance);
	void _mark_changed(const AABB &p_bounds);
	uint32_t _build_bvh(uint32_t p_begin, uint32_t p_end);
	void _publish();

public:
	void initialize();
	void set_history_frames(uint32_t p_frames) { history_frames = MAX(1u, p_frames); }
	void update(const Ref<RenderSceneBuffersRD> &p_render_buffers, const PagedArray<RenderGeometryInstance *> *p_instances, const AABB &p_gi_bounds, float p_exposure);
	void append_uniforms(LocalVector<RD::Uniform> &r_uniforms);
	void free();

	bool is_active() const { return !active_instances.is_empty(); }
	bool has_changes() const { return changed_this_frame; }
	bool has_pending_changes() const { return dirty_frames > 0; }
	uint32_t get_revision() const { return scene_data.lighting_revision; }
	uint32_t get_instance_count() const { return instance_data.size(); }
	uint64_t get_instance_id(uint32_t p_index) const { return active_instances[p_index]; }
	uint32_t get_capture_count() const { return capture_count; }
	const InstanceData &get_instance_data(uint32_t p_index) const { return instance_data[p_index]; }
	bool is_light_dirty(uint32_t p_index) const { return instances[active_instances[p_index]].light_dirty; }
	void finish_lighting(uint32_t p_index) { instances[active_instances[p_index]].light_dirty = false; }
	RID get_geometry_buffer() const { return geometry_pool.buffer; }
	RID get_dispatch_buffer() const { return dispatch_pool.buffer; }
	uint32_t get_dispatch_offset(uint32_t p_index) const { return assets[instances[active_instances[p_index]].key].dispatch.offset * sizeof(uint32_t); }
	RID get_instances_buffer() const { return instances_buffer; }
	RID get_surface_buffer() const { return surface_pool.buffer; }
	RID get_lighting_buffer() const { return lighting_pool.buffer; }
	RID get_bvh_buffer() const { return bvh_buffer; }
	const AABB &get_dirty_bounds() const { return dirty_bounds; }
};

} // namespace RendererRD
