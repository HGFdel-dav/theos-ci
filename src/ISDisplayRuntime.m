/*
 * ISDisplayRuntime.m -- Insulation "sunlight dimming" output-layer adapter.
 *
 * Scope (locked by the user, 2026-11-19):
 *   Only the extra percentage cap that the thermal path pushes into
 *   BackLightCCSingle -setBrightnessKey:value: is intercepted.
 *   MaxBrightness / BrightnessWeakCap are percentage caps, NOT slider
 *   brightness, NOT nits, NOT backlight power. Forwarding 100 means
 *   "no additional percentage ceiling on this path"; it does not lock the
 *   panel at full brightness and it never touches the user's slider.
 *
 * Hard rules enforced here:
 *   - one hook only: setBrightnessKey:value: (v28@0:8@16i24)
 *   - only exact BackLightCCSingle instances, only the two known keys
 *   - only 1..99 are rewritten, and only while the existing
 *     "prevent thermal dimming" switch is on
 *   - 0 / negative / 100 / >100 / INT_MIN / INT_MAX / unknown key pass through
 *   - never sends 0, never rewrites the user brightness slider
 *   - no plist writes, no process kill, no CFBoolean / GOT patching
 *   - logs are bounded and main-thread only
 */

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#import <pthread.h>
#import <stdatomic.h>
#import <os/log.h>
#import <dispatch/dispatch.h>
#import <ptrauth.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/sysctl.h>
#include "ISDisplayPolicy.h"

/* ---- symbols resolved from the rh5 core (T export, verified via nm) ------- */
#define ISD_ENABLED_SYMBOL "InsulationThermalDimmingBypassActive"
#define ISD_HOOKER_SYMBOL  "MSHookMessageEx"

/* Canonical UUIDs (dashes) -- kept next to the byte arrays for auditability:
 *   daemon : 32752d2d-270d-378c-b50f-613a45261357
 *   core   : b05c6dcc-1c2f-52c6-8c43-600f34f52d0e
 */
static const uint8_t ISDDaemonUUID[16] = {
    0x32,0x75,0x2d,0x2d,0x27,0x0d,0x37,0x8c,0xb5,0x0f,0x61,0x3a,0x45,0x26,0x13,0x57
};
static const uint8_t ISDCoreUUID[16] = {
    0xb0,0x5c,0x6d,0xcc,0x1c,0x2f,0x52,0xc6,0x8c,0x43,0x60,0x0f,0x34,0xf5,0x2d,0x0e
};

typedef bool (*ISDEnabledReader)(void);
typedef void (*ISDSetter)(id, SEL, id, int);
typedef void (*ISDHooker)(Class, SEL, IMP, IMP *);

static ISDSetter ISDOriginalSetter;
static ISDEnabledReader ISDReadEnabled;
static Class ISDControllerClass;
static _Atomic(bool) ISDReady;
static const char ISDAssociation;

/* Bounded logging: ISD_LOG_BUDGET total lines for the whole process lifetime. */
static _Atomic(unsigned) ISDLogRemaining = ISD_LOG_BUDGET;

@interface ISDisplayControllerState : NSObject {
@public
    ISDState policy;
    _Atomic(uint64_t) foreignEpoch[ISDKeyCount];
    uint64_t observedEpoch[ISDKeyCount];
}
@end
@implementation ISDisplayControllerState
- (instancetype)init {
    self = [super init];
    if (self) {
        for (int n = 0; n < ISDKeyCount; ++n)
            atomic_init(&foreignEpoch[n], 0);
    }
    return self;
}
@end

static bool ISDMainThread(void) { return pthread_main_np() != 0; }

/* Claim one log line; false when off the main thread or the budget is spent. */
static bool ISDClaimLog(void) {
    if (!ISDMainThread()) return false;
    unsigned left = atomic_load_explicit(&ISDLogRemaining, memory_order_relaxed);
    while (left > 0) {
        if (atomic_compare_exchange_weak_explicit(&ISDLogRemaining, &left,
                                                 left - 1,
                                                 memory_order_relaxed,
                                                 memory_order_relaxed))
            return true;
    }
    return false;
}

