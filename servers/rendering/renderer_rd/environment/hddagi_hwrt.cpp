/**************************************************************************/
/*  hddagi_hwrt.cpp                                                       */
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

#include "hddagi_hwrt.h"

#include "core/config/project_settings.h"
#include "core/io/marshalls.h"
#include "servers/rendering/renderer_rd/renderer_scene_render_rd.h"
#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"
#include "servers/rendering/renderer_rd/storage_rd/mesh_storage.h"
#include "servers/rendering/renderer_rd/storage_rd/render_scene_data_rd.h"
#include "servers/rendering/renderer_rd/storage_rd/texture_storage.h"
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"
#include "servers/rendering/rendering_server.h"
#include "servers/rendering/rendering_server_globals.h"

using namespace RendererRD;

bool HDDAGIHwrt::Pool::reserve(uint32_t p_count) {
	if (p_count <= capacity) {
		return true;
	}
	RD *rd = RD::get_singleton();
	uint64_t new_capacity = Math::nearest_power_of_2_templated(MAX(uint64_t(p_count), uint64_t(16)));
	if (growth_quantum != 0 && new_capacity > growth_quantum) {
		new_capacity = ((uint64_t(p_count) + growth_quantum - 1) / growth_quantum) * growth_quantum;
	}
	ERR_FAIL_COND_V(new_capacity * stride > UINT32_MAX, false);
	RID next = rd->storage_buffer_create(uint32_t(new_capacity) * stride);
	if (next.is_null()) {
		return false;
	}
	if (buffer.is_valid()) {
		rd->buffer_copy(buffer, next, 0, 0, capacity * stride);
		rd->free_rid(buffer);
	}
	buffer = next;
	capacity = uint32_t(new_capacity);
	return true;
}

HDDAGIHwrt::Range HDDAGIHwrt::Pool::allocate(uint32_t p_count, bool p_reserve_buffer) {
	for (uint32_t i = 0; i < free_ranges.size(); i++) {
		if (free_ranges[i].count >= p_count) {
			Range result{ free_ranges[i].offset, p_count };
			free_ranges[i].offset += p_count;
			free_ranges[i].count -= p_count;
			if (free_ranges[i].count == 0) {
				free_ranges.remove_at(i);
			}
			return result;
		}
	}
	if (p_count > UINT32_MAX - used || uint64_t(used + p_count) * stride > UINT32_MAX || (p_reserve_buffer && !reserve(used + p_count))) {
		return Range();
	}
	Range result{ used, p_count };
	used += p_count;
	return result;
}

void HDDAGIHwrt::Pool::release(Range p_range) {
	if (p_range.count == 0) {
		return;
	}
	for (uint32_t i = 0; i < free_ranges.size();) {
		const Range &other = free_ranges[i];
		if (other.offset + other.count == p_range.offset || p_range.offset + p_range.count == other.offset) {
			p_range.offset = MIN(p_range.offset, other.offset);
			p_range.count += other.count;
			free_ranges.remove_at(i);
			i = 0;
		} else {
			i++;
		}
	}
	if (p_range.offset + p_range.count == used) {
		used = p_range.offset;
	} else {
		free_ranges.push_back(p_range);
	}
}

void HDDAGIHwrt::Pool::free() {
	if (buffer.is_valid()) {
		RD::get_singleton()->free_rid(buffer);
	}
	buffer = RID();
	capacity = 0;
	used = 0;
	free_ranges.clear();
}

bool HDDAGIHwrt::is_supported() {
	RD *rd = RD::get_singleton();
	return rd && rd->has_feature(RD::SUPPORTS_RAY_QUERY) && rd->has_feature(RD::SUPPORTS_BUFFER_DEVICE_ADDRESS);
}

bool HDDAGIHwrt::_supports_instance(RenderGeometryInstanceBase *p_instance) const {
	// Match scene culling: a small determinant is valid (centimeter imports use
	// a 0.01 scale, hence a 1e-6 determinant). Only singular transforms are invalid.
	if (p_instance->data->base_type != RSE::INSTANCE_MESH ||
			p_instance->data->material_overlay.is_valid() || !p_instance->transform.is_finite() || p_instance->transform.basis.determinant() == 0) {
		return false;
	}
	return true;
}

uint32_t HDDAGIHwrt::MeshKeyHasher::hash(const MeshKey &p_key) {
	uint32_t hash = hash_murmur3_one_64(p_key.mesh.get_id());
	hash = hash_murmur3_one_32(p_key.deformed, hash);
	for (int surface : p_key.surfaces) {
		hash = hash_murmur3_one_32(surface, hash);
	}
	for (uint32_t lod : p_key.lods) {
		hash = hash_murmur3_one_32(lod, hash);
	}
	return hash_fmix32(hash);
}

HDDAGIHwrt::MeshKey HDDAGIHwrt::_mesh_key(RenderGeometryInstanceBase *p_instance, int p_surface) const {
	MeshKey key;
	key.mesh = p_instance->get_hddagi_mesh();
	key.deformed = p_instance->mesh_instance.is_valid();
	MaterialStorage *material_storage = MaterialStorage::get_singleton();
	auto supports_material = [&](RID p_material) {
		while (p_material.is_valid()) {
			if (material_storage->material_get_next_pass(p_material).is_valid()) {
				return false;
			}
			MaterialStorage::ShaderData *shader = material_storage->material_get_shader_data(p_material);
			if (shader && (!shader->supports_hddagi_hwrt() || shader->is_animated())) {
				return false;
			}
			p_material = material_storage->material_get_next_pass(p_material);
		}
		return true;
	};
	MeshStorage *mesh_storage = MeshStorage::get_singleton();
	RID mesh = key.mesh;
	void *surface_data = mesh_storage->mesh_get_surface(mesh, uint32_t(p_surface));
	if (mesh_storage->mesh_surface_get_primitive(surface_data) != RSE::PRIMITIVE_TRIANGLES ||
			(mesh_storage->mesh_surface_get_format(surface_data) & RSE::ARRAY_FLAG_USE_2D_VERTICES)) {
		return key;
	}
	RID material = p_instance->data->material_override;
	if (material.is_null() && p_surface < p_instance->data->surface_materials.size()) {
		material = p_instance->data->surface_materials[p_surface];
	}
	if (material.is_null()) {
		material = mesh_storage->mesh_surface_get_material(mesh, p_surface);
	}
	if (supports_material(material)) {
		key.surfaces.push_back(p_surface);
		key.lods.push_back(0);
		key.has_lods = key.has_lods || mesh_storage->mesh_surface_has_lod(surface_data);
	}
	return key;
}

bool HDDAGIHwrt::_update_mesh_lods(RenderGeometryInstanceBase *p_instance, const RenderSceneDataRD *p_scene_data, MeshKey &r_key) const {
	if (!r_key.has_lods) {
		return false;
	}
	bool changed = false;
	MeshStorage *mesh_storage = MeshStorage::get_singleton();
	const float distance = p_instance->get_lod_distance(p_scene_data->main_cam_transform.origin, p_scene_data->cam_orthogonal) * p_scene_data->lod_distance_multiplier;
	for (int i = 0; i < r_key.surfaces.size(); i++) {
		void *surface = mesh_storage->mesh_get_surface(r_key.mesh, uint32_t(r_key.surfaces[i]));
		uint32_t lod = 0;
		if (p_scene_data->screen_mesh_lod_threshold > 0.0 && mesh_storage->mesh_surface_has_lod(surface)) {
			uint32_t index_count = 0;
			lod = mesh_storage->mesh_surface_get_lod(surface, p_instance->lod_model_scale * p_instance->lod_bias,
					distance, p_scene_data->screen_mesh_lod_threshold, index_count);
		}
		// Detach the shared cache key only on an actual transition.
		if (r_key.lods[i] != lod) {
			r_key.lods.write[i] = lod;
			changed = true;
		}
	}
	return changed;
}

