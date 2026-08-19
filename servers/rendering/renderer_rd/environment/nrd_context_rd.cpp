/**************************************************************************/
/*  nrd_context_rd.cpp                                                    */
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

#include "nrd_context_rd.h"

#include "core/string/print_string.h"
#include "core/templates/hash_map.h"

#include <cstring>

#ifdef NVIDIA_NRD_ENABLED

#include <NRD.h>

static_assert(NRD_VERSION_MAJOR == 4 && NRD_VERSION_MINOR == 17 && NRD_VERSION_BUILD == 4, "NrdContextRD requires NRD 4.17.4 exactly.");

namespace {

constexpr nrd::Identifier RELAX_DIFFUSE_IDENTIFIER = 0;
constexpr uint32_t SPIRV_MAGIC = 0x07230203;
constexpr uint16_t SPIRV_OP_ENTRY_POINT = 15;
constexpr uint16_t SPIRV_OP_TYPE_INT = 21;
constexpr uint16_t SPIRV_OP_SPEC_CONSTANT = 50;
constexpr uint16_t SPIRV_OP_FUNCTION = 54;
constexpr uint16_t SPIRV_OP_DECORATE = 71;
constexpr uint32_t SPIRV_DECORATION_SPEC_ID = 1;
constexpr uint32_t RESPV_BYPASS_SPEC_ID = 0;

static RenderingDevice::DataFormat _nrd_format_to_rd(nrd::Format p_format) {
	switch (p_format) {
		case nrd::Format::R8_UNORM:
			return RD::DATA_FORMAT_R8_UNORM;
		case nrd::Format::R8_SNORM:
			return RD::DATA_FORMAT_R8_SNORM;
		case nrd::Format::R8_UINT:
			return RD::DATA_FORMAT_R8_UINT;
		case nrd::Format::R8_SINT:
			return RD::DATA_FORMAT_R8_SINT;
		case nrd::Format::RG8_UNORM:
			return RD::DATA_FORMAT_R8G8_UNORM;
		case nrd::Format::RG8_SNORM:
			return RD::DATA_FORMAT_R8G8_SNORM;
		case nrd::Format::RG8_UINT:
			return RD::DATA_FORMAT_R8G8_UINT;
		case nrd::Format::RG8_SINT:
			return RD::DATA_FORMAT_R8G8_SINT;
		case nrd::Format::RGBA8_UNORM:
			return RD::DATA_FORMAT_R8G8B8A8_UNORM;
		case nrd::Format::RGBA8_SNORM:
			return RD::DATA_FORMAT_R8G8B8A8_SNORM;
		case nrd::Format::RGBA8_UINT:
			return RD::DATA_FORMAT_R8G8B8A8_UINT;
		case nrd::Format::RGBA8_SINT:
			return RD::DATA_FORMAT_R8G8B8A8_SINT;
		case nrd::Format::RGBA8_SRGB:
			return RD::DATA_FORMAT_R8G8B8A8_SRGB;
		case nrd::Format::R16_UNORM:
			return RD::DATA_FORMAT_R16_UNORM;
		case nrd::Format::R16_SNORM:
			return RD::DATA_FORMAT_R16_SNORM;
		case nrd::Format::R16_UINT:
			return RD::DATA_FORMAT_R16_UINT;
		case nrd::Format::R16_SINT:
			return RD::DATA_FORMAT_R16_SINT;
		case nrd::Format::R16_SFLOAT:
			return RD::DATA_FORMAT_R16_SFLOAT;
		case nrd::Format::RG16_UNORM:
			return RD::DATA_FORMAT_R16G16_UNORM;
		case nrd::Format::RG16_SNORM:
			return RD::DATA_FORMAT_R16G16_SNORM;
		case nrd::Format::RG16_UINT:
			return RD::DATA_FORMAT_R16G16_UINT;
		case nrd::Format::RG16_SINT:
			return RD::DATA_FORMAT_R16G16_SINT;
		case nrd::Format::RG16_SFLOAT:
			return RD::DATA_FORMAT_R16G16_SFLOAT;
		case nrd::Format::RGBA16_UNORM:
			return RD::DATA_FORMAT_R16G16B16A16_UNORM;
		case nrd::Format::RGBA16_SNORM:
			return RD::DATA_FORMAT_R16G16B16A16_SNORM;
		case nrd::Format::RGBA16_UINT:
			return RD::DATA_FORMAT_R16G16B16A16_UINT;
		case nrd::Format::RGBA16_SINT:
			return RD::DATA_FORMAT_R16G16B16A16_SINT;
		case nrd::Format::RGBA16_SFLOAT:
			return RD::DATA_FORMAT_R16G16B16A16_SFLOAT;
		case nrd::Format::R32_UINT:
			return RD::DATA_FORMAT_R32_UINT;
		case nrd::Format::R32_SINT:
			return RD::DATA_FORMAT_R32_SINT;
		case nrd::Format::R32_SFLOAT:
			return RD::DATA_FORMAT_R32_SFLOAT;
		case nrd::Format::RG32_UINT:
			return RD::DATA_FORMAT_R32G32_UINT;
		case nrd::Format::RG32_SINT:
			return RD::DATA_FORMAT_R32G32_SINT;
		case nrd::Format::RG32_SFLOAT:
			return RD::DATA_FORMAT_R32G32_SFLOAT;
		case nrd::Format::RGB32_UINT:
			return RD::DATA_FORMAT_R32G32B32_UINT;
		case nrd::Format::RGB32_SINT:
			return RD::DATA_FORMAT_R32G32B32_SINT;
		case nrd::Format::RGB32_SFLOAT:
			return RD::DATA_FORMAT_R32G32B32_SFLOAT;
		case nrd::Format::RGBA32_UINT:
			return RD::DATA_FORMAT_R32G32B32A32_UINT;
		case nrd::Format::RGBA32_SINT:
			return RD::DATA_FORMAT_R32G32B32A32_SINT;
		case nrd::Format::RGBA32_SFLOAT:
			return RD::DATA_FORMAT_R32G32B32A32_SFLOAT;
		case nrd::Format::R10_G10_B10_A2_UNORM:
			return RD::DATA_FORMAT_A2B10G10R10_UNORM_PACK32;
		case nrd::Format::R10_G10_B10_A2_UINT:
			return RD::DATA_FORMAT_A2B10G10R10_UINT_PACK32;
		case nrd::Format::R11_G11_B10_UFLOAT:
			return RD::DATA_FORMAT_B10G11R11_UFLOAT_PACK32;
		case nrd::Format::R9_G9_B9_E5_UFLOAT:
			return RD::DATA_FORMAT_E5B9G9R9_UFLOAT_PACK32;
		default:
			return RD::DATA_FORMAT_MAX;
	}
}

static const char *_nrd_resource_name(nrd::ResourceType p_type) {
	switch (p_type) {
		case nrd::ResourceType::IN_MV:
			return "motion_vectors";
		case nrd::ResourceType::IN_NORMAL_ROUGHNESS:
			return "normal_roughness";
		case nrd::ResourceType::IN_VIEWZ:
			return "view_z";
		case nrd::ResourceType::IN_DIFF_RADIANCE_HITDIST:
			return "diffuse_radiance_hitdist";
		case nrd::ResourceType::OUT_DIFF_RADIANCE_HITDIST:
			return "output_diffuse_radiance_hitdist";
		case nrd::ResourceType::OUT_VALIDATION:
			return "validation";
		case nrd::ResourceType::PERMANENT_POOL:
			return "permanent_pool";
		case nrd::ResourceType::TRANSIENT_POOL:
			return "transient_pool";
		default:
			return "unsupported";
	}
}

static bool _entry_point_matches(const uint32_t *p_words, uint32_t p_word_count, const CharString &p_expected, uint32_t &r_name_word_count) {
	if (p_word_count <= 3) {
		return false;
	}

	const char *name = reinterpret_cast<const char *>(p_words + 3);
	const uint32_t max_name_bytes = (p_word_count - 3) * sizeof(uint32_t);
	uint32_t name_length = 0;
	while (name_length < max_name_bytes && name[name_length] != '\0') {
		name_length++;
	}
	if (name_length == max_name_bytes) {
		return false;
	}

	r_name_word_count = (name_length + 1 + sizeof(uint32_t) - 1) / sizeof(uint32_t);
	if (name_length != (uint32_t)p_expected.length()) {
		return false;
	}
	return name_length == 0 || memcmp(name, p_expected.get_data(), name_length) == 0;
}

// Godot's Vulkan driver uses the fixed entry point "main". NRD currently emits
// that name too, but rewriting the OpEntryPoint instruction keeps the adapter
// safe if an NRD build overrides NRD_CS_MAIN. Interface IDs are shifted rather
// than zero-filled, preserving a valid instruction.
static bool _ensure_main_entry_point(Vector<uint8_t> &r_spirv, const char *p_entry_point) {
	if (p_entry_point == nullptr || r_spirv.size() < 5 * (int)sizeof(uint32_t) || (r_spirv.size() % sizeof(uint32_t)) != 0) {
		return false;
	}

	Vector<uint32_t> words;
	words.resize(r_spirv.size() / sizeof(uint32_t));
	memcpy(words.ptrw(), r_spirv.ptr(), r_spirv.size());
	if (words[0] != SPIRV_MAGIC) {
		return false;
	}

	const CharString expected = String::utf8(p_entry_point).ascii();
	const CharString main_name = String("main").ascii();
	for (uint32_t offset = 5; offset < (uint32_t)words.size();) {
		const uint32_t instruction = words[offset];
		const uint32_t word_count = instruction >> 16;
		const uint16_t opcode = instruction & 0xffff;
		if (word_count == 0 || offset + word_count > (uint32_t)words.size()) {
			return false;
		}

		if (opcode == SPIRV_OP_ENTRY_POINT) {
			uint32_t name_word_count = 0;
			if (_entry_point_matches(words.ptr() + offset, word_count, main_name, name_word_count)) {
				return true;
			}
			if (_entry_point_matches(words.ptr() + offset, word_count, expected, name_word_count)) {
				constexpr uint32_t main_word_count = 2; // "main" plus its NUL terminator.
				const uint32_t interface_offset = offset + 3 + name_word_count;
				const uint32_t interface_word_count = offset + word_count - interface_offset;
				const uint32_t rewritten_word_count = 3 + main_word_count + interface_word_count;

				Vector<uint32_t> rewritten;
				rewritten.reserve(words.size() - word_count + rewritten_word_count);
				for (uint32_t i = 0; i < offset; i++) {
					rewritten.push_back(words[i]);
				}
				rewritten.push_back((rewritten_word_count << 16) | SPIRV_OP_ENTRY_POINT);
				rewritten.push_back(words[offset + 1]);
				rewritten.push_back(words[offset + 2]);
				rewritten.push_back(0x6e69616d); // "main" in SPIR-V's little-endian string encoding.
				rewritten.push_back(0);
				for (uint32_t i = 0; i < interface_word_count; i++) {
					rewritten.push_back(words[interface_offset + i]);
				}
				for (uint32_t i = offset + word_count; i < (uint32_t)words.size(); i++) {
					rewritten.push_back(words[i]);
				}

				r_spirv.resize(rewritten.size() * sizeof(uint32_t));
				memcpy(r_spirv.ptrw(), rewritten.ptr(), r_spirv.size());
				return true;
			}
		}

		offset += word_count;
	}

	return false;
}

// The Vulkan driver eagerly runs Godot's re-SPIR-V optimizer on shaders that
// have no specialization constants. As of Godot 4.7, that optimizer corrupts
// the forward references used by OpPhi in several NRD 4.17.4 nested loops,
// producing an invalid module and crashing some Vulkan drivers during pipeline
// creation. A shader with specialization constants takes the deferred path;
// compute pipelines without overrides then use the original, valid module.
// Injecting an unused uint specialization constant is semantics-preserving and
// keeps this compatibility workaround local to externally supplied NRD blobs.
static bool _add_respv_bypass_specialization_constant(Vector<uint8_t> &r_spirv) {
	if (r_spirv.size() < 5 * (int)sizeof(uint32_t) || (r_spirv.size() % sizeof(uint32_t)) != 0) {
		return false;
	}

	Vector<uint32_t> words;
	words.resize(r_spirv.size() / sizeof(uint32_t));
	memcpy(words.ptrw(), r_spirv.ptr(), r_spirv.size());
	if (words[0] != SPIRV_MAGIC || words[3] == UINT32_MAX) {
		return false;
	}

	uint32_t uint_type_id = 0;
	uint32_t annotation_offset = UINT32_MAX;
	uint32_t function_offset = UINT32_MAX;
	bool has_specialization_constant = false;
	for (uint32_t offset = 5; offset < (uint32_t)words.size();) {
		const uint32_t instruction = words[offset];
		const uint32_t word_count = instruction >> 16;
		const uint16_t opcode = instruction & 0xffff;
		if (word_count == 0 || offset + word_count > (uint32_t)words.size()) {
			return false;
		}

		// OpTypeVoid through OpTypeForwardPointer form the beginning of the
		// types/constants section. Decorations must be inserted before it.
		if (annotation_offset == UINT32_MAX && opcode >= 19 && opcode <= 39) {
			annotation_offset = offset;
		}
		if (opcode == SPIRV_OP_TYPE_INT && word_count == 4 && words[offset + 2] == 32 && words[offset + 3] == 0) {
			uint_type_id = words[offset + 1];
		}
		if (opcode == SPIRV_OP_DECORATE && word_count >= 4 && words[offset + 2] == SPIRV_DECORATION_SPEC_ID) {
			has_specialization_constant = true;
		}
		if (opcode == SPIRV_OP_FUNCTION) {
			function_offset = offset;
			break;
		}
		offset += word_count;
	}

	if (has_specialization_constant) {
		return true;
	}
	if (uint_type_id == 0 || annotation_offset == UINT32_MAX || function_offset == UINT32_MAX || annotation_offset > function_offset) {
		return false;
	}

	const uint32_t spec_constant_id = words[3];
	Vector<uint32_t> rewritten;
	rewritten.reserve(words.size() + 8);
	for (uint32_t i = 0; i < annotation_offset; i++) {
		rewritten.push_back(words[i]);
	}
	rewritten.push_back((4u << 16) | SPIRV_OP_DECORATE);
	rewritten.push_back(spec_constant_id);
	rewritten.push_back(SPIRV_DECORATION_SPEC_ID);
	rewritten.push_back(RESPV_BYPASS_SPEC_ID);
	for (uint32_t i = annotation_offset; i < function_offset; i++) {
		rewritten.push_back(words[i]);
	}
	rewritten.push_back((4u << 16) | SPIRV_OP_SPEC_CONSTANT);
	rewritten.push_back(uint_type_id);
	rewritten.push_back(spec_constant_id);
	rewritten.push_back(0);
	for (uint32_t i = function_offset; i < (uint32_t)words.size(); i++) {
		rewritten.push_back(words[i]);
	}
	rewritten.write[3] = spec_constant_id + 1;

	r_spirv.resize(rewritten.size() * sizeof(uint32_t));
	memcpy(r_spirv.ptrw(), rewritten.ptr(), r_spirv.size());
	return true;
}

static nrd::AccumulationMode _to_nrd_accumulation_mode(NrdContextRD::AccumulationMode p_mode) {
	switch (p_mode) {
		case NrdContextRD::AccumulationMode::RESTART:
			return nrd::AccumulationMode::RESTART;
		case NrdContextRD::AccumulationMode::CLEAR_AND_RESTART:
			return nrd::AccumulationMode::CLEAR_AND_RESTART;
		default:
			return nrd::AccumulationMode::CONTINUE;
	}
}

static nrd::CheckerboardMode _to_nrd_checkerboard_mode(NrdContextRD::CheckerboardMode p_mode) {
	switch (p_mode) {
		case NrdContextRD::CheckerboardMode::BLACK:
			return nrd::CheckerboardMode::BLACK;
		case NrdContextRD::CheckerboardMode::WHITE:
			return nrd::CheckerboardMode::WHITE;
		default:
			return nrd::CheckerboardMode::OFF;
	}
}

static nrd::HitDistanceReconstructionMode _to_nrd_hit_distance_mode(NrdContextRD::HitDistanceReconstructionMode p_mode) {
	switch (p_mode) {
		case NrdContextRD::HitDistanceReconstructionMode::AREA_3X3:
			return nrd::HitDistanceReconstructionMode::AREA_3X3;
		case NrdContextRD::HitDistanceReconstructionMode::AREA_5X5:
			return nrd::HitDistanceReconstructionMode::AREA_5X5;
		default:
			return nrd::HitDistanceReconstructionMode::OFF;
	}
}

static Error _nrd_result_to_error(nrd::Result p_result, const String &p_operation) {
	if (p_result == nrd::Result::SUCCESS) {
		return OK;
	}

	ERR_PRINT(vformat("NRD %s failed with result %d.", p_operation, (uint32_t)p_result));
	switch (p_result) {
		case nrd::Result::INVALID_ARGUMENT:
		case nrd::Result::NON_UNIQUE_IDENTIFIER:
			return ERR_INVALID_PARAMETER;
		case nrd::Result::UNSUPPORTED:
			return ERR_UNAVAILABLE;
		default:
			return FAILED;
	}
}

} // namespace

