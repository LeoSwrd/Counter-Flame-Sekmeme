// Path: CounterFlameNoRecoil.mm
// Build: clang++ -std=c++20 -O2 -Wall -Wextra -arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) -dynamiclib CounterFlameNoRecoil.mm -framework Foundation -o CounterFlameNoRecoil.dylib

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

// ============================================================================
// 1. IL2CPP RUNTIME ABI TYPES & EXPORT SIGNATURES
// ============================================================================
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

struct Vector2f {
    float x;
    float y;
};

struct Vector3f {
    float x;
    float y;
    float z;
};

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

// ============================================================================
// 2. SIGNED REPLACEMENT STUBS (LIVE IN THIS DYLIB'S SIGNED __TEXT SEGMENT)
// ============================================================================
static void stub_return_void() noexcept {
    return;
}

static float stub_return_zero_float() noexcept {
    return 0.0f;
}

static Vector3f stub_return_zero_vec3() noexcept {
    return Vector3f{0.0f, 0.0f, 0.0f};
}

static void* stub_invoker_zero(
    Il2CppMethodPointer /*fn*/,
    const MethodInfo*   /*method*/,
    void*               /*obj*/,
    void**              /*params*/,
    void*               returnValue
) noexcept {
    if (returnValue != nullptr) {
        std::memset(returnValue, 0, sizeof(Vector3f));
    }
    return nullptr;
}

// ============================================================================
// 3. OPTIONAL STATIC RVA FALLBACK TABLE
// ============================================================================
struct StaticPatch {
    uintptr_t      rva;
    const uint8_t* patch_bytes;
    size_t         length;
};

constexpr std::array<uint8_t, 4>  kArm64Ret       = { 0xC0, 0x03, 0x5F, 0xD6 };
constexpr std::array<uint8_t, 8>  kArm64FloatZero = { 0xE0, 0x03, 0x27, 0x1E, 0xC0, 0x03, 0x5F, 0xD6 };
constexpr std::array<uint8_t, 16> kArm64Vec3Zero  = {
    0xE0, 0x03, 0x27, 0x1E,
    0xE1, 0x03, 0x27, 0x1E,
    0xE2, 0x03, 0x27, 0x1E,
    0xC0, 0x03, 0x5F, 0xD6
};

constexpr std::array<StaticPatch, 3> kStaticRvaPatches = {{
    { 0x0, kArm64Ret.data(),       kArm64Ret.size() },
    { 0x0, kArm64FloatZero.data(), kArm64FloatZero.size() },
    { 0x0, kArm64Vec3Zero.data(),  kArm64Vec3Zero.size() }
}};

extern "C" kern_return_t mach_vm_protect(
    vm_map_t           target_task,
    mach_vm_address_t  address,
    mach_vm_size_t     size,
    boolean_t          set_maximum,
    vm_prot_t          new_protection
);

extern "C" kern_return_t mach_vm_write(
    vm_map_t               target_task,
    mach_vm_address_t      address,
    vm_offset_t            data,
    mach_msg_type_number_t dataCnt
);

