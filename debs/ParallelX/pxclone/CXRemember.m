// CXRemember.m
//
// 分屏窗口大小记忆：按「应用 + 容器」各记各的。
//   · 调整窗口结束后记录原版 hostCard 的宽高（panelWindow 是菜单窗）
//   · 下次打开同一应用/账号时，在原版布局后恢复 hostCard，再调 layoutHost
// 不写任何设置界面，纯自动。
#import "CXRemember.h"
#import "CXPrefs.h"
#import "CXCraneBridge.h"
#import "CXLog.h"
#import "CXArcWake.h"
#import "CXPXRuntime.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <math.h>
#include <string.h>
#include <stdlib.h>

static NSString *const CXRememberKey = @"CXRememberSizes";   // { "bundle#container": {w,h,updated} }
NSString *const CXRememberEnabledKey = @"CXRememberEnabled"; // BOOL 默认 YES
static NSString *const CXLastOpenKey  = @"CXLastOpen";       // { bundle, container, at }

#pragma mark - 当前打开上下文

static NSDictionary *CXLastOpen(void) {
    id v = [CXPrefs.shared objectForKey:CXLastOpenKey];
    return [v isKindOfClass:NSDictionary.class] ? v : nil;
}

void CXRememberNoteLaunch(NSString *bundleID, NSString *containerID) {
    if (!bundleID.length || !containerID.length) return;
    [CXPrefs.shared setObject:@{@"bundle": bundleID, @"container": containerID,
                                @"at": @([[NSDate date] timeIntervalSince1970])}
                       forKey:CXLastOpenKey];
}

static NSString *CXKey(NSString *bundle, NSString *container) {
    if (!bundle.length) return nil;
    return [NSString stringWithFormat:@"%@#%@", bundle, container.length ? container : @"DEFAULT"];
}

#pragma mark - 读写记忆

static NSMutableDictionary *CXAllSizes(void) {
    id v = [CXPrefs.shared objectForKey:CXRememberKey];
    return [v isKindOfClass:NSDictionary.class] ? [v mutableCopy] : [NSMutableDictionary dictionary];
}

static NSDictionary *CXSizeFor(NSString *bundle, NSString *container) {
    NSString *key = CXKey(bundle, container);
    if (!key) return nil;
    id v = CXAllSizes()[key];
    return [v isKindOfClass:NSDictionary.class] ? v : nil;
}

static BOOL CXRememberOn(void) {
    return [CXPrefs.shared boolForKey:CXRememberEnabledKey defaultValue:YES];
}

static void CXStoreSize(NSString *bundle, NSString *container, CGSize size) {
    if (!CXRememberOn()) return;
    NSString *key = CXKey(bundle, container);
    if (!key || !isfinite(size.width) || !isfinite(size.height) ||
        size.width < 40 || size.height < 40) return;
    if (size.width > 5000 || size.height > 5000) return;
    NSMutableDictionary *all = CXAllSizes();
    NSDictionary *old = all[key];
    if ([old isKindOfClass:NSDictionary.class]) {
        double ow = [old[@"w"] doubleValue], oh = [old[@"h"] doubleValue];
        if (fabs(ow - size.width) < 0.5 && fabs(oh - size.height) < 0.5) return;   // 没变不写
    }
    all[key] = @{@"w": @(size.width), @"h": @(size.height),
                 @"updated": @([[NSDate date] timeIntervalSince1970])};
    [CXPrefs.shared setObject:all forKey:CXRememberKey];
    CXLog(@"[remember] store %@ %.0fx%.0f", key, size.width, size.height);
}

#pragma mark - PX 宿主上下文（复用旧按应用/容器方案，取真实 activeBridge）

// 不从16字节 Swift String? 读取 hostedBundleID。bundleID 用桥的 ObjC getter。
static char CXRememberBindingKey;
static __weak id CXBoundBridge;
static __weak UIView *CXBoundCanvas;
static NSInteger CXOpenGeneration = 0;

