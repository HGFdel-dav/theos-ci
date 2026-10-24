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
#import "CXBuild.h"
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

// 这些应用依赖 PX 自己的场景几何；外部恢复尺寸会导致内容黑屏，先走原版路径。
static BOOL CXRememberTransformBlacklisted(NSString *bundleID) {
    static NSSet *blacklist;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        blacklist = [NSSet setWithObjects:
            @"com.pixelcyber.shu",          // Shu 文件
            @"com.crossutility.quantumult-x", // Quantumult X
            @"com.shanlian.pro",            // 闪连 VPN
            nil];
    });
    return [blacklist containsObject:bundleID];
}

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

static NSString *CXGeometrySlot(UIView *card) {
    CGSize host = card.superview ? card.superview.bounds.size : UIScreen.mainScreen.bounds.size;
    CGSize content = card ? card.bounds.size : CGSizeZero;
    return [NSString stringWithFormat:@"H%d-C%d", host.width > host.height,
            content.width > content.height];
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

static void CXStoreSize(NSString *bundle, NSString *container, UIView *card) {
    CGRect frame = card.frame;
    if (!CXRememberOn()) return;
    NSString *key = CXKey(bundle, container);
    if (!key || !isfinite(frame.origin.x) || !isfinite(frame.origin.y) ||
        !isfinite(frame.size.width) || !isfinite(frame.size.height) ||
        frame.size.width < 40 || frame.size.height < 40) return;
    if (frame.size.width > 5000 || frame.size.height > 5000) return;
    NSMutableDictionary *all = CXAllSizes();
    NSDictionary *record = [all[key] isKindOfClass:NSDictionary.class] ? all[key] : @{};
    NSMutableDictionary *slots = [record[@"slots"] isKindOfClass:NSDictionary.class] ? [record[@"slots"] mutableCopy] : [NSMutableDictionary dictionary];
    NSString *slot = CXGeometrySlot(card);
    NSDictionary *old = slots[slot];
    if ([old isKindOfClass:NSDictionary.class]) {
        double ox = old[@"x"] ? [old[@"x"] doubleValue] : NAN;
        double oy = old[@"y"] ? [old[@"y"] doubleValue] : NAN;
        double ow = [old[@"w"] doubleValue], oh = [old[@"h"] doubleValue];
        if (fabs(ow - frame.size.width) < 0.5 && fabs(oh - frame.size.height) < 0.5 &&
            fabs(ox - frame.origin.x) < 0.5 && fabs(oy - frame.origin.y) < 0.5) return; // 没变不写
    }
    slots[slot] = @{@"referenceW": @(card.superview.bounds.size.width),
                    @"referenceH": @(card.superview.bounds.size.height),
                    @"x": @(frame.origin.x), @"y": @(frame.origin.y),
                 @"w": @(frame.size.width), @"h": @(frame.size.height),
                 @"updated": @([[NSDate date] timeIntervalSince1970])};
    all[key] = @{@"version": @2, @"slots": slots};
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
static BOOL CXPendingApplied = YES;
static char CXRememberHiddenKey;
static __weak UIView *CXHiddenCard;
static BOOL CXPendingRevealed;
static CGFloat CXExpectedScale = 1.0;
static UIView *CXBoundHostCard(void);
static void CXSyncContentScale(UIView *card, id bridge, id entry);
static void CXCancelPendingRestore(void);
static BOOL CXNativeGeometryOpen = NO;
static void CXNotifyHostedGeometry(id entry, id bridge, UIView *card);

static void CXRememberHideInitialHost(void) {
    UIView *target = CXBoundHostCard();
    if (![target isKindOfClass:UIView.class]) target = CXBoundCanvas;
    if (![target isKindOfClass:UIView.class]) return;
    if (!objc_getAssociatedObject(target, &CXRememberHiddenKey))   // 已经藏过就别把 0 当成原值
        objc_setAssociatedObject(target, &CXRememberHiddenKey, @(target.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    target.alpha = 0.0;
}

static void CXRememberRevealHost(UIView *target) {
    CXPendingRevealed = YES;
    // 隐藏可能落在卡片上，也可能落在外层画布上，两处都要还原。
    NSArray *targets = @[target ?: NSNull.null, CXHiddenCard ?: NSNull.null,
                         CXBoundCanvas ?: NSNull.null, CXBoundHostCard() ?: NSNull.null];
    for (id item in targets) {
        if (item == NSNull.null) continue;
        UIView *view = item;
        NSNumber *oldAlpha = objc_getAssociatedObject(view, &CXRememberHiddenKey);
        if (!oldAlpha) continue;
        CGFloat target = oldAlpha.doubleValue;
        if (target < 0.05) target = 1.0;
        view.alpha = target;
        objc_setAssociatedObject(view, &CXRememberHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (view == CXHiddenCard) CXHiddenCard = nil;
    }
}

void CXRememberBindOpen(id bridge, UIView *canvas, NSString *bundleID, NSString *containerID) {
    if (!bridge || ![canvas isKindOfClass:UIView.class] || !bundleID.length) return;
    CXCancelPendingRestore();
    CXNativeGeometryOpen = CXRememberTransformBlacklisted(bundleID);
    if (CXNativeGeometryOpen) {
        CXBoundBridge = nil;
        CXBoundCanvas = nil;
        CXLog(@"[remember] native bypass %@: no hide/restore/scale", bundleID);
        return;
    }
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
    CXRememberHideInitialHost();
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
    id bridge = entry ? CXEntryBridge(entry) : nil;
    if (!bridge) bridge = CXBoundBridge;
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


static void CXStoreFailure(NSString *reason) {
    static NSString *lastReason;
    if ([lastReason isEqual:reason]) return;
    lastReason = reason;
    CXLog(@"[remember] capture skipped: %@", reason);
}

#pragma mark - 捕获（缩放结束 / 关闭）

static void (*CXOrigApplyResizePreview)(id, SEL);
static void (*CXOrigCloseTapped)(id, SEL);
static void (*CXOrigResizeHost)(id, SEL, id);
static void (*CXOrigMoveHost)(id, SEL, id);
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
    if (CXNativeGeometryOpen || CXRememberTransformBlacklisted(bundle)) return;
    id bridge = nil;
    UIView *card = nil;
    if (!CXGetHost(entry, bundle, &bridge, &card)) { CXStoreFailure(@"hostCard unavailable"); return; }
    // 缩放手势停手后原版已把 transform 清零并 setFrame；记录完整 frame（含贴边位置）。
    if (!CGAffineTransformIsIdentity(card.transform) || !CXPendingApplied) return;
    CXStoreSize(bundle, CXEntryContainer(entry), card);
    // 原生缩放过程里 PX 自己会处理内容，这里不再补缩放，避免叠加。

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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
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
    if (state == UIGestureRecognizerStateBegan) {
        CXOpenGeneration++;
        CXPendingGen++;
        CXPendingApplied = YES;
        CXLog(@"[remember] cancel pending restore for manual resize");
    }
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

static void CXMoveHostHook(id self, SEL command, id gesture) {
    CXRememberEntry = self;
    UIGestureRecognizerState state = [gesture isKindOfClass:UIGestureRecognizer.class]
        ? ((UIGestureRecognizer *)gesture).state : UIGestureRecognizerStatePossible;
    if (state == UIGestureRecognizerStateBegan) {
        CXPendingGen++;
        CXPendingApplied = YES;
        CXOpenGeneration++;
    }
    if (CXOrigMoveHost) CXOrigMoveHost(self, command, gesture);
    if (state == UIGestureRecognizerStateEnded || state == UIGestureRecognizerStateCancelled)
        CXScheduleCapture(self);
}

static NSDictionary *CXPendingRecord;
static NSDictionary *CXSelectGeometry(NSDictionary *record, UIView *card) {
    NSDictionary *slots = record[@"slots"];
    if (![slots isKindOfClass:NSDictionary.class]) return record;
    id selected = slots[CXGeometrySlot(card)];
    if ([selected isKindOfClass:NSDictionary.class]) return selected;
    CGSize host = card.superview ? card.superview.bounds.size : UIScreen.mainScreen.bounds.size;
    NSString *prefix = [NSString stringWithFormat:@"H%d-", host.width > host.height];
    NSDictionary *latest = nil;
    for (NSString *key in slots) {
        id candidate = slots[key];
        if (![key hasPrefix:prefix] || ![candidate isKindOfClass:NSDictionary.class]) continue;
        if (!latest || [candidate[@"updated"] doubleValue] > [latest[@"updated"] doubleValue]) latest = candidate;
    }
    return latest;
}

static CGRect CXResolvedGeometry(UIView *card) {
    NSDictionary *saved = CXSelectGeometry(CXPendingRecord, card);
    if (!saved) return card.frame;
    CGFloat w = [saved[@"w"] doubleValue], h = [saved[@"h"] doubleValue];
    CGFloat x = saved[@"x"] ? [saved[@"x"] doubleValue] : NAN;
    CGFloat y = saved[@"y"] ? [saved[@"y"] doubleValue] : NAN;
    CGSize reference = CGSizeMake([saved[@"referenceW"] doubleValue], [saved[@"referenceH"] doubleValue]);
    CGSize current = card.superview.bounds.size;
    if (!isfinite(w) || !isfinite(h) || w < 40 || h < 40) return card.frame;
    if (isfinite(reference.width) && isfinite(reference.height) && reference.width > 0 && reference.height > 0) {
        CGFloat sx = current.width / reference.width, sy = current.height / reference.height;
        x *= sx; y *= sy; w *= sx; h *= sy;
    }
    return CGRectMake(x, y, w, h);
}

#pragma mark - 恢复

static __weak id CXPendingBridge;
static NSString *CXPendingBundle, *CXPendingContainer;
static CGRect CXPendingRect = {0};
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
    CXRememberRevealHost(CXBoundHostCard());
    CXPendingApplied = YES;
    CXPendingKey = nil;
    CXPendingBridge = nil;
    CXPendingBundle = nil;
    CXPendingContainer = nil;
    CXPendingRect = CGRectZero;
    CXPendingRecord = nil;
}

static void CXCancelPendingRestore(void) {
    CXOpenGeneration++;
    CXCaptureGeneration++;
    CXPendingGen++;
    CXRememberLayoutApplied();
}

static void CXRememberTickApply(NSInteger generation);
static void CXRememberRetryLater(NSInteger generation);
static BOOL CXUserTouching(void);
static void CXSettleTick(NSInteger generation, CGRect target, NSInteger quiet, NSInteger ticks);
static void CXApplyFrameToCard(UIView *card, id bridge, id entry, CGRect target);
static void CXNotifyHostedGeometry(id entry, id bridge, UIView *card);
static void CXLogSelectorsOnce(id entry, id bridge, UIView *card);
static void CXLogTree(UIView *view, NSInteger depth);
static NSInteger CXPendingTries = 0;
static BOOL CXPendingPrepareAt = NO;
static BOOL CXPendingFallback = NO;


void CXRememberApplySoon(NSString *bundleID, NSString *containerID) {
    if (!bundleID.length || !CXRememberOn() || CXNativeGeometryOpen ||
        CXRememberTransformBlacklisted(bundleID)) {
        CXCancelPendingRestore();
        return;
    }
    NSString *container = containerID.length ? containerID : @"DEFAULT";
    NSString *key = CXKey(bundleID, container);
    NSDictionary *saved = CXSizeFor(bundleID, container);
    if (!saved) { CXRememberLayoutApplied(); return; }
    CXPendingRecord = saved;
    NSDictionary *initial = CXSelectGeometry(saved, CXBoundHostCard());
    if (!initial) { CXRememberLayoutApplied(); return; }
    saved = initial;
    CGFloat w = [saved[@"w"] doubleValue], h = [saved[@"h"] doubleValue];
    if (!isfinite(w) || !isfinite(h) || w < 40 || h < 40) { CXRememberLayoutApplied(); return; }
    CGFloat x = saved[@"x"] ? [saved[@"x"] doubleValue] : NAN;
    CGFloat y = saved[@"y"] ? [saved[@"y"] doubleValue] : NAN;
    CXPendingGen++;
    CXPendingTries = 0;
    CXPendingBridge = CXBoundBridge;
    CXPendingBundle = [bundleID copy];
    CXPendingContainer = [container copy];
    CXPendingKey = [key copy];
    CXPendingRect = CGRectMake(x, y, w, h);
    CXPendingApplied = NO;
    // 不再用多组延迟硬压 frame。等两件事都成立再套一次：
    //   ① PX 真正开始建窗（prepareWindow 之后），或 2.6s 内没收到建窗信号才自己兜底；
    //   ② hostCard 已挂到窗口、尺寸有效、用户没在拖。
    CXPendingPrepareAt = NO;
    CXPendingFallback = NO;
    CXPendingRevealed = NO;
    NSInteger generation = CXPendingGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != CXPendingGen || CXPendingPrepareAt) return;
        CXPendingFallback = YES;
        if (CXPendingApplied) return;
        CXRememberTickApply(generation);
    });
}

void CXRememberApplyAfterPrepare(NSString *bundleID) {
    if (CXNativeGeometryOpen || CXRememberTransformBlacklisted(bundleID)) return;
    if (!CXPendingBundle.length) return;
    if (CXPendingApplied) {
        if (!CXPendingFallback) return;
        if (!CXUserTouching()) CXPendingApplied = NO;
        else return;
    }
    if (bundleID.length && ![bundleID isEqual:CXPendingBundle]) return;
    CXPendingPrepareAt = 1;
    CXLog(@"[remember] prepare seen %@", CXPendingBundle);
    CXRememberTickApply(CXPendingGen);
}

static BOOL CXUserTouching(void) {
    id entry = CXRememberEntry ?: CXFindPanelEntry();
    if (!entry) return NO;
    if ([objc_getAssociatedObject(entry, &CXResizeActiveKey) boolValue]) return YES;
    return CXPXEntryFlag(entry, "fullscreenToWindowInProgress") ||
           CXPXEntryFlag(entry, "fullscreenLaunchInProgress");
}

// PX 的宿主用 sourceSize + scale 把内容缩放到卡片大小，
// 只改 frame 不让它重算就会内容偏大/偏小。这里尽量走它自己的几何更新。
static void CXNotifyHostedGeometry(id entry, id bridge, UIView *card) {
    NSString *name = @"PXHostedGeometryChanged";
    NSNotification *note = [NSNotification notificationWithName:name object:card];
    NSArray *candidates = @[card ?: NSNull.null, bridge ?: NSNull.null, entry ?: NSNull.null];
    SEL sel = NSSelectorFromString(@"hostedGeometryChanged:");
    BOOL called = NO;
    for (id target in candidates) {
        if (target == NSNull.null || ![target respondsToSelector:sel]) continue;
        @try { ((void (*)(id, SEL, id))objc_msgSend)(target, sel, note); }
        @catch (NSException *e) { CXLog(@"[remember] geom 异常 %@", e.reason); }
        called = YES;
    }
    if (!called) {
        Method m = class_getInstanceMethod([card class], sel);
        CXLog(@"[remember] hostedGeometryChanged: 不可用 %@", m ? @(method_getTypeEncoding(m)) : @"none");
    }
    [NSNotificationCenter.defaultCenter postNotificationName:name object:card];
}

// 只负责把当前待恢复几何套到已挂载的卡片上，最多一次修正。
static void CXRememberTickApply(NSInteger generation) {
    if (generation != CXPendingGen || CXPendingApplied) return;
    id entry = CXRememberEntry ?: CXFindPanelEntry();
    id bridge = entry ? CXEntryBridge(entry) : CXPendingBridge;
    NSString *actualBundle = CXPXGetObject(bridge, @"bundleID");
    if (![actualBundle isKindOfClass:NSString.class] ||
        ![actualBundle isEqualToString:CXPendingBundle]) {
        CXRememberRevealHost(CXHiddenCard);
        return;
    }
    UIView *card = entry ? CXEntryCard(entry) : nil;
    if (![card isKindOfClass:UIView.class] && bridge) {
        id value = CXPXGetObject(bridge, @"hostCard");
        if ([value isKindOfClass:UIView.class]) card = value;
    }
    UIView *surface = card.superview ?: card.window;
    if (!card.window || !surface || CGRectIsEmpty(surface.bounds)) {
        CXRememberRetryLater(generation);
        return;
    }
    CGRect target = CXSanitizedTarget(CXResolvedGeometry(card), card.frame, surface.bounds);
    if (CGRectGetMaxX(target) < 0) { CXRememberRetryLater(generation); return; }
    CXPendingApplied = YES;
    UIView *canvas = CXPXGetObject(bridge, @"canvas");
    if (![canvas isKindOfClass:UIView.class]) canvas = CXBoundCanvas;
    UIView *hostView = CXPXGetObject(bridge, @"hostView");
    if (![hostView isKindOfClass:UIView.class]) hostView = canvas;
    CXRememberHideInitialHost();
    CXLogSelectorsOnce(entry, bridge, card);
    @try {
        CXApplyFrameToCard(card, bridge, entry, target);
    } @catch (NSException *e) {
        CXLog(@"[remember] apply 异常 %@ %@", e.name, e.reason);
    }
    CXLog(@"[remember] apply-once %@ %.0f,%.0f %.0fx%.0f", CXPendingBundle,
          target.origin.x, target.origin.y, target.size.width, target.size.height);
    // 卡片一直藏着，每 0.1s 看一次：被 PX 顶偏就按回去，连续两次没跑偏才显示。
    CXSettleTick(generation, target, 0, 0);
}

static void CXApplyFrameToCard(UIView *card, id bridge, id entry, CGRect target) {
    if (CXNativeGeometryOpen || CXRememberTransformBlacklisted(CXPXGetObject(bridge, @"bundleID"))) return;
    UIView *canvas = CXPXGetObject(bridge, @"canvas");
    if (![canvas isKindOfClass:UIView.class]) canvas = CXBoundCanvas;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [card.layer removeAllAnimations];
    [canvas.layer removeAllAnimations];
    card.transform = CGAffineTransformIdentity;
    card.frame = target;
    // ScreenCore 的做法：内容保持原始尺寸，用缩放变换套进容器，而不是改内容尺寸。
    [card.superview setNeedsLayout];
    [CATransaction commit];
    // 内容按“场景参考尺寸”摆放，再整体缩放到目标尺寸（ScreenCore 的参考尺寸模型）。
    CGSize source = CGSizeZero;
    SEL srcSel = NSSelectorFromString(@"hostedSourceSize");
    if (bridge && [bridge respondsToSelector:srcSel]) {
        source = ((CGSize (*)(id, SEL))objc_msgSend)(bridge, srcSel);
    }
    if (source.width < 1 || source.height < 1) source = canvas.bounds.size;
    if (source.width < 1 || source.height < 1) source = target.size;
    for (UIView *layerView in @[canvas]) {
        if (fabs(layerView.bounds.size.width - source.width) > 8 ||
            fabs(layerView.bounds.size.height - source.height) > 8) {
            layerView.bounds = (CGRect){ CGPointZero, source };
            layerView.frame = (CGRect){ layerView.frame.origin, source };
        }
        CXExpectedScale = target.size.width / source.width;
        layerView.transform = CGAffineTransformIdentity;
        layerView.layer.sublayerTransform = CATransform3DMakeScale(CXExpectedScale, CXExpectedScale, 1.0);
        if (layerView.superview == card) {
            layerView.center = CGPointMake(target.size.width / 2.0, target.size.height / 2.0);
        } else if (layerView.superview) {
            layerView.center = [card convertPoint:CGPointMake(CGRectGetMidX(card.bounds),
                                                              CGRectGetMidY(card.bounds))
                                           toView:layerView.superview];
        }
    }
    CXNotifyHostedGeometry(entry, bridge, card);
}

// 只把内容缩放同步到卡片当前尺寸，不动卡片本身（供缩放结束后用）。
static void CXSyncContentScale(UIView *card, id bridge, id entry) {
    if (CXNativeGeometryOpen || CXRememberTransformBlacklisted(CXPXGetObject(bridge, @"bundleID"))) return;
    UIView *canvas = CXPXGetObject(bridge, @"canvas");
    if (![canvas isKindOfClass:UIView.class]) canvas = CXBoundCanvas;
    if (![canvas isKindOfClass:UIView.class]) return;
    CGSize source = CGSizeZero;
    SEL srcSel = NSSelectorFromString(@"hostedSourceSize");
    if (bridge && [bridge respondsToSelector:srcSel])
        source = ((CGSize (*)(id, SEL))objc_msgSend)(bridge, srcSel);
    if (source.width < 1 || source.height < 1) source = canvas.bounds.size;
    if (source.width < 1 || source.height < 1) return;
    CGRect frame = card.frame;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CXExpectedScale = frame.size.width / source.width;
    canvas.transform = CGAffineTransformIdentity;
    canvas.layer.sublayerTransform = CATransform3DMakeScale(CXExpectedScale, CXExpectedScale, 1.0);
    if (canvas.superview == card)
        canvas.center = CGPointMake(frame.size.width / 2.0, frame.size.height / 2.0);
    else if (canvas.superview)
        canvas.center = [card convertPoint:CGPointMake(CGRectGetMidX(card.bounds), CGRectGetMidY(card.bounds))
                                   toView:canvas.superview];
    [CATransaction commit];
    CXNotifyHostedGeometry(entry, bridge, card);
}

static void CXLogSelectorsOnce(id entry, id bridge, UIView *card) {
    static NSInteger loggedGen = -1;
    if (loggedGen == CXPendingGen) return;
    loggedGen = CXPendingGen;
    NSString *cardSels = [NSString stringWithFormat:@"sourceSize=%d setSourceSize=%d scale=%d setScale=%d hostGeom=%d",
        [card respondsToSelector:NSSelectorFromString(@"sourceSize")],
        [card respondsToSelector:NSSelectorFromString(@"setSourceSize:")],
        [card respondsToSelector:NSSelectorFromString(@"scale")],
        [card respondsToSelector:NSSelectorFromString(@"setScale:")],
        [card respondsToSelector:NSSelectorFromString(@"hostedGeometryChanged:")]];
    UIView *canvas = CXPXGetObject(bridge, @"canvas");
    if (![canvas isKindOfClass:UIView.class]) canvas = CXBoundCanvas;
    NSString *src = @"-";
    SEL srcSel = NSSelectorFromString(@"hostedSourceSize");
    if ([bridge respondsToSelector:srcSel]) {
        CGSize size = ((CGSize (*)(id, SEL))objc_msgSend)(bridge, srcSel);
        src = [NSString stringWithFormat:@"%.0fx%.0f", size.width, size.height];
    }
    CXLog(@"[probe] card %@ / hostedSourceSize=%@ canvas=%.0fx%.0f scale=%.3f/%.3f cardFrame=%.0fx%.0f",
          cardSels, src, canvas.bounds.size.width, canvas.bounds.size.height,
          canvas.transform.a, canvas.transform.d, card.frame.size.width, card.frame.size.height);
    CXLogTree(card, 0);
}

static void CXLogTree(UIView *view, NSInteger depth) {
    if (depth > 2 || ![view isKindOfClass:UIView.class]) return;
    CXLog(@"[tree] %@ f=%.0f,%.0f %.0fx%.0f b=%.0fx%.0f s=%.3f a=%.2f sub=%lu",
          NSStringFromClass(view.class), view.frame.origin.x, view.frame.origin.y,
          view.frame.size.width, view.frame.size.height, view.bounds.size.width,
          view.bounds.size.height, view.transform.a, view.alpha,
          (unsigned long)view.subviews.count);
    for (UIView *child in view.subviews) CXLogTree(child, depth + 1);
}

// 藏着的这段时间里反复钉住目标几何，稳定后才显示。
static void CXSettleTick(NSInteger generation, CGRect target, NSInteger quiet, NSInteger ticks) {
    if (generation != CXPendingGen) return;
    if (ticks > 8) {
        CXLog(@"[remember] settle timeout");
        CXRememberRevealHost(CXBoundHostCard());
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != CXPendingGen || CXNativeGeometryOpen) return;
        id entry = CXRememberEntry ?: CXFindPanelEntry();
        UIView *card = entry ? CXEntryCard(entry) : nil;
        if (![card isKindOfClass:UIView.class] || !card.window) {
            CXRememberRevealHost(CXBoundHostCard());
            return;
        }
        UIView *canvasNow = CXPXGetObject(entry ? CXEntryBridge(entry) : nil, @"canvas");
        if (![canvasNow isKindOfClass:UIView.class]) canvasNow = CXBoundCanvas;
        CGFloat scaleDrift = fabs(canvasNow.layer.sublayerTransform.m11 - CXExpectedScale) > 0.02 ? 40.0 : 0.0;
        CGFloat drift = scaleDrift + fabs(card.frame.origin.x - target.origin.x) +
                        fabs(card.frame.origin.y - target.origin.y) +
                        fabs(card.frame.size.width - target.size.width) +
                        fabs(card.frame.size.height - target.size.height);
        if (drift > 1.5) {
            id bridge = entry ? CXEntryBridge(entry) : nil;
            @try { CXApplyFrameToCard(card, bridge, entry, target); }
            @catch (NSException *e) { CXLog(@"[remember] re-pin 异常 %@", e.reason); }
            CXLog(@"[remember] re-pin drift %.1f", drift);
            CXSettleTick(generation, target, 0, ticks + 1);
            return;
        }
        if (quiet >= 2) {
            CXRememberRevealHost(card);
            CXLog(@"[remember] shown after settle cardAlpha=%.2f", card.alpha);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (generation != CXPendingGen || CXNativeGeometryOpen) return;
                CXRememberRevealHost(card);
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (generation != CXPendingGen || CXNativeGeometryOpen) return;
                UIView *c = CXEntryCard(CXRememberEntry ?: CXFindPanelEntry());
                if (![c isKindOfClass:UIView.class]) return;
                UIView *cv = c.subviews.firstObject;
                CXLog(@"[post] card a=%.2f f=%.0fx%.0f win=%.0fx%.0f sub=%@ f=%.0fx%.0f sc=%.2f",
                      c.alpha, c.frame.size.width, c.frame.size.height,
                      c.window.bounds.size.width, c.window.bounds.size.height,
                      NSStringFromClass(cv.class), cv.frame.size.width, cv.frame.size.height, cv.layer.sublayerTransform.m11);
            });
            return;
        }
        CXSettleTick(generation, target, quiet + 1, ticks + 1);
    });
}

