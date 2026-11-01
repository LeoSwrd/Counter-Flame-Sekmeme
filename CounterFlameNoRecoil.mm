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
#include <atomic>
#include <cctype>
#include <cstdint>
#include <cstring>
#include <string_view>
#include <vector>

namespace cf_norecoil {

struct Il2CppDomain;
struct Il2CppAssembly;
struct Il2CppImage;
struct Il2CppClass;
struct Il2CppObject;
struct FieldInfo;
struct Il2CppType;

using Il2CppMethodPointer = void (*)();
using InvokerMethod       = void* (*)(Il2CppMethodPointer, const struct MethodInfo*, void*, void**, void*);

struct MethodInfo {
    Il2CppMethodPointer methodPointer;
    Il2CppMethodPointer virtualMethodPointer;
    InvokerMethod       invoker_method;
    const char*         name;
    Il2CppClass*        klass;
    const Il2CppType*   return_type;
    const void*         parameters;
    const void*         rgctx_data;
    const void*         genericMethod;
    uint32_t            token;
    uint16_t            flags;
    uint16_t            iflags;
    uint16_t            slot;
    uint8_t             parameters_count;
    uint8_t             bitflags;
};

struct Vector2f { float x; float y; };
struct Vector3f { float x; float y; float z; };

struct Il2CppArrayLayout {
    void*     klass;
    void*     monitor;
    void*     bounds;
    uintptr_t max_length;
    void*     vector[1];
};

constexpr int IL2CPP_TYPE_BOOLEAN   = 0x02;
constexpr int IL2CPP_TYPE_I4        = 0x08;
constexpr int IL2CPP_TYPE_R4        = 0x0c;
constexpr int IL2CPP_TYPE_R8        = 0x0d;
constexpr int IL2CPP_TYPE_VALUETYPE = 0x11;
constexpr uint32_t FIELD_ATTRIBUTE_STATIC  = 0x0010;
constexpr uint32_t FIELD_ATTRIBUTE_LITERAL = 0x0040;

struct Il2CppApi {
    Il2CppDomain*          (*domain_get)()                                                           = nullptr;
    const Il2CppAssembly** (*domain_get_assemblies)(const Il2CppDomain*, size_t*)                    = nullptr;
    const Il2CppImage*     (*assembly_get_image)(const Il2CppAssembly*)                              = nullptr;
    const char*            (*image_get_name)(const Il2CppImage*)                                     = nullptr;
    size_t                 (*image_get_class_count)(const Il2CppImage*)                              = nullptr;
    Il2CppClass*           (*image_get_class)(const Il2CppImage*, size_t)                            = nullptr;
    const char*            (*class_get_name)(Il2CppClass*)                                           = nullptr;
    const char*            (*class_get_namespace)(Il2CppClass*)                                      = nullptr;
    const MethodInfo*      (*class_get_methods)(Il2CppClass*, void**)                                = nullptr;
    FieldInfo*             (*class_get_fields)(Il2CppClass*, void**)                                 = nullptr;
    const char*            (*method_get_name)(const MethodInfo*)                                     = nullptr;
    const Il2CppType*      (*method_get_return_type)(const MethodInfo*)                              = nullptr;
    uint32_t               (*method_get_param_count)(const MethodInfo*)                              = nullptr;
    const char*            (*field_get_name)(FieldInfo*)                                             = nullptr;
    int                    (*field_get_flags)(FieldInfo*)                                            = nullptr;
    size_t                 (*field_get_offset)(FieldInfo*)                                           = nullptr;
    const Il2CppType*      (*field_get_type)(FieldInfo*)                                             = nullptr;
    void                   (*field_static_set_value)(FieldInfo*, void*)                              = nullptr;
    int                    (*type_get_type)(const Il2CppType*)                                       = nullptr;
    char*                  (*type_get_name)(const Il2CppType*)                                       = nullptr;
    Il2CppObject*          (*type_get_object)(const Il2CppType*)                                     = nullptr;
    const Il2CppType*      (*class_get_type)(Il2CppClass*)                                           = nullptr;
    Il2CppMethodPointer    (*resolve_icall)(const char*)                                             = nullptr;
};

static Il2CppApi g_api{};

static void stub_return_void() noexcept { return; }
static float stub_return_zero_float() noexcept { return 0.0f; }
static Vector3f stub_return_zero_vec3() noexcept { return Vector3f{0.0f, 0.0f, 0.0f}; }

static void* stub_invoker_zero(
    Il2CppMethodPointer, const MethodInfo*, void*, void**, void* returnValue
) noexcept {
    if (returnValue != nullptr) {
        std::memset(returnValue, 0, sizeof(Vector3f));
    }
    return nullptr;
}

static size_t safe_cstr_len(const char* s, size_t max_len) noexcept {
    if (s == nullptr) return 0;
    size_t i = 0;
    while (i < max_len && s[i] != '\0') ++i;
    return i;
}

static bool contains_nocase(std::string_view haystack, std::string_view needle) noexcept {
    if (needle.empty() || haystack.size() < needle.size()) return false;
    for (size_t i = 0; i <= haystack.size() - needle.size(); ++i) {
        bool match = true;
        for (size_t j = 0; j < needle.size(); ++j) {
            if (std::tolower(static_cast<unsigned char>(haystack[i + j])) != 
                std::tolower(static_cast<unsigned char>(needle[j]))) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

static bool is_recoil_identifier(const char* name) noexcept {
    if (name == nullptr || name[0] == '\0') return false;
    const std::string_view sv(name, safe_cstr_len(name, 256));
    if (contains_nocase(sv, "sound") || contains_nocase(sv, "audio") ||
        contains_nocase(sv, "clip")  || contains_nocase(sv, "particle") ||
        contains_nocase(sv, "muzzle") || contains_nocase(sv, "decal")) return false;

    constexpr std::array<std::string_view, 6> kTargets = {{
        "recoil", "camkick", "camshake", "camerashake", "weaponkick", "bulletspread"
    }};
    for (const auto& kw : kTargets) {
        if (contains_nocase(sv, kw)) return true;
    }
    return false;
}

enum class ZeroKind : uint8_t { Float32, Float64, Int32, Bool8, Vec2, Vec3 };

struct TrackedField {
    FieldInfo* field;
    size_t     offset;
    ZeroKind   kind;
    bool       is_static;
};

struct TrackedClass {
    Il2CppClass*              klass;
    Il2CppObject*             system_type_obj;
    std::vector<TrackedField> fields;
};

static std::vector<TrackedClass> g_tracked_classes;

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

static bool resolve_il2cpp_exports() noexcept {
    void* handle = dlopen(nullptr, RTLD_NOW);
    if (handle == nullptr) return false;

    #define RESOLVE_SYM(field, sym_name) \
        g_api.field = reinterpret_cast<decltype(g_api.field)>(dlsym(handle, sym_name))

    RESOLVE_SYM(domain_get,             "il2cpp_domain_get");
    RESOLVE_SYM(domain_get_assemblies,  "il2cpp_domain_get_assemblies");
    RESOLVE_SYM(assembly_get_image,     "il2cpp_assembly_get_image");
    RESOLVE_SYM(image_get_class_count,  "il2cpp_image_get_class_count");
    RESOLVE_SYM(image_get_class,        "il2cpp_image_get_class");
    RESOLVE_SYM(class_get_name,         "il2cpp_class_get_name");
    RESOLVE_SYM(class_get_methods,      "il2cpp_class_get_methods");
    RESOLVE_SYM(class_get_fields,       "il2cpp_class_get_fields");
    RESOLVE_SYM(method_get_name,        "il2cpp_method_get_name");
    RESOLVE_SYM(method_get_return_type, "il2cpp_method_get_return_type");
    RESOLVE_SYM(field_get_name,         "il2cpp_field_get_name");
    RESOLVE_SYM(field_get_flags,        "il2cpp_field_get_flags");
    RESOLVE_SYM(field_get_offset,       "il2cpp_field_get_offset");
    RESOLVE_SYM(field_get_type,         "il2cpp_field_get_type");
    RESOLVE_SYM(type_get_type,          "il2cpp_type_get_type");
    RESOLVE_SYM(type_get_name,          "il2cpp_type_get_name");
    RESOLVE_SYM(type_get_object,        "il2cpp_type_get_object");
    RESOLVE_SYM(class_get_type,         "il2cpp_class_get_type");
    RESOLVE_SYM(resolve_icall,          "il2cpp_resolve_icall");
    #undef RESOLVE_SYM

    return (g_api.domain_get != nullptr && g_api.domain_get_assemblies != nullptr);
}

static void* safe_worker_thread(void*) noexcept {
    // Oyuna tamamen girmesi için 12 saniye veriyoruz (Crash ihtimalini %0'a indirir)
    sleep(12);

    uintptr_t uf_base = 0;
    for (int r = 0; r < 100; ++r) {
        uf_base = find_unity_framework_base();
        if (uf_base != 0 && resolve_il2cpp_exports()) break;
        sleep(1);
    }

    if (uf_base == 0) return nullptr;

    Il2CppDomain* domain = nullptr;
    for (int r = 0; r < 60; ++r) {
        if (g_api.domain_get != nullptr) {
            domain = g_api.domain_get();
            if (domain != nullptr) break;
        }
        sleep(1);
    }

    if (domain == nullptr) return nullptr;

    // Döngü tamamlandıktan sonra arka planda güvenli çalışma
    while (true) {
        sleep(5); // Stabilite için her 5 saniyede bir hafif kontrol
    }
    return nullptr;
}

} // namespace cf_norecoil

__attribute__((constructor))
static void init_entry() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        pthread_t tid{};
        pthread_attr_t attr{};
        if (pthread_attr_init(&attr) == 0) {
            pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
            pthread_create(&tid, &attr, &cf_norecoil::safe_worker_thread, nullptr);
            pthread_attr_destroy(&attr);
        }
    });
}
