// Tweak.xm — Twin
// Arc gesture launcher + Crane container support for ParallelX split screen.
// Injects into SpringBoard + Preferences (see Twin.plist filter).
// Process routing: SpringBoard gets ParallelX-integration/Arc/Crane/remember,
// Preferences gets the appended settings UI (PSListController hook).
#import <UIKit/UIKit.h>
#import "TWPrefs.h"
#import "TWCraneBridge.h"
#import "TWArcCoordinator.h"
#import "TWArcMenuView.h"
#import "TWRemember.h"
#import "TWPlusUI.h"

#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>

#pragma mark - ParallelX integration
// Verified from supplied ParallelX.dylib ObjC metadata:
// class_ro at 0x80350 names PXPanelEntry (not ParallelX.PXPanelEntry);
// metaclass 0x812b0, method list 0x64b68: +applicationActivated: v24@0:8@16.
static void (*TWOriginalActivated)(id, SEL, id);
static void TWActivated(id target, SEL selector, id bundleID) {
    if (![bundleID isKindOfClass:NSString.class] || ![bundleID length]) {
        NSLog(@"[Twin] Invalid ParallelX bundle ID; launch cancelled."); return;
    }
    [TWCraneBridge prepareLaunchForBundleID:bundleID completion:^(BOOL success) {
        // Bridge completion runs on main, only after confirmed container read-back.
        if (success && TWOriginalActivated) TWOriginalActivated(target, selector, bundleID);
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
    if (sig.numberOfArguments != 3 || strcmp(sig.methodReturnType, @encode(void)) || strcmp([sig getArgumentTypeAtIndex:2], @encode(id))) {
        NSLog(@"[Twin] ParallelX ABI mismatch; hook not installed."); return;
    }
    typedef void (*Hook)(Class, SEL, IMP, IMP *);
    Hook hook = (Hook)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (!hook) return;
    hook(meta, sel, (IMP)TWActivated, (IMP *)&TWOriginalActivated);
    installed = TWOriginalActivated != NULL;
}
static void TWImageAdded(const struct mach_header *header, intptr_t slide) {
    // dyld callbacks must not resolve ObjC classes while the loader is locked.
    dispatch_async(dispatch_get_main_queue(), ^{ TWInstallParallelXHook(); });
}

__attribute__((constructor)) static void TWInitialize(void) {
    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
    if ([bundleID isEqualToString:@"com.apple.Preferences"]) {
        // Settings app: only the appended settings UI, never the arc gesture.
        TWPlusUIStart();
        return;
    }
    // SpringBoard: ParallelX integration + Arc + Crane + remember window size.
    _dyld_register_func_for_add_image(TWImageAdded);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        TWInstallParallelXHook();
        [[TWArcCoordinator sharedInstance] start];
        TWRememberStart();
    });
}