/**************************************************************************/
/*  avboit.cpp                                                            */
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

#include "avboit.h"

#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"

namespace RendererRD {

AVBOIT::AVBOIT() {
	Vector<String> modes;
	modes.push_back("\n#define MODE_INTEGRATE\n");
	modes.push_back("\n#define MODE_RESOLVE\n");

	shader.initialize(modes);
	shader_version = shader.version_create();
	for (uint32_t i = 0; i < MODE_MAX; i++) {
		pipelines[i] = RD::get_singleton()->compute_pipeline_create(shader.version_get_shader(shader_version, i));
	}
}

AVBOIT::~AVBOIT() {
	for (uint32_t i = 0; i < MODE_MAX; i++) {
		if (pipelines[i].is_valid()) {
			RD::get_singleton()->free_rid(pipelines[i]);
		}
	}
	shader.version_free(shader_version);
}

void AVBOIT::clear(const Buffers &p_buffers) {
	ERR_FAIL_COND(p_buffers.splat.is_null());
	ERR_FAIL_COND(p_buffers.extinction.is_null());
	ERR_FAIL_COND(p_buffers.integral.is_null());
	ERR_FAIL_COND(p_buffers.size.x <= 0 || p_buffers.size.y <= 0 || p_buffers.slice_count == 0);

	RD::get_singleton()->draw_command_begin_label("AVBOIT Prototype Clear");

	RD::get_singleton()->texture_clear(p_buffers.splat, Color(0, 0, 0, 0), 0, 1, 0, 1);
	RD::get_singleton()->texture_clear(p_buffers.extinction, Color(0, 0, 0, 0), 0, 1, 0, p_buffers.slice_count);
	RD::get_singleton()->texture_clear(p_buffers.integral, Color(0, 0, 0, 0), 0, 1, 0, p_buffers.slice_count);

	RD::get_singleton()->draw_command_end_label();
}

void AVBOIT::integrate(const Buffers &p_buffers) {
	ERR_FAIL_COND(p_buffers.extinction.is_null());
	ERR_FAIL_COND(p_buffers.integral.is_null());
	ERR_FAIL_COND(p_buffers.size.x <= 0 || p_buffers.size.y <= 0 || p_buffers.slice_count == 0);

	RD::get_singleton()->draw_command_begin_label("AVBOIT Prototype Integrate");

	RID shader_rid = shader.version_get_shader(shader_version, 0);
	ERR_FAIL_COND(shader_rid.is_null());

	RD::Uniform u_extinction(RD::UNIFORM_TYPE_IMAGE, 0, Vector<RID>({ p_buffers.extinction }));
	RD::Uniform u_integral(RD::UNIFORM_TYPE_IMAGE, 1, Vector<RID>({ p_buffers.integral }));
	RID uniform_set = UniformSetCacheRD::get_singleton()->get_cache(shader_rid, 0, u_extinction, u_integral);

	PushConstant push_constant;
	push_constant.size[0] = p_buffers.size.x;
	push_constant.size[1] = p_buffers.size.y;
	push_constant.full_size[0] = p_buffers.full_size.x;
	push_constant.full_size[1] = p_buffers.full_size.y;
	push_constant.slice_count = p_buffers.slice_count;
	push_constant.pad[0] = 0;
	push_constant.pad[1] = 0;
	push_constant.pad[2] = 0;

	RD::ComputeListID compute_list = RD::get_singleton()->compute_list_begin();
	RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, pipelines[MODE_INTEGRATE]);
	RD::get_singleton()->compute_list_bind_uniform_set(compute_list, uniform_set, 0);
	RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(PushConstant));
	RD::get_singleton()->compute_list_dispatch_threads(compute_list, p_buffers.size.x, p_buffers.size.y, 1);
	RD::get_singleton()->compute_list_end();

	RD::get_singleton()->draw_command_end_label();
}

void AVBOIT::resolve(const Buffers &p_buffers, RID p_color_buffer) {
	ERR_FAIL_COND(p_buffers.splat.is_null());
	ERR_FAIL_COND(p_color_buffer.is_null());
	ERR_FAIL_COND(p_buffers.size.x <= 0 || p_buffers.size.y <= 0 || p_buffers.full_size.x <= 0 || p_buffers.full_size.y <= 0);

	RD::get_singleton()->draw_command_begin_label("AVBOIT Prototype Resolve");

	RID shader_rid = shader.version_get_shader(shader_version, MODE_RESOLVE);
	ERR_FAIL_COND(shader_rid.is_null());
	MaterialStorage *material_storage = MaterialStorage::get_singleton();
	ERR_FAIL_NULL(material_storage);

	RID linear_sampler = material_storage->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);

	RD::Uniform u_splat(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, Vector<RID>({ linear_sampler, p_buffers.splat }));
	RD::Uniform u_color(RD::UNIFORM_TYPE_IMAGE, 1, Vector<RID>({ p_color_buffer }));
	RD::Uniform u_integral(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, Vector<RID>({ linear_sampler, p_buffers.integral }));
	RID uniform_set = UniformSetCacheRD::get_singleton()->get_cache(shader_rid, 0, u_splat, u_color, u_integral);

	PushConstant push_constant;
	push_constant.size[0] = p_buffers.size.x;
	push_constant.size[1] = p_buffers.size.y;
	push_constant.full_size[0] = p_buffers.full_size.x;
	push_constant.full_size[1] = p_buffers.full_size.y;
	push_constant.slice_count = p_buffers.slice_count;
	push_constant.pad[0] = 0;
	push_constant.pad[1] = 0;
	push_constant.pad[2] = 0;

	RD::ComputeListID compute_list = RD::get_singleton()->compute_list_begin();
	RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, pipelines[MODE_RESOLVE]);
	RD::get_singleton()->compute_list_bind_uniform_set(compute_list, uniform_set, 0);
	RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(PushConstant));
	RD::get_singleton()->compute_list_dispatch_threads(compute_list, p_buffers.full_size.x, p_buffers.full_size.y, 1);
	RD::get_singleton()->compute_list_end();

	RD::get_singleton()->draw_command_end_label();
}

} // namespace RendererRD
