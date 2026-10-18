// TWRemember.m — remember per-app floating window size/position.
//
// Optional ParallelX integration: hooks are installed only when PXPanelEntry is
// present, and they were verified from the device-installed ParallelX.dylib
// ObjC metadata:
//   -[PXPanelEntry applyResizePreview]      v16@0:8   — resize commit
//   -[PXPanelEntry moveHost:]               v24@0:8@16 — move gesture
//   -[PXPanelEntry closeTapped]             v16@0:8   — window close
//   -[PXPanelEntry init]                    @16@0:8   — fresh entry
//   ivars (object): hostedBundleID, panelWindow, resizePreview, draggingHandle,
//                   dockedHosts, fullscreenToWindowInProgress
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "TWRemember.h"
#import "TWPrefs.h"

#pragma mark - ivar helper (runtime, Swift ivars are visible to the ObjC runtime)

static id TWObjIvar(id obj, const char *name) {
    if (!obj) return nil;
    Ivar ivar = class_getInstanceVariable([obj class], name);
    if (!ivar) {
        unsigned int count = 0;
        Ivar *list = class_copyIvarList([obj class], &count);
        for (unsigned int i = 0; i < count && !ivar; i++) {
            const char *n = ivar_getName(list[i]);
            if (n && strcmp(n, name) == 0) ivar = list[i];
        }
        free(list);
    }
    if (!ivar) return nil;
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || type[0] != '@') return nil; // object ivars only (object_getIvar)
    id value = object_getIvar(obj, ivar);
    return [(NSObject *)value isKindOfClass:NSObject.class] ? value : nil;
}

static BOOL TWTwinEnabled(void) {
    return [TWPrefs.shared boolForKey:TWKeyEnabled defaultValue:NO];
}

static BOOL TWRememberEnabled(void) {
    return TWTwinEnabled() && [TWPrefs.shared boolForKey:TWKeyRememberSize defaultValue:YES];
}

static BOOL TWCanRemember(NSObject *entry) {
    if (![entry isKindOfClass:NSObject.class]) return NO;
    // Do not capture while a resize is in progress or window is going fullscreen.
    id resizePreview = TWObjIvar(entry, "resizePreview");
    if (resizePreview) return NO;
    id docked = TWObjIvar(entry, "dockedHosts");
    if ([docked isKindOfClass:NSArray.class] && [(NSArray *)docked count] > 0) return NO;
    id fullscreen = TWObjIvar(entry, "fullscreenToWindowInProgress");
    if ([fullscreen respondsToSelector:@selector(boolValue)] && [fullscreen boolValue]) return NO;
    return YES;
}

static UIWindow *TWPanelWindowOf(NSObject *entry) {
    id w = TWObjIvar(entry, "panelWindow");
    return [w isKindOfClass:UIWindow.class] ? w : nil;
}

#pragma mark - capture

static void TWCaptureFrame(NSObject *entry) {
    if (!TWRememberEnabled()) return;
    if (!TWCanRemember(entry)) return;
    UIWindow *window = TWPanelWindowOf(entry);
    id bundleID = TWObjIvar(entry, "hostedBundleID");
    if (!window || ![bundleID isKindOfClass:NSString.class] || ![bundleID length]) return;
    CGRect frame = window.frame;
    if (CGRectIsNull(frame) || CGRectIsEmpty(frame) || frame.size.width > 5000 || frame.size.height > 5000) return;
    // Require the window to intersect the main screen bounds (not stashed offscreen).
    CGRect screen = UIScreen.mainScreen.bounds;
    if (!CGRectIntersectsRect(CGRectInset(screen, -2, -2), frame)) return;
    [[TWPrefs shared] setRememberedFrame:frame forBundleID:bundleID];
}

// moveHost: fires continuously; debounce the save to capture the final position.
// Debounce is a plain main-queue delayed block with a generation token — the
// previous dispatch-source implementation called dispatch_resume on every move,
// which over-resumes the source and can abort the process.
static void (*origMoveHost)(id, SEL, id);
static void replMoveHost(id self, SEL _cmd, id gesture) {
    origMoveHost(self, _cmd, gesture);
    if (!TWRememberEnabled()) return;
    static __weak NSObject *pendingEntry;
    static NSUInteger generation;
    pendingEntry = self;                 // main-queue only (gesture handler)
    NSUInteger token = ++generation;     // main-queue only
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (token != generation) return; // superseded by a newer move
        NSObject *entry = pendingEntry;
        pendingEntry = nil;
        if (entry) TWCaptureFrame(entry);
    });
}

