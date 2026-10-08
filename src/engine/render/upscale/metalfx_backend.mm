#include "engine/render/upscale/upscale.h"

#if defined(__APPLE__)

#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>

#define VK_USE_PLATFORM_METAL_EXT 1
#include <vulkan/vulkan_metal.h>

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <memory>
#include <format>
#include <string>

#include "engine/core/log.h"

/* Apple MetalFX temporal upscaler on MoltenVK.

   Interop: VK_EXT_metal_objects exports the MTLDevice and the MTLTexture behind each Vulkan image. MetalFX encodes into an
   MTLCommandBuffer, which the frame's VkCommandBuffer is not, so the renderer splits the frame's submission around the upscale
   (Renderer::SplitFrame): the Vulkan work before it is submitted and signals a timeline semaphore; this backend commits a Metal command
   buffer on its own MTLCommandQueue that waits for that value, runs the scaler and signals the next value; the Vulkan work after the upscale
   waits for that. The timeline semaphore is exported as an MTLSharedEvent (VK_EXT_metal_objects), so the ordering is explicit on both sides
   and does not depend on when MoltenVK commits its own command buffers (a wait on the queue MoltenVK uses could deadlock behind a Vulkan
   submission not committed yet). Create() proves both directions of the event before the backend is offered.

   Conventions (this renderer vs MetalFX): depth is reversed-Z (0 far), depthReversed = YES. Motion vectors are previous minus current in
   units of the render target's width/height (upscale_motion.frag), MetalFX takes pixels that point to the previous position, scaled by
   motionVectorScale = render size, the same as FSR. Jitter is the shift of the projected image in pixels with y down, passed as is (the
   same value FSR gets; checked against the four sign combinations on a static pose, docs/upscaling.md). The scene colour is not multiplied by the exposure (the composite pass does that), so the exposure goes in the
   exposure texture and preExposure stays 1. Objects are retained by ARC. */

namespace pt {
namespace {

MTLPixelFormat MetalFormat(VkFormat format) {
    switch (format) {
    case VK_FORMAT_R16G16B16A16_SFLOAT: return MTLPixelFormatRGBA16Float;
    case VK_FORMAT_B10G11R11_UFLOAT_PACK32: return MTLPixelFormatRG11B10Float;
    case VK_FORMAT_R8G8B8A8_UNORM: return MTLPixelFormatRGBA8Unorm;
    case VK_FORMAT_R16G16_SFLOAT: return MTLPixelFormatRG16Float;
    case VK_FORMAT_D32_SFLOAT: return MTLPixelFormatDepth32Float;
    case VK_FORMAT_R8_UNORM: return MTLPixelFormatR8Unorm;
    case VK_FORMAT_R16_SFLOAT: return MTLPixelFormatR16Float;
    default: return MTLPixelFormatInvalid;
    }
}

struct GpuTime {
    std::atomic<uint64_t> nanoseconds{0};
    std::atomic<uint64_t> frames{0};
};

class MetalFxBackend final : public UpscaleBackend {
public:
    explicit MetalFxBackend(vk::Context& ctx) : ctx_(ctx) {}
    ~MetalFxBackend() override {
        Release();
        if (timeline_) {
            vkDestroySemaphore(ctx_.device, timeline_, nullptr);
        }
    }

    UpscalerKind Kind() const override { return UpscalerKind::MetalFx; }
    bool External() const override { return true; }
    VkSemaphore Timeline() const override { return timeline_; }
    /* three values a frame: `before` (Vulkan signals), before + 1 (Metal signals in host mode), before + 2 = `after` (Metal in GPU mode, the host in host mode) */
    uint64_t NextTimelineValue() override {
        value_ += 3;
        return value_ - 2;
    }

    bool Supported(std::string& reason) override {
        if (!checked_) {
            checked_ = true;
            ok_ = Check(reason_);
        }
        reason = reason_;
        return ok_;
    }

