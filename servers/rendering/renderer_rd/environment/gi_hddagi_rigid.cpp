/**************************************************************************/
/*  gi_hddagi_rigid.cpp                                                    */
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

#include "gi.h"

#include "servers/rendering/renderer_rd/renderer_scene_render_rd.h"
#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"
#include "servers/rendering/renderer_rd/storage_rd/render_scene_buffers_rd.h"
#include "servers/rendering/renderer_rd/storage_rd/texture_storage.h"
#include "servers/rendering/renderer_rd/storage_rd/utilities.h"
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"
#include "servers/rendering/rendering_server_globals.h"

using namespace RendererRD;

void GI::HDDAGI::update_rigid_objects(RenderDataRD *p_render_data) {
	if (hwrt_enabled) {
		DEV_ASSERT(cascades.is_empty() && voxel_bits_tex.is_null() && voxel_light_tex.is_null() && !rigid.is_active());
		RENDER_TIMESTAMP("HDDAGI HWRT Scene Update");
		hwrt.update(p_render_data->hddagi_update_data->hwrt_geometry_instances, p_render_data->scene_data);
		RENDER_TIMESTAMP("HDDAGI HWRT Scene Update End");
		return;
	}
	uint64_t membership_version = p_render_data->hddagi_update_data->rigid_membership_version;
	if (rigid_membership_version != UINT64_MAX && rigid_membership_version != membership_version) {
		// Cull already prepared this frame's static regions. Re-cull once next
		// frame when a mesh changes layers; ordinary rigid motion never does this.
		rigid_static_recapture_pending = true;
	}
	rigid_membership_version = membership_version;
	const Cascade &outer = cascades[cascades.size() - 1];
	AABB bounds(Vector3(outer.position - cascade_size / 2) * outer.cell_size, Vector3(cascade_size) * outer.cell_size);
	bounds.position.y /= y_mult;
	bounds.size.y /= y_mult;
	float exposure = p_render_data->camera_attributes.is_valid() ? RSG::camera_attributes->camera_attributes_get_exposure_normalization_factor(p_render_data->camera_attributes) : 1.0f;
	static const uint32_t inactive_intervals[] = { 1, 2, 4, 8 };
	rigid.set_history_frames((frames_to_converge + 1) * inactive_intervals[gi->inactive_probe_frames]);
	rigid.update(p_render_data->render_buffers, p_render_data->hddagi_update_data->rigid_geometry_instances, bounds, exposure);
	if (rigid.has_changes()) {
		for (Cascade &cascade : cascades) {
			cascade.dynamic_lights_dirty = true;
		}
	}
}

void GI::HDDAGI::refresh_rigid_static_lights(RenderDataRD *p_render_data) {
	if (!rigid.has_changes()) {
		return;
	}
	// Reuse static light evaluation, but the shader only refreshes cells whose
	// light segment crosses the swept bounds. No occupancy/region rebuild.
	const PagedArray<RID> *source_lights = p_render_data->hddagi_update_data->rigid_static_lights;
	PagedArrayPool<RID> light_pool(64);
	PagedArray<RID> cascade_lights[MAX_CASCADES];
	uint32_t cascade_indices[MAX_CASCADES];
	for (uint32_t i = 0; i < cascades.size(); i++) {
		cascade_indices[i] = i;
		cascade_lights[i].set_page_pool(&light_pool);
		if (source_lights) {
			for (uint32_t j = 0; j < source_lights->size(); j++) {
				cascade_lights[i].push_back((*source_lights)[j]);
			}
		}
	}
	render_static_lights(p_render_data, p_render_data->render_buffers, cascades.size(), cascade_indices, cascade_lights);
}

