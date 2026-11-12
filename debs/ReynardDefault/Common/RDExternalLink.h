#ifndef RD_EXTERNAL_LINK_H
#define RD_EXTERNAL_LINK_H
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <substrate.h>
#import <atomic>
#import <cstdlib>
#import <cstring>
#import "Common/Common.h"
#import "RDLinkPolicy.h"
#import "RDGeckoABI.h"

#define RD_EXTERNAL_XUL_UUID_BYTES {0x4c,0x4c,0x44,0x29,0x55,0x55,0x31,0x44,0xa1,0x13,0x2f,0x42,0xdb,0x9c,0xfa,0x90}
#define RD_EXTERNAL_RECV_LOAD_URI_EXTERNAL 0x52201d0ULL
#define RD_EXTERNAL_MAYBEDISCARDED_CONTEXT_OFFSET 8u
#define RD_EXTERNAL_CONTEXT_DISCARDED_OFFSET 0x54cu
#define RD_EXTERNAL_CONTEXT_DISCARDED_BIT (1u<<2)
struct RDExternalMaybeDiscardedContext { uint64_t id; void *context; };
static_assert(sizeof(RDExternalMaybeDiscardedContext)==16,"MaybeDiscarded ABI changed");
#define RD_EXTERNAL_GET_PARENT 0x5d1b678ULL
static uintptr_t gRDExternalGetParent = 0;

/* IPCResult is a one-byte value object in Firefox's ProtocolUtils.h.  The
   wrapper types NotNull<T*> and const MaybeDiscarded<T>& have zero-overhead
   pointer representations at this ABI boundary. */
struct RDExternalIPCResult { bool success; };
static_assert(sizeof(RDExternalIPCResult) == 1, "IPCResult ABI changed");
typedef RDExternalIPCResult (*RDExternalRecvFn)(
    void *, void *, void *, void *, void *, bool, bool, bool);

struct RDExternalCString { char *data; uint32_t length; uint16_t dataFlags; uint16_t classFlags; };
struct RDExternalAutoCString { RDExternalCString base; uint32_t inlineCapacity; char storage[64]; };
struct RDExternalStringBufferHeader { std::atomic<uint32_t> refCount; uint32_t storageSize; };
#define RD_EXT_STRINGBUFFER 0x04u
#define RD_EXT_OWNED 0x08u
#define RD_EXT_INLINE 0x10u
#define RD_EXT_INLINE_CLASS 0x01u

static RDExternalRecvFn gRDExternalOriginal = nullptr;
static std::atomic_bool gRDExternalInstalled{false};
static std::atomic_bool gRDExternalRejected{false};
static std::atomic_bool gRDExternalImageCallback{false};
static std::atomic_uint gRDExternalAttempts{0};