const HDDAGIHwrt::SourceSurface *HDDAGIHwrt::_get_source_surface(RID p_mesh, int p_surface) {
	const MeshStorage *mesh_storage = MeshStorage::get_singleton();
	SourceMesh &source = source_meshes[p_mesh];
	const uint64_t version = mesh_storage->mesh_get_data_version(p_mesh);
	if (source.version != version) {
		source = SourceMesh();
		source.version = version;
	}
	source.last_seen = frame;
	if (const SourceSurface *surface = source.surfaces.getptr(p_surface)) {
		return surface;
	}
	// All LODs share these attributes. Read and decode once per source version,
	// rather than flushing the GPU again every time the camera selects a new LOD.
	const RenderingServerTypes::SurfaceData data = mesh_storage->mesh_get_surface(p_mesh, p_surface);
	mesh_timestamped = false;
	material_timestamped = false;
	deform_timestamped = false;
	const Array arrays = RenderingServer::get_singleton()->mesh_create_arrays_from_surface_data(data);
	ERR_FAIL_COND_V(arrays.size() != RSE::ARRAY_MAX, nullptr);
	SourceSurface surface;
	surface.positions = arrays[RSE::ARRAY_VERTEX];
	surface.normals = arrays[RSE::ARRAY_NORMAL];
	surface.tangents = arrays[RSE::ARRAY_TANGENT];
	surface.colors = arrays[RSE::ARRAY_COLOR];
	surface.uv = arrays[RSE::ARRAY_TEX_UV];
	surface.indices.push_back(arrays[RSE::ARRAY_INDEX]);
	for (const RenderingServerTypes::SurfaceData::LOD &lod : data.lods) {
		const uint32_t index_size = data.vertex_count <= 65536 ? sizeof(uint16_t) : sizeof(uint32_t);
		ERR_FAIL_COND_V(lod.index_data.size() % index_size != 0, nullptr);
		Vector<int> indices;
		indices.resize(lod.index_data.size() / index_size);
		int *write = indices.ptrw();
		const uint8_t *read = lod.index_data.ptr();
		for (int i = 0; i < indices.size(); i++) {
			write[i] = index_size == sizeof(uint16_t) ? decode_uint16(read + i * index_size) : decode_uint32(read + i * index_size);
		}
		surface.indices.push_back(indices);
	}
	surface.deformed = (data.format & RSE::ARRAY_FORMAT_BONES) || mesh_storage->mesh_get_blend_shape_count(p_mesh) > 0;
	source.bytes += uint64_t(surface.positions.size() + surface.normals.size()) * sizeof(Vector3) +
			uint64_t(surface.tangents.size()) * sizeof(float) + uint64_t(surface.colors.size()) * sizeof(Color) + uint64_t(surface.uv.size()) * sizeof(Vector2);
	for (const Vector<int> &indices : surface.indices) {
		source.bytes += uint64_t(indices.size()) * sizeof(int);
	}
	return &source.surfaces.insert(p_surface, surface)->value;
}