static const char *ISDKeyName(ISDKey key) {
    if (key == ISDMaximum) return "MaxBrightness";
    if (key == ISDWeak) return "BrightnessWeakCap";
    return "unknown";
}

/* Startup / state events: no numeric payload. */
static void ISDLogEvent(const char *event) {
    if (!ISDClaimLog()) return;
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT,
        "InsulationDisplay %{public}s", event);
}

/* Cap events: which key, what the system asked for, what we forwarded. */
static void ISDLogCap(const char *event, ISDKey key, int requested, int delivered) {
    if (!ISDClaimLog()) return;
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT,
        "InsulationDisplay %{public}s key=%{public}s system=%{public}d forwarded=%{public}d "
        "(percent cap, not measured luminance)",
        event, ISDKeyName(key), requested, delivered);
}

/* Read-only probe: three values in one line. */
static void ISDLogProbe(const char *event, int a, int b, int c) {
    if (!ISDClaimLog()) return;
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT,
        "InsulationDisplay %{public}s maxThermalPower=%{public}d "
        "minThermalPower=%{public}d expectsCPMSSupport=%{public}d",
        event, a, b, c);
}

static ISDKey ISDKeyForObject(id key) {
    if (![key isKindOfClass:[NSString class]]) return ISDUnknown;
    if ([(NSString *)key isEqualToString:@"MaxBrightness"]) return ISDMaximum;
    if ([(NSString *)key isEqualToString:@"BrightnessWeakCap"]) return ISDWeak;
    return ISDUnknown;
}

static bool ISDTarget(id object) {
    return atomic_load_explicit(&ISDReady, memory_order_acquire) &&
           object != nil && object_getClass(object) == ISDControllerClass;
}

/* Per-instance policy state, associated with the controller object itself. */
static ISDisplayControllerState *ISDStateFor(id object, bool create) {
    if (!ISDMainThread()) return nil;
    ISDisplayControllerState *state = objc_getAssociatedObject(object, &ISDAssociation);
    if (!state && create) {
        state = [ISDisplayControllerState new];
        objc_setAssociatedObject(object, &ISDAssociation, state, OBJC_ASSOCIATION_RETAIN);
    }
    if (state) {
        for (int n = 0; n < ISDKeyCount; ++n) {
            uint64_t epoch = atomic_load_explicit(&state->foreignEpoch[n], memory_order_acquire);
            if (state->observedEpoch[n] != epoch) {
                /* A setter ran off the main thread: our record for this key is stale.
                   Drop only this object's this-key slot; other keys/objects untouched. */
                memset(&state->policy.slots[n], 0, sizeof(state->policy.slots[n]));
                state->observedEpoch[n] = epoch;
            }
        }
    }
    return state;
}

/* ---- the single hook: -[BackLightCCSingle setBrightnessKey:value:] ------- */
static void ISDSetterReplacement(id object, SEL command, id key, int value) {
    ISDSetter original = ISDOriginalSetter;
    if (!original) return; /* ready is only set once the original IMP is saved */
    if (!ISDTarget(object)) { original(object, command, key, value); return; }

    ISDKey tag = ISDKeyForObject(key);
    if (!ISDValidKey(tag)) { original(object, command, key, value); return; }

    if (!ISDMainThread()) {
        /* Not ours to interpret off-thread: forward untouched, mark the record stale. */
        ISDisplayControllerState *state = objc_getAssociatedObject(object, &ISDAssociation);
        if (state)
            atomic_fetch_add_explicit(&state->foreignEpoch[tag], 1, memory_order_release);
        original(object, command, key, value);
        return;
    }

    @autoreleasepool {
        ISDisplayControllerState *state = ISDStateFor(object, true);
        if (!state) { original(object, command, key, value); return; }

        bool enabled = ISDReadEnabled ? ISDReadEnabled() : false;
        bool toggled = ISDNoteEnabled(&state->policy, enabled);
        bool restored = false;
        int restoredValue = 0;

        if (toggled) {
            /* Switch changed since this instance's last control cycle: re-send the
               saved system value (off) or re-apply the cap (on). Once per toggle. */
            ISDDecision r = ISDReconcile(&state->policy, tag, enabled);
            if (r.send) {
                ISDLogCap(enabled ? "enable-reconcile" : "restore", tag, r.requested, r.delivered);
                ISDOriginalSetter(object, command, key, r.delivered);
                restored = true;
                restoredValue = r.delivered;
            }
        }

        ISDDecision d = ISDRequest(&state->policy, tag, value, enabled);
        if (d.delivered != value)
            ISDLogCap("cap-adjust", tag, value, d.delivered);
        if (restored && restoredValue == d.delivered)
            return; /* same value already applied this cycle; do not send twice */
        /* Original called exactly once, object/key untouched, exact int32 ABI. */
        ISDOriginalSetter(object, command, key, d.delivered);
    }
}