struct NrdContextRD::Implementation {
	struct Pipeline {
		RID shader;
		RID pipeline;
	};

	struct ViewContext {
		nrd::Instance *instance = nullptr;
		const nrd::InstanceDesc *instance_desc = nullptr;
		Size2i size;
		Vector<RID> permanent_pool;
		Vector<RID> transient_pool;
		Vector<Pipeline> pipelines;
		Vector<RID> constant_buffers;
		CommonSettings common_settings;
		RelaxSettings relax_settings;
		bool has_common_settings = false;
		bool history_reset_pending = true;
		bool clear_history_resources = true;
	};

	struct RecordedDispatch {
		RID constant_set;
		RID resources_set;
		uint16_t pipeline_index = 0;
		uint16_t grid_width = 0;
		uint16_t grid_height = 0;
	};

	HashMap<uint32_t, ViewContext *> views;
	const nrd::LibraryDesc *library_desc = nullptr;
	RID nearest_sampler;
	RID linear_sampler;

	RID get_sampler(nrd::Sampler p_sampler) const {
		return p_sampler == nrd::Sampler::LINEAR_CLAMP ? linear_sampler : nearest_sampler;
	}

	Error initialize() {
		if (library_desc != nullptr && nearest_sampler.is_valid() && linear_sampler.is_valid()) {
			return OK;
		}

		const nrd::LibraryDesc *desc = nrd::GetLibraryDesc();
		ERR_FAIL_NULL_V_MSG(desc, ERR_CANT_CREATE, "NRD returned a null library descriptor.");
		ERR_FAIL_COND_V_MSG(desc->versionMajor != NRD_VERSION_MAJOR || desc->versionMinor != NRD_VERSION_MINOR || desc->versionBuild != NRD_VERSION_BUILD, ERR_UNAVAILABLE,
				vformat("NrdContextRD requires NRD %d.%d.%d exactly, got %d.%d.%d.", NRD_VERSION_MAJOR, NRD_VERSION_MINOR, NRD_VERSION_BUILD, desc->versionMajor, desc->versionMinor, desc->versionBuild));
		ERR_FAIL_COND_V_MSG(desc->normalEncoding != nrd::NormalEncoding::RGBA8_UNORM, ERR_UNAVAILABLE,
				"NrdContextRD's normal/roughness input contract requires an NRD library built with NRD_NORMAL_ENCODING=0 (RGBA8_UNORM).");
		ERR_FAIL_COND_V_MSG(desc->roughnessEncoding != nrd::RoughnessEncoding::LINEAR, ERR_UNAVAILABLE,
				"NrdContextRD requires an NRD library built with NRD_ROUGHNESS_ENCODING=1 (linear roughness).");
		library_desc = desc;

		RD *rd = RD::get_singleton();
		ERR_FAIL_NULL_V(rd, ERR_UNAVAILABLE);

		RD::SamplerState nearest_state;
		nearest_state.mag_filter = RD::SAMPLER_FILTER_NEAREST;
		nearest_state.min_filter = RD::SAMPLER_FILTER_NEAREST;
		nearest_state.mip_filter = RD::SAMPLER_FILTER_NEAREST;
		nearest_sampler = rd->sampler_create(nearest_state);
		if (nearest_sampler.is_null()) {
			library_desc = nullptr;
			return ERR_CANT_CREATE;
		}
		rd->set_resource_name(nearest_sampler, "NRD nearest clamp sampler");

		RD::SamplerState linear_state;
		linear_state.mag_filter = RD::SAMPLER_FILTER_LINEAR;
		linear_state.min_filter = RD::SAMPLER_FILTER_LINEAR;
		linear_state.mip_filter = RD::SAMPLER_FILTER_NEAREST;
		linear_sampler = rd->sampler_create(linear_state);
		if (linear_sampler.is_null()) {
			rd->free_rid(nearest_sampler);
			nearest_sampler = RID();
			library_desc = nullptr;
			return ERR_CANT_CREATE;
		}
		rd->set_resource_name(linear_sampler, "NRD linear clamp sampler");

		return OK;
	}

