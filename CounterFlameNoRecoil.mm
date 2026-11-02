// File: TaterCheat.mm
// Architecture: ARM64 iOS (UnityFramework IL2CPP)
// Dependencies: None (Zero-Substrate native Mach vm_protect inline hook & patcher)
// Compile: clang++ -dynamiclib -arch arm64 -fobjc-arc -O2 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics TaterCheat.mm -o TaterCheat.dylib

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <sys/mman.h>
#import <libkern/OSCacheControl.h>
#import <pthread.h>
#import <stdint.h>
#import <string.h>
#import <unistd.h>

namespace Offsets {
    // Replace these RVAs with the values from your Counter Flame dump.cs
    constexpr uintptr_t Weapon_ApplyRecoil  = 0x18A4B20; // void ApplyRecoil(float vert, float horiz)
    constexpr uintptr_t Weapon_GetSpread    = 0x18A4C90; // float GetSpread()
    constexpr uintptr_t Player_Update       = 0x1642110; // void Update()
    constexpr uintptr_t Material_SetInt     = 0x24FB490; // void SetInt(Il2CppString* name, int value)
    constexpr uintptr_t Material_SetColor   = 0x24FB120; // void SetColor(Il2CppString* name, Color value)
    constexpr uintptr_t Il2Cpp_StringNew    = 0x1104820; // Il2CppString* il2cpp_string_new(const char* str)
    constexpr uintptr_t Player_MatField     = 0x48;      // Field offset of cached Material* inside PlayerController
}

struct Color {
    float r, g, b, a;
};

static bool g_Wallhack = true;
static bool g_NoRecoil = true;
static uintptr_t g_UnityBase = 0;

static uintptr_t GetFrameworkBase(const char* frameworkName) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char* name = _dyld_get_image_name(i);
        if (name && strstr(name, frameworkName)) {
            return (uintptr_t)_dyld_get_image_header(i);
        }
    }
    return (uintptr_t)_dyld_get_image_header(0);
}

static uintptr_t GetAbsoluteAddress(uintptr_t rva) {
    if (g_UnityBase == 0) {
        g_UnityBase = GetFrameworkBase("UnityFramework");
    }
    return g_UnityBase + rva;
}

