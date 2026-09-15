#ifndef GPU_SCENE_MATERIAL_INC_GLSL
#define GPU_SCENE_MATERIAL_INC_GLSL

// Shared by ray-query and SBT hit shaders. The caller supplies the descriptor
// declarations and enables GL_EXT_nonuniform_qualifier before other GLSL code.
struct GPUSceneMaterial {
	vec4 albedo_metallic;
	vec4 emission_energy;
	vec4 uv_scale_offset;
	vec4 metallic_channel;
	uvec4 textures_sampler;
	uvec4 flags;
};

// Ordinary handles can cross function boundaries. Decorate the descriptor
// indices at the actual sample, and evaluate each caller argument only once.
vec4 gpu_scene_texture_grad(uvec2 handle, vec2 uv, vec2 dx, vec2 dy) {
	return textureGrad(sampler2D(gpu_scene_textures[nonuniformEXT(handle.x)], gpu_scene_samplers[nonuniformEXT(handle.y)]), uv, dx, dy);
}

vec4 gpu_scene_texture_bias(uvec2 handle, vec2 uv, vec2 dx, vec2 dy, float bias, vec2 sampling_bias) {
	// Vulkan clamps the sum of instruction and sampler bias. The sampler adds
	// its own bias after the gradient-derived LOD; compensate before sampling.
	// The first four samplers disable mipmaps and carry no sampler bias.
	float sampler_bias = handle.y < 4u ? 0.0 : sampling_bias.x;
	float scale = exp2(clamp(sampler_bias + bias, -sampling_bias.y, sampling_bias.y) - sampler_bias);
	return gpu_scene_texture_grad(handle, uv, dx * scale, dy * scale);
}

vec4 gpu_scene_texture_lod(uvec2 handle, vec2 uv, float lod) {
	return textureLod(sampler2D(gpu_scene_textures[nonuniformEXT(handle.x)], gpu_scene_samplers[nonuniformEXT(handle.y)]), uv, lod);
}

vec4 gpu_scene_texel_fetch(uvec2 handle, ivec2 coordinate, int lod) {
	return texelFetch(sampler2D(gpu_scene_textures[nonuniformEXT(handle.x)], gpu_scene_samplers[nonuniformEXT(handle.y)]), coordinate, lod);
}

ivec2 gpu_scene_texture_size(uvec2 handle, int lod) {
	return textureSize(sampler2D(gpu_scene_textures[nonuniformEXT(handle.x)], gpu_scene_samplers[nonuniformEXT(handle.y)]), lod);
}

int gpu_scene_texture_levels(uvec2 handle) {
	return textureQueryLevels(sampler2D(gpu_scene_textures[nonuniformEXT(handle.x)], gpu_scene_samplers[nonuniformEXT(handle.y)]));
}

void gpu_scene_sample_material(GPUSceneMaterial material, vec2 uv, mat2 uv_gradients, out vec3 albedo, out vec3 emission) {
	uv = uv * material.uv_scale_offset.xy + material.uv_scale_offset.zw;
	uv_gradients[0] *= material.uv_scale_offset.xy;
	uv_gradients[1] *= material.uv_scale_offset.xy;
	uint sampler_index = material.textures_sampler.w;
	vec3 color = textureGrad(sampler2D(gpu_scene_textures[nonuniformEXT(material.textures_sampler.x)], gpu_scene_samplers[nonuniformEXT(sampler_index)]), uv, uv_gradients[0], uv_gradients[1]).rgb;
	vec4 metal = textureGrad(sampler2D(gpu_scene_textures[nonuniformEXT(material.textures_sampler.y)], gpu_scene_samplers[nonuniformEXT(sampler_index)]), uv, uv_gradients[0], uv_gradients[1]);
	float metallic = clamp(dot(metal, material.metallic_channel) * material.albedo_metallic.a, 0.0, 1.0);
	albedo = clamp(material.albedo_metallic.rgb * color, vec3(0.0), vec3(1.0)) * (1.0 - metallic);
	emission = vec3(0.0);
	if (material.emission_energy.a != 0.0) {
		vec3 tex_emission = textureGrad(sampler2D(gpu_scene_textures[nonuniformEXT(material.textures_sampler.z)], gpu_scene_samplers[nonuniformEXT(sampler_index)]), uv, uv_gradients[0], uv_gradients[1]).rgb;
		emission = (material.flags.x & 1u) != 0u ? material.emission_energy.rgb * tex_emission : material.emission_energy.rgb + tex_emission;
		emission = max(emission * material.emission_energy.a, vec3(0.0));
	}
}

#endif
