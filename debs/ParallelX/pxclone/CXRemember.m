// CXRemember.m
//
// 分屏窗口大小记忆：按「应用 + 容器」各记各的。
//   · 调整窗口结束后记录原版 hostCard 的宽高（panelWindow 是菜单窗）
//   · 下次打开同一应用/账号时，在真实 hostCard 出现后恢复 frame。
// 不写任何设置界面，纯自动。
#import "CXRemember.h"
#import "CXPrefs.h"
#import "CXCraneBridge.h"
#import "CXLog.h"
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

static NSMutableSet<NSString *> *CXAppliedKeySet(void);
static NSMutableDictionary<NSString *, NSNumber *> *CXAppliedGenerations(void);
void CXRememberApplySoon(NSString *bundleID, NSString *containerID);
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

static void CXStoreSize(NSString *bundle, NSString *container, CGRect frame) {
    if (!CXRememberOn()) return;
    NSString *key = CXKey(bundle, container);
    if (!key || !isfinite(frame.origin.x) || !isfinite(frame.origin.y) ||
        !isfinite(frame.size.width) || !isfinite(frame.size.height) ||
        frame.size.width < 40 || frame.size.height < 40) return;
    if (frame.size.width > 5000 || frame.size.height > 5000) return;
    NSMutableDictionary *all = CXAllSizes();
    NSDictionary *old = all[key];
    if ([old isKindOfClass:NSDictionary.class]) {
        double ox = old[@"x"] ? [old[@"x"] doubleValue] : NAN;
        double oy = old[@"y"] ? [old[@"y"] doubleValue] : NAN;
        double ow = [old[@"w"] doubleValue], oh = [old[@"h"] doubleValue];
        if (fabs(ow - frame.size.width) < 0.5 && fabs(oh - frame.size.height) < 0.5 &&
            fabs(ox - frame.origin.x) < 0.5 && fabs(oy - frame.origin.y) < 0.5) return; // 没变不写
    }
    all[key] = @{@"x": @(frame.origin.x), @"y": @(frame.origin.y),
                 @"w": @(frame.size.width), @"h": @(frame.size.height),
                 @"updated": @([[NSDate date] timeIntervalSince1970])};
    [CXPrefs.shared setObject:all forKey:CXRememberKey];
    CXLog(@"[remember] store %@ %.0f,%.0f %.0fx%.0f", key, frame.origin.x, frame.origin.y,
          frame.size.width, frame.size.height);
}

#pragma mark - PX 宿主上下文（复用旧按应用/容器方案，取真实 activeBridge）

// 不从16字节 Swift String? 读取 hostedBundleID。bundleID 用桥的 ObjC getter。
static char CXRememberBindingKey;
static __weak id CXBoundBridge;
static __weak UIView *CXBoundCanvas;
static NSInteger CXOpenGeneration = 0;
static NSInteger CXPendingGen = 0;
static char CXRememberHiddenKey;
static UIView *CXBoundHostCard(void);