bool HDDAGIHwrt::_create_mesh(const MeshKey &p_key, Mesh &r_mesh, bool p_create_geometry) {
	r_mesh.family = p_key;
	r_mesh.family.lods.clear();
	r_mesh.material_surfaces.clear();
	LocalVector<float> vertices;
	LocalVector<float> normals;
	LocalVector<uint32_t> triangle_indices;
	Vector<Array> material_arrays;
	// Each entry contains one compatible surface, independently of the LODs or
	// material support of the other surfaces in the imported mesh.
	for (int surface_index = 0; surface_index < p_key.surfaces.size(); surface_index++) {
		const int surface = p_key.surfaces[surface_index];
		const SourceSurface *source = _get_source_surface(p_key.mesh, surface);
		if (!source) {
			return false;
		}
		const uint32_t lod = p_key.lods[surface_index];
		ERR_FAIL_UNSIGNED_INDEX_V(lod, uint32_t(source->indices.size()), false);
		const Vector<Vector3> &positions = source->positions;
		const Vector<int> &indices = source->indices[lod];
		const Vector<Vector3> &source_normals = source->normals;
		const Vector<float> &source_tangents = source->tangents;
		const Vector<Color> &source_colors = source->colors;
		const Vector<Vector2> &source_uv = source->uv;
		Vector<Vector3> bake_positions;
		Vector<Vector3> bake_normals;
		Vector<float> bake_tangents;
		Vector<Color> bake_colors;
		Vector<Vector2> bake_uv;
		Vector<Vector2> bake_uv2;
		const uint32_t triangle_offset = normals.size() / 4;
		const uint32_t count = indices.is_empty() ? positions.size() : indices.size();
		if (count % 3 != 0) {
			return false;
		}
		// Fill the chart arrays through stable writes; per-vertex Vector::push_back
		// repeatedly checks copy-on-write ownership and dominates cold preparation.
		bake_positions.resize(count);
		bake_normals.resize(count);
		bake_uv2.resize(count);
		bake_tangents.resize(source_tangents.is_empty() ? 0 : count * 4);
		bake_colors.resize(source_colors.is_empty() ? 0 : count);
		bake_uv.resize(source_uv.is_empty() ? 0 : count);
		Vector3 *positions_write = bake_positions.ptrw();
		Vector3 *normals_write = bake_normals.ptrw();
		Vector2 *uv2_write = bake_uv2.ptrw();
		float *tangents_write = bake_tangents.ptrw();
		Color *colors_write = bake_colors.ptrw();
		Vector2 *uv_write = bake_uv.ptrw();
		vertices.reserve(vertices.size() + count * 3);
		normals.reserve(normals.size() + count / 3 * 4);
		if (p_key.deformed) {
			triangle_indices.reserve(triangle_indices.size() + count);
		}
		uint32_t baked_vertices = 0;
		for (uint32_t triangle = 0; triangle < count; triangle += 3) {
			Vector3 points[3];
			int corner_indices[3];
			for (uint32_t corner = 0; corner < 3; corner++) {
				int index = indices.is_empty() ? int(triangle + corner) : indices[triangle + corner];
				if (index < 0 || index >= positions.size() || !positions[index].is_finite()) {
					return false;
				}
				points[corner] = positions[index];
				corner_indices[corner] = index;
			}
			Vector3 normal = (points[1] - points[0]).cross(points[2] - points[0]);
			if (normal.length_squared() == 0.0 && !p_key.deformed) {
				continue;
			}
			// Degenerate bind-pose triangles can open when bones move.
			normal = normal.length_squared() > 0.0 ? normal.normalized() : Vector3(0, 0, 1);
			const uint32_t primitive = normals.size() / 4;
			const Vector2 chart_origin = Vector2(primitive % MATERIAL_TILES_PER_ROW, primitive / MATERIAL_TILES_PER_ROW) * MATERIAL_TILE_SIZE + Vector2(0.5, 0.5);
			for (uint32_t corner = 0; corner < 3; corner++) {
				const int index = corner_indices[corner];
				if (p_key.deformed) {
					triangle_indices.push_back(index);
				}
				positions_write[baked_vertices] = points[corner];
				normals_write[baked_vertices] = source_normals.is_empty() ? -normal : source_normals[index];
				if (!source_tangents.is_empty()) {
					for (int axis = 0; axis < 4; axis++) {
						tangents_write[baked_vertices * 4 + axis] = source_tangents[index * 4 + axis];
					}
				}
				if (!source_colors.is_empty()) {
					colors_write[baked_vertices] = source_colors[index];
				}
				if (!source_uv.is_empty()) {
					uv_write[baked_vertices] = source_uv[index];
				}
				uv2_write[baked_vertices] = chart_origin + Vector2(corner == 1 ? MATERIAL_TILE_SIZE - 1 : 0, corner == 2 ? MATERIAL_TILE_SIZE - 1 : 0);
				baked_vertices++;
			}
			for (const Vector3 &point : points) {
				for (int axis = 0; axis < 3; axis++) {
					vertices.push_back(point[axis]);
				}
			}
			for (int axis = 0; axis < 3; axis++) {
				normals.push_back(normal[axis]);
			}
			normals.push_back(0.0f);
		}
		bake_positions.resize(baked_vertices);
		bake_normals.resize(baked_vertices);
		bake_uv2.resize(baked_vertices);
		bake_tangents.resize(source_tangents.is_empty() ? 0 : baked_vertices * 4);
		bake_colors.resize(source_colors.is_empty() ? 0 : baked_vertices);
		bake_uv.resize(source_uv.is_empty() ? 0 : baked_vertices);
		if (!bake_positions.is_empty()) {
			if (p_create_geometry && p_key.deformed && source->deformed) {
				r_mesh.deform_surfaces.push_back({ uint32_t(surface), triangle_offset, uint32_t(normals.size() / 4) - triangle_offset });
			}
			Array bake;
			bake.resize(RSE::ARRAY_MAX);
			bake[RSE::ARRAY_VERTEX] = bake_positions;
			bake[RSE::ARRAY_NORMAL] = bake_normals;
			bake[RSE::ARRAY_TEX_UV2] = bake_uv2;
			if (!bake_tangents.is_empty()) {
				bake[RSE::ARRAY_TANGENT] = bake_tangents;
			}
			if (!bake_colors.is_empty()) {
				bake[RSE::ARRAY_COLOR] = bake_colors;
			}
			if (!bake_uv.is_empty()) {
				bake[RSE::ARRAY_TEX_UV] = bake_uv;
			}
			material_arrays.push_back(bake);
			r_mesh.material_surfaces.push_back(surface);
		}
	}
	if (vertices.is_empty()) {
		return true;
	}
	RD *rd = RD::get_singleton();
	const uint32_t triangle_count = normals.size() / 4;
	r_mesh.material_size = Size2i(MIN(triangle_count, MATERIAL_TILES_PER_ROW), (triangle_count + MATERIAL_TILES_PER_ROW - 1) / MATERIAL_TILES_PER_ROW) * MATERIAL_TILE_SIZE;
	if (uint32_t(r_mesh.material_size.y) > rd->limit_get(RD::LIMIT_MAX_TEXTURE_SIZE_2D)) {
		return false;
	}
	MeshStorage *mutable_mesh_storage = MeshStorage::get_singleton();
	r_mesh.material_mesh = mutable_mesh_storage->mesh_allocate();
	mutable_mesh_storage->mesh_initialize(r_mesh.material_mesh);
	for (Array &bake : material_arrays) {
		Vector<Vector2> uv2 = bake[RSE::ARRAY_TEX_UV2];
		for (Vector2 &uv : uv2) {
			uv /= Vector2(r_mesh.material_size);
		}
		bake[RSE::ARRAY_TEX_UV2] = uv2;
		RenderingServerTypes::SurfaceData data;
		if (RenderingServer::get_singleton()->mesh_create_surface_data_from_arrays(&data, RSE::PRIMITIVE_TRIANGLES, bake) != OK) {
			return false;
		}
		mutable_mesh_storage->mesh_add_surface(r_mesh.material_mesh, data);
	}
	// Raster-only chart geometry is scratch data. Keep it through this update so
	// instances with different materials can share it, then release the GPU copy.
	material_meshes_to_release.push_back(p_key);
	if (!p_create_geometry) {
		return true;
	}
	r_mesh.vertices = rd->vertex_buffer_create(vertices.size() * sizeof(float),
			Span<uint8_t>(reinterpret_cast<const uint8_t *>(vertices.ptr()), vertices.size() * sizeof(float)),
			RD::BUFFER_CREATION_DEVICE_ADDRESS_BIT | RD::BUFFER_CREATION_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT);
	if (r_mesh.vertices.is_null()) {
		return false;
	}
	r_mesh.triangle_count = triangle_count;
	r_mesh.bytes = uint64_t(vertices.size()) * sizeof(float) + uint64_t(triangle_count) * 128;
	if (p_key.deformed) {
		// Keep bind-pose data only as a shared template. Each animated instance owns
		// its BLAS; surfaces without skinning retain this template's geometry.
		r_mesh.triangle_indices = rd->storage_buffer_create(triangle_indices.size() * sizeof(uint32_t), triangle_indices.span().reinterpret<uint8_t>());
		r_mesh.normal_template = rd->storage_buffer_create(normals.size() * sizeof(float), normals.span().reinterpret<uint8_t>());
		return r_mesh.triangle_indices.is_valid() && r_mesh.normal_template.is_valid();
	}
	r_mesh.normals = normal_pool.allocate(triangle_count);
	if (r_mesh.normals.count == 0) {
		return false;
	}
	rd->buffer_update(normal_pool.buffer, r_mesh.normals.offset * normal_pool.stride, normals.size() * sizeof(float), normals.ptr());
	RD::AccelerationStructureGeometry geometry;
	geometry.flags = RD::ACCELERATION_STRUCTURE_GEOMETRY_OPAQUE_BIT;
	geometry.vertex_buffer = r_mesh.vertices;
	geometry.vertex_stride = sizeof(float) * 3;
	geometry.vertex_count = vertices.size() / 3;
	geometry.vertex_format = RD::DATA_FORMAT_R32G32B32_SFLOAT;
	r_mesh.blas = rd->blas_create(Span<RD::AccelerationStructureGeometry>(&geometry, 1), RD::ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT);
	if (r_mesh.blas.is_null()) {
		return false;
	}
	rd->draw_command_begin_label("HDDAGI HWRT Build BLAS");
	// Bound timestamp queries to the first asset in each command batch. The
	// Scene Update pair measures warm updates without adding per-instance queries.
	if (!mesh_timestamped) {
		RENDER_TIMESTAMP("HDDAGI HWRT Build BLAS");
	}
	Error error = rd->blas_build(r_mesh.blas);
	if (!mesh_timestamped) {
		RENDER_TIMESTAMP("HDDAGI HWRT Build BLAS End");
		mesh_timestamped = true;
	}
	rd->draw_command_end_label();
	return error == OK;
}

