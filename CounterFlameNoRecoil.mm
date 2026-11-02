// File: CounterFlameCheat.mm
// Target: iOS ARM64 (Jailed / Sideloaded via E-Sign)

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <libkern/OSCacheControl.h>
#include <stdint.h>
#include <string.h>
#include <atomic>

namespace Config {
    static std::atomic<bool> WallhackEnabled{true};
    static std::atomic<bool> NoRecoilEnabled{true};

    // Replace these RVAs with the exact offsets dumped from Counter Flame's global-metadata.dat
    // via Il2CppDumper (WeaponController / GunController / FirstPersonCamera)
    constexpr uintptr_t RVA_GetRecoilMultiplier = 0x1A4F280; // float GetRecoil()
    constexpr uintptr_t RVA_ApplyRecoil         = 0x1A4F810; // void ApplyRecoil(Vector3)
    constexpr uintptr_t RVA_AddCameraKick       = 0x1B02C40; // void AddPitchYaw(float, float)
}

namespace Memory {
    static uintptr_t GetFrameworkBase(const char* imageName) {
        uint32_t count = _dyld_image_count();
        for (uint32_t i = 0; i < count; ++i) {
            const char* name = _dyld_get_image_name(i);
            if (name && strstr(name, imageName)) {
                return reinterpret_cast<uintptr_t>(_dyld_get_image_header(i));
            }
        }
        return 0;
    }

    static bool PatchBytes(uintptr_t address, const void* buffer, size_t size) {
        if (address == 0 || buffer == nullptr || size == 0 || size > 4096) {
            return false;
        }

        mach_port_t task = mach_task_self();
        vm_address_t pageStart = address & ~(vm_page_size - 1);
        vm_size_t pageSpan = ((address + size - pageStart + vm_page_size - 1) / vm_page_size) * vm_page_size;

        // Jailed iOS prohibits RWX simultaneously under APRR/W^X; flip to RW, write, flush icache, restore RX
        kern_return_t kr = vm_protect(task, pageStart, pageSpan, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
        if (kr != KERN_SUCCESS) {
            return false;
        }

        memcpy(reinterpret_cast<void*>(address), buffer, size);
        sys_icache_invalidate(reinterpret_cast<void*>(address), size);

        kr = vm_protect(task, pageStart, pageSpan, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
        return (kr == KERN_SUCCESS);
    }

    // ARM64: FMOV S0, WZR (1F 00 27 1E) ; RET (C0 03 5F D6) -> returns 0.0f
    static bool PatchReturnZeroFloat(uintptr_t address) {
        static constexpr uint8_t kZeroFloatRet[8] = {
            0x1F, 0x00, 0x27, 0x1E, // fmov s0, wzr
            0xC0, 0x03, 0x5F, 0xD6  // ret
        };
        return PatchBytes(address, kZeroFloatRet, sizeof(kZeroFloatRet));
    }

    // ARM64: RET (C0 03 5F D6) -> immediate void return
    static bool PatchVoidReturn(uintptr_t address) {
        static constexpr uint8_t kVoidRet[4] = {
            0xC0, 0x03, 0x5F, 0xD6  // ret
        };
        return PatchBytes(address, kVoidRet, sizeof(kVoidRet));
    }
}

namespace MetalWallhack {
    static id<MTLDepthStencilState> g_XRayDepthState = nil;
    static IMP g_OrigSetDepthStencilState = nullptr;
    static IMP g_OrigDrawIndexedPrimitives = nullptr;
    static std::atomic<uint32_t> g_CurrentVertexBufferCount{0};

    static void EnsureXRayState(id<MTLDevice> device) {
        if (g_XRayDepthState != nil || device == nil) {
            return;
        }
        MTLDepthStencilDescriptor* desc = [[MTLDepthStencilDescriptor alloc] init];
        desc.depthCompareFunction = MTLCompareFunctionAlways;
        desc.depthWriteEnabled = NO;
        g_XRayDepthState = [device newDepthStencilStateWithDescriptor:desc];
    }

    static void Hooked_SetVertexBuffer(id self, SEL _cmd, id<MTLBuffer> buffer, NSUInteger offset, NSUInteger index) {
        // Track skinned mesh streams (Unity character meshes bind bone weights on index 1/2)
        if (buffer != nil && index == 1) {
            g_CurrentVertexBufferCount.fetch_add(1, std::memory_order_relaxed);
        }
        using FnType = void(*)(id, SEL, id<MTLBuffer>, NSUInteger, NSUInteger);
        reinterpret_cast<FnType>(class_getMethodImplementation([self class], _cmd))(self, _cmd, buffer, offset, index);
    }

    static void Hooked_DrawIndexedPrimitives(
        id self,
        SEL _cmd,
        MTLPrimitiveType primitiveType,
        NSUInteger indexCount,
        MTLIndexType indexType,
        id<MTLBuffer> indexBuffer,
        NSUInteger indexBufferOffset
    ) {
        // Unity player characters typically fall within 1200..35000 indices in mobile FPS builds
        if (Config::WallhackEnabled.load(std::memory_order_relaxed) &&
            primitiveType == MTLPrimitiveTypeTriangle &&
            indexCount >= 1200 && indexCount <= 35000) {

            id<MTLRenderCommandEncoder> encoder = (id<MTLRenderCommandEncoder>)self;
            EnsureXRayState(encoder.device);

            if (g_XRayDepthState != nil && g_OrigSetDepthStencilState != nullptr) {
                using SetDepthFn = void(*)(id, SEL, id<MTLDepthStencilState>);
                reinterpret_cast<SetDepthFn>(g_OrigSetDepthStencilState)(
                    self, @selector(setDepthStencilState:), g_XRayDepthState
                );
            }
        }

        using DrawFn = void(*)(id, SEL, MTLPrimitiveType, NSUInteger, MTLIndexType, id<MTLBuffer>, NSUInteger);
        reinterpret_cast<DrawFn>(g_OrigDrawIndexedPrimitives)(
            self, _cmd, primitiveType, indexCount, indexType, indexBuffer, indexBufferOffset
        );
    }

    static void InstallMetalHooks() {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return;

        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> cmdBuf = [queue commandBuffer];
        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];

        MTLTextureDescriptor* texDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                           width:4
                                                                                          height:4
                                                                                       mipmapped:NO];
        texDesc.usage = MTLTextureUsageRenderTarget;
        pass.colorAttachments[0].texture = [device newTextureWithDescriptor:texDesc];

        id<MTLRenderCommandEncoder> dummyEncoder = [cmdBuf renderCommandEncoderWithDescriptor:pass];
        Class encoderClass = [dummyEncoder class];
        [dummyEncoder endEncoding];

        Method depthMethod = class_getInstanceMethod(encoderClass, @selector(setDepthStencilState:));
        if (depthMethod) {
            g_OrigSetDepthStencilState = method_getImplementation(depthMethod);
        }

        SEL drawSel = @selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:);
        Method drawMethod = class_getInstanceMethod(encoderClass, drawSel);
        if (drawMethod) {
            g_OrigDrawIndexedPrimitives = method_setImplementation(drawMethod, (IMP)Hooked_DrawIndexedPrimitives);
        }
    }
}

