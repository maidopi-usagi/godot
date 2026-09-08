#[compute]

#version 450

#VERSION_DEFINES

// The descriptor layout is shared with HDDAGIRigidInstance; offsets are element indices.
layout(push_constant, std430) uniform Params {
	uvec4 grid;
	uvec4 offsets;
}
params;

layout(r32ui, set = 0, binding = 4) uniform restrict readonly uimage3D src_normal_bits;
layout(set = 0, binding = 41, std430) restrict buffer Geometry {
	uint data[];
}
geometry;

uint cell_index(uvec3 cell, uvec3 dimensions) {
	return cell.x + dimensions.x * (cell.y + dimensions.y * cell.z);
}

#ifdef MODE_REGION_STORE
layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
shared uint region_bits[16];
shared uint region_used;
#endif

#ifdef MODE_LIGHT_STORE
layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;
layout(r16ui, set = 0, binding = 1) uniform restrict readonly uimage3D src_albedo;
layout(r32ui, set = 0, binding = 2) uniform restrict readonly uimage3D src_emission;
layout(r32ui, set = 0, binding = 3) uniform restrict readonly uimage3D src_emission_aniso;
layout(set = 0, binding = 42, std430) restrict writeonly buffer Surfaces {
	uvec4 data[];
}
surfaces;
layout(set = 0, binding = 43, std430) restrict writeonly buffer Lighting {
	uint data[];
}
lighting;
const uint LIGHT_CELL_VALID_BIT = 1u << 26u;
shared uint store_count;
shared uint store_base;
shared uint normal_facings[6 * 6 * 6];

uint get_normal_facing(ivec3 p_pos) {
	p_pos += ivec3(1);
	return normal_facings[p_pos.z * 6 * 6 + p_pos.y * 6 + p_pos.x];
}

void set_normal_facing(ivec3 p_pos, uint p_facing) {
	p_pos += ivec3(1);
	normal_facings[p_pos.z * 6 * 6 + p_pos.y * 6 + p_pos.x] = p_facing;
}

vec2 octahedron_wrap(vec2 v) {
	vec2 signVal;
	signVal.x = v.x >= 0.0 ? 1.0 : -1.0;
	signVal.y = v.y >= 0.0 ? 1.0 : -1.0;
	return (1.0 - abs(v.yx)) * signVal;
}

vec2 octahedron_encode(vec3 n) {
	// https://twitter.com/Stubbesaurus/status/937994790553227264
	n /= (abs(n.x) + abs(n.y) + abs(n.z));
	n.xy = n.z >= 0.0 ? n.xy : octahedron_wrap(n.xy);
	n.xy = n.xy * 0.5 + 0.5;
	return n.xy;
}

vec3 octahedron_decode(vec2 f) {
	// https://twitter.com/Stubbesaurus/status/937994790553227264
	f = f * 2.0 - 1.0;
	vec3 n = vec3(f.x, f.y, 1.0f - abs(f.x) - abs(f.y));
	float t = clamp(-n.z, 0.0, 1.0);
	n.x += n.x >= 0 ? -t : t;
	n.y += n.y >= 0 ? -t : t;
	return normalize(n);
}

uint rgbe_encode(vec3 rgb) {
	const float rgbe_max = uintBitsToFloat(0x477F8000);
	const float rgbe_min = uintBitsToFloat(0x37800000);

	rgb = clamp(rgb, 0, rgbe_max);

	float max_channel = max(max(rgbe_min, rgb.r), max(rgb.g, rgb.b));

	float bias = uintBitsToFloat((floatBitsToUint(max_channel) + 0x07804000) & 0x7F800000);

	uvec3 urgb = floatBitsToUint(rgb + bias);
	uint e = (floatBitsToUint(bias) << 4) + 0x10000000;
	return e | (urgb.b << 18) | (urgb.g << 9) | (urgb.r & 0x1FF);
}

vec3 rgbe_decode(uint p_rgbe) {
	vec4 rgbef = vec4((uvec4(p_rgbe) >> uvec4(0, 9, 18, 27)) & uvec4(0x1FF, 0x1FF, 0x1FF, 0x1F));
	return rgbef.rgb * pow(2.0, rgbef.a - 15.0 - 9.0);
}

#include "hddagi_surface_inc.glsl"
#endif