	void free_pool(Vector<RID> &r_pool) {
		RD *rd = RD::get_singleton();
		if (rd != nullptr) {
			for (RID rid : r_pool) {
				if (rid.is_valid()) {
					rd->free_rid(rid);
				}
			}
		}
		r_pool.clear();
	}

	void free_view(ViewContext *p_view) {
		if (p_view == nullptr) {
			return;
		}

		RD *rd = RD::get_singleton();
		if (rd != nullptr) {
			for (RID rid : p_view->constant_buffers) {
				if (rid.is_valid()) {
					rd->free_rid(rid);
				}
			}
			for (const Pipeline &pipeline : p_view->pipelines) {
				if (pipeline.pipeline.is_valid()) {
					rd->free_rid(pipeline.pipeline);
				}
				if (pipeline.shader.is_valid()) {
					rd->free_rid(pipeline.shader);
				}
			}
		}
		free_pool(p_view->transient_pool);
		free_pool(p_view->permanent_pool);

		if (p_view->instance != nullptr) {
			nrd::DestroyInstance(*p_view->instance);
			p_view->instance = nullptr;
		}
		memdelete(p_view);
	}

	void clear() {
		for (const KeyValue<uint32_t, ViewContext *> &E : views) {
			free_view(E.value);
		}
		views.clear();

		RD *rd = RD::get_singleton();
		if (rd != nullptr) {
			if (linear_sampler.is_valid()) {
				rd->free_rid(linear_sampler);
			}
			if (nearest_sampler.is_valid()) {
				rd->free_rid(nearest_sampler);
			}
		}
		linear_sampler = RID();
		nearest_sampler = RID();
		library_desc = nullptr;
	}

	Error create_pool(const nrd::TextureDesc *p_descs, uint32_t p_count, const Size2i &p_size, const String &p_prefix, Vector<RID> &r_pool) {
		RD *rd = RD::get_singleton();
		ERR_FAIL_NULL_V(rd, ERR_UNAVAILABLE);
		r_pool.resize(p_count);

		for (uint32_t i = 0; i < p_count; i++) {
			const nrd::TextureDesc &nrd_desc = p_descs[i];
			ERR_FAIL_COND_V_MSG(nrd_desc.downsampleFactor == 0, ERR_BUG, "NRD returned a zero texture downsample factor.");
			const RD::DataFormat format = _nrd_format_to_rd(nrd_desc.format);
			ERR_FAIL_COND_V_MSG(format == RD::DATA_FORMAT_MAX, ERR_UNAVAILABLE, vformat("Unsupported NRD texture format %d.", (uint32_t)nrd_desc.format));

			RD::TextureFormat texture_format;
			texture_format.texture_type = RD::TEXTURE_TYPE_2D;
			texture_format.width = (p_size.x + nrd_desc.downsampleFactor - 1) / nrd_desc.downsampleFactor;
			texture_format.height = (p_size.y + nrd_desc.downsampleFactor - 1) / nrd_desc.downsampleFactor;
			texture_format.format = format;
			texture_format.usage_bits = RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_STORAGE_BIT;
			ERR_FAIL_COND_V_MSG(!rd->texture_is_format_supported_for_usage(format, texture_format.usage_bits), ERR_UNAVAILABLE,
					vformat("RenderingDevice does not support NRD pool format %d for sampled storage textures.", (uint32_t)format));

			r_pool.write[i] = rd->texture_create(texture_format, RD::TextureView());
			ERR_FAIL_COND_V_MSG(r_pool[i].is_null(), ERR_OUT_OF_MEMORY, vformat("Failed to create NRD pool texture %s[%d].", p_prefix, i));
			rd->set_resource_name(r_pool[i], vformat("NRD %s[%d]", p_prefix, i));
		}

		return OK;
	}

