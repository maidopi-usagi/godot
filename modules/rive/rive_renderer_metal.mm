// Metal bridge for Rive renderer: create context and provide flush helpers.

#import <Metal/Metal.h>

#include "rive/renderer/metal/render_context_metal_impl.h"
#include "rive/renderer/render_context.hpp"
#include "rive/file.hpp"
#include "rive/artboard.hpp"
#include "rive/renderer/rive_renderer.hpp"
#include "rive_render_registry.h"
#include <vector>

#include <memory>
#include <objc/runtime.h>
#include <CoreFoundation/CoreFoundation.h>

#include "servers/rendering/rendering_device.h"
#include "drivers/metal/rendering_device_driver_metal.h"
#include "core/os/os.h"

using namespace rive;

namespace rive_integration {

static rive::gpu::RenderContext *g_rive_context = nullptr;

// Create a RenderContext from an Objective-C `id<MTLDevice>` passed as void*.
bool create_metal_context(void *device_ptr) {
    if (!device_ptr) return false;
    id<MTLDevice> device = (__bridge id<MTLDevice>)(device_ptr);

    rive::gpu::RenderContextMetalImpl::ContextOptions options;
    std::unique_ptr<rive::gpu::RenderContext> ctx = rive::gpu::RenderContextMetalImpl::MakeContext(device, options);
    if (!ctx) return false;

    if (g_rive_context) delete g_rive_context;
    g_rive_context = ctx.release();

    RiveRenderRegistry::get_singleton()->set_factory(g_rive_context);
    print_verbose("RIVE: create_metal_context succeeded");
    return true;
}

// Flush a frame into an external Metal command buffer/texture.
// `cmd_buffer_ptr` must be an `id<MTLCommandBuffer>` (as void*).
void flush_with_command_buffer(void *cmd_buffer_ptr, void *texture_ptr, uint64_t current_frame, uint64_t safe_frame, uint32_t width, uint32_t height, void* layer_ptr) {
    if (!g_rive_context) return;
    id<MTLCommandBuffer> cmd = (__bridge id<MTLCommandBuffer>)(cmd_buffer_ptr);
    if (!cmd) {
        ERR_PRINT(vformat("RIVE: flush called with null command buffer ptr=%p", cmd_buffer_ptr));
        return;
    }

    // Skip very small targets.
    if (width < 800 || height < 600) return;

    CFRetain((__bridge CFTypeRef)cmd);

    rive::gpu::RenderContext::FrameDescriptor fd;
    fd.renderTargetWidth = width;
    fd.renderTargetHeight = height;
    fd.loadAction = rive::gpu::LoadAction::preserveRenderTarget;

    g_rive_context->beginFrame(fd);

    {
        id<MTLTexture> texture = (__bridge id<MTLTexture>)(texture_ptr);
        if (!texture) {
            ERR_PRINT(vformat("RIVE: flush called with null texture_ptr=%p", texture_ptr));
            CFRelease((__bridge CFTypeRef)cmd);
            return;
        }

        rive::gpu::RenderContextMetalImpl *impl = g_rive_context->static_impl_cast<rive::gpu::RenderContextMetalImpl>();
        rive::rcp<rive::gpu::RenderTargetMetal> rtarget = impl->makeRenderTarget(texture.pixelFormat, width, height);
        if (!rtarget) {
            ERR_PRINT("RIVE: failed to create RenderTarget from texture");
            CFRelease((__bridge CFTypeRef)cmd);
            return;
        }

        rtarget->setTargetTexture(texture);

        rive::gpu::RenderContext::FlushResources fr;
        fr.renderTarget = rtarget.get();
        fr.externalCommandBuffer = cmd_buffer_ptr;
        fr.currentFrameNumber = current_frame;
        fr.safeFrameNumber = safe_frame;

        // Draw all registered drawables and flush.
        {
            rive::RiveRenderer renderer(g_rive_context);
            RiveRenderRegistry::get_singleton()->draw_all(&renderer);
        }

        g_rive_context->flush(fr);
    }

    CFRelease((__bridge CFTypeRef)cmd);
    print_verbose(vformat("RIVE: flushed into command buffer for %d x %d", width, height));
}

bool has_context() { return g_rive_context != nullptr; }

// Render a RiveDrawable into a Godot texture via Metal.
void render_texture_metal(RenderingDevice *rd, RID texture_rid, RiveDrawable *drawable, uint32_t width, uint32_t height) {
    @autoreleasepool {
        if (!g_rive_context || !rd || !drawable) return;

        RenderingDeviceDriverMetal *driver = dynamic_cast<RenderingDeviceDriverMetal*>(rd->get_device_driver());
        if (!driver) return;

        id<MTLCommandQueue> queue = driver->get_queue();
        if (!queue) return;

        uint64_t native_handle = rd->get_driver_resource(RD::DRIVER_RESOURCE_TEXTURE, texture_rid);
        id<MTLTexture> texture = (__bridge id<MTLTexture>)(void*)native_handle;
        if (!texture) return;

        id<MTLCommandBuffer> cmd = [queue commandBuffer];
        if (!cmd) return;

        CFRetain((__bridge CFTypeRef)cmd);

        rive::gpu::RenderContextMetalImpl *impl = g_rive_context->static_impl_cast<rive::gpu::RenderContextMetalImpl>();
        rive::rcp<rive::gpu::RenderTargetMetal> rtarget = impl->makeRenderTarget(texture.pixelFormat, width, height);

        if (rtarget) {
            rtarget->setTargetTexture(texture);

            rive::gpu::RenderContext::FrameDescriptor fd;
            fd.renderTargetWidth = width;
            fd.renderTargetHeight = height;
            fd.loadAction = rive::gpu::LoadAction::clear;
            fd.clearColor = 0x00000000;

            g_rive_context->beginFrame(fd);

            {
                rive::RiveRenderer renderer(g_rive_context);
                drawable->draw(&renderer);
            }

            static uint64_t frame_idx = 0;
            frame_idx++;

            rive::gpu::RenderContext::FlushResources fr;
            fr.renderTarget = rtarget.get();
            fr.externalCommandBuffer = (__bridge void*)cmd;
            fr.currentFrameNumber = frame_idx;
            fr.safeFrameNumber = (frame_idx > 2) ? frame_idx - 2 : 0;

            g_rive_context->flush(fr);
        }

        [cmd commit];
        CFRelease((__bridge CFTypeRef)cmd);
    }
}

} // namespace rive_integration
