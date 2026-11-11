#ifndef RD_NATIVE_LINK_H
#define RD_NATIVE_LINK_H
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <substrate.h>
#import <atomic>
#import <cstdlib>
#import <cstring>
#import "RDLinkPolicy.h"
#import "RDGeckoABI.h"
#import "RDProtocolCore.h"

#define RD_NS_ERROR_ABORT ((int32_t)0x80004004)
#define RD_HOOK_NOTIFICATION CFSTR("com.guacforlife.reynarddefault.external-link")
#define RD_PENDING_HANDOFF_KEY @"pendingExternalHandoff"
#define RD_REYNARD_HELPER_BUNDLE_ID @"com.minh-ton.Reynard.Helper"
#define RD_XUL_ON_LINK_CLICK 0x5d78310ULL
#define RD_XUL_GET_BROWSING_CONTEXT 0x5d65e54ULL
#define RD_XUL_GET_PARENT 0x5d1b678ULL
#define RD_GECKO_STRING_VOIDED 0x02u
#define RD_GECKO_STRING_STRINGBUFFER 0x04u
#define RD_GECKO_STRING_OWNED 0x08u
#define RD_GECKO_STRING_INLINE 0x10u
#define RD_GECKO_STRING_CLASS_INLINE 0x01u
static const uint8_t kRDExpectedXULUUID[16] = {
    0x4c,0x4c,0x44,0x29,0x55,0x55,0x31,0x44,
    0xa1,0x13,0x2f,0x42,0xdb,0x9c,0xfa,0x90
};
static const uint32_t kRDLinkPrologue[5] = {
    0xa9ba6ffc,0xa90167fa,0xa9025ff8,0xa90357f6,0xa9044ff4
};
static const uint32_t kRDContextPrologue[2] = {0xf9415000,0xd65f03c0};
static const uint32_t kRDParentPrologue[4] = {0xf9426008,0xb4000068,0xf940f900,0xd65f03c0};

struct RDGeckoCString {
    char *data; uint32_t length; uint16_t dataFlags; uint16_t classFlags;
};
struct RDGeckoU16String {
    char16_t *data; uint32_t length; uint16_t dataFlags; uint16_t classFlags;
};
struct RDGeckoAutoCString {
    RDGeckoCString base; uint32_t inlineCapacity; char storage[64];
};
struct RDGeckoStringBufferHeader {
    std::atomic<uint32_t> refCount; uint32_t storageSize;
};
typedef int32_t RDGeckoResult;
typedef int32_t (*RDOnLinkClickFn)(
    void *, void *, void *, const RDGeckoU16String *, const RDGeckoU16String *,
    void *, void *, bool, uint8_t, void *, void *);
static_assert(sizeof(RDGeckoCString) == 16, "nsCString ABI mismatch");
static_assert(offsetof(RDGeckoAutoCString, inlineCapacity) == 16, "nsAutoCString capacity offset changed");
static_assert(offsetof(RDGeckoAutoCString, storage) == 20, "nsAutoCString storage offset changed");
static_assert(sizeof(RDGeckoAutoCString) == 88, "nsAutoCString size changed");
static_assert(sizeof(RDGeckoStringBufferHeader) == 8, "StringBuffer header ABI changed");

static RDOnLinkClickFn gRDOriginalOnLinkClick = nullptr;
static std::atomic_bool gRDHookInstalled{false};
static std::atomic_bool gRDImageCallbackRegistered{false};
static std::atomic_bool gRDInstallScheduled{false};
static std::atomic_uint gRDInstallAttempts{0};

