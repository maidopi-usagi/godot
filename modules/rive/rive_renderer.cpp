#include "register_types.h"

#include "servers/rendering/rendering_device.h"
#include "rive_render_registry.h"

#if defined(VULKAN_ENABLED)
#include <vulkan/vulkan.h>
#endif

#if defined(D3D12_ENABLED) || defined(RIVE_D3D12)
#include <d3d12.h>
#endif

#if __has_include(<rive/renderer.hpp>) || __has_include("rive/renderer.hpp")
#include <rive/renderer.hpp>
#endif

namespace rive_integration {

bool is_rive_available() {
#if __has_include(<rive/renderer.hpp>) || __has_include("rive/renderer.hpp")
	// If metal bridge exists, prefer checking runtime context.
#if defined(__APPLE__)
	extern bool has_context();
	return has_context();
#else
	return true;
#endif
#else
	return false;
#endif
}

void draw_rive_to_canvas(void * /*canvas*/) {
	// noop for now
}

} // namespace rive_integration

namespace rive_integration {

#if defined(VULKAN_ENABLED)
bool create_vulkan_context(VkInstance instance, VkPhysicalDevice physical_device, VkDevice device, const VkPhysicalDeviceFeatures &features, PFN_vkGetInstanceProcAddr get_instance_proc_addr) {
    extern bool create_vulkan_context_impl(VkInstance, VkPhysicalDevice, VkDevice, const VkPhysicalDeviceFeatures &, PFN_vkGetInstanceProcAddr);
    return create_vulkan_context_impl(instance, physical_device, device, features, get_instance_proc_addr);
}

extern void render_texture_vulkan(RenderingDevice *rd, RID texture_rid, RiveDrawable *drawable, uint32_t width, uint32_t height);
#endif

#if defined(D3D12_ENABLED) || defined(RIVE_D3D12)
bool create_d3d12_context(ID3D12Device *device, ID3D12GraphicsCommandList *command_list, bool is_intel) {
    extern bool create_d3d12_context_impl(ID3D12Device *, ID3D12GraphicsCommandList *, bool);
    return create_d3d12_context_impl(device, command_list, is_intel);
}

extern void render_texture_d3d12(RenderingDevice *rd, RID texture_rid, RiveDrawable *drawable, uint32_t width, uint32_t height);
#endif

bool create_metal_context_from_device(void *device_ptr) {
#if defined(__APPLE__)
	extern bool create_metal_context(void *);
	return create_metal_context(device_ptr);
#else
	(void)device_ptr;
	return false;
#endif
}

// Backwards-compatible API: old callers (no texture, no frame counters).
void flush_frame_with_metal_command_buffer(void *cmd_buffer_ptr, uint32_t w, uint32_t h) {
#if defined(__APPLE__)
	extern void flush_with_command_buffer(void *, void *, uint64_t, uint64_t, uint32_t, uint32_t, void*);
	// Default frame values (1/0) for legacy callers.
	flush_with_command_buffer(cmd_buffer_ptr, nullptr, 1, 0, w, h, nullptr);
#else
	(void)cmd_buffer_ptr; (void)w; (void)h;
#endif
}

// New API that accepts both command buffer, texture pointers and frame counters.
void flush_frame_with_metal_command_buffer(void *cmd_buffer_ptr, void *texture_ptr, uint64_t current_frame, uint64_t safe_frame, uint32_t w, uint32_t h, void* layer_ptr) {
#if defined(__APPLE__)
	extern void flush_with_command_buffer(void *, void *, uint64_t, uint64_t, uint32_t, uint32_t, void*);
	flush_with_command_buffer(cmd_buffer_ptr, texture_ptr, current_frame, safe_frame, w, h, layer_ptr);
#else
	(void)cmd_buffer_ptr; (void)texture_ptr; (void)current_frame; (void)safe_frame; (void)w; (void)h; (void)layer_ptr;
#endif
}

#if defined(__APPLE__)
extern void render_texture_metal(RenderingDevice *rd, RID texture_rid, RiveDrawable *drawable, uint32_t width, uint32_t height);
#endif

void render_texture(RenderingDevice *rd, RID texture_rid, RiveDrawable *drawable, uint32_t width, uint32_t height) {
    if (!rd) return;
    String api = rd->get_device_api_name();
    
#if defined(VULKAN_ENABLED)
    if (api == "Vulkan") {
        render_texture_vulkan(rd, texture_rid, drawable, width, height);
        return;
    }
#endif

#if defined(D3D12_ENABLED) || defined(RIVE_D3D12)
    if (api == "D3D12") {
        render_texture_d3d12(rd, texture_rid, drawable, width, height);
        return;
    }
#endif

#if defined(__APPLE__)
    // Metal is the only option on Apple for now in this context
    render_texture_metal(rd, texture_rid, drawable, width, height);
#endif
}

} // namespace rive_integration