	Error create_pipelines(ViewContext *p_view) {
		RD *rd = RD::get_singleton();
		ERR_FAIL_NULL_V(rd, ERR_UNAVAILABLE);
		ERR_FAIL_NULL_V(p_view->instance_desc, ERR_BUG);

		Vector<RD::PipelineImmutableSampler> immutable_samplers;
		for (uint32_t i = 0; i < p_view->instance_desc->samplersNum; i++) {
			RD::PipelineImmutableSampler sampler;
			sampler.uniform_type = RD::UNIFORM_TYPE_SAMPLER;
			sampler.binding = library_desc->spirvBindingOffsets.samplerOffset + p_view->instance_desc->samplersBaseRegisterIndex + i;
			sampler.append_id(get_sampler(p_view->instance_desc->samplers[i]));
			immutable_samplers.push_back(sampler);
		}

		p_view->pipelines.resize(p_view->instance_desc->pipelinesNum);
		for (uint32_t i = 0; i < p_view->instance_desc->pipelinesNum; i++) {
			const nrd::PipelineDesc &nrd_pipeline = p_view->instance_desc->pipelines[i];
			ERR_FAIL_COND_V_MSG(nrd_pipeline.computeShaderSPIRV.bytecode == nullptr || nrd_pipeline.computeShaderSPIRV.size == 0, ERR_UNAVAILABLE,
					vformat("NRD pipeline %d has no embedded SPIR-V. Build NRD with NRD_EMBEDS_SPIRV_SHADERS=ON.", i));
			ERR_FAIL_COND_V_MSG(nrd_pipeline.computeShaderSPIRV.size > INT32_MAX, ERR_OUT_OF_MEMORY, "NRD SPIR-V shader is too large for RenderingDevice.");

			RD::ShaderStageSPIRVData stage;
			stage.shader_stage = RD::SHADER_STAGE_COMPUTE;
			stage.spirv.resize(nrd_pipeline.computeShaderSPIRV.size);
			memcpy(stage.spirv.ptrw(), nrd_pipeline.computeShaderSPIRV.bytecode, nrd_pipeline.computeShaderSPIRV.size);
			ERR_FAIL_COND_V_MSG(!_ensure_main_entry_point(stage.spirv, p_view->instance_desc->shaderEntryPoint), ERR_FILE_CORRUPT,
					vformat("NRD pipeline %d contains invalid SPIR-V or does not expose entry point '%s'.", i, p_view->instance_desc->shaderEntryPoint));
			if (rd->get_device_api_name() == "Vulkan") {
				ERR_FAIL_COND_V_MSG(!_add_respv_bypass_specialization_constant(stage.spirv), ERR_FILE_CORRUPT,
						vformat("NRD pipeline %d cannot be prepared for Godot's Vulkan shader container.", i));
			}

			Vector<RD::ShaderStageSPIRVData> stages;
			stages.push_back(stage);
			const String shader_name = vformat("NRD RELAX_DIFFUSE %d: %s", i, String::utf8(nrd_pipeline.shaderIdentifier));
			const Vector<uint8_t> shader_bytecode = rd->shader_compile_binary_from_spirv(stages, shader_name);
			ERR_FAIL_COND_V_MSG(shader_bytecode.is_empty(), ERR_CANT_CREATE, vformat("Failed to compile NRD pipeline %d for RenderingDevice.", i));

			Pipeline &pipeline = p_view->pipelines.write[i];
			pipeline.shader = rd->shader_create_from_bytecode_with_samplers(shader_bytecode, RID(), immutable_samplers);
			ERR_FAIL_COND_V_MSG(pipeline.shader.is_null(), ERR_CANT_CREATE, vformat("Failed to create NRD shader %d.", i));
			rd->set_resource_name(pipeline.shader, shader_name);
			pipeline.pipeline = rd->compute_pipeline_create(pipeline.shader);
			ERR_FAIL_COND_V_MSG(pipeline.pipeline.is_null(), ERR_CANT_CREATE, vformat("Failed to create NRD compute pipeline %d.", i));
			rd->set_resource_name(pipeline.pipeline, shader_name + " pipeline");
		}

		return OK;
	}

	Error create_view(const Size2i &p_size, ViewContext *&r_view) {
		ERR_FAIL_COND_V_MSG(p_size.x <= 0 || p_size.y <= 0 || p_size.x > 65535 || p_size.y > 65535, ERR_INVALID_PARAMETER,
				"NRD view dimensions must be in the [1, 65535] range.");
		Error err = initialize();
		if (err != OK) {
			return err;
		}

		ViewContext *view = memnew(ViewContext);
		view->size = p_size;
		nrd::DenoiserDesc denoiser_desc = {};
		denoiser_desc.identifier = RELAX_DIFFUSE_IDENTIFIER;
		denoiser_desc.denoiser = nrd::Denoiser::RELAX_DIFFUSE;
		nrd::InstanceCreationDesc creation_desc = {};
		creation_desc.denoisers = &denoiser_desc;
		creation_desc.denoisersNum = 1;
		err = _nrd_result_to_error(nrd::CreateInstance(creation_desc, view->instance), "CreateInstance");
		if (err != OK) {
			free_view(view);
			return err;
		}

		view->instance_desc = nrd::GetInstanceDesc(*view->instance);
		if (view->instance_desc == nullptr || view->instance_desc->shaderEntryPoint == nullptr ||
				view->instance_desc->resourcesSpaceIndex >= RenderingDeviceCommons::MAX_UNIFORM_SETS ||
				view->instance_desc->constantBufferAndSamplersSpaceIndex >= RenderingDeviceCommons::MAX_UNIFORM_SETS ||
				view->instance_desc->resourcesSpaceIndex == view->instance_desc->constantBufferAndSamplersSpaceIndex) {
			ERR_PRINT("NRD returned an unsupported RenderingDevice descriptor-set layout.");
			free_view(view);
			return ERR_UNAVAILABLE;
		}

		err = create_pool(view->instance_desc->permanentPool, view->instance_desc->permanentPoolSize, p_size, "permanent", view->permanent_pool);
		if (err == OK) {
			err = create_pool(view->instance_desc->transientPool, view->instance_desc->transientPoolSize, p_size, "transient", view->transient_pool);
		}
		if (err == OK) {
			err = create_pipelines(view);
		}
		if (err != OK) {
			free_view(view);
			return err;
		}

		r_view = view;
		return OK;
	}

