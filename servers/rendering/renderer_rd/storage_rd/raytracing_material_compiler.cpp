/**************************************************************************/
/*  raytracing_material_compiler.cpp                                       */
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

#include "raytracing_material_compiler.h"

#include "servers/rendering/shader_types.h"

using namespace RendererRD;

namespace {

using SL = ShaderLanguage;

struct MaterialLowering {
	String prefix;
	const HashMap<StringName, SL::ShaderNode::Uniform> *uniforms = nullptr;
	bool unsupported = false;
	bool uses_footprint = false;

	// Only duplicate side-effect-free expressions whose inputs we can identify.
	// Locals, user calls and dependent texture reads require explicit gradients.
	bool is_coordinate(const SL::Node *p_node) const {
		if (!p_node) {
			return false;
		}
		switch (p_node->type) {
			case SL::Node::NODE_TYPE_CONSTANT:
				return p_node->get_array_size() == 0;
			case SL::Node::NODE_TYPE_VARIABLE: {
				const SL::VariableNode *variable = static_cast<const SL::VariableNode *>(p_node);
				if (variable->is_local) {
					return false;
				}
				return variable->name == "UV" || variable->name == "TIME" || variable->is_const ||
						(uniforms->has(variable->name) && !(*uniforms)[variable->name].is_texture());
			}
			case SL::Node::NODE_TYPE_MEMBER: {
				const SL::MemberNode *member = static_cast<const SL::MemberNode *>(p_node);
				return !member->call_expression && !member->assign_expression && !member->index_expression && is_coordinate(member->owner);
			}
			case SL::Node::NODE_TYPE_ARRAY: {
				const SL::ArrayNode *array = static_cast<const SL::ArrayNode *>(p_node);
				return !array->is_local && !array->call_expression && !array->assign_expression &&
						uniforms->has(array->name) && !(*uniforms)[array->name].is_texture() && is_coordinate(array->index_expression);
			}
			case SL::Node::NODE_TYPE_OPERATOR: {
				const SL::OperatorNode *op = static_cast<const SL::OperatorNode *>(p_node);
				int first = 0;
				switch (op->op) {
					case SL::OP_ADD:
					case SL::OP_SUB:
					case SL::OP_MUL:
					case SL::OP_DIV:
					case SL::OP_NEGATE:
					case SL::OP_INDEX:
						break;
					case SL::OP_CONSTRUCT:
						first = 1;
						break;
					case SL::OP_CALL: {
						const StringName &name = static_cast<const SL::VariableNode *>(op->arguments[0])->name;
						bool pure = false;
						for (const char *builtin : { "sin", "cos", "tan", "asin", "acos", "atan", "abs", "sign", "floor", "ceil", "round", "trunc", "fract", "mod", "min", "max", "clamp", "mix", "step", "smoothstep", "pow", "exp", "exp2", "log", "log2", "sqrt", "inversesqrt", "length", "distance", "dot", "cross", "normalize", "reflect", "refract", "transpose", "inverse" }) {
							pure |= name == builtin;
						}
						if (!pure) {
							return false;
						}
						first = 1;
					} break;
					default:
						return false;
				}
				for (int i = first; i < op->arguments.size(); i++) {
					if (!is_coordinate(op->arguments[i])) {
						return false;
					}
				}
				return true;
			}
			default:
				return false;
		}
	}

	String gradient(const String &p_coordinate, int p_axis) const {
		// is_coordinate() guarantees the generated UV symbol is the only
		// substituted identifier; no user code or local state is replayed.
		const String shifted_uv = "(" + prefix + "uv + " + prefix + "gradients[" + itos(p_axis) + "])";
		return "(" + p_coordinate.replace(prefix + "uv", shifted_uv) + " - (" + p_coordinate + "))";
	}

