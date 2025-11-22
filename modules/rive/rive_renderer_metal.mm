// Objective-C++ bridge that creates a Rive RenderContext on a Metal device
// and exposes simple begin/flush helpers that accept Godot's Metal command
// buffer objects.

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

// device_ptr is expected to be an Objective-C id<MTLDevice> pointer passed as void*
bool create_metal_context(void *device_ptr) {
    if (!device_ptr) {
        return false;
    }
    id<MTLDevice> device = (__bridge id<MTLDevice>)(device_ptr);
    // MakeContext returns std::unique_ptr<rive::RenderContext>
    rive::gpu::RenderContextMetalImpl::ContextOptions options;
    // options.disableFramebufferReads = true; // Uncomment to force atomic mode for debugging
    std::unique_ptr<rive::gpu::RenderContext> ctx = rive::gpu::RenderContextMetalImpl::MakeContext(device, options);
    if (!ctx) {
        return false;
    }
    // Move the already-constructed RenderContext into our global pointer.
    if (g_rive_context) {
        delete g_rive_context;
    }
    g_rive_context = ctx.release();
    
    // Register the context as the factory for resource loading
    RiveRenderRegistry::get_singleton()->set_factory(g_rive_context);

    print_verbose("RIVE: create_metal_context succeeded");
    return true;
}

// Flush a single frame using an external Metal command buffer and target
// texture. cmd_buffer_ptr must be an id<MTLCommandBuffer> and
// texture_ptr must be an id<MTLTexture>, both passed as void*. The
// current_frame and safe_frame counters are used by Rive for resource
// lifetime tracking.
void flush_with_command_buffer(void *cmd_buffer_ptr, void *texture_ptr, uint64_t current_frame, uint64_t safe_frame, uint32_t width, uint32_t height, void* layer_ptr) {
    if (!g_rive_context) return;
    id<MTLCommandBuffer> cmd = (__bridge id<MTLCommandBuffer>)(cmd_buffer_ptr);
    // Defensive: ensure command buffer is valid and retained during flush.
    if (!cmd) {
        ERR_PRINT(vformat("RIVE: flush called with null command buffer ptr=%p", cmd_buffer_ptr));
        return;
    }

    // Heuristic: Only draw to the main window (assumed to be the largest one)
    // or filter out small windows (like tooltips/popups).
    // A better approach would be to match the layer against the RiveViewer's window,
    // but for now, let's just filter by size to avoid drawing on small dialogs.
    if (width < 800 || height < 600) {
        return;
    }

    // Retain the command buffer for the duration of the flush to avoid
    // lifetime/timing issues where the underlying Objective-C object might be
    // released by the caller while Rive is executing recording commands.
    CFRetain((__bridge CFTypeRef)cmd);

    rive::gpu::RenderContext::FrameDescriptor fd;
    fd.renderTargetWidth = width;
    fd.renderTargetHeight = height;
    // Don't clear the drawable to transparent by default; preserve existing
    // contents so Rive can composite on top of Godot's drawable.
    fd.loadAction = rive::gpu::LoadAction::preserveRenderTarget;

    g_rive_context->beginFrame(fd);


    // Create a RenderTarget from the provided MTLTexture so Rive has a valid
    // render target to draw into.
    rive::gpu::RenderTarget* raw_target = nullptr;
    // Hold the rcp<> so the RenderTarget remains alive for the duration of
    // the flush.
    {
        id<MTLTexture> texture = (__bridge id<MTLTexture>)(texture_ptr);
        if (!texture) {
            ERR_PRINT(vformat("RIVE: flush called with null texture_ptr=%p", texture_ptr));
            // Release retain and return
            CFRelease((__bridge CFTypeRef)cmd);
            return;
        }

        // Use the metal-specific makeRenderTarget helper to construct a
        // RenderTarget backing the provided texture.
        rive::gpu::RenderContextMetalImpl *impl = g_rive_context->static_impl_cast<rive::gpu::RenderContextMetalImpl>();
    rive::rcp<rive::gpu::RenderTargetMetal> rtarget = impl->makeRenderTarget(texture.pixelFormat, width, height);
        if (!rtarget) {
            ERR_PRINT("RIVE: failed to create RenderTarget from texture");
            CFRelease((__bridge CFTypeRef)cmd);
            return;
        }
        rtarget->setTargetTexture(texture);
        raw_target = rtarget.get();

        rive::gpu::RenderContext::FlushResources fr;
        fr.renderTarget = raw_target;
        fr.externalCommandBuffer = cmd_buffer_ptr;
        fr.currentFrameNumber = current_frame;
        fr.safeFrameNumber = safe_frame;

        // Draw all registered Rive drawables
        {
            rive::RiveRenderer renderer(g_rive_context);
            RiveRenderRegistry::get_singleton()->draw_all(&renderer);
        }

        g_rive_context->flush(fr);

        // rtarget will go out of scope and release after flush returns.
    }

    // Release the retain we took above.
    CFRelease((__bridge CFTypeRef)cmd);
    
    print_verbose(vformat("RIVE: flushed into command buffer for %d x %d", width, height));
}

bool has_context() { return g_rive_context != nullptr; }

void render_texture_metal(RenderingDevice *rd, RID texture_rid, RiveDrawable *drawable, uint32_t width, uint32_t height) {
    @autoreleasepool {
        if (!g_rive_context) return;
        if (!rd || !drawable) return;

        RenderingDeviceDriverMetal *driver = dynamic_cast<RenderingDeviceDriverMetal*>(rd->get_device_driver());
        if (!driver) return;

        id<MTLCommandQueue> queue = driver->get_queue();
        if (!queue) return;

        uint64_t native_handle = rd->get_driver_resource(RD::DRIVER_RESOURCE_TEXTURE, texture_rid);
        id<MTLTexture> texture = (__bridge id<MTLTexture>)(void*)native_handle;
        if (!texture) return;
        
        id<MTLCommandBuffer> cmd = [queue commandBuffer];
        if (!cmd) return;

        // Retain command buffer to ensure it lives through Rive's potential usage
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
            // fd.disableRasterOrdering = true; // Force atomic mode for better compatibility?

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