static void try_static_rva_patch(uintptr_t base_addr, const StaticPatch& entry) noexcept {
    if (base_addr == 0 || entry.rva == 0 || entry.patch_bytes == nullptr || entry.length == 0) {
        return;
    }

    const uintptr_t target = base_addr + entry.rva;
    const vm_map_t self = mach_task_self();
    const mach_vm_address_t page = target & ~static_cast<uintptr_t>(vm_page_size - 1);

    if (mach_vm_protect(self, page, vm_page_size, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) == KERN_SUCCESS) {
        if (mach_vm_write(self, target, reinterpret_cast<vm_offset_t>(entry.patch_bytes), static_cast<mach_msg_type_number_t>(entry.length)) == KERN_SUCCESS) {
            mach_vm_protect(self, page, vm_page_size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
            sys_icache_invalidate(reinterpret_cast<void*>(target), entry.length);
        }
    }
}

// ============================================================================
// 4. CASE-INSENSITIVE KEYWORD MATCHER FOR RECOIL / SPREAD / KICK
// ============================================================================
static size_t safe_cstr_len(const char* s, size_t max_len) noexcept {
    if (s == nullptr) {
        return 0;
    }
    size_t i = 0;
    while (i < max_len && s[i] != '\0') {
        ++i;
    }
    return i;
}

static bool contains_nocase(std::string_view haystack, std::string_view needle) noexcept {
    if (needle.empty() || haystack.size() < needle.size()) {
        return false;
    }
    for (size_t i = 0; i <= haystack.size() - needle.size(); ++i) {
        bool match = true;
        for (size_t j = 0; j < needle.size(); ++j) {
            const unsigned char c1 = static_cast<unsigned char>(haystack[i + j]);
            const unsigned char c2 = static_cast<unsigned char>(needle[j]);
            if (std::tolower(c1) != std::tolower(c2)) {
                match = false;
                break;
            }
        }
        if (match) {
            return true;
        }
    }
    return false;
}

static bool is_recoil_identifier(const char* name) noexcept {
    if (name == nullptr || name[0] == '\0') {
        return false;
    }
    const std::string_view sv(name, safe_cstr_len(name, 256));

    if (contains_nocase(sv, "sound") || contains_nocase(sv, "audio") ||
        contains_nocase(sv, "clip")  || contains_nocase(sv, "particle") ||
        contains_nocase(sv, "muzzle") || contains_nocase(sv, "decal") ||
        contains_nocase(sv, "ui")    || contains_nocase(sv, "hud")) {
        return false;
    }

    constexpr std::array<std::string_view, 9> kTargets = {{
        "recoil",
        "camkick",
        "camshake",
        "camerashake",
        "weaponkick",
        "gunkick",
        "aimkick",
        "bulletspread",
        "weaponspread"
    }};

    for (const auto& kw : kTargets) {
        if (contains_nocase(sv, kw)) {
            return true;
        }
    }
    return false;
}

static bool is_weapon_class_identifier(const char* name) noexcept {
    if (name == nullptr || name[0] == '\0') {
        return false;
    }
    const std::string_view sv(name, safe_cstr_len(name, 256));
    constexpr std::array<std::string_view, 8> kClassKeywords = {{
        "weapon",
        "gun",
        "recoil",
        "firearm",
        "shooter",
        "rifle",
        "pistol",
        "cameracontrol"
    }};
    for (const auto& kw : kClassKeywords) {
        if (contains_nocase(sv, kw)) {
            return true;
        }
    }
    return false;
}

// ============================================================================
// 5. DYNAMIC FIELD & METHOD HOOK REGISTRY
// ============================================================================
enum class ZeroKind : uint8_t {
    Float32,
    Float64,
    Int32,
    Bool8,
    Vec2,
    Vec3
};

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
    const uint32_t limit = (count < 2048U) ? count : 2048U;
    for (uint32_t i = 0; i < limit; ++i) {
        const char* name = _dyld_get_image_name(i);
        if (name != nullptr && std::strstr(name, "UnityFramework") != nullptr) {
            return reinterpret_cast<uintptr_t>(_dyld_get_image_header(i));
        }
    }
    return (_dyld_image_count() > 0) ? reinterpret_cast<uintptr_t>(_dyld_get_image_header(0)) : 0;
}

static bool resolve_il2cpp_exports() noexcept {
    void* handle = dlopen(nullptr, RTLD_NOW);
    if (handle == nullptr) {
        return false;
    }

    #define RESOLVE_SYM(field, sym_name) \
        g_api.field = reinterpret_cast<decltype(g_api.field)>(dlsym(handle, sym_name))

    RESOLVE_SYM(domain_get,             "il2cpp_domain_get");
    RESOLVE_SYM(domain_get_assemblies,  "il2cpp_domain_get_assemblies");
    RESOLVE_SYM(assembly_get_image,     "il2cpp_assembly_get_image");
    RESOLVE_SYM(image_get_name,         "il2cpp_image_get_name");
    RESOLVE_SYM(image_get_class_count,  "il2cpp_image_get_class_count");
    RESOLVE_SYM(image_get_class,        "il2cpp_image_get_class");
    RESOLVE_SYM(class_get_name,         "il2cpp_class_get_name");
    RESOLVE_SYM(class_get_namespace,    "il2cpp_class_get_namespace");
    RESOLVE_SYM(class_get_methods,      "il2cpp_class_get_methods");
    RESOLVE_SYM(class_get_fields,       "il2cpp_class_get_fields");
    RESOLVE_SYM(method_get_name,        "il2cpp_method_get_name");
    RESOLVE_SYM(method_get_return_type, "il2cpp_method_get_return_type");
    RESOLVE_SYM(method_get_param_count, "il2cpp_method_get_param_count");
    RESOLVE_SYM(field_get_name,         "il2cpp_field_get_name");
    RESOLVE_SYM(field_get_flags,        "il2cpp_field_get_flags");
    RESOLVE_SYM(field_get_offset,       "il2cpp_field_get_offset");
    RESOLVE_SYM(field_get_type,         "il2cpp_field_get_type");
    RESOLVE_SYM(field_static_set_value, "il2cpp_field_static_set_value");
    RESOLVE_SYM(type_get_type,          "il2cpp_type_get_type");
    RESOLVE_SYM(type_get_name,          "il2cpp_type_get_name");
    RESOLVE_SYM(type_get_object,        "il2cpp_type_get_object");
    RESOLVE_SYM(class_get_type,         "il2cpp_class_get_type");
    RESOLVE_SYM(resolve_icall,          "il2cpp_resolve_icall");

    #undef RESOLVE_SYM

    return (g_api.domain_get != nullptr &&
            g_api.domain_get_assemblies != nullptr &&
            g_api.assembly_get_image != nullptr &&
            g_api.image_get_class_count != nullptr &&
            g_api.image_get_class != nullptr &&
            g_api.class_get_name != nullptr);
}