bool HDDAGIHwrt::_prepare_lods(RenderGeometryInstanceBase *p_instance, const CachedInstance &p_cached, uint64_t p_version) {
	const SourceSurface *source = _get_source_surface(p_cached.mesh.mesh, p_cached.mesh.surfaces[0]);
	if (!source) {
		return false;
	}
	// Prepare a surface's imported LODs with the initial asset/material upload.
	// Surface-level BLASes avoid the combinatorial whole-mesh LOD cache, while
	// preserving exactly the topology selected by rasterization for each surface.
	bool materials_changed = false;
	LocalVector<uint32_t> capture_lods;
	MeshKey mesh_key = p_cached.mesh;
	MaterialKey material_key = p_cached.material;
	for (int lod = 0; lod < source->indices.size(); lod++) {
		mesh_key.lods.write[0] = lod;
		material_key.lods = mesh_key.lods;
		Mesh &mesh = meshes[mesh_key];
		if (mesh.version != p_version) {
			_free_mesh(mesh);
			if (!_create_mesh(mesh_key, mesh)) {
				WARN_PRINT_ONCE("HDDAGI HWRT could not build a triangle surface; skipping that contributor.");
				_free_mesh(mesh);
			}
			mesh.family = p_cached.mesh_family;
			mesh.version = p_version;
		}
		mesh.last_seen = frame;
		if (mesh.triangle_count == 0 || (!mesh_key.deformed && mesh.blas.is_null())) {
			continue;
		}
		if (!materials.has(material_key)) {
			Material &material = materials[material_key];
			material.family = p_cached.material_family;
			// Assign stable ranges for the entire LOD batch before growing the GPU
			// pool. Existing free ranges are reused without overestimating capacity.
			material.samples = material_pool.allocate(mesh.triangle_count * MATERIAL_SAMPLES_PER_TRIANGLE, false);
			material.last_seen = frame;
			materials_changed = true;
			if (material.samples.count != 0) {
				capture_lods.push_back(lod);
			} else {
				WARN_PRINT_ONCE("HDDAGI HWRT could not allocate surface material samples; skipping that contributor.");
			}
		}
	}
	if (!capture_lods.is_empty()) {
		const bool reserved = material_pool.reserve(material_pool.used);
		for (uint32_t lod : capture_lods) {
			mesh_key.lods.write[0] = lod;
			material_key.lods = mesh_key.lods;
			Material &material = materials[material_key];
			// A failed grow must not prevent captures that fit in the old buffer.
			const bool fits = reserved || uint64_t(material.samples.offset) + material.samples.count <= material_pool.capacity;
			material.valid = fits && _capture_material(p_instance, mesh_key, meshes[mesh_key], material);
			if (!material.valid) {
				material_pool.release(material.samples);
				material.samples = Range();
				WARN_PRINT_ONCE("HDDAGI HWRT could not capture a surface material; skipping that contributor.");
			}
		}
	}
	return materials_changed;
}

bool HDDAGIHwrt::_update_deformed(RID p_mesh_instance, const Mesh &p_mesh, DeformedMesh &r_deformed, bool &r_changed) {
	MeshStorage *mesh_storage = MeshStorage::get_singleton();
	if (r_deformed.mesh_instance != p_mesh_instance || r_deformed.mesh_version != p_mesh.version) {
		_free_deformed(r_deformed);
	}
	r_deformed.last_seen = frame;
	const uint64_t version = mesh_storage->mesh_instance_get_deformation_version(p_mesh_instance);
	if (r_deformed.blas.is_valid() && r_deformed.version == version) {
		return true;
	}
	RD *rd = RD::get_singleton();
	if (deform_shader_version.is_null()) {
		if (!deform_shader_initialized) {
			Vector<String> modes;
			modes.push_back("");
			deform_shader.initialize(modes);
			deform_shader_initialized = true;
		}
		deform_shader_version = deform_shader.version_create();
		RID shader = deform_shader.version_get_shader(deform_shader_version, 0);
		if (shader.is_valid()) {
			deform_pipeline = rd->compute_pipeline_create(shader);
		}
	}
	if (deform_pipeline.is_null()) {
		return false;
	}
	if (r_deformed.blas.is_null()) {
		const uint32_t vertex_bytes = p_mesh.triangle_count * 9 * sizeof(float);
		r_deformed.vertices = rd->vertex_buffer_create(vertex_bytes, Vector<uint8_t>(),
				RD::BUFFER_CREATION_AS_STORAGE_BIT | RD::BUFFER_CREATION_DEVICE_ADDRESS_BIT | RD::BUFFER_CREATION_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT);
		r_deformed.normals = normal_pool.allocate(p_mesh.triangle_count);
		if (r_deformed.vertices.is_null() || r_deformed.normals.count == 0) {
			_free_deformed(r_deformed);
			return false;
		}
		rd->buffer_copy(p_mesh.vertices, r_deformed.vertices, 0, 0, vertex_bytes);
		rd->buffer_copy(p_mesh.normal_template, normal_pool.buffer, 0,
				r_deformed.normals.offset * normal_pool.stride, p_mesh.triangle_count * normal_pool.stride);
		RD::AccelerationStructureGeometry geometry;
		geometry.flags = RD::ACCELERATION_STRUCTURE_GEOMETRY_OPAQUE_BIT;
		geometry.vertex_buffer = r_deformed.vertices;
		geometry.vertex_stride = sizeof(float) * 3;
		geometry.vertex_count = p_mesh.triangle_count * 3;
		geometry.vertex_format = RD::DATA_FORMAT_R32G32B32_SFLOAT;
		r_deformed.blas = rd->blas_create(Span<RD::AccelerationStructureGeometry>(&geometry, 1), RD::ACCELERATION_STRUCTURE_PREFER_FAST_BUILD_BIT);
		if (r_deformed.blas.is_null()) {
			_free_deformed(r_deformed);
			return false;
		}
		r_deformed.family = p_mesh.family;
		r_deformed.mesh_instance = p_mesh_instance;
		r_deformed.mesh_version = p_mesh.version;
	}
	// Read the current native skinning buffer (including motion-vector ping-pong).
	// No bone/vertex readback, CPU skinning or material recapture per pose.
	thread_local LocalVector<RID> uniform_sets;
	uniform_sets.clear();
	RID shader = deform_shader.version_get_shader(deform_shader_version, 0);
	for (const Mesh::DeformSurface &surface : p_mesh.deform_surfaces) {
		RID source = mesh_storage->mesh_instance_surface_get_deformed_vertex_buffer(p_mesh_instance, surface.surface);
		if (source.is_null()) {
			return false;
		}
		uniform_sets.push_back(UniformSetCacheRD::get_singleton()->get_cache(shader, 0,
				RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 0, source),
				RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 1, p_mesh.triangle_indices),
				RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 2, r_deformed.vertices),
				RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 3, normal_pool.buffer)));
	}
	if (!deform_timestamped) {
		RENDER_TIMESTAMP("HDDAGI HWRT Deform BLAS");
	}
	RD::ComputeListID list = rd->compute_list_begin();
	rd->compute_list_bind_compute_pipeline(list, deform_pipeline);
	for (uint32_t i = 0; i < p_mesh.deform_surfaces.size(); i++) {
		const Mesh::DeformSurface &surface = p_mesh.deform_surfaces[i];
		const uint32_t push_constant[4] = { surface.triangle_offset, surface.triangle_count, r_deformed.normals.offset, 0 };
		rd->compute_list_bind_uniform_set(list, uniform_sets[i], 0);
		rd->compute_list_set_push_constant(list, push_constant, sizeof(push_constant));
		rd->compute_list_dispatch_threads(list, surface.triangle_count, 1, 1);
	}
	rd->compute_list_end();
	// Reuse the allocation and scratch storage. RD currently exposes BUILD only.
	const Error error = rd->blas_build(r_deformed.blas);
	if (!deform_timestamped) {
		RENDER_TIMESTAMP("HDDAGI HWRT Deform BLAS End");
		deform_timestamped = true;
	}
	if (error != OK) {
		_free_deformed(r_deformed);
		return false;
	}
	r_deformed.version = version;
	r_changed = true;
	return true;
}

