#[compute]

#version 450

#VERSION_DEFINES

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// Hash Table Buffers
layout(set = 0, binding = 0, std430) restrict buffer HashKeys {
	uint data[];
} hash_keys;

layout(set = 0, binding = 1, std430) restrict buffer HashCounters {
	uint data[];
} hash_counters;

layout(set = 0, binding = 2, std430) restrict buffer HashPayload {
	uvec2 data[];
} hash_payload;

layout(set = 0, binding = 3, std430) restrict buffer HashRadiance {
	uvec4 data[];
} hash_radiance;

layout(set = 0, binding = 4, std430) restrict buffer HashPositions {
	uvec4 data[];
} hash_positions;

layout(push_constant, std430) uniform Params {
	uint table_size;
	uint update_offset;
	uint update_fraction;
	float decay_rate;
	
	vec3 grid_origin;
	float cell_size;
	
	uint frame_count;
	uint max_ray_count;
} params;

// MurmurHash3
uint hash_uint(uint k) {
	k ^= k >> 16;
	k *= 0x85ebca6b;
	k ^= k >> 13;
	k *= 0xc2b2ae35;
	k ^= k >> 16;
	return k;
}

uint compute_hash_key(vec3 position, vec3 normal) {
	// Quantize position
	ivec3 grid_pos = ivec3(floor((position - params.grid_origin) / params.cell_size));
	
	// Quantize normal (octahedral encoding or simple quantization)
	// Simple quantization for now
	ivec3 norm_int = ivec3(normal * 127.0 + 128.0);
	
	uint h = hash_uint(uint(grid_pos.x));
	h = hash_uint(h ^ uint(grid_pos.y));
	h = hash_uint(h ^ uint(grid_pos.z));
	h = hash_uint(h ^ uint(norm_int.x));
	h = hash_uint(h ^ uint(norm_int.y));
	h = hash_uint(h ^ uint(norm_int.z));
	
	return h;
}

// Linear probing
uint find_entry(uint key) {
	uint slot = key % params.table_size;
	
	for (uint i = 0; i < 64; i++) { // Max probe depth
		uint stored_key = hash_keys.data[slot];
		
		if (stored_key == key) {
			return slot; // Found
		}
		
		if (stored_key == 0) {
			return 0xFFFFFFFF; // Not found (empty slot)
		}
		
		slot = (slot + 1) % params.table_size;
	}
	
	return 0xFFFFFFFF; // Not found (table full or collision limit)
}

uint insert_entry(uint key) {
	uint slot = key % params.table_size;
	
	for (uint i = 0; i < 64; i++) {
		uint expected = 0;
		// Try to claim empty slot
		uint prev = atomicCompSwap(hash_keys.data[slot], expected, key);
		
		if (prev == 0 || prev == key) {
			return slot; // Success or already exists
		}
		
		slot = (slot + 1) % params.table_size;
	}
	
	return 0xFFFFFFFF; // Failed to insert
}

#ifdef MODE_UPDATE_CACHE
// Update cache entries (decay, recycle)
void main() {
	uint index = gl_GlobalInvocationID.x;
	
	// Process a fraction of the table each frame
	uint stride = params.table_size / params.update_fraction;
	uint start = params.update_offset * stride;
	uint end = start + stride;
	
	if (index >= stride) return;
	
	uint slot = start + index;
	if (slot >= params.table_size) return;
	
	uint key = hash_keys.data[slot];
	if (key == 0) return;
	
	uint counter = hash_counters.data[slot];
	
	// Decay
	if (counter > 0) {
		counter--;
		hash_counters.data[slot] = counter;
	} else {
		// Recycle
		hash_keys.data[slot] = 0;
		hash_payload.data[slot] = uvec2(0);
		hash_radiance.data[slot] = uvec4(0);
	}
}
#endif

#ifdef MODE_QUERY_INSERT
// This mode is called from other shaders (via include) or separate dispatch
// For now, just a placeholder for the logic
void main() {
	// ...
}
#endif
