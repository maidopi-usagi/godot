// Shared air-side surface construction for the static field and object-local captures.
// The caller supplies get_normal_facing() over a one-cell halo, source textures,
// and the existing RGB9E5 and octahedral helpers.
bool hddagi_build_surface(ivec3 pos, ivec3 local, out vec4 albedo_accum, out vec4 emission_accum, out vec3 normal_accum, out uint neighbour_voxels, out uint disocclusion) {
	albedo_accum = vec4(0.0);
	emission_accum = vec4(0.0);
	normal_accum = vec3(0.0);
	neighbour_voxels = 0u;
	disocclusion = 0u;
	uint solid = get_normal_facing(local);
	bool voxels_found = false;
	//opposite to aniso dir
	const ivec3 offsets[6] = ivec3[](
			ivec3(1, 0, 0),
			ivec3(-1, 0, 0),
			ivec3(0, 1, 0),
			ivec3(0, -1, 0),
			ivec3(0, 0, 1),
			ivec3(0, 0, -1));

	const vec3 aniso_dir[6] = vec3[](
			vec3(-1, 0, 0),
			vec3(1, 0, 0),
			vec3(0, -1, 0),
			vec3(0, 1, 0),
			vec3(0, 0, -1),
			vec3(0, 0, 1));

	// aniso dir in bitform
	const uint aniso_mask[6] = uint[](
			(1 << 0),
			(1 << 1),
			(1 << 2),
			(1 << 3),
			(1 << 4),
			(1 << 5));

	const uint aniso_offset_mask[6] = uint[](
			(1 << 1),
			(1 << 0),
			(1 << 3),
			(1 << 2),
			(1 << 5),
			(1 << 4));

	const int facing_direction_count = 26;
	const vec3 facing_directions[26] = vec3[](vec3(-1.0, 0.0, 0.0), vec3(1.0, 0.0, 0.0), vec3(0.0, -1.0, 0.0), vec3(0.0, 1.0, 0.0), vec3(0.0, 0.0, -1.0), vec3(0.0, 0.0, 1.0), vec3(-0.5773502691896258, -0.5773502691896258, -0.5773502691896258), vec3(-0.7071067811865475, -0.7071067811865475, 0.0), vec3(-0.5773502691896258, -0.5773502691896258, 0.5773502691896258), vec3(-0.7071067811865475, 0.0, -0.7071067811865475), vec3(-0.7071067811865475, 0.0, 0.7071067811865475), vec3(-0.5773502691896258, 0.5773502691896258, -0.5773502691896258), vec3(-0.7071067811865475, 0.7071067811865475, 0.0), vec3(-0.5773502691896258, 0.5773502691896258, 0.5773502691896258), vec3(0.0, -0.7071067811865475, -0.7071067811865475), vec3(0.0, -0.7071067811865475, 0.7071067811865475), vec3(0.0, 0.7071067811865475, -0.7071067811865475), vec3(0.0, 0.7071067811865475, 0.7071067811865475), vec3(0.5773502691896258, -0.5773502691896258, -0.5773502691896258), vec3(0.7071067811865475, -0.7071067811865475, 0.0), vec3(0.5773502691896258, -0.5773502691896258, 0.5773502691896258), vec3(0.7071067811865475, 0.0, -0.7071067811865475), vec3(0.7071067811865475, 0.0, 0.7071067811865475), vec3(0.5773502691896258, 0.5773502691896258, -0.5773502691896258), vec3(0.7071067811865475, 0.7071067811865475, 0.0), vec3(0.5773502691896258, 0.5773502691896258, 0.5773502691896258));

	bool use_for_filter = false;

	for (int i = 0; i < 6; i++) {
		uint n = get_normal_facing(local + offsets[i]);
		if (n == 0) {
			disocclusion |= aniso_offset_mask[i];
		} else if (solid == 0) {
			use_for_filter = true;
		}

		if (solid != 0 || !bool(n & aniso_mask[i])) {
			// Not solid, continue.
			continue;
		}

		voxels_found = true;

		for (int j = 0; j < facing_direction_count; j++) {
			if (bool(n & uint((1 << (j + 6))))) {
				normal_accum += facing_directions[j];
			}
		}

		ivec3 ofs = pos + offsets[i];
		//normal_accum += aniso_dir[i];

		ivec3 albedo_ofs = ofs >> 1;
		albedo_ofs.z *= 6;
		albedo_ofs.z += i;

		uint a = imageLoad(src_albedo, albedo_ofs).r;
		albedo_accum += vec4(vec3((ivec3(a) >> ivec3(0, 5, 11)) & ivec3(0x1f, 0x3f, 0x1f)) / vec3(31.0, 63.0, 31.0), 1.0);

		uint rgbe = imageLoad(src_emission, ofs >> 1).r;

		vec3 emission = rgbe_decode(rgbe);

		uint rgbe_aniso = imageLoad(src_emission_aniso, ofs >> 1).r;
		float strength = ((rgbe_aniso >> (i * 5)) & 0x1F) / float(0x1F);
		emission_accum += vec4(emission * strength, 1.0);
	}

	if (solid == 0u && use_for_filter) {
		for (int i = 0; i < facing_direction_count; i++) {
			ivec3 neighbor = ivec3(sign(facing_directions[i]));
			ivec3 neighbour_pos = local + neighbor;
			uint n = get_normal_facing(neighbour_pos);
			if (n == 0) {
				continue; // Nothing here
			}

			for (int j = 0; j < 6; j++) {
				//if (!bool(n&(1<<j))) {
				//	continue; // Nothing here either.
				//}
				ivec3 neighbour_neighbour = neighbour_pos + ivec3(aniso_dir[j]);
				ivec3 nn_rel = neighbour_neighbour - local;

				if (any(lessThan(nn_rel, -ivec3(1))) || any(greaterThan(nn_rel, +ivec3(1)))) {
					continue; // Too far away, ignore.
				}

				if (nn_rel == ivec3(0)) {
					continue; // Point to itself, ignore.
				}

				uint q = get_normal_facing(local + nn_rel);
				if (q != 0) {
					continue; // Points to a solid block (can happen), Ignore.
				}

				ivec3 nn_rel_abs = abs(nn_rel);

				int nn_steps = nn_rel_abs.x + nn_rel_abs.y + nn_rel_abs.z;
				if (nn_steps == 3) {
					continue;
				}
				if (nn_steps > 1) {
					// must make sure we are not occluded towards this
					ivec3 test_dirs[3] = ivec3[](ivec3(nn_rel.x, 0, 0), ivec3(0, nn_rel.y, 0), ivec3(0, 0, nn_rel.z));
					int occlusions = 0;
					for (int k = 0; k < 3; k++) {
						if (test_dirs[k] == ivec3(0)) {
							continue; // Direction not used
						}

						q = get_normal_facing(local + test_dirs[k]);
						if (q != 0) {
							occlusions++;
						}
					}

					if (occlusions >= 2) {
						continue; // Occluded from here, ignore. May be unoccluded from another neighbor.
					}
				}

				const uint reverse_map[27] = uint[](6, 14, 18, 9, 4, 21, 11, 16, 23, 7, 2, 19, 0, 0, 1, 12, 3, 24, 8, 15, 20, 10, 5, 22, 13, 17, 25);
				ivec3 abs_pos = nn_rel + ivec3(1);
				// All good, this is a valid neighbor!
				neighbour_voxels |= 1 << reverse_map[abs_pos.z * 3 * 3 + abs_pos.y * 3 + abs_pos.x];
			}
		}
	}

	return voxels_found && solid == 0u;
}

uint hddagi_pack_surface_albedo(vec4 albedo_accum, vec3 normal_accum) {
	albedo_accum.rgb /= albedo_accum.a;
	normal_accum = normalize(normal_accum);
	uint albedo_norm = 0u;
	albedo_norm |= clamp(uint(albedo_accum.r * 31.0), 0u, 31u) << 0;
	albedo_norm |= clamp(uint(albedo_accum.g * 63.0), 0u, 63u) << 5;
	albedo_norm |= clamp(uint(albedo_accum.b * 31.0), 0u, 31u) << 11;
	uvec2 octa_unormal = clamp(uvec2(octahedron_encode(normal_accum) * 255.0), uvec2(0), uvec2(255));
	return albedo_norm | (octa_unormal.x << 16) | (octa_unormal.y << 24);
}