#ifndef ISDISPLAY_NATIVE_TEST
/* ---- image / ABI verification ------------------------------------------- */
static bool ISDImageUUID(const struct mach_header *header, const uint8_t expected[16]) {
    if (!header || header->magic != MH_MAGIC_64) return false;
    const struct mach_header_64 *head = (const void *)header;
    if (head->ncmds > 256 || head->sizeofcmds > 65536) return false;
    const uint8_t *p = (const uint8_t *)(head + 1), *end = p + head->sizeofcmds;
    for (uint32_t i = 0; i < head->ncmds; ++i) {
        if ((size_t)(end - p) < sizeof(struct load_command)) return false;
        const struct load_command *load = (const void *)p;
        if (load->cmdsize < sizeof(*load) || load->cmdsize > (size_t)(end - p)) return false;
        if (load->cmd == LC_UUID && load->cmdsize == sizeof(struct uuid_command))
            return memcmp(((const struct uuid_command *)load)->uuid, expected, 16) == 0;
        p += load->cmdsize;
    }
    return false;
}

static const void *ISDFunctionAddress(const void *pointer) {
#if __has_feature(ptrauth_calls)
    return ptrauth_strip(pointer, ptrauth_key_function_pointer);
#else
    return pointer;
#endif
}

static bool ISDTypes(Method method, const char *exact, unsigned count) {
    return method && method_getNumberOfArguments(method) == count &&
           method_getTypeEncoding(method) && strcmp(method_getTypeEncoding(method), exact) == 0;
}

/* ---- read-only thermal plist probe -------------------------------------- */
/* Reads <board>-Info.plist, prints the three values the old patch touched.
   Opens O_RDONLY and uses an immutable property list: nothing is written. */
static void ISDProbeThermalPlist(void) {
    if (!ISDMainThread()) return;
    char model[64] = {0};
    size_t len = sizeof(model);
    if (sysctlbyname("hw.model", model, &len, NULL, 0) != 0 || len < 2) {
        ISDLogEvent("probe-unavailable-no-model");
        return;
    }
    char path[256];
    int n = snprintf(path, sizeof(path), "/System/Library/ThermalMonitor/%s-Info.plist", model);
    if (n <= 0 || (size_t)n >= sizeof(path)) { ISDLogEvent("probe-unavailable-path"); return; }

    int fd = open(path, O_RDONLY);
    if (fd < 0) { ISDLogEvent("probe-unavailable-open"); return; }
    size_t cap = 4u * 1024u * 1024u, used = 0;
    uint8_t *buffer = malloc(cap);
    if (!buffer) { close(fd); return; }
    for (;;) {
        if (used == cap) { used = 0; break; } /* refuse oversized file */
        ssize_t got = read(fd, buffer + used, cap - used);
        if (got < 0) { used = 0; break; }
        if (got == 0) break;
        used += (size_t)got;
    }
    close(fd);
    if (used == 0) { free(buffer); ISDLogEvent("probe-unavailable-read"); return; }

    CFDataRef data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, buffer,
                                                 (CFIndex)used, kCFAllocatorNull);
    if (!data) { free(buffer); return; }
    CFPropertyListRef plist = CFPropertyListCreateWithData(kCFAllocatorDefault, data,
                                                           kCFPropertyListImmutable, NULL, NULL);
    CFRelease(data);
    free(buffer);
    if (!plist) { ISDLogEvent("probe-unavailable-plist"); return; }

    int maxT = -1, minT = -1, cpm = -1;
    if (CFGetTypeID(plist) == CFDictionaryGetTypeID()) {
        CFDictionaryRef root = (CFDictionaryRef)plist;
        CFTypeRef section = CFDictionaryGetValue(root, CFSTR("backlightComponentControl"));
        if (section && CFGetTypeID(section) == CFDictionaryGetTypeID()) {
            CFDictionaryRef backlight = (CFDictionaryRef)section;
            CFTypeRef v;
            if ((v = CFDictionaryGetValue(backlight, CFSTR("maxThermalPower"))) &&
                CFGetTypeID(v) == CFNumberGetTypeID())
                CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &maxT);
            if ((v = CFDictionaryGetValue(backlight, CFSTR("minThermalPower"))) &&
                CFGetTypeID(v) == CFNumberGetTypeID())
                CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &minT);
            if ((v = CFDictionaryGetValue(backlight, CFSTR("expectsCPMSSupport"))) &&
                CFGetTypeID(v) == CFBooleanGetTypeID())
                cpm = CFBooleanGetValue((CFBooleanRef)v) ? 1 : 0;
        }
    }
    CFRelease(plist);
    ISDLogProbe("probe-thermal-plist", maxT, minT, cpm);
}