static void CXRememberHideInitialHost(void) {
    UIView *target = CXBoundHostCard();
    if (![target isKindOfClass:UIView.class]) target = CXBoundCanvas;
    if (![target isKindOfClass:UIView.class]) return;
    objc_setAssociatedObject(target, &CXRememberHiddenKey, @(target.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    target.alpha = 0.0;
}

static void CXRememberRevealHost(UIView *target) {
    if (![target isKindOfClass:UIView.class]) target = CXBoundCanvas;
    if (![target isKindOfClass:UIView.class]) return;
    NSNumber *oldAlpha = objc_getAssociatedObject(target, &CXRememberHiddenKey);
    target.alpha = oldAlpha ? oldAlpha.doubleValue : 1.0;
    objc_setAssociatedObject(target, &CXRememberHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void CXRememberBindOpen(id bridge, UIView *canvas, NSString *bundleID, NSString *containerID) {
    if (!bridge || ![canvas isKindOfClass:UIView.class] || !bundleID.length) return;
    NSString *container = containerID.length ? containerID : @"DEFAULT";
    CXBoundBridge = bridge;
    CXBoundCanvas = canvas;
    CXOpenGeneration++;
    CXPendingGen++;
    NSString *appliedKey = CXKey(bundleID, container);
    if (appliedKey) [CXAppliedKeySet() removeObject:appliedKey]; // 新开窗：允许这套组合再套一次
    NSDictionary *context = @{@"bundle": bundleID, @"container": container};
    objc_setAssociatedObject(bridge, &CXRememberBindingKey, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CXRememberNoteLaunch(bundleID, container);
    CXLog(@"[remember] bind %@#%@ canvas=%@", bundleID, container, NSStringFromClass(canvas.class));
    CXRememberApplySoon(bundleID, container);
}

static id CXRememberEntry;

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

static id CXFindPanelEntry(void) { return CXRememberEntry; }

static UIView *CXBoundHostCard(void) {
    UIView *view = CXBoundCanvas;
    for (NSInteger depth = 0; view && depth < 8; depth++, view = view.superview) {
        NSString *name = NSStringFromClass(view.class);
        if ([name containsString:@"PXHostCard"] || [name containsString:@"HostCard"]) return view;
    }
    id entry = CXRememberEntry;
    UIView *card = CXEntryCard(entry);
    return [card isKindOfClass:UIView.class] ? card : nil;
}

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
        ![card isKindOfClass:UIView.class] || !card.window) return NO;
    if (bridgeOut) *bridgeOut = bridge;
    if (cardOut) *cardOut = card;
    return YES;
}


static void CXNormalizeContentTree(UIView *root, CGRect bounds, NSInteger depth) {
    if (![root isKindOfClass:UIView.class] || depth > 4) return;
    NSArray *children = [root.subviews copy];
    for (UIView *child in children) {
        if (child.hidden || child.alpha <= 0.001) continue;
        NSString *name = NSStringFromClass(child.class);
        BOOL likelyContent = [name containsString:@"Content"] ||
            [name containsString:@"Host"] || [name containsString:@"Scene"] ||
            CGRectGetWidth(child.frame) > CGRectGetWidth(root.bounds) * 0.75;
        if (likelyContent && child != root) {
            child.transform = CGAffineTransformIdentity;
            child.frame = bounds;
            child.bounds = (CGRect){ CGPointZero, bounds.size };
            [child setNeedsLayout];
            [child layoutIfNeeded];
        }
        CXNormalizeContentTree(child, child.bounds, depth + 1);
    }
}

static void CXNormalizeContent(UIView *card, UIView *canvas, UIView *hostView) {
    CGRect bounds = card.bounds;
    for (UIView *view in @[canvas ?: (id)[NSNull null], hostView ?: (id)[NSNull null]]) {
        if (![view isKindOfClass:UIView.class] || view == card) continue;
        view.transform = CGAffineTransformIdentity;
        view.frame = bounds;
        view.bounds = (CGRect){ CGPointZero, bounds.size };
        [view setNeedsLayout];
        [view layoutIfNeeded];
        CXNormalizeContentTree(view, view.bounds, 0);
    }
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
    // 只在原生缩放完全结束后保存，拖动过程不触碰记忆状态。
    if ([objc_getAssociatedObject(entry, &CXResizeActiveKey) boolValue] ||
        CXPXEntryFlag(entry, "fullscreenToWindowInProgress") ||
        CXPXEntryFlag(entry, "fullscreenLaunchInProgress")) return;
    NSString *bundle = CXEntryBundle(entry);
    if (!bundle.length) { CXStoreFailure(@"activeBridge.bundleID unavailable"); return; }
    id bridge = nil;
    UIView *card = nil;
    if (!CXGetHost(entry, bundle, &bridge, &card)) { CXStoreFailure(@"hostCard unavailable"); return; }
    // 缩放手势停手后原版已把 transform 清零并 setFrame；记录完整 frame（含贴边位置）。
    CXStoreSize(bundle, CXEntryContainer(entry), card.frame);
}

static void CXApplyResizePreview(id self, SEL _cmd) {
    // 预览回调发生在原生手势中间，不写记忆，避免 frame 被回放造成跳动。
    if (CXOrigApplyResizePreview) CXOrigApplyResizePreview(self, _cmd);
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
    UIGestureRecognizerState state = [gesture isKindOfClass:UIGestureRecognizer.class]
        ? ((UIGestureRecognizer *)gesture).state : UIGestureRecognizerStatePossible;
    BOOL active = state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateChanged;
    if (state == UIGestureRecognizerStateBegan) CXOpenGeneration++; // 手动调整取消本次开窗的延迟恢复
    objc_setAssociatedObject(self, &CXResizeActiveKey, @(active), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateEnded)
        CXLog(@"[remember] resize state=%ld", (long)state);
    if (CXOrigResizeHost) CXOrigResizeHost(self, _cmd, gesture);
    if (state == UIGestureRecognizerStateEnded ||
        state == UIGestureRecognizerStateCancelled ||
        state == UIGestureRecognizerStateFailed) {
        objc_setAssociatedObject(self, &CXResizeActiveKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // 原生 resizeHost 已完成最终 frame，此处只保存一次。
        CXCapture(self);
    }
}

#pragma mark - 恢复

static __weak id CXPendingBridge;
static NSString *CXPendingBundle, *CXPendingContainer;
static CGRect CXPendingRect = {0};
static BOOL CXPendingApplied = YES;
static NSMutableSet<NSString *> *CXAppliedKeys;
static NSString *CXPendingKey;
static BOOL CXInLayoutApply;
static void (*CXOrigLayoutHost)(id, SEL);
static NSMutableSet<NSString *> *CXAppliedKeySet(void) {
    if (!CXAppliedKeys) CXAppliedKeys = [NSMutableSet set];
    return CXAppliedKeys;
}

static CGRect CXSanitizedTarget(CGRect saved, CGRect current, CGRect screen) {
    CGFloat w = MIN(saved.size.width, CGRectGetWidth(screen));
    CGFloat h = MIN(saved.size.height, CGRectGetHeight(screen));
    CGFloat x = saved.origin.x, y = saved.origin.y;
    if (!isfinite(x) || !isfinite(y)) {
        x = CGRectGetMidX(current) - w / 2.0;
        y = CGRectGetMidY(current) - h / 2.0;
    }
    x = MIN(MAX(x, CGRectGetMinX(screen)), CGRectGetMaxX(screen) - w);
    y = MIN(MAX(y, CGRectGetMinY(screen)), CGRectGetMaxY(screen) - h);
    return CGRectMake(x, y, w, h);
}

static void CXRememberLayoutApplied(void) {
    CXPendingApplied = YES;
    CXPendingKey = nil;
    CXPendingBridge = nil;
    CXPendingBundle = nil;
    CXPendingContainer = nil;
    CXPendingRect = CGRectZero;
}

void CXRememberApplySoon(NSString *bundleID, NSString *containerID) {
    if (!bundleID.length || !CXRememberOn()) { CXRememberLayoutApplied(); return; }
    NSString *container = containerID.length ? containerID : @"DEFAULT";
    NSString *key = CXKey(bundleID, container);
    NSDictionary *saved = CXSizeFor(bundleID, container);
    if (!saved) { CXRememberLayoutApplied(); return; }
    CGFloat w = [saved[@"w"] doubleValue], h = [saved[@"h"] doubleValue];
    if (!isfinite(w) || !isfinite(h) || w < 40 || h < 40) { CXRememberLayoutApplied(); return; }
    CGFloat x = saved[@"x"] ? [saved[@"x"] doubleValue] : NAN;
    CGFloat y = saved[@"y"] ? [saved[@"y"] doubleValue] : NAN;
    CXPendingGen++;
    CXPendingBridge = CXBoundBridge;
    CXPendingBundle = [bundleID copy];
    CXPendingContainer = [container copy];
    CXPendingKey = [key copy];
    CXPendingRect = CGRectMake(x, y, w, h);
    CXPendingApplied = NO;
    // PX alpha342 没有 layoutHost；在原生开窗完成后的多个布局窗口重试。
    NSInteger generation = CXPendingGen;
    NSArray *delays = @[@0.20, @0.55, @1.00, @1.60, @2.40, @3.20, @4.00];
    for (NSUInteger attempt = 0; attempt < delays.count; attempt++) {
        NSNumber *delay = delays[attempt];
        BOOL finalAttempt = (attempt + 1 == delays.count);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (generation != CXPendingGen || CXPendingApplied) return;
            id entry = CXRememberEntry ?: CXFindPanelEntry();
            id bridge = entry ? CXEntryBridge(entry) : CXPendingBridge;
            NSString *actualBundle = CXPXGetObject(bridge, @"bundleID");
            if (![actualBundle isKindOfClass:NSString.class] ||
                ![actualBundle isEqualToString:CXPendingBundle]) {
                CXLog(@"[remember] retry bundle expected=%@ actual=%@", CXPendingBundle,
                      [actualBundle isKindOfClass:NSString.class] ? actualBundle : @"<nil>");
                return;
            }
            UIView *card = entry ? CXEntryCard(entry) : nil;
            if (![card isKindOfClass:UIView.class] && bridge) {
                id value = CXPXGetObject(bridge, @"hostCard");
                if ([value isKindOfClass:UIView.class]) card = value;
            }
            if (![card isKindOfClass:UIView.class]) {
                CXLog(@"[remember] retry hostCard unavailable %@", CXPendingBundle);
                return;
            }
            if (!card.window || !card.superview) {
                CXLog(@"[remember] retry hostCard detached %@ window=%d superview=%d",
                      CXPendingBundle, card.window != nil, card.superview != nil);
                return;
            }
            UIView *surface = card.superview;
            CGRect screen = surface.bounds;
            if (CGRectIsEmpty(screen)) {
                CXLog(@"[remember] retry surface empty %@", CXPendingBundle);
                return;
            }
            CGRect target = CXSanitizedTarget(CXPendingRect, card.frame, screen);
            UIView *canvas = CXPXGetObject(bridge, @"canvas");
            if (![canvas isKindOfClass:UIView.class]) canvas = CXBoundCanvas;
            UIView *hostView = CXPXGetObject(bridge, @"hostView");
            if (![hostView isKindOfClass:UIView.class]) hostView = canvas;
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [card.layer removeAllAnimations];
            [canvas.layer removeAllAnimations];
            [hostView.layer removeAllAnimations];
            card.transform = CGAffineTransformIdentity;
            canvas.transform = CGAffineTransformIdentity;
            hostView.transform = CGAffineTransformIdentity;
            card.frame = target;
            card.bounds = (CGRect){ CGPointZero, target.size };
            if (canvas && canvas != card) {
                canvas.frame = card.bounds;
                canvas.bounds = (CGRect){ CGPointZero, card.bounds.size };
            }
            if (hostView && hostView != card && hostView != canvas) {
                hostView.frame = card.bounds;
                hostView.bounds = (CGRect){ CGPointZero, card.bounds.size };
            }
            [card setNeedsLayout];
            [canvas setNeedsLayout];
            [hostView setNeedsLayout];
            [surface setNeedsLayout];
            [card layoutIfNeeded];
            [canvas layoutIfNeeded];
            [hostView layoutIfNeeded];
            CXNormalizeContent(card, canvas, hostView);
            [CATransaction commit];
            CXPendingApplied = finalAttempt;
            if (finalAttempt && CXPendingKey) [CXAppliedKeySet() addObject:CXPendingKey];
            CXLog(@"[remember] apply-after-open %@ %.0f,%.0f %.0fx%.0f", CXPendingBundle,
                  card.frame.origin.x, card.frame.origin.y,
                  card.frame.size.width, card.frame.size.height);
        });
    }
}

static void CXApplyBeforeLayout(id self) {
    if (CXPendingApplied || CXPendingBridge != self) return;
    id entry = CXRememberEntry ?: CXFindPanelEntry();
    UIView *card = CXEntryCard(entry) ?: CXBoundHostCard();
    if (![card isKindOfClass:UIView.class]) return;
    UIView *surface = card.superview ?: card.window;
    CGRect screen = surface.bounds;
    if (CGRectIsEmpty(screen)) return;
    CXPendingApplied = YES;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    card.frame = CXSanitizedTarget(CXPendingRect, card.frame, screen);
    [CATransaction commit];
    [card setNeedsLayout];
    [surface setNeedsLayout];
    if (CXPendingKey) [CXAppliedKeySet() addObject:CXPendingKey];
    CXLog(@"[remember] apply-before-layout %@ %.0fx%.0f", CXPendingBundle,
          card.frame.size.width, card.frame.size.height);
}

static void CXLayoutHostHook(id self, SEL _cmd) {
    if (CXInLayoutApply) {
        if (CXOrigLayoutHost) CXOrigLayoutHost(self, _cmd);
        return;
    }
    CXInLayoutApply = YES;
    CXApplyBeforeLayout(self);
    if (CXOrigLayoutHost) CXOrigLayoutHost(self, _cmd);
    UIView *card = CXEntryCard(CXRememberEntry ?: CXFindPanelEntry());
    if ([card isKindOfClass:UIView.class]) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [card setNeedsLayout];
        [card.superview setNeedsLayout];
        [card layoutIfNeeded];
        [CATransaction commit];
    }
    CXInLayoutApply = NO;
    if (CXPendingApplied) CXRememberLayoutApplied();
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
            return result;
        });
        origInit = (InitFn)method_setImplementation(initMethod, newInit);
    }

    struct { const char *name; IMP imp; IMP *orig; } hooks[] = {
        {"applyResizePreview", (IMP)CXApplyResizePreview, (IMP *)&CXOrigApplyResizePreview},
        {"closeTapped", (IMP)CXCloseTapped, (IMP *)&CXOrigCloseTapped},
        {"resizeHost:", (IMP)CXResizeHostHook, (IMP *)&CXOrigResizeHost},
        {"layoutHost", (IMP)CXLayoutHostHook, (IMP *)&CXOrigLayoutHost},
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
    CXLog(@"[remember] memory-build=clone0.29 sha-marker=R029B");
    CXInstallRememberHooks();
}
