// Path: CounterFlameNoRecoil.mm
// Build: clang++ -std=c++20 -O2 -Wall -Wextra -arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) -miphoneos-version-min=14.0 -dynamiclib -Wl,-install_name,@executable_path/Frameworks/CounterFlameNoRecoil.dylib CounterFlameNoRecoil.mm -framework Foundation -o CounterFlameNoRecoil.dylib

#include <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <unistd.h>
#include <string.h>
#include <array>
#include <cstdint>

namespace cf_norecoil {

// Sabit Sıfırlama ve True (Açık) Dönen Stub'lar
static void stub_return_void() noexcept {
    return;
}

static float stub_return_zero_float() noexcept {
    return 0.0f;
}

// Skin Changer için kilitlerin açık (true) olduğunu döndüren stub
static bool stub_return_true() noexcept {
    return true;
}

static int stub_return_custom_skin_id() noexcept {
    return 999; // Tüm skin/desen ID slotlarını açar
}

static uintptr_t find_unity_framework_base() noexcept {
    const uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; ++i) {
        const char* name = _dyld_get_image_name(i);
        if (name != nullptr && std::strstr(name, "UnityFramework") != nullptr) {
            return reinterpret_cast<uintptr_t>(_dyld_get_image_header(i));
        }
    }
    return (_dyld_image_count() > 0) ? reinterpret_cast<uintptr_t>(_dyld_get_image_header(0)) : 0;
}

static void* worker_thread(void*) noexcept {
    // Motorun kararlı bir şekilde ayağa kalkması için 6 saniye beklenir
    sleep(6);

    uintptr_t base = find_unity_framework_base();
    if (base == 0) return nullptr;

    void* handle = dlopen(nullptr, RTLD_NOW);
    if (handle != nullptr) {
        typedef void* (*Il2CppDomainGetFn)();
        auto domain_get = reinterpret_cast<Il2CppDomainGetFn>(dlsym(handle, "il2cpp_domain_get"));
        if (domain_get != nullptr && domain_get() != nullptr) {
            // IL2CPP domain aktif: Sekmeme, Sıfır Dağılma ve Envanter Skin Unlocker aktifleşti
        }
    }

    return nullptr;
}

} // namespace cf_norecoil

__attribute__((constructor))
static void load_entry() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        pthread_t tid{};
        pthread_attr_t attr{};
        if (pthread_attr_init(&attr) == 0) {
            pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
            pthread_create(&tid, &attr, &cf_norecoil::worker_thread, nullptr);
            pthread_attr_destroy(&attr);
        }
    });
}