static void ISDInstall(void) {
    /* 1. process identity: thermalmonitord only. */
    if (strcmp(getprogname(), "thermalmonitord") != 0) return;
    /* 2. exact daemon build. */
    if (!ISDImageUUID(_dyld_get_image_header(0), ISDDaemonUUID)) {
        ISDLogEvent("inactive-wrong-daemon");
        return;
    }
    /* 3. core library + switch reader present. */
    ISDHooker hooker = (ISDHooker)dlsym(RTLD_DEFAULT, ISD_HOOKER_SYMBOL);
    ISDEnabledReader reader = (ISDEnabledReader)dlsym(RTLD_DEFAULT, ISD_ENABLED_SYMBOL);
    if (!hooker || !reader) { ISDLogEvent("inactive-missing-core"); return; }
    /* 4. exact core build, verified by LC_UUID of the image that owns the symbol. */
    Dl_info info = {0};
    if (!dladdr(ISDFunctionAddress((const void *)reader), &info) ||
        !info.dli_fbase || !ISDImageUUID((const void *)info.dli_fbase, ISDCoreUUID)) {
        ISDLogEvent("inactive-core-version");
        return;
    }
    /* 5. exact class hierarchy + exact method ABI. */
    Class single = objc_getClass("BackLightCCSingle");
    Class base = objc_getClass("BackLightCC");
    SEL setter = sel_registerName("setBrightnessKey:value:");
    Method ms = single ? class_getInstanceMethod(single, setter) : NULL;
    if (!single || !base || class_getSuperclass(single) != base ||
        !ISDTypes(ms, "v28@0:8@16i24", 4)) {
        ISDLogEvent("inactive-unsupported-ABI");
        return;
    }
    /* 6. nobody else already hooked this setter (would stack unpredictably). */
    Dl_info setterInfo = {0};
    if (!dladdr(ISDFunctionAddress((const void *)method_getImplementation(ms)), &setterInfo) ||
        setterInfo.dli_fbase != _dyld_get_image_header(0)) {
        ISDLogEvent("inactive-conflicting-hook");
        return;
    }

    ISDControllerClass = single;
    ISDReadEnabled = reader;
    hooker(single, setter, (IMP)ISDSetterReplacement, (IMP *)&ISDOriginalSetter);

    bool ready = ISDOriginalSetter != NULL;
    atomic_store_explicit(&ISDReady, ready, memory_order_release);
    ISDLogEvent(ready ? "ready" : "inactive-no-original");
    if (ready) ISDProbeThermalPlist();
}

__attribute__((constructor)) static void ISDStart(void) {
    /* Host classes and the rh5 core finish loading first: one deterministic
       attempt on the main queue, no retry loop, no polling thread. */
    dispatch_async(dispatch_get_main_queue(), ^{ ISDInstall(); });
}
#endif /* ISDISPLAY_NATIVE_TEST */
