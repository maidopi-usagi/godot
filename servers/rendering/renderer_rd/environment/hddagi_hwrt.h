/**************************************************************************/
/*  hddagi_hwrt.h                                                         */
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
#include "core/templates/paged_array.h"
#include "servers/rendering/renderer_geometry_instance.h"
#include "servers/rendering/renderer_rd/shaders/environment/hddagi_hwrt_deform.glsl.gen.h"
#include "servers/rendering/renderer_rd/shaders/environment/hddagi_hwrt_material.glsl.gen.h"
#include "servers/rendering/rendering_device.h"

class RenderSceneDataRD;

namespace RendererRD {

// Independent triangle scene and material samples. Screen-probe sampling and
// denoising remain shared; no voxel geometry, materials or lighting are used.
class HDDAGIHwrt {
	static constexpr uint32_t MATERIAL_TILE_SIZE = 4;
	static constexpr uint32_t MATERIAL_TILES_PER_ROW = 128;
	static constexpr uint64_t CACHE_KEEP_FRAMES = 120;
	static constexpr uint64_t CACHE_MAX_UNUSED_BYTES = 64 * 1024 * 1024;
	struct Range {
		uint32_t offset = 0;
		uint32_t count = 0;
	};
	// Stable element offsets, with GPU copies only when the backing buffer grows.
	struct Pool {
		RID buffer;
		uint32_t capacity = 0;
		uint32_t used = 0;
		uint32_t stride = 4;
		LocalVector<Range> free_ranges;
		bool reserve(uint32_t p_count);
		Range allocate(uint32_t p_count);
		void release(Range p_range);
		void free();
	};
	struct MeshKey {
		RID mesh;
		Vector<int> surfaces;
		Vector<uint32_t> lods;
		bool deformed = false;
		bool has_lods = false; // Derived from the compatible surfaces, not part of identity.
		bool operator==(const MeshKey &p_other) const { return mesh == p_other.mesh && surfaces == p_other.surfaces && lods == p_other.lods && deformed == p_other.deformed; }
	};
	struct MeshKeyHasher {
		static uint32_t hash(const MeshKey &p_key);
	};
	struct Mesh {
		RID vertices;
		RID blas;
		RID material_mesh;
		RID triangle_indices;
		RID normal_template;
		uint32_t triangle_count = 0;
		struct DeformSurface {
			uint32_t surface = 0;
			uint32_t triangle_offset = 0;
			uint32_t triangle_count = 0;
		};
		LocalVector<DeformSurface> deform_surfaces;
		Size2i material_size;
		Vector<int> material_surfaces;
		Range normals; // One vec4 per triangle, in object space.
		uint64_t bytes = 0; // Geometry/cache estimate for the inactive retention budget.
		uint64_t version = 0;
		uint64_t last_seen = 0;
	};
	struct MaterialKey {
		Vector<uint64_t> values;
		Vector<uint32_t> lods;
		bool operator==(const MaterialKey &p_other) const { return values == p_other.values && lods == p_other.lods; }
	};
	struct MaterialKeyHasher {
		static uint32_t hash(const MaterialKey &p_key);
	};
	struct Material {
		Range samples; // GPU-only 4x4 samples per triangle: albedo/metallic + RGB9E5 emission.
		uint64_t last_seen = 0;
		bool valid = false;
	};
	struct DeformedMesh {
		RID mesh_instance;
		RID vertices;
		RID blas;
		Range normals;
		uint64_t version = 0;
		uint64_t mesh_version = 0;
		uint64_t last_seen = 0;
	};
	struct Instance {
		uint64_t id = 0;
		RID blas;
		Transform3D transform;
		uint64_t mesh_version = 0;
		uint64_t deformation_version = 0;
		uint64_t surface_version = 0;
		uint32_t metadata_index = 0;
		uint32_t normal_offset = 0;
		uint32_t material_offset = 0;
		bool same_geometry(const Instance &p_other) const {
			return id == p_other.id && blas == p_other.blas && transform == p_other.transform && mesh_version == p_other.mesh_version && deformation_version == p_other.deformation_version;
		}
		bool operator<(const Instance &p_other) const { return id < p_other.id; }
	};
	struct CachedInstance {
		MeshKey mesh;
		MaterialKey material;
		HashMap<MeshKey, DeformedMesh, MeshKeyHasher> deformed_meshes;
		Instance instance;
		uint64_t capture_version = 0;
		uint64_t last_seen = 0;
	};
	HashMap<MeshKey, Mesh, MeshKeyHasher> meshes;
	HashMap<MaterialKey, Material, MaterialKeyHasher> materials;
	HashMap<uint64_t, CachedInstance> cached_instances;
	LocalVector<Instance> instances;
	LocalVector<Instance> next_instances;
	RID tlas;
	Pool normal_pool;
	RID instance_buffer;
	Pool material_pool;
	HddagiHwrtMaterialShaderRD material_shader;
	bool material_shader_initialized = false;
	RID material_shader_version;
	RID material_pipeline;
	HddagiHwrtDeformShaderRD deform_shader;
	bool deform_shader_initialized = false;
	RID deform_shader_version;
	RID deform_pipeline;
	RID scene_buffer;
	RID lights_buffer; // Owned by the GI context; packing is shared with software lighting.
	AABB bounds;
	struct SceneData {
		uint32_t light_count = 0;
		float exposure = 1.0f;
		float max_distance = 100.0f;
		float bounce_feedback = 0.0f;
	} scene_data;
	uint64_t scene_version = 0;
	uint64_t surface_version = 0;
	uint64_t lighting_version = 0;
	uint32_t lighting_signature = 0;
	uint32_t metadata_count = 0;
	LocalVector<uint32_t> free_metadata_indices;
	uint32_t instance_capacity = 0;
	uint64_t frame = 0;
	bool mesh_timestamped = false;
	bool material_timestamped = false;
	bool deform_timestamped = false;
	bool ready = false;