	static String lower(void *p_userdata, const SL::OperatorNode *p_node, const Vector<String> &p_arguments) {
		MaterialLowering &context = *static_cast<MaterialLowering *>(p_userdata);
		const StringName &name = static_cast<const SL::VariableNode *>(p_node->arguments[0])->name;
		if (name == "dFdx" || name == "dFdy" || name == "fwidth") {
			context.uses_footprint = true;
			if (!context.is_coordinate(p_node->arguments[1])) {
				context.unsupported = true;
				return p_arguments[0];
			}
			if (name == "fwidth") {
				return "(abs(" + context.gradient(p_arguments[0], 0) + ") + abs(" + context.gradient(p_arguments[0], 1) + "))";
			}
			return context.gradient(p_arguments[0], name == "dFdx" ? 0 : 1);
		}
		if (p_node->arguments[1]->get_datatype() != SL::TYPE_SAMPLER2D) {
			context.unsupported = true;
			return "vec4(0.0)";
		}
		if (name == "texture") {
			context.uses_footprint = true;
			if (!context.is_coordinate(p_node->arguments[2])) {
				context.unsupported = true;
				return "vec4(0.0)";
			}
			const bool biased = p_arguments.size() == 3;
			return String(biased ? "gpu_scene_texture_bias(" : "gpu_scene_texture_grad(") + p_arguments[0] + ", " + p_arguments[1] + ", " + context.gradient(p_arguments[1], 0) + ", " + context.gradient(p_arguments[1], 1) +
					(biased ? ", " + p_arguments[2] + ", " + context.prefix + "sampling_bias" : String()) + ")";
		}
		String function;
		if (name == "textureGrad") {
			function = "gpu_scene_texture_grad";
		} else if (name == "textureLod") {
			function = "gpu_scene_texture_lod";
		} else if (name == "texelFetch") {
			function = "gpu_scene_texel_fetch";
		} else if (name == "textureSize") {
			function = "gpu_scene_texture_size";
		} else {
			function = "gpu_scene_texture_levels";
		}
		String call = function + "(" + p_arguments[0];
		for (int i = 1; i < p_arguments.size(); i++) {
			call += ", " + p_arguments[i];
		}
		return call + ")";
	}
};

} // namespace