uint32_t HDDAGIHwrt::MaterialKeyHasher::hash(const MaterialKey &p_key) {
	uint32_t hash = HASH_MURMUR3_SEED;
	for (uint64_t value : p_key.values) {
		hash = hash_murmur3_one_64(value, hash);
	}
	for (uint32_t lod : p_key.lods) {
		hash = hash_murmur3_one_32(lod, hash);
	}
	return hash_fmix32(hash);
}

HDDAGIHwrt::MaterialKey HDDAGIHwrt::_material_key(RenderGeometryInstanceBase *p_instance, int p_surface) const {
	MeshStorage *mesh_storage = MeshStorage::get_singleton();
	MaterialStorage *material_storage = MaterialStorage::get_singleton();
	const RID mesh = p_instance->get_hddagi_mesh();
	MaterialKey key;
	key.values.push_back(mesh.get_id());
	key.values.push_back(mesh_storage->mesh_get_data_version(mesh));
	key.values.push_back(p_instance->shader_uniforms_offset >= 0 ? p_instance->get_hddagi_instance_id() : 0);
	key.values.push_back(p_instance->shader_uniforms_offset >= 0 ? p_instance->get_hddagi_capture_version() : 0);
	key.values.push_back(p_instance->mesh_instance.is_valid() ? 1 : 0);
	key.values.push_back(p_surface);
	RID material = p_instance->data->material_override;
	if (material.is_null() && p_surface < p_instance->data->surface_materials.size()) {
		material = p_instance->data->surface_materials[p_surface];
	}
	if (material.is_null()) {
		material = mesh_storage->mesh_surface_get_material(mesh, p_surface);
	}
	key.values.push_back(material.get_id());
	key.values.push_back(material.is_valid() ? material_storage->material_get_data_version(material) : 0);
	return key;
}

bool HDDAGIHwrt::_material_is_current(const MaterialKey &p_key) const {
	MaterialStorage *storage = MaterialStorage::get_singleton();
	// Uniform value changes do not always send a scene dependency notification.
	// Check the cached RID/version pairs without rebuilding or allocating keys.
	for (int i = 6; i < p_key.values.size(); i += 2) {
		RID material = RID::from_uint64(p_key.values[i]);
		if (material.is_valid() && storage->material_get_data_version(material) != p_key.values[i + 1]) {
			return false;
		}
	}
	return true;
}

bool HDDAGIHwrt::_capture_material(RenderGeometryInstanceBase *p_instance, const MeshKey &p_key, Mesh &p_mesh, Material &r_material) {
	// Reuse the native 2D material pass with a small barycentric chart per triangle.
	// This captures only material parameters; there is no voxelization or lighting cache.
	if (p_mesh.material_mesh.is_null() && !_create_mesh(p_key, p_mesh, false)) {
		if (p_mesh.material_mesh.is_valid()) {
			MeshStorage::get_singleton()->free(p_mesh.material_mesh);
			p_mesh.material_mesh = RID();
		}
		return false;
	}
	RD *rd = RD::get_singleton();
	if (material_shader_version.is_null()) {
		if (!material_shader_initialized) {
			Vector<String> modes;
			modes.push_back("");
			material_shader.initialize(modes);
			material_shader_initialized = true;
		}
		material_shader_version = material_shader.version_create();
		RID shader = material_shader.version_get_shader(material_shader_version, 0);
		if (shader.is_valid()) {
			material_pipeline = rd->compute_pipeline_create(shader);
		}
	}
	if (material_pipeline.is_null()) {
		return false;
	}
	RendererSceneRenderRD *renderer = RendererSceneRenderRD::get_singleton();
	RD::TextureFormat format;
	format.width = p_mesh.material_size.x;
	format.height = p_mesh.material_size.y;
	format.usage_bits = RD::TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT;
	Vector<RID> textures;
	for (RD::DataFormat data_format : { RD::DATA_FORMAT_R8G8B8A8_UNORM, RD::DATA_FORMAT_R8G8B8A8_UNORM, RD::DATA_FORMAT_R8G8B8A8_UNORM, RD::DATA_FORMAT_R16G16B16A16_SFLOAT, RD::DATA_FORMAT_R32_SFLOAT }) {
		format.format = data_format;
		textures.push_back(rd->texture_create(format, RD::TextureView()));
	}
	format.usage_bits = RD::TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
	format.format = rd->texture_is_format_supported_for_usage(RD::DATA_FORMAT_D32_SFLOAT, format.usage_bits) ? RD::DATA_FORMAT_D32_SFLOAT : RD::DATA_FORMAT_X8_D24_UNORM_PACK32;
	textures.push_back(rd->texture_create(format, RD::TextureView()));
	auto release = [&]() {
		for (RID texture : textures) {
			if (texture.is_valid()) {
				rd->free_rid(texture);
			}
		}
	};
	for (RID texture : textures) {
		if (texture.is_null()) {
			release();
			return false;
		}
	}
	RID framebuffer = rd->framebuffer_create(textures);
	RenderGeometryInstance *instance = renderer->geometry_instance_create(p_mesh.material_mesh);
	if (framebuffer.is_null() || !instance) {
		if (instance) {
			renderer->geometry_instance_free(instance);
		}
		release();
		return false;
	}
	Vector<RID> overrides;
	for (int surface : p_mesh.material_surfaces) {
		RID material = p_instance->data->material_override;
		if (material.is_null() && surface < p_instance->data->surface_materials.size()) {
			material = p_instance->data->surface_materials[surface];
		}
		if (material.is_null()) {
			material = MeshStorage::get_singleton()->mesh_surface_get_material(p_instance->get_hddagi_mesh(), surface);
		}
		overrides.push_back(material);
	}
	instance->set_surface_materials(overrides);
	instance->set_instance_shader_uniforms_offset(p_instance->shader_uniforms_offset);
	PagedArrayPool<RenderGeometryInstance *> pool;
	PagedArray<RenderGeometryInstance *> capture;
	capture.set_page_pool(&pool);
	capture.push_back(instance);
	DEV_ASSERT(r_material.samples.count == p_mesh.triangle_count * MATERIAL_SAMPLES_PER_TRIANGLE);
	if (!material_timestamped) {
		RENDER_TIMESTAMP("HDDAGI HWRT Material Capture");
	}
	renderer->_render_uv2(capture, framebuffer, Rect2i(Vector2i(), p_mesh.material_size), false);
	renderer->geometry_instance_free(instance);
	const uint32_t params[4] = { uint32_t(p_mesh.material_size.x), uint32_t(p_mesh.material_size.y), p_mesh.triangle_count, r_material.samples.offset };
	RID sampler = MaterialStorage::get_singleton()->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
	RID shader = material_shader.version_get_shader(material_shader_version, 0);
	RID uniform_set = UniformSetCacheRD::get_singleton()->get_cache(shader, 0,
			RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, Vector<RID>({ sampler, textures[0] })),
			RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, Vector<RID>({ sampler, textures[2] })),
			RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, Vector<RID>({ sampler, textures[3] })),
			RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 3, material_pool.buffer));
	RD::ComputeListID list = rd->compute_list_begin();
	rd->compute_list_bind_compute_pipeline(list, material_pipeline);
	rd->compute_list_bind_uniform_set(list, uniform_set, 0);
	rd->compute_list_set_push_constant(list, params, sizeof(params));
	rd->compute_list_dispatch_threads(list, params[0], params[1], 1);
	rd->compute_list_end();
	// RD keeps the attachments alive until the raster and packing commands finish.
	release();
	if (!material_timestamped) {
		RENDER_TIMESTAMP("HDDAGI HWRT Material Capture End");
		material_timestamped = true;
	}
	return true;
}