void GI::HDDAGI::update_rigid_lighting(RenderDataRD *p_render_data) {
	if (!hwrt_enabled && !rigid.is_active()) {
		return;
	}
	RD *rd = RD::get_singleton();
	LightStorage *light_storage = LightStorage::get_singleton();
	TextureStorage *texture_storage = TextureStorage::get_singleton();
	MaterialStorage *material_storage = MaterialStorage::get_singleton();
	HDDAGIShader::Light lights[MAX_DYNAMIC_LIGHTS] = {};
	uint32_t light_count = 0;
	HashSet<RID> used_lights;
	AABB object_bounds = hwrt_enabled ? hwrt.get_bounds() : AABB();
	for (uint32_t i = 0; i < rigid.get_instance_count(); i++) {
		const HDDAGIRigid::InstanceData &instance = rigid.get_instance_data(i);
		Vector3 from(instance.bounds_min[0], instance.bounds_min[1], instance.bounds_min[2]);
		Vector3 to(instance.bounds_max[0], instance.bounds_max[1], instance.bounds_max[2]);
		if (i == 0) {
			object_bounds = AABB(from, to - from);
		} else {
			object_bounds.merge_with(AABB(from, to - from));
		}
	}
	auto append_light = [&](RID p_instance) {
		if (light_count == MAX_DYNAMIC_LIGHTS || used_lights.has(p_instance) || !light_storage->owns_light_instance(p_instance)) {
			return;
		}
		RID light = light_storage->light_instance_get_base_light(p_instance);
		RSE::LightType type = light_storage->light_get_type(light);
		if (type == RSE::LIGHT_DIRECTIONAL) {
			if (light_storage->light_directional_get_sky_mode(light) == RSE::LIGHT_DIRECTIONAL_SKY_MODE_SKY_ONLY) {
				return;
			}
		} else if (!object_bounds.intersects(light_storage->light_instance_get_base_aabb(p_instance))) {
			return;
		}
		used_lights.insert(p_instance);
		HDDAGIShader::Light &packed = lights[light_count++];
		Transform3D transform = light_storage->light_instance_get_base_transform(p_instance);
		Vector3 direction = -transform.basis.get_column(Vector3::AXIS_Z);
		if (type == RSE::LIGHT_DIRECTIONAL) {
			direction.y *= y_mult;
			direction.normalize();
		}
		Vector3 position = transform.origin;
		position.y *= y_mult;
		Color color = light_storage->light_get_color(light).srgb_to_linear();
		for (int axis = 0; axis < 3; axis++) {
			packed.direction[axis] = direction[axis];
			packed.position[axis] = position[axis];
			packed.color[axis] = color[axis];
		}
		packed.type = type;
		packed.energy = light_storage->light_get_param(light, RSE::LIGHT_PARAM_ENERGY) * light_storage->light_get_param(light, RSE::LIGHT_PARAM_INDIRECT_ENERGY);
		if (RendererSceneRenderRD::get_singleton()->is_using_physical_light_units()) {
			packed.energy *= light_storage->light_get_param(light, RSE::LIGHT_PARAM_INTENSITY);
			if (type == RSE::LIGHT_OMNI) {
				packed.energy /= Math::PI * 4.0;
			} else if (type == RSE::LIGHT_AREA) {
				packed.energy /= Math::PI * 2.0;
			} else if (type == RSE::LIGHT_SPOT) {
				packed.energy /= Math::PI;
			}
		}
		// Object caches stay in physical units; consumers apply current exposure.
		packed.has_shadow = light_storage->light_has_shadow(light);
		packed.attenuation = light_storage->light_get_param(light, RSE::LIGHT_PARAM_ATTENUATION);
		packed.radius = light_storage->light_get_param(light, RSE::LIGHT_PARAM_RANGE);
		packed.cos_spot_angle = Math::cos(Math::deg_to_rad(light_storage->light_get_param(light, RSE::LIGHT_PARAM_SPOT_ANGLE)));
		packed.inv_spot_attenuation = 1.0f / light_storage->light_get_param(light, RSE::LIGHT_PARAM_SPOT_ATTENUATION);
		if (type == RSE::LIGHT_AREA) {
			Vector2 size = light_storage->light_area_get_size(light);
			Vector3 width = transform.basis.get_column(0).normalized() * size.x;
			Vector3 height = transform.basis.get_column(1).normalized() * size.y;
			direction.normalize();
			for (int axis = 0; axis < 3; axis++) {
				packed.direction[axis] = direction[axis];
				packed.area_width[axis] = width[axis];
				packed.area_height[axis] = height[axis];
			}
			Rect2 rect = texture_storage->area_light_atlas_get_texture_rect(light_storage->light_area_get_texture(light));
			packed.area_projector_rect[0] = rect.position.x;
			packed.area_projector_rect[1] = rect.position.y;
			packed.area_projector_rect[2] = rect.size.x;
			packed.area_projector_rect[3] = rect.size.y;
			Size2i texture_size = (rect.size * texture_storage->area_light_atlas_get_size()).ceil();
			packed.cos_spot_angle = MIN(Math::floor(Math::log2(MAX(MIN(texture_size.x, texture_size.y), 1.0f))), texture_storage->area_light_atlas_get_mipmaps()) - 1.0f;
			packed.inv_spot_attenuation = 1.0f / (packed.radius + size.length() / 2.0f);
			if (light_storage->light_area_get_normalize_energy(light) && size.x * size.y > 0.0f) {
				packed.energy /= size.x * size.y;
			}
		}
	};
	const RendererSceneRender::RenderHDDAGIUpdateData *update = p_render_data->hddagi_update_data;
	if (update->directional_lights) {
		for (RID light : *update->directional_lights) {
			append_light(light);
		}
	}
	for (uint32_t i = 0; i < update->positional_light_count; i++) {
		append_light(update->positional_light_instances[i]);
	}
	if (update->rigid_static_lights) {
		for (uint32_t i = 0; i < update->rigid_static_lights->size(); i++) {
			append_light((*update->rigid_static_lights)[i]);
		}
	}
	if (rigid_lights_buffer.is_null()) {
		rigid_lights_buffer = rd->storage_buffer_create(sizeof(lights));
	}
	if (light_count) {
		rd->buffer_update(rigid_lights_buffer, 0, light_count * sizeof(HDDAGIShader::Light), lights);
	}
	if (hwrt_enabled) {
		const float exposure = p_render_data->camera_attributes.is_valid() ? RSG::camera_attributes->camera_attributes_get_exposure_normalization_factor(p_render_data->camera_attributes) : 1.0f;
		hwrt.update_lights(rigid_lights_buffer, light_count, exposure, bounce_feedback);
		return;
	}

	const int mode = HDDAGIShader::DIRECT_LIGHT_MODE_RIGID;
	LocalVector<RD::Uniform> uniforms;
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 1, voxel_bits_tex));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 2, voxel_region_tex));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER, 3, material_storage->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED)));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_UNIFORM_BUFFER, 7, cascades_ubo));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 8, rigid_lights_buffer));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 9, lightprobe_diffuse_tex));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 12, get_lightprobe_occlusion_textures()));
	rigid.append_uniforms(uniforms);
	RID uniform_set = UniformSetCacheRD::get_singleton()->get_cache_vec(gi->hddagi_shader.direct_light_shader_version[mode], 0, uniforms);
	RID area_set = UniformSetCacheRD::get_singleton()->get_cache(gi->hddagi_shader.direct_light_shader_version[mode], 1,
			RD::Uniform(RD::UNIFORM_TYPE_TEXTURE, 0, texture_storage->area_light_atlas_get_texture()),
			RD::Uniform(RD::UNIFORM_TYPE_SAMPLER, 1, material_storage->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR_WITH_MIPMAPS, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED)));
	HDDAGIShader::DirectLightPushConstant params = {};
	for (int axis = 0; axis < 3; axis++) {
		params.grid_size[axis] = cascade_size[axis];
		params.probe_axis_size[axis] = cascade_size[axis] / REGION_CELLS + 1;
	}
	params.max_cascades = cascades.size();
	params.light_count = light_count;
	params.y_mult = y_mult;
	params.bounce_feedback = bounce_feedback;
	params.probe_cell_size = REGION_CELLS;
	static const uint32_t update_intervals[] = { 1, 2, 4, 8, 16 };
	uint32_t interval = update_intervals[gi->hddagi_frames_to_update_light];
	RENDER_TIMESTAMP("> HDDAGI Rigid Surface Lighting");
	rd->draw_command_begin_label("HDDAGI Rigid Surface Lighting");
	RD::ComputeListID list = rd->compute_list_begin();
	rd->compute_list_bind_compute_pipeline(list, gi->hddagi_shader.direct_light_pipeline[mode]);
	rd->compute_list_bind_uniform_set(list, uniform_set, 0);
	rd->compute_list_bind_uniform_set(list, area_set, 1);
	for (uint32_t i = 0; i < rigid.get_instance_count(); i++) {
		params.cascade = i;
		params.process_increment = rigid.is_light_dirty(i) ? 1 : interval;
		params.process_offset = update_frame % params.process_increment;
		rd->compute_list_set_push_constant(list, &params, sizeof(params));
		rd->compute_list_dispatch_indirect(list, rigid.get_dispatch_buffer(), rigid.get_dispatch_offset(i));
		rigid.finish_lighting(i);
	}
	rd->compute_list_end();
	rd->draw_command_end_label();
	RENDER_TIMESTAMP("< HDDAGI Rigid Surface Lighting");
}