	bool _create_mesh(const MeshKey &p_key, Mesh &r_mesh);
	bool _update_deformed(RID p_mesh_instance, const Mesh &p_mesh, DeformedMesh &r_deformed, bool &r_changed);
	MaterialKey _material_key(RenderGeometryInstanceBase *p_instance) const;
	bool _material_is_current(const MaterialKey &p_key) const;
	bool _capture_material(RenderGeometryInstanceBase *p_instance, const Mesh &p_mesh, Material &r_material);
	void _evict_unused();
	void _free_mesh(Mesh &p_mesh);
	void _free_deformed(DeformedMesh &p_mesh);
	void _free_deformed_meshes(CachedInstance &p_instance);
	bool _supports_instance(RenderGeometryInstanceBase *p_instance) const;
	MeshKey _mesh_key(RenderGeometryInstanceBase *p_instance) const;
	bool _update_mesh_lods(RenderGeometryInstanceBase *p_instance, const RenderSceneDataRD *p_scene_data, MeshKey &r_key) const;

public:
	static bool is_supported();
	void update(const PagedArray<RenderGeometryInstance *> *p_instances, const RenderSceneDataRD *p_scene_data);
	void update_lights(RID p_lights_buffer, uint32_t p_light_count, float p_exposure, float p_bounce_feedback, uint32_t p_lighting_signature);
	void append_uniforms(LocalVector<RD::Uniform> &r_uniforms) const;
	const AABB &get_bounds() const { return bounds; }
	float get_max_distance() const { return scene_data.max_distance; }
	uint64_t get_scene_version() const { return scene_version; }
	RID get_instance_buffer() const { return instance_buffer; }
	uint64_t get_lighting_version() const { return lighting_version; }
	bool is_ready() const { return ready; }
	void free();
};

} // namespace RendererRD
