// ...existing code...
//#define RIVE_VULKAN
//#define VK_NO_PROTOTYPES
#include "rive/renderer/vulkan/render_context_vulkan_impl.hpp"
// ...existing code...

#include "rive/renderer/vulkan/render_target_vulkan.hpp"
#include "rive/renderer/render_context.hpp"
#include "rive/renderer/rive_renderer.hpp"
#include "rive_render_registry.h"

#include "servers/rendering/rendering_device.h"
#include "drivers/vulkan/rendering_device_driver_vulkan.h"
#include "core/os/os.h"
#include "core/templates/local_vector.h"

using namespace rive;
using namespace rive::gpu;

namespace rive_integration {

static rive::gpu::RenderContext *g_rive_context = nullptr;

#if defined(VULKAN_ENABLED) && defined(RIVE_UPSTREAM_VULKAN_IMPL)
// Use the upstream Rive Vulkan implementation when available.
bool create_vulkan_context_impl(VkInstance instance, VkPhysicalDevice physical_device, VkDevice device, const VkPhysicalDeviceFeatures &features, PFN_vkGetInstanceProcAddr get_instance_proc_addr) {
	if (!instance || !physical_device || !device) {
		return false;
	}

	rive::gpu::RenderContextVulkanImpl::ContextOptions options;

	rive::gpu::VulkanFeatures vulkan_features;
	vulkan_features.independentBlend = features.independentBlend;
	vulkan_features.fillModeNonSolid = features.fillModeNonSolid;
	vulkan_features.fragmentStoresAndAtomics = features.fragmentStoresAndAtomics;
	vulkan_features.shaderClipDistance = features.shaderClipDistance;

	std::unique_ptr<rive::gpu::RenderContext> ctx = rive::gpu::RenderContextVulkanImpl::MakeContext(
			instance,
			physical_device,
			device,
			vulkan_features,
			get_instance_proc_addr,
			options);

	if (!ctx) {
		return false;
	}

	g_rive_context = ctx.release();
	RiveRenderRegistry::get_singleton()->set_factory(g_rive_context);

#if defined(DEBUG_ENABLED)
	if (OS::get_singleton()->is_stdout_verbose()) {
		print_line("RIVE: create_vulkan_context succeeded");
	}
#endif

	return true;
}

void flush_with_vulkan_command_buffer(void *cmd_buffer_ptr, void *image_ptr, void *image_view_ptr, uint64_t current_frame, uint64_t safe_frame, uint32_t width, uint32_t height, VkFormat format) {
	if (!g_rive_context) {
		return;
	}

	VkCommandBuffer cmd_buffer = (VkCommandBuffer)cmd_buffer_ptr;
	VkImage image = (VkImage)image_ptr;
	VkImageView image_view = (VkImageView)image_view_ptr;

	if (!cmd_buffer || !image || !image_view) {
		return;
	}

	rive::gpu::RenderContext::FrameDescriptor fd;
	fd.renderTargetWidth = width;
	fd.renderTargetHeight = height;
	fd.loadAction = rive::gpu::LoadAction::preserveRenderTarget;

	g_rive_context->beginFrame(fd);

	rive::gpu::RenderContextVulkanImpl *impl = g_rive_context->static_impl_cast<rive::gpu::RenderContextVulkanImpl>();

	VkImageUsageFlags usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;

	rive::rcp<rive::gpu::RenderTargetVulkan> rtarget = impl->makeRenderTarget(width, height, format, usage);

	if (rtarget) {
		rive::gpu::vkutil::ImageAccess access;
		access.layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
		access.accessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
		access.pipelineStages = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;

		static_cast<rive::gpu::RenderTargetVulkanImpl *>(rtarget.get())->setTargetImageView(image_view, image, access);

		rive::gpu::RenderContext::FlushResources fr;
		fr.renderTarget = rtarget.get();
		fr.externalCommandBuffer = cmd_buffer_ptr;
		fr.currentFrameNumber = current_frame;
		fr.safeFrameNumber = safe_frame;

		{
			rive::RiveRenderer renderer(g_rive_context);
			RiveRenderRegistry::get_singleton()->draw_all(&renderer);
		}

		g_rive_context->flush(fr);
	}
}
#else
// Fallback stubs when upstream implementation is not available.
bool create_vulkan_context_impl(VkInstance, VkPhysicalDevice, VkDevice, const VkPhysicalDeviceFeatures &, PFN_vkGetInstanceProcAddr) {
	return false;
}

void flush_with_vulkan_command_buffer(void *, void *, void *, uint64_t, uint64_t, uint32_t, uint32_t, VkFormat) {
	// no-op
}
#endif

void render_texture_vulkan(RenderingDevice *rd, RID texture_rid, RiveDrawable *drawable, uint32_t width, uint32_t height) {
	if (!g_rive_context) {
		return;
	}
	if (!rd || !drawable) {
		return;
	}

	if (rd->get_device_api_name() != "Vulkan") {
		return;
	}

	VkDevice device = (VkDevice)rd->get_driver_resource(RD::DRIVER_RESOURCE_LOGICAL_DEVICE, RID());
	VkPhysicalDevice physical_device = (VkPhysicalDevice)rd->get_driver_resource(RD::DRIVER_RESOURCE_PHYSICAL_DEVICE, RID());

	if (!device || !physical_device) {
		return;
	}

	// Find graphics queue family
	uint32_t queue_family_count = 0;
	vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, nullptr);
	LocalVector<VkQueueFamilyProperties> queue_families;
	queue_families.resize(queue_family_count);
	vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, queue_families.ptr());

	uint32_t graphics_queue_family_index = UINT32_MAX;
	for (uint32_t i = 0; i < queue_family_count; i++) {
		if (queue_families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
			graphics_queue_family_index = i;
			break;
		}
	}

	if (graphics_queue_family_index == UINT32_MAX) {
		return;
	}

	VkQueue queue = VK_NULL_HANDLE;
	vkGetDeviceQueue(device, graphics_queue_family_index, 0, &queue);

	if (!queue) {
		return;
	}

	// Create command pool if not exists (we should probably cache this)
	VkCommandPoolCreateInfo pool_info = {};
	pool_info.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
	pool_info.queueFamilyIndex = graphics_queue_family_index;
	pool_info.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;

	VkCommandPool command_pool;
	if (vkCreateCommandPool(device, &pool_info, nullptr, &command_pool) != VK_SUCCESS) {
		return;
	}

	VkCommandBufferAllocateInfo alloc_info = {};
	alloc_info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
	alloc_info.commandPool = command_pool;
	alloc_info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
	alloc_info.commandBufferCount = 1;

	VkCommandBuffer command_buffer;
	if (vkAllocateCommandBuffers(device, &alloc_info, &command_buffer) != VK_SUCCESS) {
		vkDestroyCommandPool(device, command_pool, nullptr);
		return;
	}

	VkCommandBufferBeginInfo begin_info = {};
	begin_info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
	begin_info.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;

	if (vkBeginCommandBuffer(command_buffer, &begin_info) != VK_SUCCESS) {
		vkDestroyCommandPool(device, command_pool, nullptr);
		return;
	}

	// Get Image info
	VkImage image = (VkImage)rd->get_driver_resource(RD::DRIVER_RESOURCE_TEXTURE, texture_rid);
	VkImageView image_view = (VkImageView)rd->get_driver_resource(RD::DRIVER_RESOURCE_TEXTURE_VIEW, texture_rid);
	VkFormat format = (VkFormat)rd->get_driver_resource(RD::DRIVER_RESOURCE_TEXTURE_DATA_FORMAT, texture_rid);

	if (image && image_view) {
		rive::gpu::RenderContext::FrameDescriptor fd;
		fd.renderTargetWidth = width;
		fd.renderTargetHeight = height;
		fd.loadAction = rive::gpu::LoadAction::clear;
		fd.clearColor = 0x00000000;

		g_rive_context->beginFrame(fd);

		rive::gpu::RenderContextVulkanImpl *impl = g_rive_context->static_impl_cast<rive::gpu::RenderContextVulkanImpl>();
		VkImageUsageFlags usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
		rive::rcp<rive::gpu::RenderTargetVulkan> rtarget = impl->makeRenderTarget(width, height, format, usage);

		if (rtarget) {
			// For render_texture, we assume we can overwrite, but we need to know current state.
			// Godot textures are usually SHADER_READ_ONLY_OPTIMAL.
			rive::gpu::vkutil::ImageAccess access;
			access.layout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
			access.accessMask = VK_ACCESS_SHADER_READ_BIT;
			access.pipelineStages = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;

			static_cast<rive::gpu::RenderTargetVulkanImpl *>(rtarget.get())->setTargetImageView(image_view, image, access);

			{
				rive::RiveRenderer renderer(g_rive_context);
				drawable->draw(&renderer);
			}

			static uint64_t frame_idx = 0;
			frame_idx++;

			rive::gpu::RenderContext::FlushResources fr;
			fr.renderTarget = rtarget.get();
			fr.externalCommandBuffer = command_buffer;
			fr.currentFrameNumber = frame_idx;
			fr.safeFrameNumber = (frame_idx > 2) ? frame_idx - 2 : 0;

			g_rive_context->flush(fr);
		}
	}

	vkEndCommandBuffer(command_buffer);

	VkSubmitInfo submit_info = {};
	submit_info.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
	submit_info.commandBufferCount = 1;
	submit_info.pCommandBuffers = &command_buffer;

	vkQueueSubmit(queue, 1, &submit_info, VK_NULL_HANDLE);
	vkQueueWaitIdle(queue);

	vkDestroyCommandPool(device, command_pool, nullptr);
}

} // namespace rive_integration