@interface CFOverlayController : NSObject
+ (void)setupGestureMenu;
@end

@implementation CFOverlayController
+ (void)setupGestureMenu {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow* keyWindow = nil;
        for (UIWindowScene* scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow* w in scene.windows) {
                    if (w.isKeyWindow) { keyWindow = w; break; }
                }
            }
        }
        if (!keyWindow) return;

        // 3-finger tap toggles Wallhack at runtime
        UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleWallhack)];
        tap.numberOfTouchesRequired = 3;
        tap.numberOfTapsRequired = 1;
        [keyWindow addGestureRecognizer:tap];
    });
}

+ (void)toggleWallhack {
    bool nextState = !Config::WallhackEnabled.load();
    Config::WallhackEnabled.store(nextState);
}
@end

__attribute__((constructor))
static void InitializeCounterFlameDylib() {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        uintptr_t base = 0;
        for (int retry = 0; retry < 100 && base == 0; ++retry) {
            base = Memory::GetFrameworkBase("UnityFramework");
            if (base == 0) {
                base = Memory::GetFrameworkBase("CounterFlame");
            }
            usleep(100000); // 100ms poll until UnityFramework loads into dyld
        }

        if (base != 0 && Config::NoRecoilEnabled.load()) {
            Memory::PatchReturnZeroFloat(base + Config::RVA_GetRecoilMultiplier);
            Memory::PatchVoidReturn(base + Config::RVA_ApplyRecoil);
            Memory::PatchVoidReturn(base + Config::RVA_AddCameraKick);
        }

        MetalWallhack::InstallMetalHooks();
        [CFOverlayController setupGestureMenu];
    });
}
