/**************************************************************************/
/*  sharc_context_rd.cpp                                                  */
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

#include "sharc_context_rd.h"

#ifdef NVIDIA_SHARC_ENABLED
namespace {

SharcContextRD::BufferResource create_device_address_buffer(RenderingDevice *p_rd, uint32_t p_size_bytes, const char *p_debug_name) {
	SharcContextRD::BufferResource resource;
	resource.rid = p_rd->storage_buffer_create(p_size_bytes, {}, 0, RenderingDevice::BUFFER_CREATION_DEVICE_ADDRESS_BIT);
	if (!resource.rid.is_valid()) {
		return resource;
	}

	p_rd->set_resource_name(resource.rid, p_debug_name);
	resource.device_address = p_rd->buffer_get_device_address(resource.rid);
	resource.size_bytes = p_size_bytes;
	return resource;
}

} // namespace
#endif // NVIDIA_SHARC_ENABLED

bool SharcContextRD::is_compiled() {
#ifdef NVIDIA_SHARC_ENABLED
	return true;
#else
	return false;
#endif
}

bool SharcContextRD::is_supported() {
#ifdef NVIDIA_SHARC_ENABLED
	RenderingDevice *rd = RenderingDevice::get_singleton();
	if (rd == nullptr) {
		return false;
	}

	// The GLSL buffer-reference path is currently integrated and validated only
	// on Vulkan. Require native buffer int64 atomics: SHARC's bounded lock
	// fallback can leave its compare-exchange output undefined under contention.
	return rd->get_device_capabilities().device_family == RDD::DEVICE_VULKAN &&
			rd->has_feature(RenderingDevice::SUPPORTS_BUFFER_DEVICE_ADDRESS) &&
			rd->has_feature(RenderingDevice::SUPPORTS_SHADER_INT64) &&
			rd->has_feature(RenderingDevice::SUPPORTS_BUFFER_INT64_ATOMICS) &&
			rd->has_feature(RenderingDevice::SUPPORTS_HALF_FLOAT);
#else
	return false;
#endif
}

Error SharcContextRD::configure(uint32_t p_entry_count) {
#ifndef NVIDIA_SHARC_ENABLED
	(void)p_entry_count;
	return ERR_UNAVAILABLE;
#else
	ERR_FAIL_COND_V_MSG(!is_supported(), ERR_UNAVAILABLE, "SHARC requires the Vulkan RenderingDevice backend, shader/buffer-atomic int64, buffer device addresses and native half-float storage.");
	ERR_FAIL_COND_V_MSG(p_entry_count < MINIMUM_ENTRY_COUNT || (p_entry_count & (p_entry_count - 1u)) != 0, ERR_INVALID_PARAMETER, "SHARC cache entry count must be a power of two and at least 16.");
	ERR_FAIL_COND_V_MSG(p_entry_count > UINT32_MAX / ACCUMULATION_BYTES_PER_ENTRY, ERR_INVALID_PARAMETER, "SHARC cache buffers exceed RenderingDevice's 32-bit buffer size limit.");

	if (resources.is_valid() && resources.entry_count == p_entry_count) {
		return OK;
	}

	_release_resources();

	RenderingDevice *rd = RenderingDevice::get_singleton();
	resources.entry_count = p_entry_count;
	resources.hash = create_device_address_buffer(rd, p_entry_count * HASH_BYTES_PER_ENTRY, "SHARC Hash Entries");
	resources.accumulation = create_device_address_buffer(rd, p_entry_count * ACCUMULATION_BYTES_PER_ENTRY, "SHARC Accumulation");
	resources.resolved = create_device_address_buffer(rd, p_entry_count * RESOLVED_BYTES_PER_ENTRY, "SHARC Resolved");

	if (!resources.is_valid()) {
		_release_resources();
		ERR_FAIL_V_MSG(ERR_CANT_CREATE, "Failed to create SHARC cache device-address buffers.");
	}

	const Error clear_error = _clear_resources();
	if (clear_error != OK) {
		_release_resources();
		return clear_error;
	}

	_reset_temporal_state();
	return OK;
#endif
}

Error SharcContextRD::reset() {
#ifndef NVIDIA_SHARC_ENABLED
	return ERR_UNAVAILABLE;
#else
	ERR_FAIL_COND_V_MSG(!resources.is_valid(), ERR_UNCONFIGURED, "SHARC cache resources have not been configured.");

	const Error clear_error = _clear_resources();
	if (clear_error != OK) {
		return clear_error;
	}

	_reset_temporal_state();
	return OK;
#endif
}

Error SharcContextRD::begin_frame(const Vector3 &p_camera_position, bool p_camera_cut) {
#ifndef NVIDIA_SHARC_ENABLED
	(void)p_camera_position;
	(void)p_camera_cut;
	return ERR_UNAVAILABLE;
#else
	ERR_FAIL_COND_V_MSG(!is_available(), ERR_UNCONFIGURED, "SHARC cache resources have not been configured or are no longer supported.");

	if (p_camera_cut) {
		const Error reset_error = reset();
		if (reset_error != OK) {
			return reset_error;
		}
	}

	if (!camera_history_valid) {
		camera_position = p_camera_position;
		previous_camera_position = p_camera_position;
		frame_index = 0;
		camera_history_valid = true;
		return OK;
	}

	previous_camera_position = camera_position;
	camera_position = p_camera_position;
	frame_index++;
	return OK;
#endif
}

void SharcContextRD::clear() {
	_release_resources();
}

bool SharcContextRD::is_available() const {
	return is_supported() && resources.is_valid();
}

void SharcContextRD::_release_resources() {
	RenderingDevice *rd = RenderingDevice::get_singleton();
	if (rd != nullptr) {
		if (resources.hash.rid.is_valid()) {
			rd->free_rid(resources.hash.rid);
		}
		if (resources.accumulation.rid.is_valid()) {
			rd->free_rid(resources.accumulation.rid);
		}
		if (resources.resolved.rid.is_valid()) {
			rd->free_rid(resources.resolved.rid);
		}
	}

	resources = Resources();
	_reset_temporal_state();
}

void SharcContextRD::_reset_temporal_state() {
	camera_position = Vector3();
	previous_camera_position = Vector3();
	frame_index = 0;
	camera_history_valid = false;
}

Error SharcContextRD::_clear_resources() {
	RenderingDevice *rd = RenderingDevice::get_singleton();
	ERR_FAIL_NULL_V(rd, ERR_UNAVAILABLE);

	Error first_error = OK;
	const auto clear_buffer = [rd, &first_error](const BufferResource &p_resource) {
		const Error error = rd->buffer_clear(p_resource.rid, 0, p_resource.size_bytes);
		if (first_error == OK && error != OK) {
			first_error = error;
		}
	};

	clear_buffer(resources.hash);
	clear_buffer(resources.accumulation);
	clear_buffer(resources.resolved);
	return first_error;
}

SharcContextRD::~SharcContextRD() {
	_release_resources();
}