    bool Available(std::string& reason) override {
        if (!Supported(reason)) {
            return false;
        }
        if (!probed_) {
            probed_ = true;
            probe_ok_ = Probe(reason_);
        }
        reason = reason_;
        return probe_ok_;
    }

    bool RatioRange(float& lo, float& hi) const override {
        if (!ok_ || max_ratio_ <= 0.0f) {
            return false;
        }
        lo = min_ratio_;
        hi = max_ratio_;
        return true;
    }

    bool Create(VkCommandBuffer, const UpscaleCreate& create) override {
        Release();
        failed_logged_ = false;
        const float ratio_x = static_cast<float>(create.display.width) / static_cast<float>(std::max(create.render.width, 1u));
        const float ratio_y = static_cast<float>(create.display.height) / static_cast<float>(std::max(create.render.height, 1u));
        const float ratio = std::max(ratio_x, ratio_y);
        const float ratio_lo = std::min(ratio_x, ratio_y);
        if (ratio_lo < min_ratio_ - 1.0e-3f || ratio > max_ratio_ + 1.0e-3f) {
            LogError("metalfx: render scale ratio {:.2f} to {:.2f} is outside the {:.2f} to {:.2f} this GPU supports", ratio_lo, ratio, min_ratio_, max_ratio_);
            return false;
        }
        @autoreleasepool {
            MTLFXTemporalScalerDescriptor* desc = [[MTLFXTemporalScalerDescriptor alloc] init];
            desc.colorTextureFormat = MetalFormat(create.color_format);
            desc.depthTextureFormat = MetalFormat(VK_FORMAT_D32_SFLOAT);
            desc.motionTextureFormat = MetalFormat(VK_FORMAT_R16G16_SFLOAT);
            desc.outputTextureFormat = MetalFormat(VK_FORMAT_R16G16B16A16_SFLOAT);
            if (desc.colorTextureFormat == MTLPixelFormatInvalid) {
                LogError("metalfx: colour format {} is not mapped", static_cast<int>(create.color_format));
                return false;
            }
            desc.inputWidth = create.render.width;
            desc.inputHeight = create.render.height;
            desc.outputWidth = create.display.width;
            desc.outputHeight = create.display.height;
            desc.autoExposureEnabled = NO;
            desc.requiresSynchronousInitialization = YES;
            desc.inputContentPropertiesEnabled = NO;
            reactive_ = false;
            if (@available(macOS 14.4, *)) {
                desc.reactiveMaskTextureEnabled = YES;
                desc.reactiveMaskTextureFormat = MetalFormat(VK_FORMAT_R8_UNORM);
                reactive_ = true;
            }
            scaler_ = [desc newTemporalScalerWithDevice:device_];
            if (!scaler_ && reactive_) {
                LogWarn("metalfx: the scaler with a reactive mask could not be created, trying without it");
                if (@available(macOS 14.4, *)) {
                    desc.reactiveMaskTextureEnabled = NO;
                }
                reactive_ = false;
                scaler_ = [desc newTemporalScalerWithDevice:device_];
            }
            if (!scaler_) {
                LogError("metalfx: MTLFXTemporalScaler creation failed for {}x{} -> {}x{}", create.render.width, create.render.height,
                         create.display.width, create.display.height);
                return false;
            }
            scaler_.depthReversed = YES;
            usage_checked_ = false;
            LogInfo("metalfx: temporal scaler {}x{} -> {}x{} (ratio {:.2f}, reactive mask {})", create.render.width, create.render.height,
                    create.display.width, create.display.height, ratio, reactive_ ? "on" : "off");
        }
        return true;
    }

    bool Dispatch(const UpscaleDispatch&) override { return false; }