void CXRememberBindOpen(id bridge, UIView *canvas, NSString *bundleID, NSString *containerID) {
    if (!bridge || ![canvas isKindOfClass:UIView.class] || !bundleID.length) return;
    NSString *container = containerID.length ? containerID : @"DEFAULT";
    CXBoundBridge = bridge;
    CXBoundCanvas = canvas;
    CXOpenGeneration++;
    NSDictionary *context = @{@"bundle": bundleID, @"container": container};
    objc_setAssociatedObject(bridge, &CXRememberBindingKey, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CXRememberNoteLaunch(bundleID, container);
    CXLog(@"[remember] bind %@#%@ canvas=%@", bundleID, container, NSStringFromClass(canvas.class));
}

static id CXEntryBridge(id entry) {
    return CXPXEntryObject(entry, "activeBridge", NSClassFromString(@"PXSceneBridge"));
}

static NSString *CXEntryBundle(id entry) {
    id value = CXPXGetObject(CXEntryBridge(entry), @"bundleID");
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static UIView *CXEntryCard(id entry) {
    return CXPXEntryObject(entry, "hostCard", UIView.class);
}

static NSString *CXEntryContainer(id entry) {
    id bridge = CXEntryBridge(entry);
    NSString *bundle = CXEntryBundle(entry);
    NSDictionary *context = objc_getAssociatedObject(bridge, &CXRememberBindingKey);
    if ([context[@"bundle"] isEqual:bundle] && [context[@"container"] isKindOfClass:NSString.class])
        return context[@"container"];
    NSString *active = bundle.length ? [CXCraneBridge activeContainerForBundleID:bundle] : nil;
    return active.length ? active : @"DEFAULT";
}

static id CXFindPanelEntry(void) { return CXArcWakeEntry(); }

// 真实缩放是在 hostCard 上发生；panelWindow 只是菜单，hostWindow 常为全屏透明宿主。
static BOOL CXGetHost(id entry, NSString *bundle, id *bridgeOut, UIView **cardOut) {
    id bridge = entry ? CXEntryBridge(entry) : CXBoundBridge;
    UIView *card = entry ? CXEntryCard(entry) : nil;
    UIView *canvas = CXPXGetObject(bridge, @"canvas");
    if (![canvas isKindOfClass:UIView.class]) canvas = CXBoundCanvas;
    if (!card && canvas) {
        UIView *candidate = canvas.superview;
        if ([NSStringFromClass(candidate.class) containsString:@"PXHostCard"]) card = candidate;
    }
    NSString *actual = CXPXGetObject(bridge, @"bundleID");
    if (![actual isKindOfClass:NSString.class] || ![actual isEqual:bundle] ||
        ![card isKindOfClass:UIView.class] || !card.window || card.hidden) return NO;
    if (bridgeOut) *bridgeOut = bridge;
    if (cardOut) *cardOut = card;
    return YES;
}

static void CXStoreFailure(NSString *reason) {
    static NSString *lastReason;
    if ([lastReason isEqual:reason]) return;
    lastReason = reason;
    CXLog(@"[remember] capture skipped: %@", reason);
}

#pragma mark - 捕获（缩放结束 / 关闭）

static id CXRememberEntry = nil;

static void (*CXOrigApplyResizePreview)(id, SEL);
static void (*CXOrigCloseTapped)(id, SEL);
static void (*CXOrigResizeHost)(id, SEL, id);
static NSInteger CXCaptureGeneration = 0;
static char CXResizeActiveKey;

static void CXCapture(id entry) {
    if (!entry || !CXRememberOn()) return;
    CXRememberEntry = entry;
    CXArcWakeCaptureEntry(entry);
    if ([objc_getAssociatedObject(entry, &CXResizeActiveKey) boolValue]) return;
    if (CXPXEntryFlag(entry, "fullscreenToWindowInProgress") ||
        CXPXEntryFlag(entry, "fullscreenLaunchInProgress")) return;
    NSString *bundle = CXEntryBundle(entry);
    if (!bundle.length) { CXStoreFailure(@"activeBridge.bundleID unavailable"); return; }
    id bridge = nil;
    UIView *card = nil;
    if (!CXGetHost(entry, bundle, &bridge, &card)) { CXStoreFailure(@"hostCard unavailable"); return; }
    // 缩放停手后原版已将 transform 清零、setFrame；读取显示的真实卡片尺寸。
    CGRect f = card.frame;
    CXStoreSize(bundle, CXEntryContainer(entry), f.size);
}

static void CXApplyResizePreview(id self, SEL _cmd) {
    if (CXOrigApplyResizePreview) CXOrigApplyResizePreview(self, _cmd);
    CXCapture(self);
}

static void CXCloseTapped(id self, SEL _cmd) {
    CXCapture(self);
    CXOpenGeneration++;
    CXCaptureGeneration++;
    if (CXOrigCloseTapped) CXOrigCloseTapped(self, _cmd);
}

// resizeHost: 在拖动缩放过程中被反复调用；停手 0.6s 后再记一次
static void CXScheduleCapture(id entry) {
    CXCaptureGeneration++;
    NSInteger generation = CXCaptureGeneration;
    NSInteger openGeneration = CXOpenGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != CXCaptureGeneration || openGeneration != CXOpenGeneration) return;
        CXCapture(entry);
    });
}

