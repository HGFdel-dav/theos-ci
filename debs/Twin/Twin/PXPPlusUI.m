// PXPPlusUI.m — ParaX 增强设置分区 for the ParallelX settings page.
//
// Strategy (verified on the device-installed latest ParallelX):
//   PXRootListController is an EMPTY PSListController subclass -> everything is
//   served by the base class: -specifiers (loads Root.plist), readPreferenceValue:,
//   setPreferenceValue:specifier:, controllerForSpecifier:. Hooking the BASE
//   methods intercepts every PXRootListController instance. We append a
//   "ParaX 增强" section and answer our own sub-controllers via
//   controllerForSpecifier: (avoiding cross-bundle class lookup entirely).
//
// No static link against Preferences.framework: all calls go through
// NSClassFromString + objc_msgSend so the same dylib can inject into
// SpringBoard (which does not load Preferences) without dyld failures.
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "PXPPlusUI.h"
#import "PXPPath.h"
#import "PXPPrefs.h"
#import "PXPCraneAppsController.h"
#import "PXPRememberAppsController.h"

#pragma mark - dynamic messaging helpers

static id PXP_msg(id target, SEL sel, id arg1, id arg2) {
    return ((id (*)(id, SEL, id, id))objc_msgSend)(target, sel, arg1, arg2);
}

static id PXP_msg1(id target, SEL sel, id arg1) {
    return ((id (*)(id, SEL, id))objc_msgSend)(target, sel, arg1);
}

static void PXP_msgv(id target, SEL sel) {
    ((void (*)(id, SEL))objc_msgSend)(target, sel);
}

static NSString *PXPKeyOfSpecifier(id spec) {
    return PXP_msg(spec, sel_registerName("propertyForKey:"), @"key", nil);
}

static BOOL PXPIsParaXKey(NSString *key) {
    return [key hasPrefix:@"PXP"];
}

#pragma mark - hooks

