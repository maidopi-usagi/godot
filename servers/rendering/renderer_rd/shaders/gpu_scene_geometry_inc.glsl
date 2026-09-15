#ifndef GPU_SCENE_GEOMETRY_INC_GLSL
#define GPU_SCENE_GEOMETRY_INC_GLSL

// Object-space attributes in BLAS primitive order. Deformation updates the
// edges and normals alongside the build input, including imported LODs.
struct GPUSceneTriangle {
	vec4 edge1;
	vec4 edge2;
	uvec4 normals; // Three octahedral UNORM16x2 vertex normals; w is validity.
};

vec3 gpu_scene_triangle_normal(vec3 edge1, vec3 edge2) {
	float scale = max(max(abs(edge1.x), max(abs(edge1.y), abs(edge1.z))), max(abs(edge2.x), max(abs(edge2.y), abs(edge2.z))));
	vec3 normal = cross(edge1 / max(scale, 1e-20), edge2 / max(scale, 1e-20));
	float area_squared = dot(normal, normal);
	return area_squared > 1e-30 ? normal * inversesqrt(area_squared) : vec3(0.0, 0.0, 1.0);
}

vec3 gpu_scene_safe_normalize(vec3 normal, vec3 fallback) {
	float scale = max(abs(normal.x), max(abs(normal.y), abs(normal.z)));
	if (!(scale > 1e-20) || any(isnan(normal)) || any(isinf(normal))) {
		return fallback;
	}
	normal /= scale;
	return normalize(normal);
}

vec3 gpu_scene_decode_normal(uint packed) {
	vec2 oct = unpackUnorm2x16(packed) * 2.0 - 1.0;
	vec3 normal = vec3(oct, 1.0 - abs(oct.x) - abs(oct.y));
	normal.xy += mix(vec2(1.0), vec2(-1.0), greaterThanEqual(normal.xy, vec2(0.0))) * max(-normal.z, 0.0);
	return normalize(normal);
}

vec3 gpu_scene_triangle_shading_normal(GPUSceneTriangle triangle, vec2 barycentric, mat3 world_to_object, vec3 geometric_normal, vec3 ray_direction) {
	if (triangle.normals.w == 0u) {
		return geometric_normal;
	}
	mat3 normal_matrix = transpose(world_to_object);
	// Raster normalizes transformed vertex normals before interpolation. Match
	// that order under nonuniform scale; transforming the interpolant differs.
	vec3 n0 = gpu_scene_safe_normalize(normal_matrix * gpu_scene_decode_normal(triangle.normals.x), geometric_normal);
	vec3 n1 = gpu_scene_safe_normalize(normal_matrix * gpu_scene_decode_normal(triangle.normals.y), geometric_normal);
	vec3 n2 = gpu_scene_safe_normalize(normal_matrix * gpu_scene_decode_normal(triangle.normals.z), geometric_normal);
	vec3 normal = gpu_scene_safe_normalize(n0 * (1.0 - barycentric.x - barycentric.y) + n1 * barycentric.x + n2 * barycentric.y, geometric_normal);
	// Orient against the actual hit side, including mirrored instances and
	// double-sided hits. Authored normals must not point through the surface.
	if (dot(normal, geometric_normal) < 0.0) {
		normal = -normal;
	}
	return dot(normal, ray_direction) < 0.0 ? normal : geometric_normal;
}

// Project a circular ray footprint onto the hit plane, then map it through the
// triangle's UV Jacobian. Columns are explicit textureGrad derivatives; texture
// dimensions, material UV scaling, mip bias and anisotropy are applied later.
mat2 gpu_scene_ray_cone_gradients(vec3 edge1, vec3 edge2, vec2 uv1, vec2 uv2, vec3 direction, float width) {
	float scale = max(max(abs(edge1.x), max(abs(edge1.y), abs(edge1.z))), max(abs(edge2.x), max(abs(edge2.y), abs(edge2.z))));
	if (scale < 1e-20 || width <= 0.0) {
		return mat2(0.0);
	}
	edge1 /= scale;
	edge2 /= scale;
	vec3 area_vector = cross(edge1, edge2);
	float area = length(area_vector);
	if (area < 1e-15) {
		return mat2(0.0);
	}
	vec3 normal = area_vector / area;
	vec3 minor_axis = cross(normal, direction);
	float minor_length_squared = dot(minor_axis, minor_axis);
	if (minor_length_squared < 1e-8) {
		minor_axis = normalize(cross(direction, abs(direction.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0)));
	} else {
		minor_axis *= inversesqrt(minor_length_squared);
	}
	vec3 major_axis = cross(minor_axis, direction);
	float cosine = dot(normal, direction);
	// Cap nearly tangent footprints to keep all derivatives finite. The sampler
	// will clamp the resulting LOD to the resident image's mip range.
	cosine = (cosine < 0.0 ? -1.0 : 1.0) * max(abs(cosine), 1e-4);
	major_axis -= direction * (dot(normal, major_axis) / cosine);
	vec3 dual1 = cross(edge2, normal) / area;
	vec3 dual2 = cross(normal, edge1) / area;
	float footprint = width / scale;
	return mat2((uv1 * dot(dual1, minor_axis) + uv2 * dot(dual2, minor_axis)) * footprint,
			(uv1 * dot(dual1, major_axis) + uv2 * dot(dual2, major_axis)) * footprint);
}

#endif