void HDDAGIHwrt::_free_mesh(Mesh &p_mesh) {
	normal_pool.release(p_mesh.normals);
	if (p_mesh.material_mesh.is_valid()) {
		MeshStorage::get_singleton()->free(p_mesh.material_mesh);
	}
	if (p_mesh.blas.is_valid()) {
		RD::get_singleton()->free_rid(p_mesh.blas);
	}
	if (p_mesh.vertices.is_valid()) {
		RD::get_singleton()->free_rid(p_mesh.vertices);
	}
	if (p_mesh.triangle_indices.is_valid()) {
		RD::get_singleton()->free_rid(p_mesh.triangle_indices);
	}
	if (p_mesh.normal_template.is_valid()) {
		RD::get_singleton()->free_rid(p_mesh.normal_template);
	}
	p_mesh = Mesh();
}

void HDDAGIHwrt::_free_deformed(DeformedMesh &p_mesh) {
	normal_pool.release(p_mesh.normals);
	for (RID resource : { p_mesh.blas, p_mesh.vertices }) {
		if (resource.is_valid()) {
			RD::get_singleton()->free_rid(resource);
		}
	}
	p_mesh = DeformedMesh();
}

void HDDAGIHwrt::_free_deformed_meshes(CachedInstance &p_instance) {
	for (KeyValue<MeshKey, DeformedMesh> &entry : p_instance.deformed_meshes) {
		_free_deformed(entry.value);
	}
	p_instance.deformed_meshes.clear();
}

void HDDAGIHwrt::_evict_unused() {
	// A different LOD of a contributing asset is part of its working set, not
	// an off-scene asset. Applying the inactive budget to these siblings makes
	// camera motion evict and rebuild the same geometry/materials continuously.
	next_eviction_frame = UINT64_MAX;
	struct Candidate {
		MeshKey mesh;
		MaterialKey material;
		uint64_t last_seen = 0;
		uint64_t bytes = 0;
		bool is_material = false;
		InstanceKey instance;
		RID source;
		bool operator<(const Candidate &p_other) const { return last_seen < p_other.last_seen; }
	};
	LocalVector<Candidate> unused;
	uint64_t unused_bytes = 0;
	for (KeyValue<MeshKey, Mesh> &entry : meshes) {
		const MeshFamily *family = mesh_families.getptr(entry.value.family);
		if (family && family->version == entry.value.version) {
			entry.value.last_seen = MAX(entry.value.last_seen, family->last_seen);
		}
		if (entry.value.last_seen != frame) {
			unused.push_back({ entry.key, MaterialKey(), entry.value.last_seen, entry.value.bytes, false });
			unused_bytes += entry.value.bytes;
		}
	}
	for (KeyValue<MaterialKey, Material> &entry : materials) {
		const uint64_t *last_seen = material_families.getptr(entry.value.family);
		if (last_seen) {
			entry.value.last_seen = MAX(entry.value.last_seen, *last_seen);
		}
		if (entry.value.last_seen != frame) {
			const uint64_t bytes = uint64_t(entry.value.samples.count) * material_pool.stride;
			unused.push_back({ MeshKey(), entry.key, entry.value.last_seen, bytes, true });
			unused_bytes += bytes;
		}
	}
	for (KeyValue<InstanceKey, CachedInstance> &entry : cached_instances) {
		for (KeyValue<MeshKey, DeformedMesh> &deformed : entry.value.deformed_meshes) {
			const MeshFamily *family = mesh_families.getptr(deformed.value.family);
			if (family && family->version == deformed.value.mesh_version && entry.value.mesh_family == deformed.value.family) {
				deformed.value.last_seen = MAX(deformed.value.last_seen, MIN(entry.value.last_seen, family->last_seen));
			}
			if (deformed.value.last_seen != frame && deformed.value.blas.is_valid()) {
				const uint64_t bytes = uint64_t(deformed.value.normals.count) * 160;
				unused.push_back({ deformed.key, MaterialKey(), deformed.value.last_seen, bytes, false, entry.key });
				unused_bytes += bytes;
			}
		}
	}
	for (KeyValue<RID, SourceMesh> &entry : source_meshes) {
		if (entry.value.last_seen != frame) {
			unused.push_back({ MeshKey(), MaterialKey(), entry.value.last_seen, entry.value.bytes, false, InstanceKey(), entry.key });
			unused_bytes += entry.value.bytes;
		}
	}
	unused.sort();
	for (const Candidate &candidate : unused) {
		if (frame - candidate.last_seen <= CACHE_KEEP_FRAMES && unused_bytes <= CACHE_MAX_UNUSED_BYTES) {
			next_eviction_frame = candidate.last_seen + CACHE_KEEP_FRAMES + 1;
			break;
		}
		unused_bytes -= candidate.bytes;
		if (candidate.source.is_valid()) {
			source_meshes.erase(candidate.source);
		} else if (candidate.instance.id != 0) {
			CachedInstance &instance = cached_instances[candidate.instance];
			_free_deformed(instance.deformed_meshes[candidate.mesh]);
			instance.deformed_meshes.erase(candidate.mesh);
		} else if (candidate.is_material) {
			material_pool.release(materials[candidate.material].samples);
			materials.erase(candidate.material);
		} else {
			_free_mesh(meshes[candidate.mesh]);
			meshes.erase(candidate.mesh);
		}
	}
	LocalVector<InstanceKey> removed_instances;
	for (const KeyValue<InstanceKey, CachedInstance> &entry : cached_instances) {
		if (frame - entry.value.last_seen > CACHE_KEEP_FRAMES) {
			removed_instances.push_back(entry.key);
		} else if (entry.value.last_seen != frame) {
			next_eviction_frame = MIN(next_eviction_frame, entry.value.last_seen + CACHE_KEEP_FRAMES + 1);
		}
	}
	for (const InstanceKey &id : removed_instances) {
		if (cached_instances[id].instance.key.id != 0) {
			free_metadata_indices.push_back(cached_instances[id].instance.metadata_index);
		}
		_free_deformed_meshes(cached_instances[id]);
		cached_instances.erase(id);
	}
	LocalVector<MeshKey> removed_mesh_families;
	for (const KeyValue<MeshKey, MeshFamily> &entry : mesh_families) {
		if (frame - entry.value.last_seen > CACHE_KEEP_FRAMES) {
			removed_mesh_families.push_back(entry.key);
		} else if (entry.value.last_seen != frame) {
			next_eviction_frame = MIN(next_eviction_frame, entry.value.last_seen + CACHE_KEEP_FRAMES + 1);
		}
	}
	for (const MeshKey &key : removed_mesh_families) {
		mesh_families.erase(key);
	}
	LocalVector<MaterialKey> removed_material_families;
	for (const KeyValue<MaterialKey, uint64_t> &entry : material_families) {
		if (frame - entry.value > CACHE_KEEP_FRAMES) {
			removed_material_families.push_back(entry.key);
		} else if (entry.value != frame) {
			next_eviction_frame = MIN(next_eviction_frame, entry.value + CACHE_KEEP_FRAMES + 1);
		}
	}
	for (const MaterialKey &key : removed_material_families) {
		material_families.erase(key);
	}
}

