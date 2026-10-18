// Tweak.xm — Twin (standalone)
//
// Twin is an independent enhancement layer for SpringBoard. It NEVER replaces,
// conflicts with or overwrites ParallelX, and it is never injected into the
// Settings app (its settings live in its own PreferenceBundle).
//
// Integration with ParallelX is strictly optional and detected at runtime:
//   * installed  -> its floating-window engine is used for split-screen launch
//                   and for the window size/position memory feature
//   * absent     -> Twin degrades gracefully to a plain app launcher
#import <UIKit/UIKit.h>
#import "TWPrefs.h"
#import "TWCraneBridge.h"
#import "TWArcCoordinator.h"
#import "TWArcMenuView.h"
#import "TWRemember.h"

#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>

static BOOL TWTwinEnabled(void) {
    return [TWPrefs.shared boolForKey:TWKeyEnabled defaultValue:NO];
}

static BOOL TWCraneEnabled(void) {
    return TWTwinEnabled() && [TWPrefs.shared boolForKey:TWKeyCraneEnabled defaultValue:NO];
}

#pragma mark - ParallelX integration (optional, runtime-detected)

// When ParallelX opens an app from its own panel, Twin must settle the Crane
// container first. ABI of PXPanelEntry +applicationActivated: was verified from
// the device-installed dylib (+applicationActivated: v24@0:8@16).
static void (*TWOriginalActivated)(id, SEL, id);

static void TWCallOriginalActivated(id target, SEL selector, id bundleID) {
    if (TWOriginalActivated) TWOriginalActivated(target, selector, bundleID);
}

static void TWActivated(id target, SEL selector, id bundleID) {
    if (![bundleID isKindOfClass:NSString.class] || ![bundleID length]) {
        // Never swallow a launch we cannot inspect: hand it back untouched.
        TWCallOriginalActivated(target, selector, bundleID);
        return;
    }
    // Master switch off, or the app has no Crane mapping: pass straight through.
    if (!TWCraneEnabled() || ![TWPrefs.shared craneApps][bundleID]) {
        TWCallOriginalActivated(target, selector, bundleID);
        return;
    }
    [TWCraneBridge prepareLaunchForBundleID:bundleID completion:^(BOOL success) {
        // Bridge completion runs on the main queue only after container read-back.
        if (success) TWCallOriginalActivated(target, selector, bundleID);
    }];
}

static void TWInstallParallelXHook(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class cls = objc_getClass("PXPanelEntry");
    Class meta = cls ? object_getClass(cls) : Nil;
    SEL sel = sel_registerName("applicationActivated:");
    Method method = meta ? class_getInstanceMethod(meta, sel) : NULL;
    if (!method) return;
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (sig.numberOfArguments != 3 || strcmp(sig.methodReturnType, @encode(void)) ||
        strcmp([sig getArgumentTypeAtIndex:2], @encode(id))) return;
    typedef void (*Hook)(Class, SEL, IMP, IMP *);
    Hook hook = (Hook)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (!hook) return;
    hook(meta, sel, (IMP)TWActivated, (IMP *)&TWOriginalActivated);
    installed = TWOriginalActivated != NULL;
}

static void TWImageAdded(const struct mach_header *header, intptr_t slide) {
    // dyld callbacks must not resolve ObjC classes while the loader is locked.
    dispatch_async(dispatch_get_main_queue(), ^{
        TWInstallParallelXHook();   // ParallelX may be loaded after SpringBoard
        TWRememberStart();          // window memory needs PXPanelEntry as well
    });
}

#pragma mark - entry point

__attribute__((constructor)) static void TWInitialize(void) {
    // SpringBoard only. The Settings app is intentionally untouched: Twin's
    // panel is a plain PreferenceBundle loaded by the Preferences process.
    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
    if (![bundleID isEqualToString:@"com.apple.springboard"]) return;

    _dyld_register_func_for_add_image(TWImageAdded);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        TWInstallParallelXHook();
        [[TWArcCoordinator sharedInstance] start];
        TWRememberStart();
    });
}