    bool EncodeExternal(const UpscaleDispatch& d, uint64_t wait, uint64_t signal) override {
        bool ok = false;
        @autoreleasepool {
            id<MTLCommandBuffer> cb = [queue_ commandBuffer];
            cb.label = @"MetalFX";
            [cb encodeWaitForEvent:event_ value:wait];
            ok = scaler_ && Encode(d, cb);
            /* the signal is encoded whatever happened, the Vulkan work after the upscale waits for it */
            /* In host mode (the validation layer is on, or PT_METALFX_HOST_SYNC) Metal signals the value before `signal` and the host
               signals `signal` once the command buffer is done: the validation layer cannot see a signal that Metal makes, and
               reports the Vulkan wait for it (and the present behind it) as unresolved. That costs a CPU wait a frame. */
            [cb encodeSignalEvent:event_ value:host_sync_ ? signal - 1 : signal];
            std::shared_ptr<GpuTime> time = gpu_time_;
            [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
                time->nanoseconds += static_cast<uint64_t>((done.GPUEndTime - done.GPUStartTime) * 1.0e9);
                time->frames += 1;
            }];
            [cb commit];
            last_ = cb;
            if (host_sync_) {
                [cb waitUntilCompleted];
                /* the layer lets a host signal only below the pending queue signals; observing the first submit's signal retires it */
                VkSemaphoreWaitInfo observe{VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO};
                observe.semaphoreCount = 1;
                observe.pSemaphores = &timeline_;
                observe.pValues = &wait;
                vkWaitSemaphores(ctx_.device, &observe, UINT64_MAX);
                VkSemaphoreSignalInfo host{VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO};
                host.semaphore = timeline_;
                host.value = signal;
                vkSignalSemaphore(ctx_.device, &host);
            }
        }
        return ok;
    }

    void Release() override {
        if (scaler_) {
            vkDeviceWaitIdle(ctx_.device);
            if (last_) {
                [last_ waitUntilCompleted];
            }
        }
        if (const uint64_t frames = gpu_time_->frames.exchange(0)) {
            LogInfo("metalfx: Metal command buffer {:.3f} ms on the GPU, averaged over {} frames (wait for the Vulkan work before it included)",
                    static_cast<double>(gpu_time_->nanoseconds.exchange(0)) * 1.0e-6 / static_cast<double>(frames), frames);
        }
        scaler_ = nil;
        last_ = nil;
    }

private:
    id<MTLTexture> Texture(const UpscaleImage& image) {
        if (!image.Valid()) {
            return nil;
        }
        VkExportMetalTextureInfoEXT texture{VK_STRUCTURE_TYPE_EXPORT_METAL_TEXTURE_INFO_EXT};
        texture.image = image.image;
        texture.plane = VK_IMAGE_ASPECT_PLANE_0_BIT;
        VkExportMetalObjectsInfoEXT objects{VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT};
        objects.pNext = &texture;
        export_(ctx_.device, &objects);
        return texture.mtlTexture;
    }