static BOOL RDNativeEnabled(void) {
    return RDReadBoolPref(kEnabledKey, YES) && RDReadBoolPref(kHandoffKey, YES);
}
static BOOL RDNativeInternalScheme(NSString *scheme) {
    static NSSet *internal; static dispatch_once_t once;
    dispatch_once(&once, ^{
        internal = [NSSet setWithArray:@[
            @"http",@"https",@"about",@"data",@"blob",@"javascript",
            @"moz-extension",@"jar",@"view-source",@"file",@"resource",
            @"wyciwyg",@"ws",@"wss",@"ftp",@"intent",@"reynard",
            @"chrome",@"chrome-extension"
        ]];
    });
    return [internal containsObject:scheme.lowercaseString];
}
static NSURL *RDNativeAppURL(NSString *spec) {
    if (!spec.length || spec.length >= RD_URL_CAP ||
        [spec rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound ||
        [spec rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound)
        return nil;
    char normalized[RD_URL_CAP + 2];
    if (!RDNormalizeAppURL(spec.UTF8String, normalized, sizeof(normalized))) return nil;
    NSString *value = [NSString stringWithUTF8String:normalized];
    NSURLComponents *parts = [NSURLComponents componentsWithString:value];
    if (!parts.scheme.length || RDNativeInternalScheme(parts.scheme)) return nil;
    return parts.URL;
}
static void RDReleaseGeckoCString(RDGeckoCString *value) {
    if (!value || !value->data || !(value->dataFlags & RD_GECKO_STRING_OWNED)) return;
    if (value->dataFlags & RD_GECKO_STRING_STRINGBUFFER) {
        RDGeckoStringBufferHeader *header =
            reinterpret_cast<RDGeckoStringBufferHeader *>(value->data) - 1;
        uint32_t previous = header->refCount.fetch_sub(1, std::memory_order_release);
        if (previous == 1) {
            (void)header->refCount.load(std::memory_order_acquire); free(header);
        }
    } else {
        free(value->data);
    }
}
static NSString *RDNativeURISpec(void *uri) {
    if (!uri) return nil;
    RDGeckoAutoCString storage;
    RDGeckoCString &value = storage.base;
    value.data = storage.storage; value.length = 0;
    value.dataFlags = 0x11; value.classFlags = RD_GECKO_STRING_CLASS_INLINE;
    storage.inlineCapacity = 63; storage.storage[0] = 0;
    RDGeckoResult result = (RDGeckoResult)RDGeckoCallUnsignedVTable3(uri, &value);
    NSString *copy = nil;
    BOOL inlineStorage = value.data == storage.storage;
    BOOL inlineFlag = (value.dataFlags & RD_GECKO_STRING_INLINE) != 0;
    if (result == 0 && value.data && value.length < RD_URL_CAP && inlineStorage == inlineFlag)
        copy = [[NSString alloc] initWithBytes:value.data length:value.length encoding:NSUTF8StringEncoding];
    RDReleaseGeckoCString(&value);
    return copy;
}
static BOOL gRDHandlingLinkClick = NO;
struct RDNativeClickGuard {
    BOOL owns;
    RDNativeClickGuard() : owns(!gRDHandlingLinkClick) { if (owns) gRDHandlingLinkClick = YES; }
    ~RDNativeClickGuard() { if (owns) gRDHandlingLinkClick = NO; }
};
static uintptr_t gRDGetContextAddress=0;
static uintptr_t gRDGetParentAddress=0;
static BOOL RDNativeOpenCustom(NSURL *url) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    BOOL accepted = [[UIApplication sharedApplication] openURL:url];
#pragma clang diagnostic pop
    return accepted;
}
static NSString *RDNativeHandoffDomain(void) {
    return @"com.guacforlife.reynarddefaultprefs";
}
static BOOL RDNativePublishExternalURL(NSString *spec) {
    if (!spec.length || spec.length >= RD_URL_CAP) return NO;
    NSDictionary *payload=@{ @"url": spec, @"time": @([[NSDate date] timeIntervalSince1970]) };
    CFPreferencesSetValue((__bridge CFStringRef)RD_PENDING_HANDOFF_KEY,
                          (__bridge CFPropertyListRef)payload,
                          (__bridge CFStringRef)RDNativeHandoffDomain(),
                          kCFPreferencesCurrentUser,kCFPreferencesAnyHost);
    BOOL synchronized=CFPreferencesSynchronize((__bridge CFStringRef)RDNativeHandoffDomain(),
                                                kCFPreferencesCurrentUser,kCFPreferencesAnyHost);
    if (synchronized)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             RD_HOOK_NOTIFICATION,NULL,NULL, true);
    return synchronized;
}
static NSDictionary *RDNativeConsumeExternalURL(void) {
    CFPropertyListRef value=CFPreferencesCopyValue((__bridge CFStringRef)RD_PENDING_HANDOFF_KEY,
                                                     (__bridge CFStringRef)RDNativeHandoffDomain(),
                                                     kCFPreferencesCurrentUser,kCFPreferencesAnyHost);
    NSDictionary *payload=[(__bridge id)value isKindOfClass:[NSDictionary class]] ? [(__bridge id)value copy] : nil;
    if (value) CFRelease(value);
    if (payload) {
        CFPreferencesSetValue((__bridge CFStringRef)RD_PENDING_HANDOFF_KEY,NULL,
                              (__bridge CFStringRef)RDNativeHandoffDomain(),
                              kCFPreferencesCurrentUser,kCFPreferencesAnyHost);
        CFPreferencesSynchronize((__bridge CFStringRef)RDNativeHandoffDomain(),
                                 kCFPreferencesCurrentUser,kCFPreferencesAnyHost);
    }
    return payload;
}
static int32_t RDNativeCallOriginal(void *self, void *content, void *uri,
    const RDGeckoU16String *target, const RDGeckoU16String *file,
    void *post, void *headers, bool user, uint8_t involvement,
    void *principal, void *policy) {
    return gRDOriginalOnLinkClick(self,content,uri,target,file,post,headers,user,involvement,principal,policy);
}
static int32_t RDNativeOnLinkClick(void *self, void *content, void *uri,
    const RDGeckoU16String *target, const RDGeckoU16String *file,
    void *post, void *headers, bool user, uint8_t involvement,
    void *principal, void *policy) {
    if (!gRDOriginalOnLinkClick) return 0;
    if (gRDHandlingLinkClick)
        return RDNativeCallOriginal(self,content,uri,target,file,post,headers,user,involvement,principal,policy);
    RDNativeClickGuard guard;
    BOOL fileVoid = !file || (file->dataFlags & RD_GECKO_STRING_VOIDED) != 0;
    RDClickIntent intent={ true,true,true,content!=NULL,false,true,false,fileVoid,
        post!=NULL,headers!=NULL,user,user,(uint8_t)involvement };
    if (!RDClickIntentEligible(intent)) {
        RDLog(@"native click reject reason=%s",RDClickIntentReason(intent));
        return RDNativeCallOriginal(self,content,uri,target,file,post,headers,user,involvement,principal,policy);
    }
    NSString *spec = RDNativeURISpec(uri);
    if (!spec) {
        RDLog(@"native click reject reason=uri-spec");
        return RDNativeCallOriginal(self,content,uri,target,file,post,headers,user,involvement,principal,policy);
    }
    char scheme[RD_SCHEME_CAP];
    if (!RDProtocolCopyScheme(spec.UTF8String,strlen(spec.UTF8String),scheme)) {
        RDLog(@"native click reject reason=scheme");
        return RDNativeCallOriginal(self,content,uri,target,file,post,headers,user,involvement,principal,policy);
    }
    if (gRDGetContextAddress && gRDGetParentAddress) {
        void *ctx=RDGeckoCallUnsignedMethod0(self,gRDGetContextAddress);
        if (ctx && RDGeckoCallUnsignedMethod0(ctx,gRDGetParentAddress)) {
            RDLog(@"native click reject reason=subframe");
            return RDNativeCallOriginal(self,content,uri,target,file,post,headers,user,involvement,principal,policy);
        }
    }
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        RDLog(@"native click reject reason=background");
        return RDNativeCallOriginal(self,content,uri,target,file,post,headers,user,involvement,principal,policy);
    }
    NSURL *appURL = RDNativeAppURL(spec);
    if (!appURL) {
        RDLog(@"native click reject reason=app-url");
        return RDNativeCallOriginal(self,content,uri,target,file,post,headers,user,involvement,principal,policy);
    }
    RDLog(@"native click candidate scheme=%@",appURL.scheme);
    BOOL helper = [[NSBundle mainBundle].bundleIdentifier isEqualToString:RD_REYNARD_HELPER_BUNDLE_ID];
    if (helper) {
        BOOL relayed=RDNativePublishExternalURL(appURL.absoluteString);
        RDLog(@"native click relay scheme=%@ synchronized=%d",appURL.scheme,relayed);
        if (relayed) return RD_NS_ERROR_ABORT;
        return RDNativeCallOriginal(self,content,uri,target,file,post,headers,user,involvement,principal,policy);
    }
    BOOL accepted = RDNativeOpenCustom(appURL);
    RDLog(@"native click scheme=%@ accepted=%d",appURL.scheme,accepted);
    if (accepted) return RD_NS_ERROR_ABORT;
    return RDNativeCallOriginal(self,content,uri,target,file,post,headers,user,involvement,principal,policy);
}
static BOOL RDNativeXULMatches(const struct mach_header_64 *header) {
    if (!header || header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64) return NO;
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    uint64_t textSize = 0; BOOL uuid = NO; uint32_t commandBytes = 0;
    for (uint32_t i = 0; i < header->ncmds; ++i) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmdsize < sizeof(*lc) || commandBytes > header->sizeofcmds ||
            lc->cmdsize > header->sizeofcmds - commandBytes) return NO;
        commandBytes += lc->cmdsize;
        if (lc->cmd == LC_UUID && lc->cmdsize >= sizeof(struct uuid_command))
            uuid = memcmp(((const struct uuid_command *)lc)->uuid,kRDExpectedXULUUID,16) == 0;
        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)lc;
            if (strncmp(segment->segname,"__TEXT",16) == 0 && segment->vmaddr == 0)
                textSize = segment->vmsize;
        }
        cursor += lc->cmdsize;
    }
    uint64_t end=RD_XUL_ON_LINK_CLICK+sizeof(kRDLinkPrologue);
    if (end<RD_XUL_GET_BROWSING_CONTEXT+sizeof(kRDContextPrologue)) end=RD_XUL_GET_BROWSING_CONTEXT+sizeof(kRDContextPrologue);
    if (end<RD_XUL_GET_PARENT+sizeof(kRDParentPrologue)) end=RD_XUL_GET_PARENT+sizeof(kRDParentPrologue);
    return uuid && textSize>end;
}
static void RDNativeTryInstallXUL(void);
static void RDNativeScheduleInstall(void) {
    if (gRDHookInstalled.load(std::memory_order_acquire) ||
        gRDInstallAttempts.load(std::memory_order_relaxed)>=100 ||
        gRDInstallScheduled.exchange(true,std::memory_order_acq_rel)) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        gRDInstallScheduled.store(false,std::memory_order_release);
        RDNativeTryInstallXUL();
    });
}
static void RDNativeTryInstallXUL(void) {
    if (gRDHookInstalled.load(std::memory_order_acquire) || ![NSThread isMainThread]) return;
    gRDInstallAttempts.fetch_add(1,std::memory_order_relaxed);
    for (uint32_t i=0;i<_dyld_image_count();++i) {
        const char *name=_dyld_get_image_name(i);
        if (!name || !strstr(name,"/Frameworks/XUL")) continue;
        const struct mach_header_64 *header=(const struct mach_header_64*)_dyld_get_image_header(i);
        if (!RDNativeXULMatches(header)) { RDLog(@"native XUL baseline mismatch"); gRDHookInstalled.store(true,std::memory_order_release); return; }
        uintptr_t slide=(uintptr_t)_dyld_get_image_vmaddr_slide(i);
        uintptr_t address=slide+RD_XUL_ON_LINK_CLICK;
        uintptr_t context=slide+RD_XUL_GET_BROWSING_CONTEXT;
        uintptr_t parent=slide+RD_XUL_GET_PARENT;
        if (memcmp((const void*)address,kRDLinkPrologue,sizeof(kRDLinkPrologue))!=0 ||
            memcmp((const void*)context,kRDContextPrologue,sizeof(kRDContextPrologue))!=0 ||
            memcmp((const void*)parent,kRDParentPrologue,sizeof(kRDParentPrologue))!=0) {
            RDLog(@"native click prologue mismatch"); gRDHookInstalled.store(true,std::memory_order_release); return;
        }
        gRDGetContextAddress=context; gRDGetParentAddress=parent;
        MSHookFunction((void*)address,(void*)&RDNativeOnLinkClick,(void**)&gRDOriginalOnLinkClick);
        if (gRDOriginalOnLinkClick) { gRDHookInstalled.store(true,std::memory_order_release); RDLog(@"native OnLinkClick installed"); }
        return;
    }
    RDNativeScheduleInstall();
}
static void RDNativeImageAdded(const struct mach_header *header,intptr_t slide) { (void)header; (void)slide; RDNativeScheduleInstall(); }
static void RDNativeInstallXULHook(void) {
    if (!gRDImageCallbackRegistered.exchange(true,std::memory_order_acq_rel)) _dyld_register_func_for_add_image(&RDNativeImageAdded);
    RDNativeScheduleInstall();
}
#endif
