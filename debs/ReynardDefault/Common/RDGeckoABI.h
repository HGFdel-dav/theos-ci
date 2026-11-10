#ifndef RD_GECKO_ABI_H
#define RD_GECKO_ABI_H
#include <stddef.h>
#include <stdint.h>

/* GeckoView's bundled XUL slice is plain ARM64: its XPCOM function pointers
   are not arm64e-signed. GetSpec is nsIURI's first method after the three
   nsISupports slots. Calling it as a C++ virtual from an arm64e tweak would
   add PAC authentication the foreign entry does not carry, so preserve the
   exact arm64 two-argument member-call ABI and use BLR. Keep this helper free
   of Foundation so the actual production call can be cross-assembled in CI. */
#define RD_GECKO_NS_IURI_GETSPEC_SLOT 3u
static inline int32_t RDGeckoCallUnsignedVTable3(void *object, void *argument) {
    if (!object || !argument) return (int32_t)0x80004003;
    void **vtable = *(void ***)object;
    if (!vtable || !vtable[RD_GECKO_NS_IURI_GETSPEC_SLOT]) return (int32_t)0x80004003;
#if defined(__aarch64__) || defined(__arm64__)
    register uintptr_t x0 __asm__("x0") = (uintptr_t)object;
    register uintptr_t x1 __asm__("x1") = (uintptr_t)argument;
    register uintptr_t x16 __asm__("x16") = (uintptr_t)vtable[RD_GECKO_NS_IURI_GETSPEC_SLOT];
    __asm__ volatile(
        "blr x16"
        : "+r"(x0), "+r"(x1), "+r"(x16)
        :
        : "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9",
          "x10", "x11", "x12", "x13", "x14", "x15", "x17", "x30",
          "memory", "cc");
    return (int32_t)(intptr_t)x0;
#else
    typedef int32_t (*RDGeckoGetSpecFunction)(void *, void *);
    return ((RDGeckoGetSpecFunction)vtable[RD_GECKO_NS_IURI_GETSPEC_SLOT])(object, argument);
#endif
}
#endif
