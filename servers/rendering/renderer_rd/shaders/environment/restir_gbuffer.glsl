#[compute]

#version 450

#VERSION_DEFINES

// GBuffer downsample modes
// MODE_DOWNSAMPLE_NORMAL_DEPTH - Downsample normal and depth to probe resolution
// MODE_DOWNSAMPLE_DIFFUSE - Downsample diffuse color
// MODE_BUILD_DEPTH_PYRAMID - Build hierarchical depth pyramid for screen-space tracing

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

#ifdef MODE_DOWNSAMPLE_NORMAL_DEPTH

layout(set = 0, binding = 0) uniform sampler2D u_source_normal_roughness;
layout(set = 0, binding = 1) uniform sampler2D u_source_depth;
layout(rgba16f, set = 0, binding = 2) uniform restrict writeonly image2D dest_normal_depth;

layout(push_constant, std430) uniform Params {
	ivec2 source_size;
	ivec2 dest_size;
	float depth_scale;
	uint view_index;
	uint pad1;
	uint pad2;
} params;

vec3 decode_octahedral_normal(vec2 e) {
	vec3 v = vec3(e.xy, 1.0 - abs(e.x) - abs(e.y));
	if (v.z < 0.0) {
		v.xy = (1.0 - abs(v.yx)) * sign(v.xy);
	}
	return normalize(v);
}

void main() {
	ivec2 dest_pos = ivec2(gl_GlobalInvocationID.xy);
	
	if (dest_pos.x >= params.dest_size.x || dest_pos.y >= params.dest_size.y) {
		return;
	}
	
	// Calculate source coordinates for downsampling
	vec2 uv_center = (vec2(dest_pos) + 0.5) / vec2(params.dest_size);
	vec2 texel_size = 1.0 / vec2(params.source_size);
	
	// Sample 2x2 neighborhood for better quality
	vec3 normal_sum = vec3(0.0);
	float depth_sum = 0.0;
	float weight_sum = 0.0;
	
	for (int y = -1; y <= 0; y++) {
		for (int x = -1; x <= 0; x++) {
			vec2 offset = vec2(x, y) * texel_size * 0.5;
			vec2 sample_uv = uv_center + offset;
			
			vec4 normal_roughness = texture(u_source_normal_roughness, sample_uv);
			// Godot uses Octahedral compression in RG channels
			vec3 normal = decode_octahedral_normal(normal_roughness.xy * 2.0 - 1.0);
			float depth = texture(u_source_depth, sample_uv).r;
			
			// Weight by normal validity (non-zero normals)
			float weight = step(0.001, length(normal));
			
			normal_sum += normal * weight;
			depth_sum += depth * weight;
			weight_sum += weight;
		}
	}
	
	// Normalize
	if (weight_sum > 0.0) {
		normal_sum /= weight_sum;
		depth_sum /= weight_sum;
	}
	
	// Normalize the averaged normal
	vec3 final_normal = normalize(normal_sum);
	
	// Pack normal (xyz) and depth (w) into output
	imageStore(dest_normal_depth, dest_pos, vec4(final_normal, depth_sum * params.depth_scale));
}

#endif

#ifdef MODE_DOWNSAMPLE_DIFFUSE

layout(set = 0, binding = 0) uniform sampler2D u_source_albedo;
layout(rgba8, set = 0, binding = 1) uniform restrict writeonly image2D dest_diffuse;

layout(push_constant, std430) uniform Params {
	ivec2 source_size;
	ivec2 dest_size;
	uint view_index;
	uint pad1;
	uint pad2;
	uint pad3;
} params;

void main() {
	ivec2 dest_pos = ivec2(gl_GlobalInvocationID.xy);
	
	if (dest_pos.x >= params.dest_size.x || dest_pos.y >= params.dest_size.y) {
		return;
	}
	
	vec2 uv = (vec2(dest_pos) + 0.5) / vec2(params.dest_size);
	
	// Simple bilinear sampling for albedo
	vec4 albedo = texture(u_source_albedo, uv);
	
	imageStore(dest_diffuse, dest_pos, albedo);
}

#endif

#ifdef MODE_BUILD_DEPTH_PYRAMID

layout(set = 0, binding = 0) uniform sampler2D u_source_depth;
layout(r32f, set = 0, binding = 1) uniform restrict writeonly image2D dest_depth_mip;

layout(push_constant, std430) uniform Params {
	ivec2 source_size;
	ivec2 dest_size;
	int source_mip;
	uint view_index;
	uint pad1;
	uint pad2;
} params;

void main() {
	ivec2 dest_pos = ivec2(gl_GlobalInvocationID.xy);
	
	if (dest_pos.x >= params.dest_size.x || dest_pos.y >= params.dest_size.y) {
		return;
	}
	
	// For hierarchical Z-buffer, we want the farthest depth (maximum)
	// This is conservative for screen-space ray marching
	vec2 uv = vec2(dest_pos * 2) / vec2(params.source_size);
	vec2 texel_size = 1.0 / vec2(params.source_size);
	
	float max_depth = 0.0;
	
	// Sample 2x2 block and take maximum depth
	for (int y = 0; y < 2; y++) {
		for (int x = 0; x < 2; x++) {
			vec2 sample_uv = uv + vec2(x, y) * texel_size;
			float depth = textureLod(u_source_depth, sample_uv, float(params.source_mip)).r;
			max_depth = max(max_depth, depth);
		}
	}
	
	imageStore(dest_depth_mip, dest_pos, vec4(max_depth));
}

#endif

#ifdef MODE_EXTRACT_MOTION_VECTORS

layout(set = 0, binding = 0) uniform sampler2D u_source_velocity;
layout(rg16f, set = 0, binding = 1) uniform restrict writeonly image2D dest_motion;

layout(set = 0, binding = 2) uniform sampler2D u_source_depth;
layout(set = 0, binding = 3, std140) uniform ReprojectionData {
	mat4 prev_view_proj;
	mat4 inv_view_proj;
	vec2 screen_size;
	vec2 inv_screen_size;
} reprojection;

layout(push_constant, std430) uniform Params {
	ivec2 dest_size;
	uint view_index;
	uint pad1;
} params;

void main() {
	ivec2 dest_pos = ivec2(gl_GlobalInvocationID.xy);
	
	if (dest_pos.x >= params.dest_size.x || dest_pos.y >= params.dest_size.y) {
		return;
	}
	
	vec2 uv = (vec2(dest_pos) + 0.5) / vec2(params.dest_size);
	
	// Try to read velocity buffer first (if available from material pass)
	vec2 velocity = texture(u_source_velocity, uv).xy;
	
	// If velocity is near zero, compute from depth reprojection
	if (length(velocity) < 0.0001) {
		float depth = texture(u_source_depth, uv).r;
		
		// Reconstruct world position from depth
		vec4 ndc = vec4(uv * 2.0 - 1.0, depth, 1.0);
		vec4 world_pos = reprojection.inv_view_proj * ndc;
		world_pos /= world_pos.w;
		
		// Reproject to previous frame
		vec4 prev_ndc = reprojection.prev_view_proj * world_pos;
		prev_ndc.xy /= prev_ndc.w;
		
		// Calculate motion vector in screen space
		velocity = (ndc.xy - prev_ndc.xy) * 0.5;
	}
	
	imageStore(dest_motion, dest_pos, vec4(velocity, 0.0, 0.0));
}

#endif
