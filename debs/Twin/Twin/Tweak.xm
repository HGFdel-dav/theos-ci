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
#import "TWProbe.h"
#import "TWContainerExport.h"
#import "TWSceneHost.h"
#import "TWPath.h"
#import "TWRuntimeLog.h"
#import "TWSceneInject.h"
#import "TWSystemGesture.h"
#import "TWContainerActions.h"
#import "TWSplitFeatures.h"
#import "TWURLRouting.h"

#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>

static BOOL TWTwinEnabled(void) {
    // 0.9.1：总开关不再是用户要去找的东西，缺省即开。
    return [TWPrefs.shared boolForKey:TWKeyEnabled defaultValue:YES];
}

static BOOL TWCraneEnabled(void) {
    return TWTwinEnabled() && [TWPrefs.shared boolForKey:TWKeyCraneEnabled defaultValue:YES];
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
    if (TWContainerActionLaunchIsPrepared(bundleID) || !TWCraneEnabled() || ![TWPrefs.shared craneApps][bundleID]) {
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
        TWURLRoutingStart();
        TWSplitFeaturesStart();
        TWContainerActionsStart();
        TWInstallParallelXHook();   // ParallelX may be loaded after SpringBoard
        TWRememberStart();          // window memory needs PXPanelEntry as well
    });
}

#pragma mark - 主开关联动

// 引擎偏好 com.moxuan.parallelx.plist 的落点：优先用现成文件，没有就用当前 jbroot 的标准路径。
static NSString *TWEnginePrefsPath(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *best = nil;
    NSTimeInterval bestTime = -1;
    for (NSString *root in TWJBRootCandidates()) {
        NSString *p = [[root stringByAppendingPathComponent:
                        @"var/mobile/Library/Preferences/com.moxuan.parallelx.plist"]
                       stringByResolvingSymlinksInPath];
        if (![fm fileExistsAtPath:p]) continue;
        NSTimeInterval t = [[[fm attributesOfItemAtPath:p error:nil] fileModificationDate] timeIntervalSince1970];
        if (t >= bestTime) { best = p; bestTime = t; }
    }
    if (best.length) return best;
    NSString *root = TWJBRootPath();
    if (!root.length) return nil;
    return [root stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.moxuan.parallelx.plist"];
}

// 主开关使用原引擎 pluginEnabled，保留其它偏好。
static void TWSyncEngineEnabled(void) {
    BOOL enabled = TWTwinEnabled();
    CFStringRef domain = CFSTR("com.moxuan.parallelx");
    CFPreferencesAppSynchronize(domain);
    CFPropertyListRef previous = CFPreferencesCopyAppValue(CFSTR("pluginEnabled"), domain);
    BOOL same = previous && CFGetTypeID(previous) == CFBooleanGetTypeID() && CFBooleanGetValue(previous) == enabled;
    if (previous) CFRelease(previous);
    // Window memory writes this same notification frequently. Never reload the
    // entire engine unless its master state actually changed.
    if (same) return;
    CFPreferencesSetAppValue(CFSTR("pluginEnabled"), enabled ? kCFBooleanTrue : kCFBooleanFalse, domain);
    CFPreferencesAppSynchronize(domain);
    for (NSString *name in @[@"com.moxuan.parallelx.capture-updated", @"com.moxuan.parallelx.handle-updated", @"com.moxuan.parallelx.dock-updated"])
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)name, NULL, NULL, YES);
}

static void TWMasterChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                            const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[TWPrefs shared] reload];
        TWSyncEngineEnabled();
        [[TWArcCoordinator sharedInstance] refreshEnabledState];
        TWSystemGestureSync();
        TWSceneInjectSync();
    });
}

#pragma mark - entry point

__attribute__((constructor)) static void TWInitialize(void) {
    // SpringBoard only. The Settings app is intentionally untouched: Twin's
    // panel is a plain PreferenceBundle loaded by the Preferences process.
    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
    if (![bundleID isEqualToString:@"com.apple.springboard"]) return;

    TWSyncEngineEnabled();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, TWMasterChanged,
                                     CFSTR(TWPrefsChangedNotification), NULL,
                                     CFNotificationSuspensionBehaviorDeliverImmediately);

    TWRuntimeLog(@"[tweak] init 0.9.34 jbRoot=%@ prefs=%@ engine=%@",
                 TWJBRootPath() ?: @"(nil)", TWPrefsFilePath() ?: @"(nil)", TWEnginePrefsPath() ?: @"(nil)");

    _dyld_register_func_for_add_image(TWImageAdded);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        TWURLRoutingStart();
        TWSplitFeaturesStart();
        TWContainerActionsStart();
        TWInstallParallelXHook();
        TWSceneInjectStart();   // App 前台时也能从角落起手（注入 scene 呈现层）
        TWSystemGestureStart(); // App 内唤醒的正路：注册进系统手势通道（原版同款）
        [[TWArcCoordinator sharedInstance] start];
        TWRememberStart();
        TWContainerExportStart();   // Crane 容器清单导出给面板（跨进程）
        TWProbeStart();   // 只在真机 dump ParallelX 的可用接口，写文件供分析
    });
}