	Error resize_pools(ViewContext *p_view, const Size2i &p_size) {
		ERR_FAIL_NULL_V(p_view, ERR_INVALID_PARAMETER);
		ERR_FAIL_COND_V_MSG(p_size.x <= 0 || p_size.y <= 0 || p_size.x > 65535 || p_size.y > 65535, ERR_INVALID_PARAMETER,
				"NRD view dimensions must be in the [1, 65535] range.");

		// NRD's instance, descriptor layout, shaders, pipelines and constant
		// buffers are resolution-independent. Release both old texture pools
		// before allocating either replacement pool so a resize never owns two
		// complete NRD working sets or recompiles RELAX.
		free_pool(p_view->transient_pool);
		free_pool(p_view->permanent_pool);
		p_view->size = Size2i();
		p_view->history_reset_pending = true;
		p_view->clear_history_resources = true;

		Error err = create_pool(p_view->instance_desc->permanentPool, p_view->instance_desc->permanentPoolSize, p_size, "permanent", p_view->permanent_pool);
		if (err == OK) {
			err = create_pool(p_view->instance_desc->transientPool, p_view->instance_desc->transientPoolSize, p_size, "transient", p_view->transient_pool);
		}
		if (err != OK) {
			// Leave the instance and pipelines alive, but no partially allocated
			// pool. A later resize_view() call can retry without recompilation.
			free_pool(p_view->transient_pool);
			free_pool(p_view->permanent_pool);
			return err;
		}

		p_view->size = p_size;
		return OK;
	}

	ViewContext *get_view(uint32_t p_view_id) const {
		ViewContext *const *view = views.getptr(p_view_id);
		return view != nullptr ? *view : nullptr;
	}

	RID resolve_resource(const ViewContext *p_view, const nrd::ResourceDesc &p_desc, const ExternalResources &p_external) const {
		switch (p_desc.type) {
			case nrd::ResourceType::IN_MV:
				return p_external.motion_vectors;
			case nrd::ResourceType::IN_NORMAL_ROUGHNESS:
				return p_external.normal_roughness;
			case nrd::ResourceType::IN_VIEWZ:
				return p_external.view_z;
			case nrd::ResourceType::IN_DIFF_RADIANCE_HITDIST:
				return p_external.diffuse_radiance_hitdist;
			case nrd::ResourceType::OUT_DIFF_RADIANCE_HITDIST:
				return p_external.output_diffuse_radiance_hitdist;
			case nrd::ResourceType::OUT_VALIDATION:
				return p_external.validation;
			case nrd::ResourceType::PERMANENT_POOL:
				return p_desc.indexInPool < (uint32_t)p_view->permanent_pool.size() ? p_view->permanent_pool[p_desc.indexInPool] : RID();
			case nrd::ResourceType::TRANSIENT_POOL:
				return p_desc.indexInPool < (uint32_t)p_view->transient_pool.size() ? p_view->transient_pool[p_desc.indexInPool] : RID();
			default:
				return RID();
		}
	}

	Error validate_texture(RID p_texture, const Size2i &p_size, RD::DataFormat p_format, uint32_t p_required_usage, const String &p_name, bool p_optional = false) const {
		if (p_texture.is_null() && p_optional) {
			return OK;
		}
		RD *rd = RD::get_singleton();
		ERR_FAIL_NULL_V(rd, ERR_UNAVAILABLE);
		ERR_FAIL_COND_V_MSG(!rd->texture_is_valid(p_texture), ERR_INVALID_PARAMETER, vformat("NRD external resource '%s' is not a valid RenderingDevice texture.", p_name));
		const RD::TextureFormat format = rd->texture_get_format(p_texture);
		ERR_FAIL_COND_V_MSG(format.format != p_format, ERR_INVALID_PARAMETER,
				vformat("NRD external resource '%s' has format %d, expected %d.", p_name, (uint32_t)format.format, (uint32_t)p_format));
		ERR_FAIL_COND_V_MSG((format.usage_bits & p_required_usage) != p_required_usage, ERR_INVALID_PARAMETER,
				vformat("NRD external resource '%s' is missing required texture usage bits 0x%x.", p_name, p_required_usage));
		ERR_FAIL_COND_V_MSG(rd->texture_size(p_texture) != p_size, ERR_INVALID_PARAMETER,
				vformat("NRD external resource '%s' has size %s, expected %s.", p_name, rd->texture_size(p_texture), p_size));
		return OK;
	}

	Error validate_external_resources(const ViewContext *p_view, const ExternalResources &p_resources) const {
		Error err = validate_texture(p_resources.motion_vectors, p_view->size, RD::DATA_FORMAT_R16G16B16A16_SFLOAT, RD::TEXTURE_USAGE_SAMPLING_BIT, "motion_vectors");
		if (err == OK) {
			err = validate_texture(p_resources.normal_roughness, p_view->size, RD::DATA_FORMAT_R8G8B8A8_UNORM, RD::TEXTURE_USAGE_SAMPLING_BIT, "normal_roughness");
		}
		if (err == OK) {
			err = validate_texture(p_resources.view_z, p_view->size, RD::DATA_FORMAT_R32_SFLOAT, RD::TEXTURE_USAGE_SAMPLING_BIT, "view_z");
		}
		if (err == OK) {
			RD *rd = RD::get_singleton();
			ERR_FAIL_NULL_V(rd, ERR_UNAVAILABLE);
			ERR_FAIL_COND_V_MSG(!rd->texture_is_valid(p_resources.diffuse_radiance_hitdist), ERR_INVALID_PARAMETER,
					"NRD external resource 'diffuse_radiance_hitdist' is not a valid RenderingDevice texture.");
			const RD::DataFormat noisy_format = rd->texture_get_format(p_resources.diffuse_radiance_hitdist).format;
			ERR_FAIL_COND_V_MSG(noisy_format != RD::DATA_FORMAT_R16G16B16A16_SFLOAT && noisy_format != RD::DATA_FORMAT_R32G32B32A32_SFLOAT,
					ERR_INVALID_PARAMETER, "NRD diffuse_radiance_hitdist must be RGBA16F or RGBA32F.");
			err = validate_texture(p_resources.diffuse_radiance_hitdist, p_view->size, noisy_format, RD::TEXTURE_USAGE_SAMPLING_BIT, "diffuse_radiance_hitdist");
		}
		if (err == OK) {
			err = validate_texture(p_resources.output_diffuse_radiance_hitdist, p_view->size, RD::DATA_FORMAT_R16G16B16A16_SFLOAT,
					RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_STORAGE_BIT, "output_diffuse_radiance_hitdist");
		}
		if (err == OK) {
			ERR_FAIL_COND_V_MSG(p_resources.diffuse_radiance_hitdist == p_resources.output_diffuse_radiance_hitdist, ERR_INVALID_PARAMETER,
					"NRD diffuse input and output must be distinct textures.");
		}
		if (err == OK && p_view->common_settings.enable_validation) {
			err = validate_texture(p_resources.validation, p_view->size, RD::DATA_FORMAT_R8G8B8A8_UNORM, RD::TEXTURE_USAGE_STORAGE_BIT, "validation");
		} else if (err == OK) {
			err = validate_texture(p_resources.validation, p_view->size, RD::DATA_FORMAT_R8G8B8A8_UNORM, RD::TEXTURE_USAGE_STORAGE_BIT, "validation", true);
		}
		return err;
	}