static void (*origApplyResizePreview)(id, SEL);
static void replApplyResizePreview(id self, SEL _cmd) {
    origApplyResizePreview(self, _cmd);
    TWCaptureFrame(self);
}

static void (*origCloseTapped)(id, SEL);
static void replCloseTapped(id self, SEL _cmd) {
    TWCaptureFrame(self);
    origCloseTapped(self, _cmd);
}

#pragma mark - apply

static id (*origInit)(id, SEL);
static id replInit(id self, SEL _cmd) {
    self = origInit(self, _cmd);
    if (self) {
        // Apply remembered frame shortly after a fresh entry lays out.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!TWRememberEnabled()) return;
            id bundleID = TWObjIvar(self, "hostedBundleID");
            if (![bundleID isKindOfClass:NSString.class] || ![bundleID length]) return;
            CGRect remembered = [[TWPrefs shared] rememberedFrameForBundleID:bundleID];
            if (CGRectIsNull(remembered)) return;
            if (!TWCanRemember(self)) return;
            UIWindow *window = TWPanelWindowOf(self);
            if (!window) return;
            CGRect screen = UIScreen.mainScreen.bounds;
            CGRect target = remembered;
            // Clamp into screen so a rotated or resized device never loses the window.
            if (target.size.width > screen.size.width) target.size.width = screen.size.width;
            if (target.size.height > screen.size.height) target.size.height = screen.size.height;
            target.origin.x = fmin(fmax(target.origin.x, screen.origin.x - target.size.width + 80),
                                   screen.origin.x + screen.size.width - 80);
            target.origin.y = fmin(fmax(target.origin.y, 20), screen.origin.y + screen.size.height - 80);
            if (fabs(target.origin.x - window.frame.origin.x) < 1 &&
                fabs(target.origin.y - window.frame.origin.y) < 1 &&
                fabs(target.size.width - window.frame.size.width) < 1 &&
                fabs(target.size.height - window.frame.size.height) < 1) return;
            [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                window.frame = target;
            } completion:nil];
        });
    }
    return self;
}

#pragma mark - installation (ABI-checked, optional ParallelX integration)

typedef void (*TWMSHookFn)(Class, SEL, IMP, IMP *);

static BOOL TWInstallMethod(Class cls, BOOL isClassMethod, SEL sel,
                             IMP replacement, IMP *origSlot, const char *expectedTypes) {
    Class target = isClassMethod ? object_getClass(cls) : cls;
    Method method = class_getInstanceMethod(target, sel);
    if (!method) return NO;
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (!sig || strcmp(sig.methodReturnType, expectedTypes) != 0) return NO;
    TWMSHookFn hook = (TWMSHookFn)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (!hook) return NO;
    hook(target, sel, replacement, origSlot);
    return *origSlot != NULL;
}

void TWRememberStart(void) {
    static BOOL started = NO;
    if (started) return;
    Class cls = objc_getClass("PXPanelEntry");
    if (!cls) return; // ParallelX not installed: window memory is simply inactive
    // Verify the class is the entry we expect (has the ivars we read).
    if (class_getInstanceVariable(cls, "hostedBundleID") == NULL) return;
    BOOL ok = YES;
    ok &= TWInstallMethod(cls, NO, sel_registerName("applyResizePreview"), (IMP)replApplyResizePreview, (IMP *)&origApplyResizePreview, "v");
    ok &= TWInstallMethod(cls, NO, sel_registerName("moveHost:"), (IMP)replMoveHost, (IMP *)&origMoveHost, "v");
    ok &= TWInstallMethod(cls, NO, sel_registerName("closeTapped"), (IMP)replCloseTapped, (IMP *)&origCloseTapped, "v");
    ok &= TWInstallMethod(cls, NO, sel_registerName("init"), (IMP)replInit, (IMP *)&origInit, "@");
    if (ok) started = YES;
}