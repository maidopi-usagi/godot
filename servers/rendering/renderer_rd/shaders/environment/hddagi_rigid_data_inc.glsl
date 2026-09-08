#ifndef HDDAGI_RIGID_DATA_INC_GLSL
#define HDDAGI_RIGID_DATA_INC_GLSL

#ifndef HDDAGI_RIGID_SET
#define HDDAGI_RIGID_SET 0
#endif

// Geometry/material addresses are shared by compatible assets. Lighting addresses
// belong to an instance and remain in local space when its transform changes.
struct HDDAGIRigidInstance {
	mat4 world_to_cell;
	mat4 cell_to_world;
	uvec4 grid;
	uvec4 offsets;
	vec4 bounds_min;
	vec4 bounds_max;
};

struct HDDAGIRigidBVHNode {
	vec3 bounds_min;
	uint instance;
	vec3 bounds_max;
	uint escape;
};

layout(set = HDDAGI_RIGID_SET, binding = 40, std430) restrict readonly buffer HDDAGIRigidInstances {
	uvec4 header; // Instance count, BVH node count, revision, change flags (pending: 1, this frame: 2).
	vec4 dirty_min;
	vec4 dirty_max;
	HDDAGIRigidInstance data[];
}
hddagi_rigid_instances;

layout(set = HDDAGI_RIGID_SET, binding = 41, std430) restrict readonly buffer HDDAGIRigidGeometry {
	uint data[];
}
hddagi_rigid_geometry;

layout(set = HDDAGI_RIGID_SET, binding = 42, std430) restrict readonly buffer HDDAGIRigidSurfaces {
	uvec4 data[]; // Albedo/normal, intrinsic emission, neighbours/valid, disocclusion.
}
hddagi_rigid_surfaces;

#ifdef HDDAGI_RIGID_LIGHTING_WRITABLE
layout(set = HDDAGI_RIGID_SET, binding = 43, std430) restrict buffer HDDAGIRigidLighting {
#else
layout(set = HDDAGI_RIGID_SET, binding = 43, std430) restrict readonly buffer HDDAGIRigidLighting {
#endif
	uint data[];
}
hddagi_rigid_lighting;

layout(set = HDDAGI_RIGID_SET, binding = 44, std430) restrict readonly buffer HDDAGIRigidBVH {
	HDDAGIRigidBVHNode data[];
}
hddagi_rigid_bvh;

#endif // HDDAGI_RIGID_DATA_INC_GLSL