static void hook_recoil_method_info(MethodInfo* method) noexcept {
    if (method == nullptr || g_api.method_get_name == nullptr) {
        return;
    }
    const char* mname = g_api.method_get_name(method);
    if (!is_recoil_identifier(mname)) {
        return;
    }

    int ret_type_code = 0;
    const char* ret_type_name = nullptr;
    if (g_api.method_get_return_type != nullptr && g_api.type_get_type != nullptr) {
        const Il2CppType* rtype = g_api.method_get_return_type(method);
        if (rtype != nullptr) {
            ret_type_code = g_api.type_get_type(rtype);
            if (g_api.type_get_name != nullptr) {
                ret_type_name = g_api.type_get_name(rtype);
            }
        }
    }

    if (ret_type_code == 0x01) {
        method->methodPointer        = reinterpret_cast<Il2CppMethodPointer>(&stub_return_void);
        method->virtualMethodPointer = reinterpret_cast<Il2CppMethodPointer>(&stub_return_void);
        method->invoker_method       = &stub_invoker_zero;
    } else if (ret_type_code == IL2CPP_TYPE_R4 || ret_type_code == IL2CPP_TYPE_I4 || ret_type_code == IL2CPP_TYPE_BOOLEAN) {
        method->methodPointer        = reinterpret_cast<Il2CppMethodPointer>(&stub_return_zero_float);
        method->virtualMethodPointer = reinterpret_cast<Il2CppMethodPointer>(&stub_return_zero_float);
        method->invoker_method       = &stub_invoker_zero;
    } else if (ret_type_code == IL2CPP_TYPE_VALUETYPE && ret_type_name != nullptr &&
               (std::strstr(ret_type_name, "Vector2") != nullptr || std::strstr(ret_type_name, "Vector3") != nullptr)) {
        method->methodPointer        = reinterpret_cast<Il2CppMethodPointer>(&stub_return_zero_vec3);
        method->virtualMethodPointer = reinterpret_cast<Il2CppMethodPointer>(&stub_return_zero_vec3);
        method->invoker_method       = &stub_invoker_zero;
    }
}