	nrd::CommonSettings make_common_settings(const ViewContext *p_view) const {
		const CommonSettings &source = p_view->common_settings;
		nrd::CommonSettings settings = {};
		memcpy(settings.viewToClipMatrix, source.view_to_clip, sizeof(settings.viewToClipMatrix));
		memcpy(settings.viewToClipMatrixPrev, source.view_to_clip_prev, sizeof(settings.viewToClipMatrixPrev));
		memcpy(settings.worldToViewMatrix, source.world_to_view, sizeof(settings.worldToViewMatrix));
		memcpy(settings.worldToViewMatrixPrev, source.world_to_view_prev, sizeof(settings.worldToViewMatrixPrev));
		memcpy(settings.motionVectorScale, source.motion_vector_scale, sizeof(settings.motionVectorScale));
		memcpy(settings.cameraJitter, source.camera_jitter, sizeof(settings.cameraJitter));
		memcpy(settings.cameraJitterPrev, source.camera_jitter_prev, sizeof(settings.cameraJitterPrev));

		settings.resourceSize[0] = source.resource_size[0] != 0 ? source.resource_size[0] : p_view->size.x;
		settings.resourceSize[1] = source.resource_size[1] != 0 ? source.resource_size[1] : p_view->size.y;
		settings.resourceSizePrev[0] = source.resource_size_prev[0] != 0 ? source.resource_size_prev[0] : settings.resourceSize[0];
		settings.resourceSizePrev[1] = source.resource_size_prev[1] != 0 ? source.resource_size_prev[1] : settings.resourceSize[1];
		settings.rectSize[0] = source.rect_size[0] != 0 ? source.rect_size[0] : settings.resourceSize[0];
		settings.rectSize[1] = source.rect_size[1] != 0 ? source.rect_size[1] : settings.resourceSize[1];
		settings.rectSizePrev[0] = source.rect_size_prev[0] != 0 ? source.rect_size_prev[0] : settings.rectSize[0];
		settings.rectSizePrev[1] = source.rect_size_prev[1] != 0 ? source.rect_size_prev[1] : settings.rectSize[1];

		settings.viewZScale = source.view_z_scale;
		settings.timeDeltaBetweenFrames = source.time_delta_between_frames_ms;
		settings.denoisingRange = source.denoising_range;
		settings.disocclusionThreshold = source.disocclusion_threshold;
		settings.disocclusionThresholdAlternate = source.disocclusion_threshold_alternate;
		settings.splitScreen = source.split_screen;
		settings.frameIndex = source.frame_index;
		settings.accumulationMode = _to_nrd_accumulation_mode(source.accumulation_mode);
		if (p_view->history_reset_pending) {
			if (p_view->clear_history_resources) {
				settings.accumulationMode = nrd::AccumulationMode::CLEAR_AND_RESTART;
			} else if (settings.accumulationMode == nrd::AccumulationMode::CONTINUE) {
				settings.accumulationMode = nrd::AccumulationMode::RESTART;
			}
		}
		settings.isMotionVectorInWorldSpace = source.motion_vectors_in_world_space;
		settings.isHistoryConfidenceAvailable = false;
		settings.isDisocclusionThresholdMixAvailable = false;
		settings.enableValidation = source.enable_validation;
		return settings;
	}

	nrd::RelaxSettings make_relax_settings(const RelaxSettings &p_source) const {
		nrd::RelaxSettings settings = {};
		settings.antilagSettings.accelerationAmount = p_source.antilag_acceleration_amount;
		settings.antilagSettings.spatialSigmaScale = p_source.antilag_spatial_sigma_scale;
		settings.antilagSettings.temporalSigmaScale = p_source.antilag_temporal_sigma_scale;
		settings.antilagSettings.resetAmount = p_source.antilag_reset_amount;
		settings.diffuseMaxAccumulatedFrameNum = p_source.diffuse_max_accumulated_frame_num;
		settings.diffuseMaxFastAccumulatedFrameNum = p_source.diffuse_max_fast_accumulated_frame_num;
		settings.historyFixFrameNum = p_source.history_fix_frame_num;
		settings.historyFixBasePixelStride = p_source.history_fix_base_pixel_stride;
		settings.historyFixAlternatePixelStride = p_source.history_fix_alternate_pixel_stride;
		settings.historyFixEdgeStoppingNormalPower = p_source.history_fix_edge_stopping_normal_power;
		settings.fastHistoryClampingSigmaScale = p_source.fast_history_clamping_sigma_scale;
		settings.diffusePrepassBlurRadius = p_source.diffuse_prepass_blur_radius;
		settings.minHitDistanceWeight = p_source.min_hit_distance_weight;
		settings.spatialVarianceEstimationHistoryThreshold = p_source.spatial_variance_estimation_history_threshold;
		settings.diffusePhiLuminance = p_source.diffuse_phi_luminance;
		settings.lobeAngleFraction = p_source.lobe_angle_fraction;
		settings.roughnessFraction = p_source.roughness_fraction;
		settings.atrousIterationNum = p_source.atrous_iteration_num;
		settings.diffuseMinLuminanceWeight = p_source.diffuse_min_luminance_weight;
		settings.depthThreshold = p_source.depth_threshold;
		settings.confidenceDrivenRelaxationMultiplier = p_source.confidence_driven_relaxation_multiplier;
		settings.confidenceDrivenLuminanceEdgeStoppingRelaxation = p_source.confidence_driven_luminance_edge_stopping_relaxation;
		settings.confidenceDrivenNormalEdgeStoppingRelaxation = p_source.confidence_driven_normal_edge_stopping_relaxation;
		settings.checkerboardMode = _to_nrd_checkerboard_mode(p_source.checkerboard_mode);
		settings.hitDistanceReconstructionMode = _to_nrd_hit_distance_mode(p_source.hit_distance_reconstruction_mode);
		settings.minMaterialForDiffuse = p_source.min_material_for_diffuse;
		settings.enableAntiFirefly = p_source.enable_anti_firefly;
		settings.enableRoughnessEdgeStopping = p_source.enable_roughness_edge_stopping;
		return settings;
	}

	Error ensure_constant_buffers(ViewContext *p_view, uint32_t p_count) {
		ERR_FAIL_COND_V_MSG(p_count > p_view->instance_desc->descriptorPoolDesc.setsMaxNum, ERR_BUG,
				"NRD returned more dispatches than its descriptor pool declaration permits.");
		if (p_view->constant_buffers.size() < (int)p_count) {
			p_view->constant_buffers.resize(p_count);
		}

		RD *rd = RD::get_singleton();
		ERR_FAIL_NULL_V(rd, ERR_UNAVAILABLE);
		for (uint32_t i = 0; i < p_count; i++) {
			if (p_view->constant_buffers[i].is_valid()) {
				continue;
			}
			p_view->constant_buffers.write[i] = rd->uniform_buffer_create(p_view->instance_desc->constantBufferMaxDataSize);
			ERR_FAIL_COND_V_MSG(p_view->constant_buffers[i].is_null(), ERR_CANT_CREATE, vformat("Failed to create NRD constant buffer %d.", i));
			rd->set_resource_name(p_view->constant_buffers[i], vformat("NRD dispatch constant buffer %d", i));
		}
		return OK;
	}

	Error create_constant_set(ViewContext *p_view, uint32_t p_dispatch_index, uint16_t p_pipeline_index, RID &r_set) {
		const nrd::PipelineDesc &pipeline_desc = p_view->instance_desc->pipelines[p_pipeline_index];
		if (!pipeline_desc.hasConstantData) {
			return OK;
		}

		Vector<RD::Uniform> uniforms;
		for (uint32_t i = 0; i < p_view->instance_desc->samplersNum; i++) {
			RD::Uniform sampler;
			sampler.uniform_type = RD::UNIFORM_TYPE_SAMPLER;
			sampler.binding = library_desc->spirvBindingOffsets.samplerOffset + p_view->instance_desc->samplersBaseRegisterIndex + i;
			sampler.immutable_sampler = true;
			sampler.append_id(get_sampler(p_view->instance_desc->samplers[i]));
			uniforms.push_back(sampler);
		}

		RD::Uniform constant_buffer;
		constant_buffer.uniform_type = RD::UNIFORM_TYPE_UNIFORM_BUFFER;
		constant_buffer.binding = library_desc->spirvBindingOffsets.constantBufferOffset + p_view->instance_desc->constantBufferRegisterIndex;
		constant_buffer.append_id(p_view->constant_buffers[p_dispatch_index]);
		uniforms.push_back(constant_buffer);

		RD *rd = RD::get_singleton();
		r_set = rd->uniform_set_create(uniforms, p_view->pipelines[p_pipeline_index].shader, p_view->instance_desc->constantBufferAndSamplersSpaceIndex, true);
		ERR_FAIL_COND_V_MSG(r_set.is_null(), ERR_CANT_CREATE, vformat("Failed to create NRD constants uniform set for dispatch %d.", p_dispatch_index));
		return OK;
	}