static void CXResizeHostHook(id self, SEL _cmd, id gesture) {
    CXRememberEntry = self;
    CXArcWakeCaptureEntry(self);
    UIGestureRecognizerState state = [gesture isKindOfClass:UIGestureRecognizer.class]
        ? ((UIGestureRecognizer *)gesture).state : UIGestureRecognizerStatePossible;
    BOOL active = state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateChanged;
    if (state == UIGestureRecognizerStateBegan) CXOpenGeneration++; // 手动调整取消本次开窗的延迟恢复
    objc_setAssociatedObject(self, &CXResizeActiveKey, @(active), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateEnded)
        CXLog(@"[remember] resize state=%ld", (long)state);
    if (CXOrigResizeHost) CXOrigResizeHost(self, _cmd, gesture);
    CXScheduleCapture(self);
}

#pragma mark - 恢复

static BOOL CXApplySize(id entry, NSString *bundle, NSString *container) {
    if (!CXRememberOn()) return YES;
    NSDictionary *saved = CXSizeFor(bundle, container);
    if (!saved) return YES;
    CGFloat w = [saved[@"w"] doubleValue], h = [saved[@"h"] doubleValue];
    if (!isfinite(w) || !isfinite(h) || w < 40 || h < 40 || w > 5000 || h > 5000) return YES;
    if (entry && ([objc_getAssociatedObject(entry, &CXResizeActiveKey) boolValue] ||
                  CXPXEntryFlag(entry, "fullscreenToWindowInProgress") ||
                  CXPXEntryFlag(entry, "fullscreenLaunchInProgress"))) return NO;
    id bridge = nil;
    UIView *card = nil;
    if (!CXGetHost(entry, bundle, &bridge, &card)) return NO;
    if (entry && ![CXEntryContainer(entry) isEqual:container]) return YES;
    if (!CXPXVoidSelector(bridge, @"layoutHost", 0)) return NO;
    CGRect f = card.frame;
    CGRect screen = card.superview ? card.superview.bounds : card.window.bounds;
    if (CGRectIsEmpty(screen)) return NO;
    w = MIN(w, CGRectGetWidth(screen));
    h = MIN(h, CGRectGetHeight(screen));
    CGFloat cx = CGRectGetMidX(f), cy = CGRectGetMidY(f);
    CGRect target = CGRectMake(cx - w / 2.0, cy - h / 2.0, w, h);
    if (CGRectGetMaxX(f) > CGRectGetMaxX(screen) - 2) target.origin.x = CGRectGetMaxX(screen) - w;
    target.origin.x = MIN(MAX(target.origin.x, CGRectGetMinX(screen)), CGRectGetMaxX(screen) - w);
    target.origin.y = MIN(MAX(target.origin.y, CGRectGetMinY(screen)), CGRectGetMaxY(screen) - h);
    if (fabs(f.size.width - w) < 0.5 && fabs(f.size.height - h) < 0.5) return YES;
    // 原版 resizeHost: 结束顺序：卡片 transform=identity -> setFrame -> layoutIfNeeded
    // -> activeBridge.layoutHost。只改window.frame不会更新里面的真实宿主比例。
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    card.transform = CGAffineTransformIdentity;
    card.frame = target;
    [card setNeedsLayout];
    [card layoutIfNeeded];
    ((void (*)(id, SEL))objc_msgSend)(bridge, NSSelectorFromString(@"layoutHost"));
    [CATransaction commit];
    CXLog(@"[remember] apply %@#%@ %.0fx%.0f hostCard", bundle, container, w, h);
    return YES;
}