static void RDExternalReleaseCString(RDExternalCString *value) {
    if (!value || !value->data || !(value->dataFlags & RD_EXT_OWNED)) return;
    if (value->dataFlags & RD_EXT_STRINGBUFFER) {
        RDExternalStringBufferHeader *header =
            reinterpret_cast<RDExternalStringBufferHeader *>(value->data) - 1;
        uint32_t old = header->refCount.fetch_sub(1, std::memory_order_release);
        if (old == 1) { (void)header->refCount.load(std::memory_order_acquire); free(header); }
    } else free(value->data);
}
static NSString *RDExternalSpec(void *uri) {
    if (!uri) return nil;
    RDExternalAutoCString storage;
    RDExternalCString &value = storage.base;
    value.data = storage.storage; value.length = 0; value.dataFlags = 0x11;
    value.classFlags = RD_EXT_INLINE_CLASS; storage.inlineCapacity = 63; storage.storage[0] = 0;
    int32_t rv = RDGeckoCallUnsignedVTable3(uri, &value);
    BOOL inlineStorage = value.data == storage.storage;
    BOOL inlineFlag = (value.dataFlags & RD_EXT_INLINE) != 0;
    NSString *result = nil;
    if (rv == 0 && value.data && value.length < RD_URL_CAP && inlineStorage == inlineFlag)
        result = [[NSString alloc] initWithBytes:value.data length:value.length encoding:NSUTF8StringEncoding];
    RDExternalReleaseCString(&value);
    return result;
}
static BOOL RDExternalInternalScheme(NSString *scheme) {
    static NSSet *set; static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSSet setWithArray:@[
        @"http", @"https", @"about", @"data", @"blob", @"javascript",
        @"moz-extension", @"jar", @"view-source", @"file", @"resource",
        @"wyciwyg", @"ws", @"wss", @"ftp", @"intent", @"reynard",
        @"chrome", @"chrome-extension"]]; });
    return [set containsObject:scheme.lowercaseString];
}
static NSURL *RDExternalURL(NSString *spec) {
    if (!spec.length || spec.length >= RD_URL_CAP ||
        [spec rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound ||
        [spec rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound) return nil;
    char normalized[RD_URL_CAP + 2];
    if (!RDNormalizeAppURL(spec.UTF8String, normalized, sizeof(normalized))) return nil;
    NSString *value = [NSString stringWithUTF8String:normalized];
    NSURLComponents *parts = [NSURLComponents componentsWithString:value];
    if (!parts.scheme.length || RDExternalInternalScheme(parts.scheme)) return nil;
    return parts.URL;
}
static BOOL RDExternalOpen(NSURL *url) {
    if (!url || ![NSThread isMainThread] ||
        [UIApplication sharedApplication].applicationState != UIApplicationStateActive) return NO;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    BOOL accepted = [[UIApplication sharedApplication] openURL:url];
#pragma clang diagnostic pop
    RDLog(@"external IPC open scheme=%@ accepted=%d", url.scheme, accepted);
    return accepted;
}
static_assert(sizeof(RDMaybeDiscardedContext)==16,
              "MaybeDiscarded<BrowsingContext> ABI changed");
static BOOL RDExternalTopLevel(void *maybeContext) {
    if (!gRDExternalGetParent) return NO;
    uint64_t id=0; uintptr_t context=0;
    if (!RDUnwrapMaybeDiscardedContext(maybeContext,&id,&context)) return NO;
    (void)id;
    uint16_t state=0;
    memcpy(&state,(const uint8_t *)context+RD_EXTERNAL_CONTEXT_DISCARDED_OFFSET,sizeof(state));
    if (state & RD_EXTERNAL_CONTEXT_DISCARDED_BIT) return NO;
    return RDGeckoCallUnsignedMethod0((void *)context,gRDExternalGetParent)==NULL;
}
static RDExternalIPCResult RDExternalHook(void *self, void *uri, void *principal,
    void *redirectPrincipal, void *browsingContext, bool externallyTriggered,
    bool userGesture, bool newWindowTarget) {
    if (!gRDExternalOriginal) return (RDExternalIPCResult){false};
    NSString *spec = RDExternalSpec(uri);
    NSURL *url = RDExternalURL(spec);
    NSString *bundle = [NSBundle mainBundle].bundleIdentifier;
    BOOL eligible = [bundle isEqualToString:@"com.minh-ton.Reynard"] && RDReadBoolPref(kEnabledKey, YES) &&
        RDReadBoolPref(kHandoffKey, YES) && userGesture && !externallyTriggered &&
        [NSThread isMainThread] && [UIApplication sharedApplication].applicationState == UIApplicationStateActive &&
        RDExternalTopLevel(browsingContext) && url;
    RDLog(@"external hook scheme=%@ gesture=%d ext=%d top=%d state=%ld eligible=%d",
          url.scheme ?: spec, userGesture, externallyTriggered, RDExternalTopLevel(browsingContext),
          (long)[UIApplication sharedApplication].applicationState, eligible);
    if (!eligible)
        return gRDExternalOriginal(self, uri, principal, redirectPrincipal, browsingContext,
                                    externallyTriggered, userGesture, newWindowTarget);
    if (RDExternalOpen(url)) return (RDExternalIPCResult){true};
    return gRDExternalOriginal(self, uri, principal, redirectPrincipal, browsingContext,
                                externallyTriggered, userGesture, newWindowTarget);
}
static BOOL RDExternalHeaderMatches(const struct mach_header_64 *header) {
    if (!header || header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64) return NO;
    const uint8_t expectedUUID[16] = RD_EXTERNAL_XUL_UUID_BYTES;
    const uint8_t *cursor = (const uint8_t *)(header + 1); uint32_t used = 0; uint64_t textSize = 0; BOOL uuid = NO;
    for (uint32_t i=0; i<header->ncmds; ++i) {
        const struct load_command *lc=(const struct load_command *)cursor;
        if (lc->cmdsize < sizeof(*lc) || used > header->sizeofcmds || lc->cmdsize > header->sizeofcmds-used) return NO;
        used += lc->cmdsize;
        if (lc->cmd == LC_UUID && lc->cmdsize >= sizeof(struct uuid_command)) uuid = memcmp(((const struct uuid_command *)lc)->uuid, expectedUUID, 16) == 0;
        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *seg=(const struct segment_command_64 *)lc;
            if (!strncmp(seg->segname, "__TEXT", 16) && seg->vmaddr == 0) textSize=seg->vmsize;
        }
        cursor += lc->cmdsize;
    }
    uint64_t end=RD_EXTERNAL_RECV_LOAD_URI_EXTERNAL+24;
    if (end<RD_EXTERNAL_GET_PARENT+16) end=RD_EXTERNAL_GET_PARENT+16;
    return uuid && textSize > end;
}
static void RDExternalTryInstall(void);
static void RDExternalImageAdded(const struct mach_header *header, intptr_t slide) {
    (void)header; (void)slide; dispatch_async(dispatch_get_main_queue(), ^{ RDExternalTryInstall(); });
}
static void RDExternalTryInstall(void) {
    if (gRDExternalInstalled.load(std::memory_order_acquire) || gRDExternalRejected.load(std::memory_order_acquire) || ![NSThread isMainThread]) return;
    if (gRDExternalAttempts.fetch_add(1, std::memory_order_relaxed) >= 100) return;
    for (uint32_t i=0; i<_dyld_image_count(); ++i) {
        const char *name=_dyld_get_image_name(i); if (!name || !strstr(name, "/Frameworks/XUL")) continue;
        const struct mach_header_64 *header=(const struct mach_header_64 *)_dyld_get_image_header(i);
        RDLog(@"external hook XUL found");
        if (!RDExternalHeaderMatches(header)) { gRDExternalRejected.store(true, std::memory_order_release); RDLog(@"external IPC XUL identity mismatch"); return; }
        uintptr_t address=(uintptr_t)_dyld_get_image_vmaddr_slide(i)+RD_EXTERNAL_RECV_LOAD_URI_EXTERNAL;
        uintptr_t parent=(uintptr_t)_dyld_get_image_vmaddr_slide(i)+RD_EXTERNAL_GET_PARENT;
        const uint32_t expected[6]={0xd101c3ff,0xa90267fa,0xa9035ff8,0xa90457f6,0xa9054ff4,0xa9067bfd};
        const uint32_t expectedParent[4]={0xf9426008,0xb4000068,0xf940f900,0xd65f03c0};
        if (memcmp((const void *)address, expected, sizeof(expected)) != 0 ||
            memcmp((const void *)parent, expectedParent, sizeof(expectedParent)) != 0) {
            gRDExternalRejected.store(true, std::memory_order_release); RDLog(@"external IPC prologue mismatch"); return;
        }
        gRDExternalGetParent=parent;
        MSHookFunction((void *)address, (void *)&RDExternalHook, (void **)&gRDExternalOriginal);
        if (gRDExternalOriginal) { gRDExternalInstalled.store(true, std::memory_order_release); RDLog(@"external IPC hook installed"); }
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ RDExternalTryInstall(); });
}
static void RDInstallExternalLinkHook(void) {
    if (!gRDExternalImageCallback.exchange(true, std::memory_order_acq_rel)) _dyld_register_func_for_add_image(&RDExternalImageAdded);
    if ([NSThread isMainThread]) RDExternalTryInstall(); else dispatch_async(dispatch_get_main_queue(), ^{ RDExternalTryInstall(); });
}
#endif
