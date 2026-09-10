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
#include "servers/rendering/rendering_device.h"

namespace RendererRD {

// Independent triangle scene and material samples. Screen-probe sampling and
// denoising remain shared; no voxel geometry, materials or lighting are used.
class HDDAGIHwrt {
	static constexpr uint32_t MATERIAL_TILE_SIZE = 4;
	static constexpr uint32_t MATERIAL_TILES_PER_ROW = 128;
	struct MeshKey {
		RID mesh;
		Vector<int> surfaces;
		bool operator==(const MeshKey &p_other) const { return mesh == p_other.mesh && surfaces == p_other.surfaces; }
	};
	struct MeshKeyHasher {
		static uint32_t hash(const MeshKey &p_key);
	};
	struct Mesh {
		RID vertices;
		RID blas;
		RID material_mesh;
		Size2i material_size;
		Vector<int> material_surfaces;
		Vector<float> normals; // One vec4 per triangle, in object space.
		uint64_t version = 0;
		uint64_t last_seen = 0;
		uint32_t normal_offset = 0;
	};
	struct MaterialKey {
		Vector<uint64_t> values;
		bool operator==(const MaterialKey &p_other) const { return values == p_other.values; }
	};
	struct MaterialKeyHasher {
		static uint32_t hash(const MaterialKey &p_key);
	};
	struct Material {
		Vector<uint32_t> samples; // 4x4 barycentric samples per triangle: albedo/metallic + RGB9E5 emission.
		uint64_t last_seen = 0;
		uint32_t offset = 0;
		bool valid = false;
	};
	struct Instance {
		uint64_t id = 0;
		MeshKey mesh;
		Transform3D transform;
		MaterialKey material;
		bool operator==(const Instance &p_other) const {
			return id == p_other.id && mesh == p_other.mesh && transform == p_other.transform && material == p_other.material;
		}
		bool operator<(const Instance &p_other) const { return id < p_other.id; }
	};
	HashMap<MeshKey, Mesh, MeshKeyHasher> meshes;
	HashMap<MaterialKey, Material, MaterialKeyHasher> materials;
	LocalVector<Instance> instances;
	RID tlas;
	RID normal_buffer;
	RID instance_buffer;
	RID material_buffer;
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
	uint32_t instance_capacity = 0;
	uint64_t frame = 0;
	bool ready = false;

	bool _create_mesh(const MeshKey &p_key, Mesh &r_mesh);
	MaterialKey _material_key(RenderGeometryInstanceBase *p_instance) const;
	bool _capture_material(RenderGeometryInstanceBase *p_instance, const Mesh &p_mesh, Material &r_material);
	void _free_mesh(Mesh &p_mesh);
	bool _supports_instance(RenderGeometryInstanceBase *p_instance) const;
	MeshKey _mesh_key(RenderGeometryInstanceBase *p_instance) const;

public:
	static bool is_supported();
	void update(const PagedArray<RenderGeometryInstance *> *p_instances, const Vector3 &p_origin);
	void update_lights(RID p_lights_buffer, uint32_t p_light_count, float p_exposure, float p_bounce_feedback);
	void append_uniforms(LocalVector<RD::Uniform> &r_uniforms) const;
	const AABB &get_bounds() const { return bounds; }
	float get_max_distance() const { return scene_data.max_distance; }
	uint64_t get_scene_version() const { return scene_version; }
	bool is_ready() const { return ready; }
	void free();
};

} // namespace RendererRD
