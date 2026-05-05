/**************************************************************************/
/*  avboit.h                                                              */
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

#include "core/math/vector2i.h"
#include "core/templates/rid.h"
#include "servers/rendering/renderer_rd/shaders/effects/avboit.glsl.gen.h"

namespace RendererRD {

class AVBOIT {
public:
	struct Buffers {
		RID splat;
		RID extinction;
		RID integral;
		Size2i size;
		Size2i full_size;
		uint32_t slice_count = 0;
	};

private:
	struct PushConstant {
		uint32_t size[2];
		uint32_t full_size[2];
		uint32_t slice_count;
		uint32_t pad[3];
	};

	enum Mode {
		MODE_INTEGRATE,
		MODE_RESOLVE,
		MODE_MAX
	};

	AvboitShaderRD shader;
	RID shader_version;
	RID pipelines[MODE_MAX];

public:
	AVBOIT();
	~AVBOIT();

	void clear(const Buffers &p_buffers);
	void integrate(const Buffers &p_buffers);
	void resolve(const Buffers &p_buffers, RID p_color_buffer);
};

} // namespace RendererRD