void main() {
#ifdef MODE_REGION_STORE
	uvec3 local = gl_LocalInvocationID.xyz;
	uvec3 subregion = local / 4u;
	uint subregion_index = cell_index(subregion, uvec3(2));
	uint subregion_bit = cell_index(local % 4u, uvec3(4));
	if (gl_LocalInvocationIndex < 16u) {
		region_bits[gl_LocalInvocationIndex] = 0u;
	}
	if (gl_LocalInvocationIndex == 0u) {
		region_used = 0u;
	}
	barrier();

	if (imageLoad(src_normal_bits, ivec3(gl_GlobalInvocationID.xyz)).r != 0u) {
		atomicOr(region_bits[subregion_index * 2u + subregion_bit / 32u], 1u << (subregion_bit & 31u));
		atomicOr(region_used, 1u);
	}
	barrier();

	if (subregion_bit == 0u) {
		uvec3 block = gl_WorkGroupID.xyz * 2u + subregion;
		uint block_index = params.grid.w + cell_index(block, params.grid.xyz / 4u) * 2u;
		geometry.data[block_index] = region_bits[subregion_index * 2u];
		geometry.data[block_index + 1u] = region_bits[subregion_index * 2u + 1u];
	}
	if (gl_LocalInvocationIndex == 0u) {
		geometry.data[params.offsets.x + cell_index(gl_WorkGroupID.xyz, params.grid.xyz / 8u)] = region_used;
		if (all(equal(gl_WorkGroupID.xyz, uvec3(0)))) {
			// Surface construction follows this dispatch, so no counter reset races.
			geometry.data[params.offsets.w] = 0u;
			geometry.data[params.offsets.w + 1u] = 1u;
			geometry.data[params.offsets.w + 2u] = 1u;
			geometry.data[params.offsets.w + 3u] = 0u;
		}
	}
#endif

#ifdef MODE_LIGHT_STORE
	ivec3 local = ivec3(gl_LocalInvocationID.xyz);
	ivec3 pos = ivec3(gl_GlobalInvocationID.xyz);
	ivec3 load_from = local * 6 / 4;
	ivec3 load_to = (local + ivec3(1)) * 6 / 4;
	ivec3 base_pos = ivec3(gl_WorkGroupID.xyz) * 4;
	for (int x = load_from.x; x < load_to.x; x++) {
		for (int y = load_from.y; y < load_to.y; y++) {
			for (int z = load_from.z; z < load_to.z; z++) {
				ivec3 local_offset = ivec3(x, y, z) - ivec3(1);
				ivec3 source_pos = base_pos + local_offset;
				uint facing = 0u;
				if (all(greaterThanEqual(source_pos, ivec3(0))) && all(lessThan(source_pos, ivec3(params.grid.xyz)))) {
					facing = imageLoad(src_normal_bits, source_pos).r;
				}
				set_normal_facing(local_offset, facing);
			}
		}
	}
	if (gl_LocalInvocationIndex == 0u) {
		store_count = 0u;
	}
	barrier();

	vec4 albedo;
	vec4 emission;
	vec3 normal;
	uint neighbours;
	uint disocclusion;
	bool valid = hddagi_build_surface(pos, local, albedo, emission, normal, neighbours, disocclusion);
	uint linear_cell = cell_index(uvec3(pos), params.grid.xyz);
	uvec4 surface = uvec4(0u, 0u, neighbours, disocclusion);
	uint task_index = 0u;
	if (valid) {
		surface.x = hddagi_pack_surface_albedo(albedo, normal);
		surface.y = rgbe_encode(emission.rgb / emission.a);
		surface.z |= LIGHT_CELL_VALID_BIT;
		task_index = atomicAdd(store_count, 1u);
	}
	surfaces.data[params.offsets.y + linear_cell] = surface;
	lighting.data[params.offsets.z + linear_cell] = surface.y;
	barrier();

	if (gl_LocalInvocationIndex == 0u && store_count > 0u) {
		store_base = atomicAdd(geometry.data[params.offsets.w + 3u], store_count);
		atomicMax(geometry.data[params.offsets.w], (store_base + store_count + 63u) / 64u);
	}
	barrier();
	if (valid) {
		geometry.data[params.offsets.w + 4u + store_base + task_index] = linear_cell;
	}
#endif
}