	Error create_resources_set(ViewContext *p_view, const nrd::DispatchDesc &p_dispatch, const ExternalResources &p_external, RID &r_set) {
		const nrd::PipelineDesc &pipeline_desc = p_view->instance_desc->pipelines[p_dispatch.pipelineIndex];
		Vector<RD::Uniform> uniforms;
		uint32_t resource_index = 0;
		for (uint32_t range_index = 0; range_index < pipeline_desc.resourceRangesNum; range_index++) {
			const nrd::ResourceRangeDesc &range = pipeline_desc.resourceRanges[range_index];
			const uint32_t binding_base = p_view->instance_desc->resourcesBaseRegisterIndex +
					(range.descriptorType == nrd::DescriptorType::TEXTURE ? library_desc->spirvBindingOffsets.textureOffset : library_desc->spirvBindingOffsets.storageTextureAndBufferOffset);
			for (uint32_t i = 0; i < range.descriptorsNum; i++, resource_index++) {
				ERR_FAIL_COND_V_MSG(resource_index >= p_dispatch.resourcesNum, ERR_BUG, "NRD resource ranges exceed the dispatch resource array.");
				const nrd::ResourceDesc &resource_desc = p_dispatch.resources[resource_index];
				ERR_FAIL_COND_V_MSG(resource_desc.descriptorType != range.descriptorType, ERR_BUG, "NRD dispatch resource type disagrees with its pipeline range.");
				const RID texture = resolve_resource(p_view, resource_desc, p_external);
				ERR_FAIL_COND_V_MSG(texture.is_null(), ERR_INVALID_PARAMETER,
						vformat("NRD dispatch '%s' requested unavailable resource '%s' (pool index %d).", p_dispatch.name, _nrd_resource_name(resource_desc.type), resource_desc.indexInPool));

				RD::Uniform uniform;
				uniform.uniform_type = range.descriptorType == nrd::DescriptorType::TEXTURE ? RD::UNIFORM_TYPE_TEXTURE : RD::UNIFORM_TYPE_IMAGE;
				uniform.binding = binding_base + i;
				uniform.append_id(texture);
				uniforms.push_back(uniform);
			}
		}
		ERR_FAIL_COND_V_MSG(resource_index != p_dispatch.resourcesNum, ERR_BUG, "NRD dispatch contains resources not covered by pipeline ranges.");

		if (uniforms.is_empty()) {
			return OK;
		}
		RD *rd = RD::get_singleton();
		r_set = rd->uniform_set_create(uniforms, p_view->pipelines[p_dispatch.pipelineIndex].shader, p_view->instance_desc->resourcesSpaceIndex, true);
		ERR_FAIL_COND_V_MSG(r_set.is_null(), ERR_CANT_CREATE, vformat("Failed to create NRD resources uniform set for dispatch '%s'.", p_dispatch.name));
		return OK;
	}

	void free_recorded_sets(const Vector<RecordedDispatch> &p_dispatches) {
		RD *rd = RD::get_singleton();
		if (rd == nullptr) {
			return;
		}
		// Linear-pool sets are still owned RIDs. RenderingDevice requires their
		// callers to free them within the same frame.
		for (const RecordedDispatch &dispatch : p_dispatches) {
			if (dispatch.resources_set.is_valid()) {
				rd->free_rid(dispatch.resources_set);
			}
			if (dispatch.constant_set.is_valid()) {
				rd->free_rid(dispatch.constant_set);
			}
		}
	}
};

#endif // NVIDIA_NRD_ENABLED

bool NrdContextRD::is_available() {
#ifdef NVIDIA_NRD_ENABLED
	RD *rd = RD::get_singleton();
	if (rd == nullptr) {
		return false;
	}
	const String device_api = rd->get_device_api_name();
	if (device_api != "Vulkan" && device_api != "D3D12") {
		return false;
	}
	const nrd::LibraryDesc *desc = nrd::GetLibraryDesc();
	return desc != nullptr && desc->versionMajor == NRD_VERSION_MAJOR && desc->versionMinor == NRD_VERSION_MINOR && desc->versionBuild == NRD_VERSION_BUILD &&
			desc->normalEncoding == nrd::NormalEncoding::RGBA8_UNORM && desc->roughnessEncoding == nrd::RoughnessEncoding::LINEAR;
#else
	return false;
#endif
}

NrdContextRD::NrdContextRD() {
#ifdef NVIDIA_NRD_ENABLED
	implementation = memnew(Implementation);
#endif
}

NrdContextRD::~NrdContextRD() {
	clear();
#ifdef NVIDIA_NRD_ENABLED
	if (implementation != nullptr) {
		memdelete(implementation);
		implementation = nullptr;
	}
#endif
}

Error NrdContextRD::resize_view(uint32_t p_view_id, const Size2i &p_size) {
#ifdef NVIDIA_NRD_ENABLED
	ERR_FAIL_NULL_V(implementation, ERR_UNAVAILABLE);
	Implementation::ViewContext *old_view = implementation->get_view(p_view_id);
	if (old_view != nullptr && old_view->size == p_size) {
		return OK;
	}
	if (old_view != nullptr) {
		return implementation->resize_pools(old_view, p_size);
	}

	Implementation::ViewContext *new_view = nullptr;
	Error err = implementation->create_view(p_size, new_view);
	if (err != OK) {
		return err;
	}
	implementation->views.insert(p_view_id, new_view);
	return OK;
#else
	(void)p_view_id;
	(void)p_size;
	return ERR_UNAVAILABLE;
#endif
}

void NrdContextRD::remove_view(uint32_t p_view_id) {
#ifdef NVIDIA_NRD_ENABLED
	if (implementation == nullptr) {
		return;
	}
	Implementation::ViewContext *view = implementation->get_view(p_view_id);
	if (view != nullptr) {
		implementation->views.erase(p_view_id);
		implementation->free_view(view);
	}
#else
	(void)p_view_id;
#endif
}

void NrdContextRD::clear() {
#ifdef NVIDIA_NRD_ENABLED
	if (implementation != nullptr) {
		implementation->clear();
	}
#endif
}

bool NrdContextRD::has_view(uint32_t p_view_id) const {
#ifdef NVIDIA_NRD_ENABLED
	return implementation != nullptr && implementation->get_view(p_view_id) != nullptr;
#else
	(void)p_view_id;
	return false;
#endif
}

Size2i NrdContextRD::get_view_size(uint32_t p_view_id) const {
#ifdef NVIDIA_NRD_ENABLED
	if (implementation != nullptr) {
		const Implementation::ViewContext *view = implementation->get_view(p_view_id);
		if (view != nullptr) {
			return view->size;
		}
	}
#else
	(void)p_view_id;
#endif
	return Size2i();
}

Error NrdContextRD::set_common_settings(uint32_t p_view_id, const CommonSettings &p_settings) {
#ifdef NVIDIA_NRD_ENABLED
	ERR_FAIL_NULL_V(implementation, ERR_UNAVAILABLE);
	Implementation::ViewContext *view = implementation->get_view(p_view_id);
	ERR_FAIL_NULL_V_MSG(view, ERR_DOES_NOT_EXIST, vformat("NRD view %d does not exist.", p_view_id));
	view->common_settings = p_settings;
	view->has_common_settings = true;
	return OK;
#else
	(void)p_view_id;
	(void)p_settings;
	return ERR_UNAVAILABLE;
#endif
}

Error NrdContextRD::set_relax_settings(uint32_t p_view_id, const RelaxSettings &p_settings) {
#ifdef NVIDIA_NRD_ENABLED
	ERR_FAIL_NULL_V(implementation, ERR_UNAVAILABLE);
	Implementation::ViewContext *view = implementation->get_view(p_view_id);
	ERR_FAIL_NULL_V_MSG(view, ERR_DOES_NOT_EXIST, vformat("NRD view %d does not exist.", p_view_id));
	view->relax_settings = p_settings;
	return OK;
#else
	(void)p_view_id;
	(void)p_settings;
	return ERR_UNAVAILABLE;
#endif
}

void NrdContextRD::reset_history(uint32_t p_view_id, bool p_clear_resources) {
#ifdef NVIDIA_NRD_ENABLED
	if (implementation == nullptr) {
		return;
	}
	Implementation::ViewContext *view = implementation->get_view(p_view_id);
	if (view != nullptr) {
		view->history_reset_pending = true;
		view->clear_history_resources = view->clear_history_resources || p_clear_resources;
	}
#else
	(void)p_view_id;
	(void)p_clear_resources;
#endif
}

