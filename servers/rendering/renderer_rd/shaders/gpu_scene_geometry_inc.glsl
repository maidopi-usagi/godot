#ifndef GPU_SCENE_GEOMETRY_INC_GLSL
#define GPU_SCENE_GEOMETRY_INC_GLSL

// Object-space edges in BLAS primitive order. Deformation updates this record
// alongside the build input, so shading never uses a bind-pose UV density.
struct GPUSceneTriangle {
	vec4 edge1;
	vec4 edge2;
};

vec3 gpu_scene_triangle_normal(vec3 edge1, vec3 edge2) {
	float scale = max(max(abs(edge1.x), max(abs(edge1.y), abs(edge1.z))), max(abs(edge2.x), max(abs(edge2.y), abs(edge2.z))));
	vec3 normal = cross(edge1 / max(scale, 1e-20), edge2 / max(scale, 1e-20));
	float area_squared = dot(normal, normal);
	return area_squared > 1e-30 ? normal * inversesqrt(area_squared) : vec3(0.0, 0.0, 1.0);
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