static id (*origSpecifiers)(id, SEL);
static id replSpecifiers(id self, SEL _cmd) {
    id array = origSpecifiers(self, _cmd);
    // Only extend the root ParallelX settings page.
    Class rootCls = NSClassFromString(@"PXRootListController");
    if (!rootCls || ![self isKindOfClass:rootCls] || !array) return array;
    static char PXPPlusAppendedKey;
    // The base implementation returns its internal cached array (without our
    // additions), so dedupe must live on the controller instance itself.
    if (objc_getAssociatedObject(self, &PXPPlusAppendedKey)) return array;
    NSMutableArray *result = [array mutableCopy];
    Class specCls = NSClassFromString(@"PSSpecifier");
    if (specCls) {
        // Group header
        id group = ((id (*)(id, SEL, id))objc_msgSend)(specCls, sel_registerName("groupSpecifierWithName:"), @"ParaX 增强");
        if (group) [result addObject:group];

        // Switch specifiers (pxpKey resolved through hooked read/set preference methods)
        NSArray *switches = @[
            @{@"title": @"启用 ParaX", @"key": PXPKeyEnabled, @"default": @NO},
            @{@"title": @"弧形唤醒", @"key": PXPKeyArcEnabled, @"default": @YES},
            @{@"title": @"Crane 分身", @"key": PXPKeyCraneEnabled, @"default": @NO},
            @{@"title": @"记忆窗口尺寸", @"key": PXPKeyRememberSize, @"default": @YES},
        ];
        for (NSDictionary *item in switches) {
            id spec = ((id (*)(id, SEL, NSString *, id, id, id, NSString *, int, int))objc_msgSend)(
                specCls, sel_registerName("preferenceSpecifierNamed:target:set:get:detail:cell:edit:"),
                item[@"title"], self, NULL, NULL, nil, 3 /* PSSwitchCell */, 0);
            if (!spec) continue;
            ((void (*)(id, SEL, id, id))objc_msgSend)(spec, sel_registerName("setProperty:forKey:"), item[@"key"], @"key");
            ((void (*)(id, SEL, id, id))objc_msgSend)(spec, sel_registerName("setProperty:forKey:"), item[@"default"], @"default");
            [result addObject:spec];
        }

        // Link rows pushing our own controllers (answered by controllerForSpecifier hook).
        NSArray *links = @[
            @{@"title": @"Crane 应用映射", @"detail": @"PXPCraneAppsController"},
            @{@"title": @"记忆的窗口", @"detail": @"PXPRememberAppsController"},
        ];
        for (NSDictionary *item in links) {
            id spec = ((id (*)(id, SEL, NSString *, id, id, id, NSString *, int, int))objc_msgSend)(
                specCls, sel_registerName("preferenceSpecifierNamed:target:set:get:detail:cell:edit:"),
                item[@"title"], self, NULL, NULL, item[@"detail"], 1 /* PSLinkCell */, 0);
            if (spec) [result addObject:spec];
        }
    }
    objc_setAssociatedObject(self, &PXPPlusAppendedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return result;
}

static id (*origReadPreference)(id, SEL, id);
static id replReadPreference(id self, SEL _cmd, id specifier) {
    NSString *key = PXPKeyOfSpecifier(specifier);
    if (PXPIsParaXKey(key)) {
        id v = [[PXPPrefs shared] objectForKey:key];
        if (v) return v;
        // Defaults must mirror the runtime defaults (PXPPrefs/PXPCraneBridge).
        if ([key isEqual:PXPKeyEnabled]) return @NO;
        if ([key isEqual:PXPKeyCraneEnabled]) return @NO;
        return @YES; // arc, remember and anything else default on
    }
    return origReadPreference(self, _cmd, specifier);
}

static void (*origSetPreference)(id, SEL, id, id);
static void replSetPreference(id self, SEL _cmd, id value, id specifier) {
    NSString *key = PXPKeyOfSpecifier(specifier);
    if (PXPIsParaXKey(key)) {
        [[PXPPrefs shared] setObject:value forKey:key];
        [[PXPPrefs shared] synchronize];
        return;
    }
    origSetPreference(self, _cmd, value, specifier);
}

static id (*origControllerForSpecifier)(id, SEL, id);
static id replControllerForSpecifier(id self, SEL _cmd, id specifier) {
    NSString *detail = PXP_msg(specifier, sel_registerName("propertyForKey:"), @"detail", nil);
    if ([detail isEqual:@"PXPCraneAppsController"] || [detail isEqual:@"PXPRememberAppsController"]) {
        Class cls = NSClassFromString(detail);
        if (cls) {
            id controller = ((id (*)(id, SEL))objc_msgSend)(cls, sel_registerName("new"));
            if (controller) return controller;
        }
    }
    return origControllerForSpecifier(self, _cmd, specifier);
}

#pragma mark - installation

typedef void (*PXPMSHookFn)(Class, SEL, IMP, IMP *);

static BOOL PXPHookMethod(Class cls, SEL sel, IMP replacement, IMP *origSlot, const char *retType, int argCount) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (!sig || sig.numberOfArguments != argCount || strcmp(sig.methodReturnType, retType) != 0) return NO;
    PXPMSHookFn hook = (PXPMSHookFn)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (!hook) return NO;
    hook(cls, sel, replacement, origSlot);
    return *origSlot != NULL;
}

void PXPPlusUIStart(void) {
    static BOOL started = NO;
    if (started) return;
    Class psList = NSClassFromString(@"PSListController");
    if (!psList) return; // not the Preferences process
    // Basic ABI expectations (iOS 15 libprefs).
    if (![NSClassFromString(@"PSSpecifier") respondsToSelector:sel_registerName("groupSpecifierWithName:")]) return;

    BOOL ok = YES;
    ok &= PXPHookMethod(psList, sel_registerName("specifiers"), (IMP)replSpecifiers, (IMP *)&origSpecifiers, "@", 2);
    ok &= PXPHookMethod(psList, sel_registerName("readPreferenceValue:"), (IMP)replReadPreference, (IMP *)&origReadPreference, "@", 3);
    ok &= PXPHookMethod(psList, sel_registerName("setPreferenceValue:specifier:"), (IMP)replSetPreference, (IMP *)&origSetPreference, "v", 4);
    ok &= PXPHookMethod(psList, sel_registerName("controllerForSpecifier:"), (IMP)replControllerForSpecifier, (IMP *)&origControllerForSpecifier, "@", 3);
    if (ok) {
        started = YES;
        NSLog(@"[ParaX] Settings UI hooks installed.");
    }
}