Error NrdContextRD::denoise(uint32_t p_view_id, const ExternalResources &p_resources) {
#ifdef NVIDIA_NRD_ENABLED
	ERR_FAIL_NULL_V(implementation, ERR_UNAVAILABLE);
	Implementation::ViewContext *view = implementation->get_view(p_view_id);
	ERR_FAIL_NULL_V_MSG(view, ERR_DOES_NOT_EXIST, vformat("NRD view %d does not exist.", p_view_id));
	ERR_FAIL_COND_V_MSG(!view->has_common_settings, ERR_INVALID_PARAMETER, "NRD common settings must be supplied before denoise().");

	Error err = implementation->validate_external_resources(view, p_resources);
	if (err != OK) {
		return err;
	}

	const nrd::CommonSettings common_settings = implementation->make_common_settings(view);
	ERR_FAIL_COND_V_MSG(common_settings.resourceSize[0] != view->size.x || common_settings.resourceSize[1] != view->size.y, ERR_INVALID_PARAMETER,
			"NRD CommonSettings resource_size must match the size passed to resize_view().");
	ERR_FAIL_COND_V_MSG(common_settings.rectSize[0] == 0 || common_settings.rectSize[1] == 0 ||
					common_settings.rectSize[0] > common_settings.resourceSize[0] || common_settings.rectSize[1] > common_settings.resourceSize[1],
			ERR_INVALID_PARAMETER, "NRD CommonSettings rect_size must be non-zero and no larger than resource_size.");
	ERR_FAIL_COND_V_MSG(common_settings.resourceSizePrev[0] == 0 || common_settings.resourceSizePrev[1] == 0 ||
					common_settings.rectSizePrev[0] == 0 || common_settings.rectSizePrev[1] == 0 ||
					common_settings.rectSizePrev[0] > common_settings.resourceSizePrev[0] || common_settings.rectSizePrev[1] > common_settings.resourceSizePrev[1],
			ERR_INVALID_PARAMETER, "NRD CommonSettings previous rect/resource sizes are invalid.");
	ERR_FAIL_COND_V_MSG(common_settings.viewZScale <= 0.0f || common_settings.denoisingRange <= 0.0f ||
					common_settings.disocclusionThreshold <= 0.0f || common_settings.disocclusionThresholdAlternate <= 0.0f,
			ERR_INVALID_PARAMETER, "NRD depth scale, denoising range and disocclusion thresholds must be positive.");
	ERR_FAIL_COND_V_MSG(!common_settings.isMotionVectorInWorldSpace &&
					(common_settings.motionVectorScale[0] == 0.0f || common_settings.motionVectorScale[1] == 0.0f),
			ERR_INVALID_PARAMETER, "NRD screen-space motion vector scale X and Y must be non-zero.");
	ERR_FAIL_COND_V_MSG(common_settings.cameraJitter[0] < -0.5f || common_settings.cameraJitter[0] > 0.5f ||
					common_settings.cameraJitter[1] < -0.5f || common_settings.cameraJitter[1] > 0.5f ||
					common_settings.cameraJitterPrev[0] < -0.5f || common_settings.cameraJitterPrev[0] > 0.5f ||
					common_settings.cameraJitterPrev[1] < -0.5f || common_settings.cameraJitterPrev[1] > 0.5f,
			ERR_INVALID_PARAMETER, "NRD camera jitter must be in the [-0.5, 0.5] range.");

	err = _nrd_result_to_error(nrd::SetCommonSettings(*view->instance, common_settings), "SetCommonSettings");
	if (err != OK) {
		return err;
	}
	const nrd::RelaxSettings relax_settings = implementation->make_relax_settings(view->relax_settings);
	err = _nrd_result_to_error(nrd::SetDenoiserSettings(*view->instance, RELAX_DIFFUSE_IDENTIFIER, &relax_settings), "SetDenoiserSettings");
	if (err != OK) {
		return err;
	}

	const nrd::DispatchDesc *dispatch_descs = nullptr;
	uint32_t dispatch_count = 0;
	err = _nrd_result_to_error(nrd::GetComputeDispatches(*view->instance, &RELAX_DIFFUSE_IDENTIFIER, 1, dispatch_descs, dispatch_count), "GetComputeDispatches");
	if (err != OK) {
		return err;
	}
	ERR_FAIL_COND_V_MSG(dispatch_count == 0 || dispatch_descs == nullptr, ERR_BUG, "NRD returned no RELAX_DIFFUSE dispatches.");

	err = implementation->ensure_constant_buffers(view, dispatch_count);
	if (err != OK) {
		return err;
	}

	RD *rd = RD::get_singleton();
	ERR_FAIL_NULL_V(rd, ERR_UNAVAILABLE);
	for (uint32_t i = 0; i < dispatch_count; i++) {
		const nrd::DispatchDesc &dispatch = dispatch_descs[i];
		ERR_FAIL_INDEX_V(dispatch.pipelineIndex, view->pipelines.size(), ERR_BUG);
		const nrd::PipelineDesc &pipeline_desc = view->instance_desc->pipelines[dispatch.pipelineIndex];
		if (!pipeline_desc.hasConstantData) {
			continue;
		}
		ERR_FAIL_COND_V_MSG(dispatch.constantBufferData == nullptr || dispatch.constantBufferDataSize == 0 ||
						dispatch.constantBufferDataSize > view->instance_desc->constantBufferMaxDataSize,
				ERR_BUG, vformat("NRD dispatch '%s' returned invalid constant data.", dispatch.name));
		// Each dispatch owns a separate UBO, so copying even when NRD's
		// constantBufferDataMatchesPreviousDispatch hint is true is intentional.
		// It also keeps every update outside the compute list.
		err = rd->buffer_update(view->constant_buffers[i], 0, dispatch.constantBufferDataSize, dispatch.constantBufferData);
		if (err != OK) {
			return err;
		}
	}

	Vector<Implementation::RecordedDispatch> recorded_dispatches;
	recorded_dispatches.resize(dispatch_count);
	for (uint32_t i = 0; i < dispatch_count; i++) {
		const nrd::DispatchDesc &dispatch = dispatch_descs[i];
		Implementation::RecordedDispatch &recorded = recorded_dispatches.write[i];
		recorded.pipeline_index = dispatch.pipelineIndex;
		recorded.grid_width = dispatch.gridWidth;
		recorded.grid_height = dispatch.gridHeight;
		err = implementation->create_constant_set(view, i, dispatch.pipelineIndex, recorded.constant_set);
		if (err == OK) {
			err = implementation->create_resources_set(view, dispatch, p_resources, recorded.resources_set);
		}
		if (err != OK) {
			implementation->free_recorded_sets(recorded_dispatches);
			return err;
		}
	}

	RD::ComputeListID compute_list = rd->compute_list_begin();
	if (compute_list == RD::INVALID_ID) {
		implementation->free_recorded_sets(recorded_dispatches);
		return ERR_BUSY;
	}
	for (uint32_t i = 0; i < dispatch_count; i++) {
		const Implementation::RecordedDispatch &dispatch = recorded_dispatches[i];
		rd->compute_list_bind_compute_pipeline(compute_list, view->pipelines[dispatch.pipeline_index].pipeline);
		if (dispatch.constant_set.is_valid()) {
			rd->compute_list_bind_uniform_set(compute_list, dispatch.constant_set, view->instance_desc->constantBufferAndSamplersSpaceIndex);
		}
		if (dispatch.resources_set.is_valid()) {
			rd->compute_list_bind_uniform_set(compute_list, dispatch.resources_set, view->instance_desc->resourcesSpaceIndex);
		}
		rd->compute_list_dispatch(compute_list, dispatch.grid_width, dispatch.grid_height, 1);
		if (i + 1 < dispatch_count) {
			rd->compute_list_add_barrier(compute_list);
		}
	}
	rd->compute_list_end();
	implementation->free_recorded_sets(recorded_dispatches);

	view->history_reset_pending = false;
	view->clear_history_resources = false;
	return OK;
#else
	(void)p_view_id;
	(void)p_resources;
	return ERR_UNAVAILABLE;
#endif
}
