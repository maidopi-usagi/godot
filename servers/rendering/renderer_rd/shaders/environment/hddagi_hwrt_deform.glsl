#[compute]

#version 450

#VERSION_DEFINES

#include "../gpu_scene_geometry_inc.glsl"

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// Native 3D skinning/blend shapes write tightly packed float3 positions first.
layout(set = 0, binding = 0, std430) restrict readonly buffer SourceVertices {
	float data[];
}
source_vertices;

layout(set = 0, binding = 1, std430) restrict readonly buffer TriangleIndices {
	uint data[];
}
triangle_indices;

layout(set = 0, binding = 2, std430) restrict writeonly buffer Vertices {
	float data[];
}
vertices;

layout(set = 0, binding = 3, std430) restrict writeonly buffer Triangles {
	GPUSceneTriangle data[];
}
triangles;

layout(push_constant, std430) uniform Params {
	uint triangle_offset;
	uint triangle_count;
	uint triangle_data_offset;
	uint pad;
}
params;

void main() {
	uint index = gl_GlobalInvocationID.x;
	if (index >= params.triangle_count) {
		return;
	}
	uint triangle = params.triangle_offset + index;
	vec3 points[3];
	for (uint corner = 0; corner < 3; corner++) {
		uint source = triangle_indices.data[triangle * 3 + corner] * 3;
		points[corner] = vec3(source_vertices.data[source], source_vertices.data[source + 1], source_vertices.data[source + 2]);
		uint target = triangle * 9 + corner * 3;
		vertices.data[target] = points[corner].x;
		vertices.data[target + 1] = points[corner].y;
		vertices.data[target + 2] = points[corner].z;
	}
	// A pose can collapse a triangle; keep its primitive/material index stable.
	triangles.data[params.triangle_data_offset + triangle].edge1 = vec4(points[1] - points[0], 0.0);
	triangles.data[params.triangle_data_offset + triangle].edge2 = vec4(points[2] - points[0], 0.0);
}