static void inspect_and_register_class(Il2CppClass* klass) noexcept {
    if (klass == nullptr) {
        return;
    }
    const char* cname = g_api.class_get_name(klass);
    if (cname == nullptr) {
        return;
    }

    const bool class_matches = is_weapon_class_identifier(cname);

    if (g_api.class_get_methods != nullptr) {
        void* iter = nullptr;
        size_t guard = 0;
        while (guard++ < 512) {
            const MethodInfo* m_const = g_api.class_get_methods(klass, &iter);
            if (m_const == nullptr) {
                break;
            }
            MethodInfo* m = const_cast<MethodInfo*>(m_const);
            hook_recoil_method_info(m);
        }
    }

    if (g_api.class_get_fields == nullptr || g_api.field_get_name == nullptr ||
        g_api.field_get_offset == nullptr || g_api.field_get_type == nullptr ||
        g_api.type_get_type == nullptr) {
        return;
    }

    TrackedClass tracked{};
    tracked.klass = klass;
    tracked.system_type_obj = nullptr;

    void* f_iter = nullptr;
    size_t f_guard = 0;
    while (f_guard++ < 512) {
        FieldInfo* field = g_api.class_get_fields(klass, &f_iter);
        if (field == nullptr) {
            break;
        }

        const char* fname = g_api.field_get_name(field);
        if (fname == nullptr) {
            continue;
        }

        const std::string_view fsv(fname, safe_cstr_len(fname, 256));
        const bool field_matches = is_recoil_identifier(fname) ||
            (class_matches && (contains_nocase(fsv, "kick")   ||
                               contains_nocase(fsv, "spread") ||
                               contains_nocase(fsv, "sway")   ||
                               contains_nocase(fsv, "shake")  ||
                               contains_nocase(fsv, "bloom")));

        if (!field_matches) {
            continue;
        }

        const int flags = (g_api.field_get_flags != nullptr) ? g_api.field_get_flags(field) : 0;
        if ((flags & FIELD_ATTRIBUTE_LITERAL) != 0) {
            continue;
        }

        const bool is_static = (flags & FIELD_ATTRIBUTE_STATIC) != 0;
        const size_t offset  = g_api.field_get_offset(field);
        const Il2CppType* ftype = g_api.field_get_type(field);
        if (ftype == nullptr) {
            continue;
        }

        const int tcode = g_api.type_get_type(ftype);
        ZeroKind kind = ZeroKind::Float32;
        bool supported = false;

        if (tcode == IL2CPP_TYPE_R4) {
            kind = ZeroKind::Float32;
            supported = true;
        } else if (tcode == IL2CPP_TYPE_R8) {
            kind = ZeroKind::Float64;
            supported = true;
        } else if (tcode == IL2CPP_TYPE_I4) {
            kind = ZeroKind::Int32;
            supported = true;
        } else if (tcode == IL2CPP_TYPE_BOOLEAN) {
            kind = ZeroKind::Bool8;
            supported = true;
        } else if (tcode == IL2CPP_TYPE_VALUETYPE && g_api.type_get_name != nullptr) {
            const char* tname = g_api.type_get_name(ftype);
            if (tname != nullptr) {
                if (std::strstr(tname, "Vector2") != nullptr) {
                    kind = ZeroKind::Vec2;
                    supported = true;
                } else if (std::strstr(tname, "Vector3") != nullptr) {
                    kind = ZeroKind::Vec3;
                    supported = true;
                }
            }
        }

        if (!supported) {
            continue;
        }

        if (is_static && g_api.field_static_set_value != nullptr) {
            Vector3f zero_buf{0.0f, 0.0f, 0.0f};
            g_api.field_static_set_value(field, &zero_buf);
        }

        tracked.fields.push_back(TrackedField{field, offset, kind, is_static});
    }

    if (!tracked.fields.empty()) {
        if (g_api.class_get_type != nullptr && g_api.type_get_object != nullptr) {
            const Il2CppType* ctype = g_api.class_get_type(klass);
            if (ctype != nullptr) {
                tracked.system_type_obj = g_api.type_get_object(ctype);
            }
        }
        g_tracked_classes.push_back(tracked);
    }
}

// ============================================================================
// 6. RUNTIME INSTANCE ZEROING LOOP
// ============================================================================
using FindObjectsOfTypeFn       = Il2CppArrayLayout* (*)(Il2CppObject* systemType, bool includeInactive);
using FindObjectsOfTypeLegacyFn = Il2CppArrayLayout* (*)(Il2CppObject* systemType);

static void zero_instance_fields(void* instance_ptr, const std::vector<TrackedField>& fields) noexcept {
    if (instance_ptr == nullptr) {
        return;
    }
    uint8_t* base = reinterpret_cast<uint8_t*>(instance_ptr);

    for (const auto& tf : fields) {
        if (tf.is_static) {
            if (g_api.field_static_set_value != nullptr) {
                Vector3f z{0.0f, 0.0f, 0.0f};
                g_api.field_static_set_value(tf.field, &z);
            }
            continue;
        }
        if (tf.offset < sizeof(void*) * 2 || tf.offset > 0x4000) {
            continue;
        }

        uint8_t* field_addr = base + tf.offset;
        switch (tf.kind) {
            case ZeroKind::Float32: {
                float z = 0.0f;
                std::memcpy(field_addr, &z, sizeof(float));
                break;
            }
            case ZeroKind::Float64: {
                double z = 0.0;
                std::memcpy(field_addr, &z, sizeof(double));
                break;
            }
            case ZeroKind::Int32: {
                int32_t z = 0;
                std::memcpy(field_addr, &z, sizeof(int32_t));
                break;
            }
            case ZeroKind::Bool8: {
                uint8_t z = 0;
                std::memcpy(field_addr, &z, sizeof(uint8_t));
                break;
            }
            case ZeroKind::Vec2: {
                Vector2f z{0.0f, 0.0f};
                std::memcpy(field_addr, &z, sizeof(Vector2f));
                break;
            }
            case ZeroKind::Vec3: {
                Vector3f z{0.0f, 0.0f, 0.0f};
                std::memcpy(field_addr, &z, sizeof(Vector3f));
                break;
            }
        }
    }
}

