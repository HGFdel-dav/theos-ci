#import "TWContainerActions.h"
#import "TWPrefs.h"
#import "TWCraneBridge.h"
#import "TWRuntimeLog.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <string.h>

// Original PXSceneBridge: -performConfiguredAction: B24@0:8@16 at 0x5efac;
// -performConfiguredAction:fromSearchFavorites: B28@0:8@16B24 at 0x5ef18.
// The original dispatch consumes a dictionary (kind/workflow/app/type), not a
// container. Retain its customActions lookup/render pipeline; intercept only
// Twin-owned records. No claim that PX natively supports container switching.
static BOOL (*TWCAOriginal)(id, SEL, id);
static BOOL (*TWCAOriginalSearch)(id, SEL, id, BOOL);
static NSString *TWCAReadyBundle;
static NSMutableSet<NSString *> *TWCAPending;
static NSString *TWCAString(id obj) { return [obj isKindOfClass:NSString.class] ? obj : @""; }
static BOOL TWCAEnabled(void) {
    return [TWPrefs.shared boolForKey:TWKeyEnabled defaultValue:YES] &&
           [TWPrefs.shared boolForKey:TWKeyCraneEnabled defaultValue:YES];
}
static BOOL TWCAUnlocked(void) {
    Class cls = NSClassFromString(@"SBLockScreenManager");
    SEL shared = NSSelectorFromString(@"sharedInstance");
    id manager = [cls respondsToSelector:shared] ? ((id (*)(id, SEL))objc_msgSend)(cls, shared) : nil;
    SEL locked = NSSelectorFromString(@"isUILocked");
    NSMethodSignature *sig = [manager methodSignatureForSelector:locked];
    if (sig.numberOfArguments != 2 || strcmp(sig.methodReturnType, @encode(BOOL))) return NO;
    return !((BOOL (*)(id, SEL))objc_msgSend)(manager, locked);
}
BOOL TWContainerActionLaunchIsPrepared(NSString *bundleID) {
    return NSThread.isMainThread && TWCAReadyBundle.length && [TWCAReadyBundle isEqual:bundleID];
}
static NSDictionary *TWCARecord(id raw) {
    if ([raw isKindOfClass:NSDictionary.class]) return raw;
    if (![raw isKindOfClass:NSString.class] || ![raw hasPrefix:@"px.custom.twin-container."]) return nil;
    CFStringRef domain = CFSTR("com.moxuan.parallelx");
    CFPreferencesAppSynchronize(domain);
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("customActions"), domain);
    id list = value ? CFBridgingRelease(value) : nil;
    if ([list isKindOfClass:NSArray.class]) for (id item in list)
        if ([item isKindOfClass:NSDictionary.class] && [item[@"id"] isEqual:raw]) return item;
    return nil;
}
static BOOL TWCAHandle(id raw) {
    NSDictionary *record = TWCARecord(raw);
    if (![record[@"twOwner"] isEqual:@"com.niubiprass.twin.container"] ||
        ![record[@"kind"] isEqual:@"twin.container"]) return NO;
    // Owned records are consumed even when disabled: never pass an unknown
    // container kind into another engine as a normal application launch.
    if (!TWCAEnabled()) return YES;
    NSString *bundleID = TWCAString(record[@"app"]), *cid = TWCAString(record[@"twContainerID"]);
    if (!bundleID.length || !cid.length) return YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!TWCAEnabled() || !TWCAUnlocked()) return;
        if (!TWCAPending) TWCAPending = [NSMutableSet set];
        if ([TWCAPending containsObject:bundleID]) return;
        [TWCAPending addObject:bundleID];
        [TWCraneBridge prepareLaunchForBundleID:bundleID containerID:cid completion:^(BOOL success) {
            [TWCAPending removeObject:bundleID];
            if (!success || !TWCAEnabled() || !TWCAUnlocked()) return;
            Class cls = NSClassFromString(@"PXPanelEntry");
            SEL sel = NSSelectorFromString(@"applicationActivated:");
            NSMethodSignature *sig = [cls methodSignatureForSelector:sel];
            if (sig.numberOfArguments != 3 || strcmp(sig.methodReturnType, @encode(void)) ||
                strcmp([sig getArgumentTypeAtIndex:2], @encode(id))) return;
            [TWPrefs.shared setObject:@{@"bundleID":bundleID, @"containerID":cid, @"at":NSDate.date} forKey:TWKeyLastLaunch];
            [TWPrefs.shared synchronize];
            TWCAReadyBundle = bundleID;
            @try { ((void (*)(id, SEL, id))objc_msgSend)(cls, sel, bundleID); }
            @catch (NSException *e) { TWRuntimeLog(@"[container-action] launch failed %@", e.name); }
            @finally { TWCAReadyBundle = nil; }
        }];
    });
    return YES;
}
static BOOL TWCAConfigured(id self, SEL cmd, id action) {
    if (TWCAHandle(action)) return YES;
    return TWCAOriginal ? TWCAOriginal(self, cmd, action) : NO;
}
static BOOL TWCASearch(id self, SEL cmd, id action, BOOL search) {
    if (TWCAHandle(action)) return YES;
    return TWCAOriginalSearch ? TWCAOriginalSearch(self, cmd, action, search) : NO;
}
void TWContainerActionsStart(void) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.springboard"]) return;
    Class cls = NSClassFromString(@"PXSceneBridge");
    typedef void (*Hook)(Class, SEL, IMP, IMP *);
    Hook hook = (Hook)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (!cls || !hook) return;
    NSArray *selectors = @[@"performConfiguredAction:", @"performConfiguredAction:fromSearchFavorites:"];
    for (NSUInteger i = 0; i < selectors.count; i++) {
        if (i ? TWCAOriginalSearch != NULL : TWCAOriginal != NULL) continue;
        SEL sel = NSSelectorFromString(selectors[i]);
        Method method = class_getInstanceMethod(cls, sel);
        if (!method) continue;
        NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
        if (sig.numberOfArguments != (i ? 4 : 3) || strcmp(sig.methodReturnType, @encode(BOOL)) ||
            strcmp([sig getArgumentTypeAtIndex:2], @encode(id)) ||
            (i && strcmp([sig getArgumentTypeAtIndex:3], @encode(BOOL)))) continue;
        if (i) hook(cls, sel, (IMP)TWCASearch, (IMP *)&TWCAOriginalSearch);
        else hook(cls, sel, (IMP)TWCAConfigured, (IMP *)&TWCAOriginal);
    }
}