static bool WriteMemory(uintptr_t address, const void* buffer, size_t size) {
    if (!address || !buffer || size == 0) return false;
    mach_port_t self = mach_task_self();
    vm_address_t pageStart = address & ~(vm_page_size - 1);
    vm_size_t pageSize = ((address + size - pageStart + vm_page_size - 1) / vm_page_size) * vm_page_size;

    kern_return_t kr = vm_protect(self, pageStart, pageSize, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) return false;

    memcpy((void*)address, buffer, size);

    vm_protect(self, pageStart, pageSize, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    sys_icache_invalidate((void*)address, size);
    return true;
}

// Native 16-byte ARM64 Inline Hook (LDR X16, #8 ; BR X16 ; .quad target)
static bool InlineHook64(uintptr_t targetAddr, void* replaceFunc, void** origFuncOut) {
    if (!targetAddr || !replaceFunc) return false;

    if (origFuncOut) {
        void* trampoline = mmap(nullptr, vm_page_size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        if (trampoline == MAP_FAILED) return false;

        // Copy original 16 bytes (4 ARM64 instructions)
        memcpy(trampoline, (const void*)targetAddr, 16);

        // Append jump back to targetAddr + 16
        uint32_t* jmpBack = (uint32_t*)((uintptr_t)trampoline + 16);
        jmpBack[0] = 0x58000050; // LDR X16, #8
        jmpBack[1] = 0xD61F0200; // BR X16
        *(uint64_t*)&jmpBack[2] = (uint64_t)(targetAddr + 16);

        mprotect(trampoline, vm_page_size, PROT_READ | PROT_EXEC);
        sys_icache_invalidate(trampoline, 32);
        *origFuncOut = trampoline;
    }

    uint8_t patch[16];
    *(uint32_t*)&patch[0] = 0x58000050; // LDR X16, #8
    *(uint32_t*)&patch[4] = 0xD61F0200; // BR X16
    *(uint64_t*)&patch[8] = (uint64_t)replaceFunc;

    return WriteMemory(targetAddr, patch, sizeof(patch));
}

typedef void* (*il2cpp_string_new_t)(const char* str);
typedef void  (*Material_SetInt_t)(void* mat, void* propName, int val);
typedef void  (*Material_SetColor_t)(void* mat, void* propName, Color col);

static il2cpp_string_new_t fn_StringNew   = nullptr;
static Material_SetInt_t   fn_MatSetInt   = nullptr;
static Material_SetColor_t fn_MatSetColor = nullptr;

// Original bytes backup for live toggle on No-Recoil / Spread
static uint8_t g_OrigRecoilBytes[4] = {0};
static uint8_t g_OrigSpreadBytes[8] = {0};

static void SetRecoilPatch(bool enable) {
    uintptr_t recoilAddr = GetAbsoluteAddress(Offsets::Weapon_ApplyRecoil);
    uintptr_t spreadAddr = GetAbsoluteAddress(Offsets::Weapon_GetSpread);

    if (enable) {
        // ARM64: RET (0xD65F03C0) -> immediately returns from ApplyRecoil
        const uint8_t retInst[4] = { 0xC0, 0x03, 0x5F, 0xD6 };
        // ARM64: FMOV S0, WZR ; RET -> returns 0.0f from GetSpread
        const uint8_t retZeroFloat[8] = { 0xE0, 0x03, 0x27, 0x1E, 0xC0, 0x03, 0x5F, 0xD6 };

        WriteMemory(recoilAddr, retInst, sizeof(retInst));
        WriteMemory(spreadAddr, retZeroFloat, sizeof(retZeroFloat));
    } else {
        WriteMemory(recoilAddr, g_OrigRecoilBytes, sizeof(g_OrigRecoilBytes));
        WriteMemory(spreadAddr, g_OrigSpreadBytes, sizeof(g_OrigSpreadBytes));
    }
}

static void (*orig_PlayerUpdate)(void* instance) = nullptr;
static void hook_PlayerUpdate(void* instance) {
    if (orig_PlayerUpdate) {
        orig_PlayerUpdate(instance);
    }
    if (!instance || !fn_StringNew || !fn_MatSetInt || !fn_MatSetColor) return;

    void* playerMat = *(void**)((uintptr_t)instance + Offsets::Player_MatField);
    if (!playerMat) return;

    void* propZTest  = fn_StringNew("_ZTest");
    void* propZWrite = fn_StringNew("_ZWrite");
    void* propColor  = fn_StringNew("_Color");

    if (g_Wallhack) {
        fn_MatSetInt(playerMat, propZTest, 8);  // CompareFunction.Always (render through walls)
        fn_MatSetInt(playerMat, propZWrite, 0); // Disable depth write
        Color chamsRed = { 1.0f, 0.12f, 0.12f, 1.0f };
        fn_MatSetColor(playerMat, propColor, chamsRed);
    } else {
        fn_MatSetInt(playerMat, propZTest, 4);  // CompareFunction.LessEqual (normal depth)
        fn_MatSetInt(playerMat, propZWrite, 1);
    }
}

@interface TaterHUD : UIView
@end

@implementation TaterHUD

+ (void)presentOverlay {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *targetWindow = nil;
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in scene.windows) {
                    if (w.isKeyWindow) { targetWindow = w; break; }
                }
            }
        }
        if (!targetWindow) {
            targetWindow = [UIApplication sharedApplication].windows.firstObject;
        }
        if (!targetWindow) return;

        TaterHUD *hud = [[TaterHUD alloc] initWithFrame:CGRectMake(36, 76, 184, 112)];
        [targetWindow addSubview:hud];
    });
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.86];
        self.layer.cornerRadius = 10.0;
        self.layer.borderWidth = 1.5;
        self.layer.borderColor = [UIColor systemRedColor].CGColor;

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onDrag:)];
        [self addGestureRecognizer:pan];

        UILabel *header = [[UILabel alloc] initWithFrame:CGRectMake(8, 6, 168, 20)];
        header.text = @"KANHA // CF-MOD";
        header.textColor = [UIColor whiteColor];
        header.font = [UIFont boldSystemFontOfSize:12];
        header.textAlignment = NSTextAlignmentCenter;
        [self addSubview:header];

        UIButton *wallBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        wallBtn.frame = CGRectMake(10, 32, 164, 32);
        wallBtn.layer.cornerRadius = 6.0;
        wallBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.55 blue:0.20 alpha:1.0];
        wallBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        [wallBtn setTitle:@"Wallhack (Chams): ON" forState:UIControlStateNormal];
        [wallBtn addTarget:self action:@selector(onToggleWall:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:wallBtn];

        UIButton *recoilBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        recoilBtn.frame = CGRectMake(10, 70, 164, 32);
        recoilBtn.layer.cornerRadius = 6.0;
        recoilBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.55 blue:0.20 alpha:1.0];
        recoilBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        [recoilBtn setTitle:@"No Recoil/Spread: ON" forState:UIControlStateNormal];
        [recoilBtn addTarget:self action:@selector(onToggleRecoil:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:recoilBtn];
    }
    return self;
}

