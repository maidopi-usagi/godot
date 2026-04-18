// Shared data structures for raytracing shaders.
// Requires: GL_EXT_buffer_reference, GL_ARB_gpu_shader_int64, raytracing_inc.glsl (for OFFSET_NONE/FLAG_*)

// ============================================================================
// BUFFER REFERENCES
// ============================================================================
layout(buffer_reference, std430) readonly buffer FloatBuffer {
	float v[];
};
layout(buffer_reference, std430) readonly buffer Uint32Buffer {
	uint v[];
};

// ============================================================================
// GEOMETRY DATA (matches C++ RT_GeometryData, 128 bytes)
// ============================================================================
struct GeometryData {
	uint64_t vertex_address;
	uint64_t attribute_address;
	uint64_t index_address;

	uint vertex_count;
	uint position_stride;
	uint normal_byte_offset;
	uint normal_stride;
	uint tangent_byte_offset;
	uint tangent_stride;

	uint attribute_stride;
	uint uv_byte_offset;

	float uv_scale_x;
	float uv_scale_y;

	uint index_format;
	uint primitive_count;
	uint flags;

	float aabb_size_x;
	float aabb_size_y;
	float aabb_size_z;

	// Byte offset of the vertex color attribute inside `attribute_stride`,
	// or OFFSET_NONE if the mesh has no vertex colors.
	uint color_byte_offset;

	uint _pad[9];
};

// ============================================================================
// PER-INSTANCE MOTION DATA (matches C++ RT_InstanceMotionData, 48 bytes)
// ============================================================================
struct InstanceMotionData {
	float prev_xform[12]; // Previous object-to-world (mat3x4, transposed 3x4)
};

// ============================================================================
// MATERIAL DATA (matches C++ layout, 96 bytes)
// ============================================================================
struct MaterialData {
	uint albedo_texture_idx;
	uint normal_texture_idx;
	uint orm_texture_idx;
	uint emission_texture_idx;

	vec4 albedo_color;
	vec3 emission_color;
	float emission_strength;

	float metallic;
	float roughness;
	float ao_strength;
	uint flags; // Bit 0: has_normal_map, Bit 1: has_emission

	vec2 uv1_scale; // UV1 scale (default 1,1)
	vec2 uv1_offset; // UV1 offset (default 0,0)

	float normal_map_depth; // Normal map strength (default 1.0)
	float _pad0;
	uint64_t uniform_address; // BDA for custom shader uniform buffer (0 = none)
};
