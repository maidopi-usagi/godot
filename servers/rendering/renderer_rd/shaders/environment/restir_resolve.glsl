#[compute]

#version 450

#VERSION_DEFINES

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

struct Reservoir {
	float w_sum;
	float W;
	uint M;
	uint pad;
	vec4 sample_radiance;
	vec4 sample_dir_dist;
};

layout(set = 0, binding = 0, std430) restrict readonly buffer Reservoirs {
	Reservoir data[];
} reservoirs;

layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D output_image;

layout(push_constant, std430) uniform Params {
	ivec2 screen_size;
	vec2 padding;
} params;

void main() {
	ivec2 pixel_pos = ivec2(gl_GlobalInvocationID.xy);
	if (pixel_pos.x >= params.screen_size.x || pixel_pos.y >= params.screen_size.y) {
		return;
	}
	
	uint pixel_index = pixel_pos.y * params.screen_size.x + pixel_pos.x;
	Reservoir r = reservoirs.data[pixel_index];
	
	// DEBUG: Output raw sample radiance to verify trace
	// vec3 final_radiance = r.sample_radiance.rgb; // * r.W;
	
	vec3 final_radiance = r.sample_radiance.rgb * r.W;
	
	imageStore(output_image, pixel_pos, vec4(final_radiance, 1.0));
}