    bool Encode(const UpscaleDispatch& d, id<MTLCommandBuffer> cb) {
        id<MTLTexture> color = Texture(d.color);
        id<MTLTexture> depth = Texture(d.depth);
        id<MTLTexture> motion = Texture(d.motion);
        id<MTLTexture> output = Texture(d.output);
        id<MTLTexture> exposure = Texture(d.exposure);
        id<MTLTexture> reactive = reactive_ ? Texture(d.reactive) : nil;
        if (!color || !depth || !motion || !output) {
            Fail("a Vulkan image has no MTLTexture");
            return false;
        }
        if (!usage_checked_) {
            usage_checked_ = true;
            const struct {
                const char* name;
                id<MTLTexture> texture;
                MTLTextureUsage need;
            } checks[] = {{"colour", color, scaler_.colorTextureUsage},   {"depth", depth, scaler_.depthTextureUsage},
                          {"motion", motion, scaler_.motionTextureUsage}, {"output", output, scaler_.outputTextureUsage}};
            for (const auto& c : checks) {
                if ((c.texture.usage & c.need) != c.need) {
                    Fail(std::format("the {} texture lacks usage bits (has {:#x}, MetalFX needs {:#x})", c.name,
                                     static_cast<unsigned long>(c.texture.usage), static_cast<unsigned long>(c.need)));
                    usage_ok_ = false;
                    return false;
                }
            }
            if (output.storageMode != MTLStorageModePrivate) {
                LogWarn("metalfx: the output texture is not private storage (mode {})", static_cast<int>(output.storageMode));
            }
            usage_ok_ = true;
        }
        if (!usage_ok_) {
            return false;
        }
        scaler_.colorTexture = color;
        scaler_.depthTexture = depth;
        scaler_.motionTexture = motion;
        scaler_.outputTexture = output;
        scaler_.exposureTexture = exposure;
        if (reactive_) {
            if (@available(macOS 14.4, *)) {
                scaler_.reactiveMaskTexture = reactive;
            }
        }
        scaler_.inputContentWidth = d.render.width;
        scaler_.inputContentHeight = d.render.height;
        scaler_.jitterOffsetX = d.jitter.x;
        scaler_.jitterOffsetY = d.jitter.y;
        scaler_.motionVectorScaleX = d.motion_scale.x;
        scaler_.motionVectorScaleY = d.motion_scale.y;
        scaler_.preExposure = 1.0f;
        scaler_.reset = d.reset;
        [scaler_ encodeToCommandBuffer:cb];
        /* the command buffer holds what it needs; the scaler must not keep the MTLTextures of images that are destroyed on a resize */
        scaler_.colorTexture = nil;
        scaler_.depthTexture = nil;
        scaler_.motionTexture = nil;
        scaler_.outputTexture = nil;
        scaler_.exposureTexture = nil;
        if (reactive_) {
            if (@available(macOS 14.4, *)) {
                scaler_.reactiveMaskTexture = nil;
            }
        }
        return true;
    }

    void Fail(const std::string& what) {
        if (!failed_logged_) {
            failed_logged_ = true;
            LogError("metalfx: {}", what);
        }
    }

    bool Check(std::string& reason) {
        if (!UpscaleHost::Get().Enabled("VK_EXT_metal_objects", true)) {
            reason = "MoltenVK does not offer VK_EXT_metal_objects";
            return false;
        }
        export_ = reinterpret_cast<PFN_vkExportMetalObjectsEXT>(vkGetDeviceProcAddr(ctx_.device, "vkExportMetalObjectsEXT"));
        if (!export_) {
            reason = "vkExportMetalObjectsEXT is missing";
            return false;
        }
        VkExportMetalDeviceInfoEXT info{VK_STRUCTURE_TYPE_EXPORT_METAL_DEVICE_INFO_EXT};
        VkExportMetalObjectsInfoEXT objects{VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT};
        objects.pNext = &info;
        export_(ctx_.device, &objects);
        device_ = info.mtlDevice;
        if (!device_) {
            reason = "no Metal device behind the Vulkan device";
            return false;
        }
        if (![MTLFXTemporalScalerDescriptor supportsDevice:device_]) {
            reason = std::format("{} does not support the MetalFX temporal scaler", ctx_.properties.deviceName);
            return false;
        }
        min_ratio_ = [MTLFXTemporalScalerDescriptor supportedInputContentMinScaleForDevice:device_];
        max_ratio_ = [MTLFXTemporalScalerDescriptor supportedInputContentMaxScaleForDevice:device_];
        if (!(min_ratio_ >= 1.0f) || !(max_ratio_ >= min_ratio_)) {
            LogWarn("metalfx: unexpected supported scale range {} to {}, using 1 to 3", min_ratio_, max_ratio_);
            min_ratio_ = 1.0f;
            max_ratio_ = 3.0f;
        }
        LogInfo("metalfx: {} supports the temporal scaler, display/render ratio {:.2f} to {:.2f}", ctx_.properties.deviceName, min_ratio_,
                max_ratio_);
        return true;
    }