static void* norecoil_worker_thread(void* /*arg*/) noexcept {
    uintptr_t uf_base = 0;
    for (int retry = 0; retry < 600; ++retry) {
        uf_base = find_unity_framework_base();
        if (uf_base != 0 && resolve_il2cpp_exports()) {
            break;
        }
        usleep(50000);
    }

    if (uf_base == 0) {
        return nullptr;
    }

    for (const auto& sp : kStaticRvaPatches) {
        try_static_rva_patch(uf_base, sp);
    }

    Il2CppDomain* domain = nullptr;
    for (int retry = 0; retry < 600; ++retry) {
        if (g_api.domain_get != nullptr) {
            domain = g_api.domain_get();
            if (domain != nullptr) {
                size_t asm_count = 0;
                const Il2CppAssembly** asms = g_api.domain_get_assemblies(domain, &asm_count);
                if (asms != nullptr && asm_count > 0) {
                    break;
                }
            }
        }
        usleep(50000);
    }

    if (domain == nullptr) {
        return nullptr;
    }

    sleep(2);

    size_t assembly_count = 0;
    const Il2CppAssembly** assemblies = g_api.domain_get_assemblies(domain, &assembly_count);
    const size_t capped_assemblies = (assembly_count < 256) ? assembly_count : 256;

    for (size_t i = 0; i < capped_assemblies; ++i) {
        const Il2CppAssembly* assembly = assemblies[i];
        if (assembly == nullptr) {
            continue;
        }
        const Il2CppImage* image = g_api.assembly_get_image(assembly);
        if (image == nullptr) {
            continue;
        }

        const char* img_name = (g_api.image_get_name != nullptr) ? g_api.image_get_name(image) : "";
        if (img_name != nullptr) {
            if (std::strncmp(img_name, "mscorlib", 8) == 0 ||
                std::strncmp(img_name, "System", 6) == 0 ||
                std::strncmp(img_name, "Mono.", 5) == 0 ||
                std::strncmp(img_name, "UnityEngine.", 12) == 0 ||
                std::strncmp(img_name, "TMPro", 5) == 0) {
                continue;
            }
        }

        const size_t class_count = g_api.image_get_class_count(image);
        const size_t capped_classes = (class_count < 16384) ? class_count : 16384;
        for (size_t c = 0; c < capped_classes; ++c) {
            Il2CppClass* klass = g_api.image_get_class(image, c);
            inspect_and_register_class(klass);
        }
    }

    FindObjectsOfTypeFn find_objs_v2 = nullptr;
    FindObjectsOfTypeLegacyFn find_objs_v1 = nullptr;

    if (g_api.resolve_icall != nullptr) {
        find_objs_v2 = reinterpret_cast<FindObjectsOfTypeFn>(
            g_api.resolve_icall("UnityEngine.Object::FindObjectsOfType(System.Type,System.Boolean)")
        );
        if (find_objs_v2 == nullptr) {
            find_objs_v1 = reinterpret_cast<FindObjectsOfTypeLegacyFn>(
                g_api.resolve_icall("UnityEngine.Resources::FindObjectsOfTypeAll(System.Type)")
            );
        }
    }

    while (true) {
        for (const auto& tc : g_tracked_classes) {
            zero_instance_fields(nullptr, tc.fields);

            if (tc.system_type_obj == nullptr) {
                continue;
            }

            Il2CppArrayLayout* arr = nullptr;
            if (find_objs_v2 != nullptr) {
                arr = find_objs_v2(tc.system_type_obj, false);
            } else if (find_objs_v1 != nullptr) {
                arr = find_objs_v1(tc.system_type_obj);
            }

            if (arr != nullptr && arr->max_length > 0 && arr->max_length < 512) {
                for (uintptr_t idx = 0; idx < arr->max_length; ++idx) {
                    void* obj = arr->vector[idx];
                    if (obj != nullptr) {
                        zero_instance_fields(obj, tc.fields);
                    }
                }
            }
        }
        usleep(100000);
    }

    return nullptr;
}

} // namespace cf_norecoil

// ============================================================================
// 7. AUTO-START ENTRYPOINT
// ============================================================================
__attribute__((constructor))
static void counter_flame_norecoil_entry() {
    pthread_t tid{};
    pthread_attr_t attr{};
    if (pthread_attr_init(&attr) == 0) {
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        pthread_create(&tid, &attr, &cf_norecoil::norecoil_worker_thread, nullptr);
        pthread_attr_destroy(&attr);
    }
}
