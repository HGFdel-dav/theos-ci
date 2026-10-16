// TWCraneBridge.m
#import "TWCraneBridge.h"
#import "TWPrefs.h"
#import <objc/message.h>
#import <dlfcn.h>

@implementation TWCraneBridge

static Class CraneManagerClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cls = NSClassFromString(@"CraneManager");
        if (!cls) {
            void *handle = dlopen("/usr/lib/libcrane.dylib", RTLD_NOW | RTLD_GLOBAL);
            if (handle) cls = NSClassFromString(@"CraneManager");
        }
    });
    return cls;
}

+ (BOOL)isCraneAvailable {
    return CraneManagerClass() != nil;
}

// Runtime-safe objc_msgSend (ARC forbids direct casts, so use a function pointer).
static id TWMsgSend(id target, SEL sel) {
    if (!target || !sel) return nil;
    id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return fn(target, sel);
}

static id TWMsgSendStr(id target, SEL sel, id arg) {
    if (!target || !sel) return nil;
    id (*fn)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
    return fn(target, sel, arg);
}

+ (id)sharedManager {
    Class cls = CraneManagerClass();
    if (!cls) return nil;
    SEL sel = NSSelectorFromString(@"sharedManager");
    if (!sel || ![cls respondsToSelector:sel]) return nil;
    return TWMsgSend(cls, sel);
}

+ (BOOL)isApplicationSupportedByCrane:(NSString *)bundleID {
    id manager = [self sharedManager];
    if (!manager || !bundleID.length) return NO;
    SEL sel = NSSelectorFromString(@"isApplicationSupportedByCrane:");
    if (!sel || ![manager respondsToSelector:sel]) return NO;
    BOOL (*fn)(id, SEL, id) = (BOOL (*)(id, SEL, id))objc_msgSend;
    return fn(manager, sel, bundleID) != 0;
}

+ (NSString *)activeContainerForBundleID:(NSString *)bundleID {
    id manager = [self sharedManager];
    if (!manager || !bundleID.length) return @"";
    SEL sel = NSSelectorFromString(@"activeContainerIdentifierForApplicationWithIdentifier:");
    if (!sel || ![manager respondsToSelector:sel]) return @"";
    id result = TWMsgSendStr(manager, sel, bundleID);
    return [result isKindOfClass:[NSString class]] ? result : @"";
}

+ (BOOL)setContainer:(NSString *)containerID forBundleID:(NSString *)bundleID {
    id manager = [self sharedManager];
    if (!manager || !containerID.length || !bundleID.length) return NO;
    SEL sel = NSSelectorFromString(@"setActiveContainerIdentifier:forApplicationWithIdentifier:usingBiometricsIfNeededWithSuccessHandler:");
    if (!sel || ![manager respondsToSelector:sel]) return NO;
    void (*fn)(id, SEL, id, id, id) = (void (*)(id, SEL, id, id, id))objc_msgSend;
    fn(manager, sel, containerID, bundleID, nil);
    return YES;
}

+ (BOOL)applyContainerIfConfiguredForBundleID:(NSString *)bundleID {
    if (![self isCraneAvailable]) return NO;
    if (![[TWPrefs shared] boolForKey:TWKeyCraneEnabled defaultValue:NO]) return NO;
    if (!bundleID.length) return NO;
    NSString *container = [[TWPrefs shared] craneApps][bundleID];
    if (!container.length) return NO;
    return [self setContainer:container forBundleID:bundleID];
}

@end