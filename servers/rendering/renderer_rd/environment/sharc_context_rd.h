/**************************************************************************/
/*  sharc_context_rd.h                                                    */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#ifndef SHARC_CONTEXT_RD_H
#define SHARC_CONTEXT_RD_H

#include "core/math/vector3.h"
#include "servers/rendering/rendering_device.h"

// Owns one SHARC cache for one render-buffer/HDDAGI context. The public API
// intentionally contains no NVIDIA SDK types. Shader compilation, bindings,
// barriers, Update/Resolve/Query dispatches and draw-graph dependency aliases
// remain the caller's responsibility.
//
// NVIDIA_SHARC_ENABLED is deliberately opt-in. The currently validated shader
// path uses Vulkan buffer device addresses and native float16 storage.
class SharcContextRD {
public:
	static constexpr uint32_t DEFAULT_ENTRY_COUNT = 1u << 21;
	static constexpr uint32_t MINIMUM_ENTRY_COUNT = 16u;
	static constexpr uint32_t HASH_BYTES_PER_ENTRY = 8u;
	static constexpr uint32_t ACCUMULATION_BYTES_PER_ENTRY = 16u;
	static constexpr uint32_t RESOLVED_BYTES_PER_ENTRY = 16u;
	static constexpr uint32_t TOTAL_BYTES_PER_ENTRY = HASH_BYTES_PER_ENTRY + ACCUMULATION_BYTES_PER_ENTRY + RESOLVED_BYTES_PER_ENTRY;
	static constexpr bool USES_LOCK_FALLBACK = false;

	struct BufferResource {
		RID rid;
		uint64_t device_address = 0;
		uint32_t size_bytes = 0;

		bool is_valid() const {
			return rid.is_valid() && device_address != 0 && size_bytes != 0;
		}
	};

	struct Resources {
		BufferResource hash;
		BufferResource accumulation;
		BufferResource resolved;
		uint32_t entry_count = 0;

		bool is_valid() const {
			return entry_count != 0 && hash.is_valid() && accumulation.is_valid() && resolved.is_valid();
		}

		uint64_t get_total_size_bytes() const {
			return uint64_t(hash.size_bytes) + uint64_t(accumulation.size_bytes) + uint64_t(resolved.size_bytes);
		}
	};

	static bool is_compiled();
	static bool is_supported();

	// Creates or resizes all three device-address storage buffers. A new cache is
	// cleared before use. Reconfiguring an already valid cache to the same size
	// preserves its contents.
	Error configure(uint32_t p_entry_count = DEFAULT_ENTRY_COUNT);

	// Clears every cache buffer and discards camera/frame history.
	Error reset();

	// Call exactly once before recording a SHARC frame (not once per view).
	// A camera cut performs reset() first and starts the new frame at index zero.
	Error begin_frame(const Vector3 &p_camera_position, bool p_camera_cut = false);

	void clear();

	bool is_available() const;
	bool has_camera_history() const { return camera_history_valid; }
	uint32_t get_frame_index() const { return frame_index; }
	const Vector3 &get_camera_position() const { return camera_position; }
	const Vector3 &get_previous_camera_position() const { return previous_camera_position; }
	const Resources &get_resources() const { return resources; }

	SharcContextRD() = default;
	~SharcContextRD();

	SharcContextRD(const SharcContextRD &) = delete;
	SharcContextRD &operator=(const SharcContextRD &) = delete;

private:
	Resources resources;
	Vector3 camera_position;
	Vector3 previous_camera_position;
	uint32_t frame_index = 0;
	bool camera_history_valid = false;

	void _release_resources();
	void _reset_temporal_state();
	Error _clear_resources();
};

#endif // SHARC_CONTEXT_RD_H