void HDDAGIHwrt::update(const PagedArray<RenderGeometryInstance *> *p_instances, const RenderSceneDataRD *p_scene_data) {
	const Vector3 &p_origin = p_scene_data->cam_transform.origin;
	const float max_distance = CLAMP(GLOBAL_GET_CACHED(float, "rendering/global_illumination/hddagi/screen_probe_hwrt_max_distance"), 1.0f, 65504.0f);
	const Vector3 extent = Vector3(1, 1, 1) * max_distance;
	const AABB required_bounds(p_origin - extent, extent * 2.0f);
	// Keep a guard band around the requested coverage. Ordinary camera motion
	// neither evicts contributors nor changes their TLAS membership at every edge.
	if (scene_data.max_distance != max_distance || !bounds.encloses(required_bounds)) {
		bounds = required_bounds.grow(MIN(max_distance * 0.1f, 10.0f));
	}
	scene_data.max_distance = max_distance;
	if (!p_instances || !is_supported()) {
		if (p_instances && !is_supported()) {
			WARN_PRINT_ONCE("HDDAGI HWRT requires hardware ray queries; screen-probe GI is unavailable.");
		}
		free();
		return;
	}
	frame++;
	mesh_timestamped = false;
	material_timestamped = false;
	deform_timestamped = false;
	normal_pool.stride = sizeof(float) * 4;
	material_pool.stride = sizeof(uint32_t) * 2;
	material_pool.growth_quantum = (64 * 1024 * 1024) / material_pool.stride;
	MeshStorage *mesh_storage = MeshStorage::get_singleton();
	// Scene culling skins camera/shadow-visible meshes. GI also needs animated
	// contributors outside those lists, bounded by its independent scene coverage.
	bool has_deformed = false;
	for (uint32_t i = 0; i < p_instances->size(); i++) {
		RenderGeometryInstanceBase *geometry = static_cast<RenderGeometryInstanceBase *>((*p_instances)[i]);
		if (geometry->mesh_instance.is_valid() && bounds.intersects(geometry->transformed_aabb) && _supports_instance(geometry)) {
			mesh_storage->mesh_instance_check_for_update(geometry->mesh_instance);
			has_deformed = true;
		}
	}
	if (has_deformed) {
		mesh_storage->update_mesh_instances();
	}
	next_instances.clear();
	bool materials_changed = false;
	bool deformation_changed = false;
	bool cache_membership_changed = false;
	uint32_t active_cache_instances = 0;
	for (uint32_t i = 0; i < p_instances->size(); i++) {
		RenderGeometryInstanceBase *geometry = static_cast<RenderGeometryInstanceBase *>((*p_instances)[i]);
		if (!bounds.intersects(geometry->transformed_aabb)) {
			continue;
		}
		if (!_supports_instance(geometry)) {
			// Unsupported contributors do not disable hardware tracing for the rest of the scene.
			continue;
		}
		const uint64_t id = geometry->get_hddagi_instance_id();
		const RID mesh_rid = geometry->get_hddagi_mesh();
		const uint64_t version = mesh_storage->mesh_get_data_version(mesh_rid);
		for (int surface = 0; surface < mesh_storage->mesh_get_surface_count(mesh_rid); surface++) {
			const InstanceKey instance_key{ id, uint32_t(surface) };
			CachedInstance &cached = cached_instances[instance_key];
			cache_membership_changed = cache_membership_changed || cached.last_seen != frame - 1;
			if (cached.material.values.is_empty() || cached.mesh.mesh != mesh_rid || cached.mesh.deformed != geometry->mesh_instance.is_valid() || cached.material.values[1] != version ||
					cached.capture_version != geometry->get_hddagi_capture_version() || !_material_is_current(cached.material)) {
				cached.mesh = _mesh_key(geometry, surface);
				MaterialKey material_key = _material_key(geometry, surface);
				cache_membership_changed = cache_membership_changed || cached.material.values != material_key.values;
				if (cached.instance.key.id != 0 && cached.material.values != material_key.values) {
					lighting_version++;
				}
				cached.material = material_key;
				cached.mesh_family = cached.mesh;
				cached.mesh_family.lods.clear();
				cached.material_family = cached.material;
				cached.material_family.lods.clear();
				cached.capture_version = geometry->get_hddagi_capture_version();
			}
			cached.last_seen = frame;
			active_cache_instances++;
			if (_update_mesh_lods(geometry, p_scene_data, cached.mesh) || cached.material.lods.is_empty()) {
				cached.material.lods = cached.mesh.lods;
			}
			const MeshKey &key = cached.mesh;
			if (key.surfaces.is_empty()) {
				continue;
			}
			MeshFamily &family = mesh_families[cached.mesh_family];
			uint64_t &material_last_seen = material_families[cached.material_family];
			// An off-scene family may have been partially evicted by the inactive
			// budget. Restore its siblings on reentry, before the next LOD switch.
			const bool restore_lods = family.last_seen < frame - 1 || material_last_seen < frame - 1;
			family.last_seen = frame;
			family.version = version;
			material_last_seen = frame;
			SourceMesh *source = source_meshes.getptr(mesh_rid);
			if (source && source->version == version) {
				source->last_seen = frame;
			}
			Mesh *existing = meshes.getptr(key);
			if (restore_lods || !existing || existing->version != version || !materials.has(cached.material)) {
				materials_changed = _prepare_lods(geometry, cached, version) || materials_changed;
			}
			Mesh &mesh = meshes[key];
			mesh.last_seen = frame;
			if (mesh.triangle_count == 0 || (!key.deformed && mesh.blas.is_null())) {
				continue;
			}
			Material *material = materials.getptr(cached.material);
			if (!material || !material->valid) {
				continue;
			}
			material->last_seen = frame;
			Instance instance;
			instance.key = instance_key;
			instance.mesh_version = version;
			instance.blas = mesh.blas;
			instance.transform = geometry->transform;
			instance.normal_offset = mesh.normals.offset;
			if (key.deformed) {
				DeformedMesh &deformed = cached.deformed_meshes[key];
				if (!_update_deformed(geometry->mesh_instance, mesh, deformed, deformation_changed)) {
					WARN_PRINT_ONCE("HDDAGI HWRT could not update a deformed mesh; skipping that contributor.");
					continue;
				}
				instance.blas = deformed.blas;
				instance.deformation_version = deformed.version;
				instance.normal_offset = deformed.normals.offset;
			}
			instance.material_offset = material->samples.offset;
			if (cached.instance.key.id != 0) {
				instance.metadata_index = cached.instance.metadata_index;
			} else if (!free_metadata_indices.is_empty()) {
				instance.metadata_index = free_metadata_indices[free_metadata_indices.size() - 1];
				free_metadata_indices.resize(free_metadata_indices.size() - 1);
			} else {
				instance.metadata_index = metadata_count++;
			}
			// Stable metadata slots keep unrelated cache surfaces valid when TLAS
			// membership changes. Material changes do not alter incident irradiance.
			instance.surface_version = cached.instance.same_geometry(instance) ? cached.instance.surface_version : ++surface_version;
			cached.instance = instance;
			next_instances.push_back(instance);
		}
	}
	for (const MeshKey &key : material_meshes_to_release) {
		Mesh *mesh = meshes.getptr(key);
		if (mesh && mesh->material_mesh.is_valid()) {
			mesh_storage->free(mesh->material_mesh);
			mesh->material_mesh = RID();
		}
	}
	material_meshes_to_release.clear();
	// Family timestamps are maintained above. Scan retained LODs only when the
	// asset working set changes or an inactive entry actually reaches its TTL.
	if (cache_membership_changed || materials_changed || active_cache_instances != cache_instance_count || frame >= next_eviction_frame) {
		_evict_unused();
	}
	cache_instance_count = active_cache_instances;
	// Cull result ordering can change with worker scheduling.
	next_instances.sort();
	bool geometry_changed = !ready || instances.size() != next_instances.size();
	bool metadata_changed = geometry_changed;
	geometry_changed = geometry_changed || deformation_changed;
	for (uint32_t i = 0; i < MIN(instances.size(), next_instances.size()); i++) {
		geometry_changed = geometry_changed || !instances[i].same_geometry(next_instances[i]);
		metadata_changed = metadata_changed || instances[i].normal_offset != next_instances[i].normal_offset || instances[i].material_offset != next_instances[i].material_offset;
	}
	metadata_changed = metadata_changed || geometry_changed;
	if (!geometry_changed && !metadata_changed && !materials_changed) {
		return;
	}
	ready = false;
	scene_version++;
	RD *rd = RD::get_singleton();
	if (scene_buffer.is_null()) {
		scene_buffer = rd->uniform_buffer_create(sizeof(SceneData));
	}
	// Valid bindings are also required for the empty scene; no hit reads them.
	normal_pool.reserve(1);
	material_pool.reserve(1);
	// RD needs nonzero allocation capacity even when building zero instances.
	const uint32_t required_capacity = MAX(1u, metadata_count);
	if (required_capacity > instance_capacity) {
		if (tlas.is_valid()) {
			rd->free_rid(tlas);
		}
		if (instance_buffer.is_valid()) {
			rd->free_rid(instance_buffer);
		}
		instance_capacity = Math::nearest_power_of_2_templated(required_capacity);
		tlas = rd->tlas_create(instance_capacity, RD::ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT);
		instance_buffer = rd->storage_buffer_create(instance_capacity * 4 * sizeof(uint32_t));
	}
	if (tlas.is_null() || normal_pool.buffer.is_null() || instance_buffer.is_null() || material_pool.buffer.is_null() || scene_buffer.is_null() || metadata_count > 0x1000000u) {
		WARN_PRINT_ONCE("HDDAGI HWRT scene allocation failed; screen-probe GI is unavailable.");
		free();
		return;
	}
	if (metadata_changed) {
		LocalVector<uint32_t> metadata;
		metadata.resize(instance_capacity * 4);
		memset(metadata.ptr(), 0, metadata.size() * sizeof(uint32_t));
		for (uint32_t i = 0; i < next_instances.size(); i++) {
			const Instance &instance = next_instances[i];
			const uint32_t base = instance.metadata_index * 4;
			metadata[base] = instance.normal_offset;
			metadata[base + 1] = instance.material_offset;
			metadata[base + 2] = uint32_t(instance.surface_version);
			metadata[base + 3] = uint32_t(instance.surface_version >> 32);
		}
		rd->buffer_update(instance_buffer, 0, metadata.size() * sizeof(uint32_t), metadata.ptr());
	}
	if (geometry_changed) {
		thread_local LocalVector<RD::AccelerationStructureInstance> build_instances;
		build_instances.resize(next_instances.size());
		for (uint32_t i = 0; i < next_instances.size(); i++) {
			RD::AccelerationStructureInstance &build = build_instances[i];
			build.transform = next_instances[i].transform;
			build.id = next_instances[i].metadata_index;
			build.blas = next_instances[i].blas;
			build.flags = RD::ACCELERATION_STRUCTURE_INSTANCE_TRIANGLE_FACING_CULL_DISABLE_BIT;
		}
		// Material updates never rebuild AS. Geometry/membership changes still use
		// RD's BUILD path, including an empty TLAS when every contributor is skipped.
		rd->draw_command_begin_label("HDDAGI HWRT Build TLAS");
		RENDER_TIMESTAMP("HDDAGI HWRT Build TLAS");
		Error error = rd->tlas_build(tlas, build_instances.span());
		RENDER_TIMESTAMP("HDDAGI HWRT Build TLAS End");
		rd->draw_command_end_label();
		if (error != OK) {
			WARN_PRINT_ONCE("HDDAGI HWRT TLAS build failed; screen-probe GI is unavailable.");
			free();
			return;
		}
	}
	SWAP(instances, next_instances);
	ready = true;
}