- (void)onDrag:(UIPanGestureRecognizer *)pan {
    CGPoint delta = [pan translationInView:self.superview];
    self.center = CGPointMake(self.center.x + delta.x, self.center.y + delta.y);
    [pan setTranslation:CGPointZero inView:self.superview];
}

- (void)onToggleWall:(UIButton *)btn {
    g_Wallhack = !g_Wallhack;
    [btn setTitle:(g_Wallhack ? @"Wallhack (Chams): ON" : @"Wallhack (Chams): OFF") forState:UIControlStateNormal];
    btn.backgroundColor = g_Wallhack ? [UIColor colorWithRed:0.15 green:0.55 blue:0.20 alpha:1.0] : [UIColor darkGrayColor];
}

- (void)onToggleRecoil:(UIButton *)btn {
    g_NoRecoil = !g_NoRecoil;
    SetRecoilPatch(g_NoRecoil);
    [btn setTitle:(g_NoRecoil ? @"No Recoil/Spread: ON" : @"No Recoil/Spread: OFF") forState:UIControlStateNormal];
    btn.backgroundColor = g_NoRecoil ? [UIColor colorWithRed:0.15 green:0.55 blue:0.20 alpha:1.0] : [UIColor darkGrayColor];
}

@end

static void* BootstrapThread(void* unused) {
    while ((g_UnityBase = GetFrameworkBase("UnityFramework")) == 0) {
        usleep(200000);
    }
    sleep(4);

    fn_StringNew   = (il2cpp_string_new_t)GetAbsoluteAddress(Offsets::Il2Cpp_StringNew);
    fn_MatSetInt   = (Material_SetInt_t)GetAbsoluteAddress(Offsets::Material_SetInt);
    fn_MatSetColor = (Material_SetColor_t)GetAbsoluteAddress(Offsets::Material_SetColor);

    // Save original instructions before patching
    memcpy(g_OrigRecoilBytes, (const void*)GetAbsoluteAddress(Offsets::Weapon_ApplyRecoil), sizeof(g_OrigRecoilBytes));
    memcpy(g_OrigSpreadBytes, (const void*)GetAbsoluteAddress(Offsets::Weapon_GetSpread), sizeof(g_OrigSpreadBytes));

    SetRecoilPatch(g_NoRecoil);
    InlineHook64(GetAbsoluteAddress(Offsets::Player_Update), (void*)&hook_PlayerUpdate, (void**)&orig_PlayerUpdate);

    [TaterHUD presentOverlay];
    return nullptr;
}

__attribute__((constructor))
static void TaterEntry() {
    pthread_t tid;
    pthread_create(&tid, nullptr, BootstrapThread, nullptr);
}
