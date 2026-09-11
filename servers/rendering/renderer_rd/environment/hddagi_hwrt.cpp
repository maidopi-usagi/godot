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
#include "servers/rendering/renderer_rd/renderer_scene_render_rd.h"
#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"
#include "servers/rendering/renderer_rd/storage_rd/mesh_storage.h"
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
	const uint64_t new_capacity = Math::nearest_power_of_2_templated(MAX(uint64_t(p_count), uint64_t(16)));
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

HDDAGIHwrt::Range HDDAGIHwrt::Pool::allocate(uint32_t p_count) {
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
	if (p_count > UINT32_MAX - used || !reserve(used + p_count)) {
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
	if (p_instance->data->base_type != RSE::INSTANCE_MESH || p_instance->data->skeleton.is_valid() || p_instance->mesh_instance.is_valid() ||
			p_instance->data->material_overlay.is_valid() || !p_instance->transform.is_finite() || p_instance->transform.basis.determinant() == 0) {
		return false;
	}
	return true;
}

uint32_t HDDAGIHwrt::MeshKeyHasher::hash(const MeshKey &p_key) {
	uint32_t hash = hash_murmur3_one_64(p_key.mesh.get_id());
	for (int surface : p_key.surfaces) {
		hash = hash_murmur3_one_32(surface, hash);
	}
	return hash_fmix32(hash);
}

HDDAGIHwrt::MeshKey HDDAGIHwrt::_mesh_key(RenderGeometryInstanceBase *p_instance) const {
	MeshKey key;
	key.mesh = p_instance->get_hddagi_mesh();
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
	for (int surface = 0; surface < mesh_storage->mesh_get_surface_count(mesh); surface++) {
		void *surface_data = mesh_storage->mesh_get_surface(mesh, uint32_t(surface));
		if (mesh_storage->mesh_surface_get_primitive(surface_data) != RSE::PRIMITIVE_TRIANGLES ||
				(mesh_storage->mesh_surface_get_format(surface_data) & RSE::ARRAY_FLAG_USE_2D_VERTICES)) {
			continue;
		}
		RID material = p_instance->data->material_override;
		if (material.is_null() && surface < p_instance->data->surface_materials.size()) {
			material = p_instance->data->surface_materials[surface];
		}
		if (material.is_null()) {
			material = mesh_storage->mesh_surface_get_material(mesh, surface);
		}
		if (supports_material(material)) {
			key.surfaces.push_back(surface);
		}
	}
	return key;
}

bool HDDAGIHwrt::_create_mesh(const MeshKey &p_key, Mesh &r_mesh) {
	const MeshStorage *mesh_storage = MeshStorage::get_singleton();
	LocalVector<float> vertices;
	LocalVector<float> normals;
	Vector<Array> material_arrays;
	// Keep opaque surfaces of imported meshes which also contain unsupported
	// materials. The supported subset is part of the shared BLAS cache key.
	for (int surface : p_key.surfaces) {
		// Decode with the existing mesh codec, including compressed imported meshes.
		// Readback/upload happens only when mesh data changes, never for rigid motion.
		const RenderingServerTypes::SurfaceData surface_data = mesh_storage->mesh_get_surface(p_key.mesh, surface);
		Array arrays = RenderingServer::get_singleton()->mesh_create_arrays_from_surface_data(surface_data);
		if (arrays.size() != RSE::ARRAY_MAX) {
			return false;
		}
		const Vector<Vector3> positions = arrays[RSE::ARRAY_VERTEX];
		const Vector<int> indices = arrays[RSE::ARRAY_INDEX];
		const Vector<Vector3> source_normals = arrays[RSE::ARRAY_NORMAL];
		const Vector<float> source_tangents = arrays[RSE::ARRAY_TANGENT];
		const Vector<Color> source_colors = arrays[RSE::ARRAY_COLOR];
		const Vector<Vector2> source_uv = arrays[RSE::ARRAY_TEX_UV];
		Vector<Vector3> bake_positions;
		Vector<Vector3> bake_normals;
		Vector<float> bake_tangents;
		Vector<Color> bake_colors;
		Vector<Vector2> bake_uv;
		Vector<Vector2> bake_uv2;
		const uint32_t count = indices.is_empty() ? positions.size() : indices.size();
		if (count % 3 != 0) {
			return false;
		}
		for (uint32_t triangle = 0; triangle < count; triangle += 3) {
			Vector3 points[3];
			for (uint32_t corner = 0; corner < 3; corner++) {
				int index = indices.is_empty() ? int(triangle + corner) : indices[triangle + corner];
				if (index < 0 || index >= positions.size() || !positions[index].is_finite()) {
					return false;
				}
				points[corner] = positions[index];
			}
			Vector3 normal = (points[1] - points[0]).cross(points[2] - points[0]);
			if (normal.length_squared() == 0.0) {
				continue;
			}
			normal.normalize();
			const uint32_t primitive = normals.size() / 4;
			for (uint32_t corner = 0; corner < 3; corner++) {
				const int index = indices.is_empty() ? int(triangle + corner) : indices[triangle + corner];
				bake_positions.push_back(points[corner]);
				bake_normals.push_back(source_normals.is_empty() ? -normal : source_normals[index]);
				if (!source_tangents.is_empty()) {
					for (int axis = 0; axis < 4; axis++) {
						bake_tangents.push_back(source_tangents[index * 4 + axis]);
					}
				}
				if (!source_colors.is_empty()) {
					bake_colors.push_back(source_colors[index]);
				}
				if (!source_uv.is_empty()) {
					bake_uv.push_back(source_uv[index]);
				}
				Vector2 uv2(primitive % MATERIAL_TILES_PER_ROW, primitive / MATERIAL_TILES_PER_ROW);
				uv2 *= MATERIAL_TILE_SIZE;
				uv2 += Vector2(0.5, 0.5);
				uv2 += Vector2(corner == 1 ? MATERIAL_TILE_SIZE - 1 : 0, corner == 2 ? MATERIAL_TILE_SIZE - 1 : 0);
				bake_uv2.push_back(uv2);
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
		if (!bake_positions.is_empty()) {
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
	// Reading a newly encountered source mesh flushes RD's current frame and
	// timestamp queries. Profile the first asset in the new command batch too.
	mesh_timestamped = false;
	material_timestamped = false;
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
	r_mesh.vertices = rd->vertex_buffer_create(vertices.size() * sizeof(float),
			Span<uint8_t>(reinterpret_cast<const uint8_t *>(vertices.ptr()), vertices.size() * sizeof(float)),
			RD::BUFFER_CREATION_DEVICE_ADDRESS_BIT | RD::BUFFER_CREATION_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT);
	if (r_mesh.vertices.is_null()) {
		return false;
	}
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
	r_mesh.normals = normal_pool.allocate(triangle_count);
	if (r_mesh.normals.count == 0) {
		return false;
	}
	rd->buffer_update(normal_pool.buffer, r_mesh.normals.offset * normal_pool.stride, normals.size() * sizeof(float), normals.ptr());
	r_mesh.bytes = uint64_t(vertices.size()) * sizeof(float) * 4 + uint64_t(triangle_count) * 128;
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

uint32_t HDDAGIHwrt::MaterialKeyHasher::hash(const MaterialKey &p_key) {
	uint32_t hash = HASH_MURMUR3_SEED;
	for (uint64_t value : p_key.values) {
		hash = hash_murmur3_one_64(value, hash);
	}
	return hash_fmix32(hash);
}

HDDAGIHwrt::MaterialKey HDDAGIHwrt::_material_key(RenderGeometryInstanceBase *p_instance) const {
	MeshStorage *mesh_storage = MeshStorage::get_singleton();
	MaterialStorage *material_storage = MaterialStorage::get_singleton();
	const RID mesh = p_instance->get_hddagi_mesh();
	MaterialKey key;
	key.values.push_back(mesh.get_id());
	key.values.push_back(mesh_storage->mesh_get_data_version(mesh));
	key.values.push_back(p_instance->shader_uniforms_offset >= 0 ? p_instance->get_hddagi_instance_id() : 0);
	key.values.push_back(p_instance->shader_uniforms_offset >= 0 ? p_instance->get_hddagi_capture_version() : 0);
	for (int surface = 0; surface < mesh_storage->mesh_get_surface_count(mesh); surface++) {
		RID material = p_instance->data->material_override;
		if (material.is_null() && surface < p_instance->data->surface_materials.size()) {
			material = p_instance->data->surface_materials[surface];
		}
		if (material.is_null()) {
			material = mesh_storage->mesh_surface_get_material(mesh, surface);
		}
		key.values.push_back(material.get_id());
		key.values.push_back(material.is_valid() ? material_storage->material_get_data_version(material) : 0);
	}
	return key;
}

bool HDDAGIHwrt::_material_is_current(const MaterialKey &p_key) const {
	MaterialStorage *storage = MaterialStorage::get_singleton();
	// Uniform value changes do not always send a scene dependency notification.
	// Check the cached RID/version pairs without rebuilding or allocating keys.
	for (int i = 4; i < p_key.values.size(); i += 2) {
		RID material = RID::from_uint64(p_key.values[i]);
		if (material.is_valid() && storage->material_get_data_version(material) != p_key.values[i + 1]) {
			return false;
		}
	}
	return true;
}

bool HDDAGIHwrt::_capture_material(RenderGeometryInstanceBase *p_instance, const Mesh &p_mesh, Material &r_material) {
	// Reuse the native 2D material pass with a small barycentric chart per triangle.
	// This captures only material parameters; there is no voxelization or lighting cache.
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
	r_material.samples = material_pool.allocate(p_mesh.normals.count * MATERIAL_TILE_SIZE * MATERIAL_TILE_SIZE);
	if (r_material.samples.count == 0) {
		renderer->geometry_instance_free(instance);
		release();
		return false;
	}
	if (!material_timestamped) {
		RENDER_TIMESTAMP("HDDAGI HWRT Material Capture");
	}
	renderer->_render_uv2(capture, framebuffer, Rect2i(Vector2i(), p_mesh.material_size), false);
	renderer->geometry_instance_free(instance);
	const uint32_t params[4] = { uint32_t(p_mesh.material_size.x), uint32_t(p_mesh.material_size.y), p_mesh.normals.count, r_material.samples.offset };
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
	p_mesh = Mesh();
}

void HDDAGIHwrt::_evict_unused() {
	struct Candidate {
		MeshKey mesh;
		MaterialKey material;
		uint64_t last_seen = 0;
		uint64_t bytes = 0;
		bool is_material = false;
		bool operator<(const Candidate &p_other) const { return last_seen < p_other.last_seen; }
	};
	LocalVector<Candidate> unused;
	uint64_t unused_bytes = 0;
	for (const KeyValue<MeshKey, Mesh> &entry : meshes) {
		if (entry.value.last_seen != frame) {
			unused.push_back({ entry.key, MaterialKey(), entry.value.last_seen, entry.value.bytes, false });
			unused_bytes += entry.value.bytes;
		}
	}
	for (const KeyValue<MaterialKey, Material> &entry : materials) {
		if (entry.value.last_seen != frame) {
			const uint64_t bytes = uint64_t(entry.value.samples.count) * material_pool.stride;
			unused.push_back({ MeshKey(), entry.key, entry.value.last_seen, bytes, true });
			unused_bytes += bytes;
		}
	}
	unused.sort();
	for (const Candidate &candidate : unused) {
		if (frame - candidate.last_seen <= CACHE_KEEP_FRAMES && unused_bytes <= CACHE_MAX_UNUSED_BYTES) {
			break;
		}
		unused_bytes -= candidate.bytes;
		if (candidate.is_material) {
			material_pool.release(materials[candidate.material].samples);
			materials.erase(candidate.material);
		} else {
			_free_mesh(meshes[candidate.mesh]);
			meshes.erase(candidate.mesh);
		}
	}
	LocalVector<uint64_t> removed_instances;
	for (const KeyValue<uint64_t, CachedInstance> &entry : cached_instances) {
		if (frame - entry.value.last_seen > CACHE_KEEP_FRAMES) {
			removed_instances.push_back(entry.key);
		}
	}
	for (uint64_t id : removed_instances) {
		cached_instances.erase(id);
	}
}

void HDDAGIHwrt::update(const PagedArray<RenderGeometryInstance *> *p_instances, const Vector3 &p_origin) {
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
	normal_pool.stride = sizeof(float) * 4;
	material_pool.stride = sizeof(uint32_t) * 2;
	MeshStorage *mesh_storage = MeshStorage::get_singleton();
	next_instances.clear();
	bool materials_changed = false;
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
		CachedInstance &cached = cached_instances[id];
		if (cached.material.values.is_empty() || cached.mesh.mesh != mesh_rid || cached.material.values[1] != version ||
				cached.capture_version != geometry->get_hddagi_capture_version() || !_material_is_current(cached.material)) {
			cached.mesh = _mesh_key(geometry);
			cached.material = _material_key(geometry);
			cached.capture_version = geometry->get_hddagi_capture_version();
		}
		cached.last_seen = frame;
		const MeshKey &key = cached.mesh;
		if (key.surfaces.is_empty()) {
			continue;
		}
		Mesh &mesh = meshes[key];
		if (mesh.version != version) {
			_free_mesh(mesh);
			if (!_create_mesh(key, mesh)) {
				WARN_PRINT_ONCE("HDDAGI HWRT could not build a triangle mesh; skipping that contributor.");
				_free_mesh(mesh);
			}
			mesh.version = version;
		}
		mesh.last_seen = frame;
		if (mesh.blas.is_null()) {
			continue;
		}
		Instance instance;
		instance.id = id;
		instance.blas = mesh.blas;
		instance.transform = geometry->transform;
		instance.normal_offset = mesh.normals.offset;
		Material *material = materials.getptr(cached.material);
		if (!material) {
			material = &materials[cached.material];
			material->valid = _capture_material(geometry, mesh, *material);
			materials_changed = true;
			if (!material->valid) {
				WARN_PRINT_ONCE("HDDAGI HWRT could not capture a mesh material; skipping that contributor.");
			}
		}
		material->last_seen = frame;
		if (!material->valid) {
			continue;
		}
		instance.material_offset = material->samples.offset;
		next_instances.push_back(instance);
	}
	_evict_unused();
	// Cull result ordering can change with worker scheduling.
	next_instances.sort();
	bool geometry_changed = !ready || instances.size() != next_instances.size();
	bool metadata_changed = geometry_changed;
	for (uint32_t i = 0; i < MIN(instances.size(), next_instances.size()); i++) {
		geometry_changed = geometry_changed || !instances[i].same_geometry(next_instances[i]);
		metadata_changed = metadata_changed || instances[i].normal_offset != next_instances[i].normal_offset || instances[i].material_offset != next_instances[i].material_offset;
	}
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
	const uint32_t required_capacity = MAX(1u, next_instances.size());
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
	if (tlas.is_null() || normal_pool.buffer.is_null() || instance_buffer.is_null() || material_pool.buffer.is_null() || scene_buffer.is_null() || next_instances.size() > 0x1000000u) {
		WARN_PRINT_ONCE("HDDAGI HWRT scene allocation failed; screen-probe GI is unavailable.");
		free();
		return;
	}
	if (metadata_changed && !next_instances.is_empty()) {
		LocalVector<uint32_t> metadata;
		metadata.resize(next_instances.size() * 4);
		for (uint32_t i = 0; i < next_instances.size(); i++) {
			metadata[i * 4] = next_instances[i].normal_offset;
			metadata[i * 4 + 1] = next_instances[i].material_offset;
			metadata[i * 4 + 2] = 0;
			metadata[i * 4 + 3] = 0;
		}
		rd->buffer_update(instance_buffer, 0, metadata.size() * sizeof(uint32_t), metadata.ptr());
	}
	if (geometry_changed) {
		LocalVector<RD::AccelerationStructureInstance> build_instances;
		build_instances.resize(next_instances.size());
		for (uint32_t i = 0; i < next_instances.size(); i++) {
			RD::AccelerationStructureInstance &build = build_instances[i];
			build.transform = next_instances[i].transform;
			build.id = i;
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

void HDDAGIHwrt::update_lights(RID p_lights_buffer, uint32_t p_light_count, float p_exposure, float p_bounce_feedback) {
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
	materials.clear();
	cached_instances.clear();
	instances.clear();
	next_instances.clear();
	normal_pool.free();
	material_pool.free();
	if (material_shader_version.is_valid()) {
		material_shader.version_free(material_shader_version);
		material_shader_version = RID();
		material_pipeline = RID();
	}
	instance_capacity = 0;
	bounds = AABB();
	ready = false;
}