void HDDAGIHwrt::update_lights(RID p_lights_buffer, uint32_t p_light_count, float p_exposure, float p_bounce_feedback, uint32_t p_lighting_signature) {
	if (lighting_signature != p_lighting_signature) {
		lighting_signature = p_lighting_signature;
		lighting_version++;
	}
	lights_buffer = p_lights_buffer;
	scene_data.light_count = p_light_count;
	scene_data.exposure = p_exposure;
	scene_data.bounce_feedback = p_bounce_feedback;
	if (scene_buffer.is_valid()) {
		RD::get_singleton()->buffer_update(scene_buffer, 0, sizeof(SceneData), &scene_data);
	}
}

void HDDAGIHwrt::append_uniforms(LocalVector<RD::Uniform> &r_uniforms) const {
	DEV_ASSERT(ready);
	r_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_ACCELERATION_STRUCTURE, 45, tlas));
	r_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 46, instance_buffer));
	r_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 47, normal_pool.buffer));
	r_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 48, material_pool.buffer));
	r_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 49, lights_buffer));
	r_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_UNIFORM_BUFFER, 50, scene_buffer));
	r_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 51, TextureStorage::get_singleton()->area_light_atlas_get_texture()));
	r_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER, 52, MaterialStorage::get_singleton()->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR_WITH_MIPMAPS, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED)));
}

void HDDAGIHwrt::free() {
	RD *rd = RD::get_singleton();
	for (RID resource : { tlas, instance_buffer, scene_buffer }) {
		if (resource.is_valid()) {
			rd->free_rid(resource);
		}
	}
	tlas = RID();
	instance_buffer = RID();
	scene_buffer = RID();
	lights_buffer = RID();
	for (KeyValue<MeshKey, Mesh> &entry : meshes) {
		_free_mesh(entry.value);
	}
	meshes.clear();
	material_meshes_to_release.clear();
	mesh_families.clear();
	material_families.clear();
	source_meshes.clear();
	materials.clear();
	for (KeyValue<InstanceKey, CachedInstance> &entry : cached_instances) {
		_free_deformed_meshes(entry.value);
	}
	cached_instances.clear();
	metadata_count = 0;
	next_eviction_frame = 0;
	cache_instance_count = 0;
	free_metadata_indices.clear();
	instances.clear();
	next_instances.clear();
	normal_pool.free();
	material_pool.free();
	if (material_shader_version.is_valid()) {
		material_shader.version_free(material_shader_version);
		material_shader_version = RID();
		material_pipeline = RID();
	}
	if (deform_shader_version.is_valid()) {
		deform_shader.version_free(deform_shader_version);
		deform_shader_version = RID();
		deform_pipeline = RID();
	}
	instance_capacity = 0;
	bounds = AABB();
	ready = false;
}
