// Tweak.xm — ParaX
// Arc gesture launcher + Crane container support for ParallelX split screen.
// Injects into SpringBoard only (see ParaX.plist filter).
#import <UIKit/UIKit.h>
#import "PXPPrefs.h"
#import "PXPCraneBridge.h"
#import "PXPArcCoordinator.h"
#import "PXPArcMenuView.h"

#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>

#pragma mark - ParallelX integration
// Verified from supplied ParallelX.dylib ObjC metadata:
// class_ro at 0x80350 names PXPanelEntry (not ParallelX.PXPanelEntry);
// metaclass 0x812b0, method list 0x64b68: +applicationActivated: v24@0:8@16.
static void (*PXPOriginalActivated)(id, SEL, id);
static void PXPActivated(id target, SEL selector, id bundleID) {
    if (![bundleID isKindOfClass:NSString.class] || ![bundleID length]) {
        NSLog(@"[ParaX] Invalid ParallelX bundle ID; launch cancelled."); return;
    }
    [PXPCraneBridge prepareLaunchForBundleID:bundleID completion:^(BOOL success) {
        // Bridge completion runs on main, only after confirmed container read-back.
        if (success && PXPOriginalActivated) PXPOriginalActivated(target, selector, bundleID);
    }];
}
static void PXPInstallParallelXHook(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class cls = objc_getClass("PXPanelEntry");
    Class meta = cls ? object_getClass(cls) : Nil;
    SEL sel = sel_registerName("applicationActivated:");
    Method method = meta ? class_getInstanceMethod(meta, sel) : NULL;
    if (!method) return;
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (sig.numberOfArguments != 3 || strcmp(sig.methodReturnType, @encode(void)) || strcmp([sig getArgumentTypeAtIndex:2], @encode(id))) {
        NSLog(@"[ParaX] ParallelX ABI mismatch; hook not installed."); return;
    }
    typedef void (*Hook)(Class, SEL, IMP, IMP *);
    Hook hook = (Hook)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (!hook) return;
    hook(meta, sel, (IMP)PXPActivated, (IMP *)&PXPOriginalActivated);
    installed = PXPOriginalActivated != NULL;
}
static void PXPImageAdded(const struct mach_header *header, intptr_t slide) {
    // dyld callbacks must not resolve ObjC classes while the loader is locked.
    dispatch_async(dispatch_get_main_queue(), ^{ PXPInstallParallelXHook(); });
}

__attribute__((constructor)) static void PXPInitialize(void) {
    _dyld_register_func_for_add_image(PXPImageAdded);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        PXPInstallParallelXHook();
        [[PXPArcCoordinator sharedInstance] start];
    });
}