static void CXRememberRetryLater(NSInteger generation) {
    if (generation != CXPendingGen || CXPendingApplied) return;
    if (++CXPendingTries > 20) { CXLog(@"[remember] give up waiting hostCard"); CXRememberRevealHost(CXBoundHostCard()); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ CXRememberTickApply(generation); });
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
    card.frame = CXSanitizedTarget(CXResolvedGeometry(card), card.frame, screen);
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

// 卡片第一次挂到窗口时就藏起来，避免它先以默认位置露一帧再被挪走。
static void (*CXOrigDidMoveToWindow)(id, SEL);
static void CXCardDidMoveToWindow(id self, SEL _cmd) {
    if (CXOrigDidMoveToWindow) CXOrigDidMoveToWindow(self, _cmd);
    if (CXNativeGeometryOpen || CXPendingApplied || CXPendingRevealed || !CXPendingBundle.length) return;
    UIView *view = (UIView *)self;
    if (!view.window || view != CXBoundHostCard()) return;
    if (!objc_getAssociatedObject(view, &CXRememberHiddenKey))
        objc_setAssociatedObject(view, &CXRememberHiddenKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CXHiddenCard = view;
    view.alpha = 0.0;
}

static Class CXHostCardClass(void) {
    static Class found;
    if (found) return found;
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return nil;
    Class *classes = (Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return nil;
    objc_getClassList(classes, count);
    for (int i = 0; i < count; i++) {
        const char *name = class_getName(classes[i]);
        if (name && strstr(name, "PXHostCard")) { found = classes[i]; break; }
    }
    free(classes);
    return found;
}

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
        origInit = (InitFn)method_getImplementation(initMethod);
        if (!class_addMethod(cls, initSel, newInit, method_getTypeEncoding(initMethod)))
            origInit = (InitFn)method_setImplementation(initMethod, newInit);
    }

    struct { const char *name; IMP imp; IMP *orig; } hooks[] = {
        {"applyResizePreview", (IMP)CXApplyResizePreview, (IMP *)&CXOrigApplyResizePreview},
        {"closeTapped", (IMP)CXCloseTapped, (IMP *)&CXOrigCloseTapped},
        {"resizeHost:", (IMP)CXResizeHostHook, (IMP *)&CXOrigResizeHost},
        {"moveHost:", (IMP)CXMoveHostHook, (IMP *)&CXOrigMoveHost},
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
        *hooks[i].orig = method_getImplementation(m);
        if (!class_addMethod(cls, sel, hooks[i].imp, method_getTypeEncoding(m)))
            *hooks[i].orig = method_setImplementation(m, hooks[i].imp);
        CXLog(@"[remember] hook %s ok", hooks[i].name);
    }
    Class cardCls = CXHostCardClass();
    Method didMove = cardCls ? class_getInstanceMethod(cardCls, NSSelectorFromString(@"didMoveToWindow")) : NULL;
    if (didMove) {
        SEL moveSel = NSSelectorFromString(@"didMoveToWindow");
        CXOrigDidMoveToWindow = (void (*)(id, SEL))method_getImplementation(didMove);
        if (!class_addMethod(cardCls, moveSel, (IMP)CXCardDidMoveToWindow, method_getTypeEncoding(didMove)))
            CXOrigDidMoveToWindow = (void (*)(id, SEL))method_setImplementation(didMove, (IMP)CXCardDidMoveToWindow);
        CXLog(@"[remember] hook didMoveToWindow on %@", NSStringFromClass(cardCls));
    } else {
        CXLog(@"[remember] PXHostCard/didMoveToWindow 不可用");
    }
    installed = YES;
}

void CXRememberStart(void) {
    CXLog(@"[remember] memory-build=%@", CX_BUILD_TAG);
    CXInstallRememberHooks();
}