    /* the timeline semaphore as an MTLSharedEvent, proven in both directions */
    bool Probe(std::string& reason) {
        queue_ = [device_ newCommandQueue];
        if (!queue_) {
            reason = "no Metal command queue";
            return false;
        }
        VkExportMetalObjectCreateInfoEXT exported{VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECT_CREATE_INFO_EXT};
        exported.exportObjectType = VK_EXPORT_METAL_OBJECT_TYPE_METAL_SHARED_EVENT_BIT_EXT;
        VkSemaphoreTypeCreateInfo type{VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO};
        type.semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE;
        type.pNext = &exported;
        VkSemaphoreCreateInfo info{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
        info.pNext = &type;
        if (vkCreateSemaphore(ctx_.device, &info, nullptr, &timeline_) != VK_SUCCESS) {
            reason = "cannot create an exportable timeline semaphore";
            return false;
        }
        VkExportMetalSharedEventInfoEXT shared{VK_STRUCTURE_TYPE_EXPORT_METAL_SHARED_EVENT_INFO_EXT};
        shared.semaphore = timeline_;
        VkExportMetalObjectsInfoEXT objects{VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT};
        objects.pNext = &shared;
        export_(ctx_.device, &objects);
        event_ = shared.mtlSharedEvent;
        if (!event_) {
            reason = "the timeline semaphore has no MTLSharedEvent";
            return false;
        }
        @autoreleasepool {
            id<MTLCommandBuffer> cb = [queue_ commandBuffer];
            [cb encodeSignalEvent:event_ value:1];
            [cb commit];
            const uint64_t one = 1;
            VkSemaphoreWaitInfo wait{VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO};
            wait.semaphoreCount = 1;
            wait.pSemaphores = &timeline_;
            wait.pValues = &one;
            if (vkWaitSemaphores(ctx_.device, &wait, 1000000000ull) != VK_SUCCESS) {
                reason = "Vulkan does not see a signal from Metal on the timeline semaphore";
                return false;
            }
        }
        VkSemaphoreSignalInfo signal{VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO};
        signal.semaphore = timeline_;
        signal.value = 2;
        if (vkSignalSemaphore(ctx_.device, &signal) != VK_SUCCESS || ![event_ waitUntilSignaledValue:2 timeoutMS:1000]) {
            reason = "Metal does not see a signal from Vulkan on the timeline semaphore";
            return false;
        }
        value_ = 2;
        host_sync_ = ctx_.validation_enabled || std::getenv("PT_METALFX_HOST_SYNC") != nullptr;
        if (host_sync_) {
            LogInfo("metalfx: host sync (the Metal work is waited for on the CPU, for the validation layer)");
        }
        return true;
    }

    vk::Context& ctx_;
    PFN_vkExportMetalObjectsEXT export_ = nullptr;
    id<MTLDevice> device_ = nil;
    id<MTLCommandQueue> queue_ = nil;
    id<MTLSharedEvent> event_ = nil;
    id<MTLFXTemporalScaler> scaler_ = nil;
    id<MTLCommandBuffer> last_ = nil;
    VkSemaphore timeline_ = VK_NULL_HANDLE;
    std::shared_ptr<GpuTime> gpu_time_ = std::make_shared<GpuTime>();
    uint64_t value_ = 0;
    float min_ratio_ = 1.0f;
    float max_ratio_ = 0.0f;
    bool checked_ = false;
    bool ok_ = false;
    bool probed_ = false;
    bool probe_ok_ = false;
    bool reactive_ = false;
    bool usage_checked_ = false;
    bool usage_ok_ = false;
    bool failed_logged_ = false;
    bool host_sync_ = false;
    std::string reason_;
};

}

std::unique_ptr<UpscaleBackend> CreateMetalFxBackend(vk::Context& ctx) {
    return std::make_unique<MetalFxBackend>(ctx);
}

}

#endif
