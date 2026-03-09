// Material evaluation result - common output format for all hit groups.
// Standard materials and custom ShaderMaterials both produce this struct.

struct MaterialResult {
	vec3 albedo;
	float alpha;
	float roughness;
	float metalness;
	vec3 emissive;
	vec3 normal; // Final shading normal (world space, after normal mapping).
};

/// Sensible default for a mid-grey diffuse surface.
MaterialResult default_material_result(vec3 geometry_normal) {
	MaterialResult r;
	r.albedo = vec3(0.8);
	r.alpha = 1.0;
	r.roughness = 0.5;
	r.metalness = 0.0;
	r.emissive = vec3(0.0);
	r.normal = geometry_normal;
	return r;
}