void CXRememberApplySoon(NSString *bundleID, NSString *containerID) {
    if (!bundleID.length || !CXRememberOn()) return;
    NSString *container = containerID.length ? containerID : @"DEFAULT";
    if (!CXSizeFor(bundleID, container)) return;
    NSInteger generation = CXOpenGeneration;
    for (int i = 1; i <= 4; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * i * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (generation != CXOpenGeneration) return; // 新开窗不覆盖为上一个应用/账号
            id entry = CXRememberEntry ?: CXFindPanelEntry();
            BOOL applied = CXApplySize(entry, bundleID, container);
            if (!applied && i == 4) CXLog(@"[remember] restore skipped %@#%@: host not ready", bundleID, container);
        });
    }
}

#pragma mark - 安装

static void CXInstallRememberHooks(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class cls = NSClassFromString(@"PXPanelEntry");
    if (!cls) return;

    SEL initSel = NSSelectorFromString(@"init");
    Method initMethod = class_getInstanceMethod(cls, initSel);
    if (initMethod) {
        typedef id (*InitFn)(id, SEL);
        static InitFn origInit;
        IMP newInit = imp_implementationWithBlock(^id(id self) {
            id result = origInit ? origInit(self, initSel) : self;
            CXRememberEntry = result;
            CXArcWakeCaptureEntry(result);
            return result;
        });
        origInit = (InitFn)method_setImplementation(initMethod, newInit);
    }

    struct { const char *name; IMP imp; IMP *orig; } hooks[] = {
        {"applyResizePreview", (IMP)CXApplyResizePreview, (IMP *)&CXOrigApplyResizePreview},
        {"closeTapped", (IMP)CXCloseTapped, (IMP *)&CXOrigCloseTapped},
        {"resizeHost:", (IMP)CXResizeHostHook, (IMP *)&CXOrigResizeHost},
    };
    for (size_t i = 0; i < sizeof(hooks)/sizeof(hooks[0]); i++) {
        SEL sel = NSSelectorFromString([NSString stringWithUTF8String:hooks[i].name]);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) { CXLog(@"[remember] %s 不存在", hooks[i].name); continue; }
        NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)];
        NSUInteger want = (strchr(hooks[i].name, ':') != NULL) ? 3 : 2;
        if (!sig || sig.numberOfArguments != want || strcmp(sig.methodReturnType, @encode(void)) != 0 ||
            (want == 3 && [sig getArgumentTypeAtIndex:2][0] != '@')) {
            CXLog(@"[remember] %s 签名不符", hooks[i].name); continue;
        }
        *hooks[i].orig = (IMP)method_setImplementation(m, hooks[i].imp);
        CXLog(@"[remember] hook %s ok", hooks[i].name);
    }
    installed = YES;
}

void CXRememberStart(void) {
    CXInstallRememberHooks();
}