RayTracingMaterialCompiler::Result RayTracingMaterialCompiler::compile(const String &p_code, const String &p_path) {
	Result result;
	const String prefix = "rt_" + p_code.sha256_text() + "_";
	ShaderCompiler compiler;
	ShaderCompiler::DefaultIdentifierActions defaults;
	defaults.identifier_prefix = prefix;
	defaults.type_renames[ShaderLanguage::TYPE_SAMPLER2D] = "uvec2";
	defaults.texture_uniforms_as_globals = true;
	defaults.base_uniform_string = prefix + "parameters.";
	defaults.renames["UV"] = prefix + "uv";
	defaults.renames["TIME"] = prefix + "time";
	defaults.renames["ALBEDO"] = prefix + "albedo";
	defaults.renames["EMISSION"] = prefix + "emission";
	defaults.renames["METALLIC"] = prefix + "metallic";
	defaults.renames["PI"] = "3.14159265358979323846";
	defaults.renames["TAU"] = "6.28318530717958647692";
	defaults.renames["E"] = "2.71828182845904523536";
	compiler.initialize(defaults);
	ShaderCompiler::IdentifierActions actions;
	actions.entry_point_stages["fragment"] = ShaderCompiler::STAGE_COMPUTE;
	actions.uniforms = &result.uniforms;
	MaterialLowering lowering{ prefix, &result.uniforms };
	actions.custom_function_call = &MaterialLowering::lower;
	actions.custom_function_userdata = &lowering;
	for (const char *name : { "texture", "textureLod", "textureGrad", "texelFetch", "textureSize", "textureQueryLevels", "dFdx", "dFdy", "fwidth" }) {
		actions.custom_functions.insert(name);
	}
	bool unsupported = false;
	bool writes_uv = false;
	actions.write_flag_pointers["UV"] = &writes_uv;
	for (const KeyValue<StringName, ShaderLanguage::FunctionInfo> &function : ShaderTypes::get_singleton()->get_functions(RSE::SHADER_SPATIAL)) {
		for (const KeyValue<StringName, ShaderLanguage::BuiltInInfo> &builtin : function.value.built_ins) {
			if (!defaults.renames.has(builtin.key)) {
				actions.usage_flag_pointers[builtin.key] = &unsupported;
			}
		}
	}
	for (const char *name : { "DISCARD", "dFdxCoarse", "dFdyCoarse", "fwidthCoarse", "dFdxFine", "dFdyFine", "fwidthFine", "textureProj", "textureProjLod", "textureProjGrad", "textureGather", "textureQueryLod" }) {
		actions.usage_flag_pointers[name] = &unsupported;
	}
	actions.usage_flag_pointers["TIME"] = &result.uses_time;
	ShaderCompiler::GeneratedCode generated;
	if (compiler.compile(RSE::SHADER_SPATIAL, p_code, &actions, p_path, generated) != OK || unsupported || lowering.unsupported ||
			(writes_uv && lowering.uses_footprint) || !generated.code.has("fragment")) {
		return Result();
	}
	const ShaderLanguage::ShaderNode *parsed = compiler.get_parsed_shader();
	if (!parsed->varyings.is_empty() || !parsed->stencil_modes.is_empty() || parsed->stencil_reference != -1) {
		return Result();
	}
	for (const ShaderLanguage::ShaderNode::Function &function : parsed->vfunctions) {
		if (function.name == "vertex" || function.name == "light") {
			return Result();
		}
	}
	bool unshaded = false;
	for (const StringName &mode : parsed->render_modes) {
		if (mode == "unshaded") {
			unshaded = true;
		} else if (mode != "blend_mix" && mode != "cull_disabled" && mode != "cull_back" && mode != "cull_front") {
			return Result();
		}
	}
	for (const KeyValue<StringName, ShaderLanguage::ShaderNode::Uniform> &uniform : parsed->uniforms) {
		if (uniform.value.scope != ShaderLanguage::ShaderNode::Uniform::SCOPE_LOCAL ||
				uniform.value.type < ShaderLanguage::TYPE_BOOL || uniform.value.type > ShaderLanguage::TYPE_SAMPLER2D ||
				uniform.value.hint == ShaderLanguage::ShaderNode::Uniform::HINT_SCREEN_TEXTURE ||
				uniform.value.hint == ShaderLanguage::ShaderNode::Uniform::HINT_DEPTH_TEXTURE ||
				uniform.value.hint == ShaderLanguage::ShaderNode::Uniform::HINT_NORMAL_ROUGHNESS_TEXTURE) {
			return Result();
		}
	}
	result.uniform_offsets = generated.uniform_offsets;
	result.uniform_size = generated.uniform_total_size;
	result.textures = generated.texture_uniforms;
	result.function = prefix + "evaluate";
	String code = "vec2 " + prefix + "uv;\nfloat " + prefix + "time;\nvec3 " + prefix + "albedo;\nvec3 " + prefix + "emission;\nfloat " + prefix + "metallic;\n";
	code += "mat2 " + prefix + "gradients;\n";
	code += "vec2 " + prefix + "sampling_bias;\n";
	if (!generated.uniforms.is_empty()) {
		code += "struct " + prefix + "Parameters {\n" + generated.uniforms + "};\n" + prefix + "Parameters " + prefix + "parameters;\n";
	}
	code += generated.stage_globals[ShaderCompiler::STAGE_COMPUTE];
	// Preserve the generated fragment body and perform output conversion in
	// the entry point shared by every HWRT hit-shading call site.
	code += "void " + prefix + "fragment() " + generated.code["fragment"] + "\n";
	code += "void " + result.function + "(uint offset, vec2 uv, mat2 gradients, vec3 scene, out vec3 albedo, out vec3 emission) {\n";
	code += prefix + "gradients = gradients;\n";
	code += prefix + "sampling_bias = scene.yz;\n";
	code += prefix + "uv = uv;\n" + prefix + "time = scene.x;\n" + prefix + "albedo = vec3(1.0);\n" + prefix + "emission = vec3(0.0);\n" + prefix + "metallic = 0.0;\n";
	Vector<StringName> names;
	for (const KeyValue<StringName, ShaderLanguage::ShaderNode::Uniform> &uniform : result.uniforms) {
		names.push_back(uniform.key);
	}
	names.sort_custom<StringName::AlphCompare>();
	for (const StringName &name : names) {
		const ShaderLanguage::ShaderNode::Uniform &uniform = result.uniforms[name];
		if (uniform.is_texture()) {
			continue;
		}
		const ShaderLanguage::DataType type = uniform.type;
		const uint32_t base = result.uniform_offsets[uniform.order] / sizeof(uint32_t);
		const uint32_t stride = ((ShaderLanguage::get_datatype_size(type) + 15) & ~15) / sizeof(uint32_t);
		const int matrix_size = type >= ShaderLanguage::TYPE_MAT2 ? int(type) - int(ShaderLanguage::TYPE_MAT2) + 2 : 0;
		const int components = matrix_size ? matrix_size * matrix_size : ShaderLanguage::get_cardinality(type);
		const bool floating = type >= ShaderLanguage::TYPE_FLOAT;
		const bool boolean = type >= ShaderLanguage::TYPE_BOOL && type <= ShaderLanguage::TYPE_BVEC4;
		const bool integer = type >= ShaderLanguage::TYPE_INT && type <= ShaderLanguage::TYPE_IVEC4;
		const String identifier = prefix + "m_" + String(name).replace("__", "_dus_").replace("__", "_dus_");
		if (uniform.array_size > 0) {
			code += "for (uint element = 0u; element < " + itos(uniform.array_size) + "u; element++) {\n";
		}
		code += prefix + "parameters." + identifier + (uniform.array_size > 0 ? "[element]" : "") + " = " + ShaderLanguage::get_datatype_name(type) + "(";
		for (int component = 0; component < components; component++) {
			if (component) {
				code += ", ";
			}
			const int word = matrix_size ? (component / matrix_size) * 4 + component % matrix_size : component;
			String load = "gpu_scene_custom_uniforms.data[offset + " + itos(base + word) + "u" + (uniform.array_size > 0 ? " + element * " + itos(stride) + "u" : "") + "]";
			if (floating) {
				code += "uintBitsToFloat(" + load + ")";
			} else if (boolean) {
				code += "(" + load + " != 0u)";
			} else if (integer) {
				code += "int(" + load + ")";
			} else {
				code += load;
			}
		}
		code += ");\n";
		if (uniform.array_size > 0) {
			code += "}\n";
		}
	}
	uint32_t texture_word = result.uniform_size / sizeof(uint32_t);
	for (const ShaderCompiler::GeneratedCode::Texture &texture : result.textures) {
		const String identifier = prefix + "m_" + String(texture.name).replace("__", "_dus_").replace("__", "_dus_");
		for (int element = 0; element < MAX(1, texture.array_size); element++) {
			code += identifier + (texture.array_size > 0 ? "[" + itos(element) + "]" : "") + " = uvec2(gpu_scene_custom_uniforms.data[offset + " + itos(texture_word) + "u], gpu_scene_custom_uniforms.data[offset + " + itos(texture_word + 1) + "u]);\n";
			texture_word += 2;
		}
	}
	code += prefix + "fragment();\n";
	if (unshaded) {
		// Forward+ unshaded output is ALBEDO; it ignores EMISSION.
		code += "albedo = vec3(0.0);\nemission = max(" + prefix + "albedo, vec3(0.0));\n";
	} else {
		code += "albedo = clamp(" + prefix + "albedo, vec3(0.0), vec3(1.0)) * (1.0 - clamp(" + prefix + "metallic, 0.0, 1.0));\nemission = max(" + prefix + "emission, vec3(0.0));\n";
	}
	code += "}\n";
	result.code = code;
	return result;
}
