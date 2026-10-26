// CXArcWake.m
//
// ScreenCore 式角落拖拽唤醒 → 驱动 ParallelX 自己的手柄手势。
//
// 从角落向内拖动 → 扇形菜单（PX 的菜单条目与应用本体图标）→ 松开选中，
// 再走 PX 已验证的 externalOpenApplication 分屏链路。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>
#import "CXArcWake.h"
#import "CXLog.h"
#import "CXPrefs.h"
#import "CXArcSettings.h"
#import "CXArcGeometry.h"
#import "CXPXRuntime.h"
#import "CXArcMenu.h"
#import <CoreFoundation/CoreFoundation.h>
void CXOpenMenuItem(NSString *identifier);
#include <math.h>

// 复用旧系统通道、触发形状和不拦截的调试层；菜单/图标仍全部由 PX 绘制。
static __weak id CXLiveEntry;
static CGFloat CXArcNumber(NSString *key) {
    id value = [CXPrefs.shared objectForKey:key] ?: CXArcDefaultValue(key);
    double n = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0;
    return isfinite(n) ? n : [CXArcDefaultValue(key) doubleValue];
}
static BOOL CXArcEnabled(void) {
    return [CXPrefs.shared boolForKey:@"CXArcEnabled" defaultValue:YES];
}

// 仅在系统手势注册/角落手势处理期间短暂落盘。若 SpringBoard 崩溃，下次启动关闭系统通道；
// 使用原始 CFPreferences 避免在每次触摸时发设置变更通知、重入刷新流程。
static NSUInteger CXCrashGuardEpoch;
static void CXCrashGuardWrite(BOOL pending) {
    CFStringRef domain = CFSTR("com.niubiprass.clonex");
    CFPreferencesSetAppValue(CFSTR("CXArcChannelPending"), (__bridge CFPropertyListRef)@(pending), domain);
    CFPreferencesAppSynchronize(domain);
}
static void CXCrashGuardArm(void) {
    NSUInteger epoch = ++CXCrashGuardEpoch;
    CXCrashGuardWrite(YES);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (epoch == CXCrashGuardEpoch) CXCrashGuardWrite(NO);
    });
}
static void CXCrashGuardDisarm(void) {
    ++CXCrashGuardEpoch;
    CXCrashGuardWrite(NO);
}

static UIBezierPath *CXArcPath(BOOL left) {
    return CXArcTriggerPath(left, (NSInteger)CXArcNumber(@"CXArcTriggerRegionMode"),
        CXArcNumber(@"CXArcRadius"), CXArcNumber(@"CXArcRectangleLength"),
        CXArcNumber(@"CXArcRectangleHeight"), CXArcNumber(@"CXArcRectangleCornerRadius"),
        CXArcNumber(@"CXArcOffsetX"), CXArcNumber(@"CXArcOffsetY"), UIScreen.mainScreen.bounds);
}
static NSInteger CXArcSideAtPoint(CGPoint point) {
    @try {
        if (!CXArcEnabled()) return -1;
        NSInteger side = (NSInteger)CXArcNumber(@"CXArcSide");
        // side=1 左下，side=0 右下，side=2 两侧；先按 x 分流，避免左右路径重叠时右侧优先。
        if ((side == 1 || side == 2) && point.x <= CGRectGetMidX(UIScreen.mainScreen.bounds) && [CXArcPath(YES) containsPoint:point]) return 1;
        if ((side == 0 || side == 2) && point.x >= CGRectGetMidX(UIScreen.mainScreen.bounds) && [CXArcPath(NO) containsPoint:point]) return 0;
    } @catch (__unused NSException *e) { return -1; }
    return -1;
}

static CGPoint CXArcTouchPoint(UITouch *touch) {
    UIWindow *window = touch.window;
    if (!window) return [touch locationInView:nil];
    CGPoint point = [touch locationInView:window];
    return [window convertPoint:point toCoordinateSpace:UIScreen.mainScreen.coordinateSpace];
}
static CGPoint CXArcGesturePoint(UIPanGestureRecognizer *gesture) {
    UIWindow *window = gesture.view.window;
    CGPoint point = window ? [gesture locationInView:window] : [gesture locationInView:nil];
    if (window) point = [window convertPoint:point toCoordinateSpace:UIScreen.mainScreen.coordinateSpace];
    // 系统通道上的 recognizer 可能没有 view/window；locationInView:nil
    // 仍返回屏幕坐标，不能把该情况当成 (0,0)。
    if (CGPointEqualToPoint(point, CGPointZero) && gesture.numberOfTouches > 0)
        point = [gesture locationOfTouch:0 inView:nil];
    return point;
}

static BOOL CXArcPointIsZero(CGPoint point) {
    return point.x == 0 && point.y == 0;
}

#pragma mark - PX 对象查找

static id CXFindPanelEntry(void) {
    if (CXLiveEntry) return CXLiveEntry;
    // 初始化已经发生才载入时：查真实 UIKit 手势 target，不在响应链里造对象。
    // UIGestureRecognizerTarget 有公开于运行时的 target getter（旧 UIKit header 已核对）。
    Class px = NSClassFromString(@"PXPanelEntry");
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (![NSStringFromClass(window.class) containsString:@"PXHandleWindow"]) continue;
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
        for (NSUInteger i = 0; i < queue.count && i < 128; i++) {
            UIView *view = queue[i];
            [queue addObjectsFromArray:view.subviews];
            for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
                @try {
                    id targets = [gesture valueForKey:@"_targets"];
                    if (![targets isKindOfClass:NSArray.class]) continue;
                    for (id record in targets) {
                        id target = CXPXGetObject(record, @"target");
                        if (px && [target isKindOfClass:px]) {
                            CXArcWakeCaptureEntry(target);
                            return target;
                        }
                    }
                } @catch (__unused NSException *e) { }
            }
        }
    }
    return nil;
}

void CXArcWakeSync(void);
void CXArcWakeCaptureEntry(id entry) {
    Class cls = NSClassFromString(@"PXPanelEntry");
    if (!entry || !cls || ![entry isKindOfClass:cls]) return;
    BOOL first = !CXLiveEntry;
    if (CXLiveEntry != entry) CXLog(@"[arc] captured real PXPanelEntry");
    CXLiveEntry = entry;
    if (first && NSThread.isMainThread) CXArcWakeSync(); // 首次拿到实例后补挂调试层
}

// 原版 PXPanelEntry 的 panelWindow 是 Optional<UIWindow>；其 Swift ivar
// 在当前 arm64e 二进制中没有 ObjC type encoding。按已核证的空 type、8 字节
// 槽和边界读取，避免把 String?/tuple 当对象；其它字段仍走 CXPXRuntime 白名单。
static UIWindow *CXReadPanelWindow(id entry) {
    Class cls = NSClassFromString(@"PXPanelEntry");
    if (!entry || !cls || ![entry isKindOfClass:cls]) return nil;
    Ivar ivar = class_getInstanceVariable(cls, "panelWindow");
    if (!ivar) return nil;
    const char *type = ivar_getTypeEncoding(ivar);
    ptrdiff_t offset = ivar_getOffset(ivar);
    if ((type && type[0]) || offset < 0 || (size_t)offset + sizeof(id) > class_getInstanceSize(cls)) return nil;
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    ptrdiff_t end = (ptrdiff_t)class_getInstanceSize(cls);
    for (unsigned int i = 0; ivars && i < count; i++) {
        ptrdiff_t next = ivar_getOffset(ivars[i]);
        if (next > offset && next < end) end = next;
    }
    free(ivars);
    if (end - offset != (ptrdiff_t)sizeof(id)) return nil;
    id __unsafe_unretained value = nil;
    memcpy(&value, (const uint8_t *)(__bridge const void *)entry + offset, sizeof(value));
    return [value isKindOfClass:UIWindow.class] ? value : nil;
}

// Getter fallback is retained for builds that expose panelWindow dynamically.
static UIWindow *CXReadEntryWindow(id entry, const char *name) {
    if (!entry || !name) return nil;
    SEL sel = sel_registerName(name);
    @try {
        if (![entry respondsToSelector:sel]) return nil;
        id value = ((id (*)(id, SEL))objc_msgSend)(entry, sel);
        return [value isKindOfClass:UIWindow.class] ? value : nil;
    } @catch (__unused NSException *e) { return nil; }
}

// 菜单图标在 panelWindow；handleWindow 只是手柄条。
// 两个都读不到时再退回 PX 的所有窗口，交给扇形扫描去找 PXPanelIcon。
static NSArray<UIWindow *> *CXMenuWindows(void) {
    NSMutableArray<UIWindow *> *list = [NSMutableArray array];
    void (^addVisible)(UIWindow *) = ^(UIWindow *w) {
        if (w && !w.hidden && ![list containsObject:w]) [list addObject:w];
    };
    id entry = CXFindPanelEntry();
    // panelWindow can remain hidden while PX is constructing the menu. Keep it
    // in the scan so its PXPanelIcon subviews can still be arranged.
    UIWindow *panel = CXReadPanelWindow(entry) ?: CXReadEntryWindow(entry, "panelWindow");
    if (panel && ![list containsObject:panel]) [list addObject:panel];
    addVisible(CXPXEntryObject(entry, "handleWindow", UIWindow.class));
    addVisible(CXPXEntryObject(entry, "hostWindow", UIWindow.class));
    if (!list.count) {
        for (UIWindow *w in UIApplication.sharedApplication.windows)
            if ([NSStringFromClass(w.class) containsString:@"PX"]) addVisible(w);
    }
    return list;
}

#pragma mark - 手势

static BOOL CXIsPXHandleWindow(UIWindow *window);

@class CXArcWakeGesture;
static __weak CXArcWakeGesture *CXActiveArc;

@interface CXArcWakeGesture : UIPanGestureRecognizer <UIGestureRecognizerDelegate>
- (void)cancelForwarding;
- (void)handleUnsafe:(UIPanGestureRecognizer *)gesture;
@end

// 合成手势：PX 只读这些方法驱动它自己的菜单与动画
@interface CXSynthPan : UIPanGestureRecognizer
@property (nonatomic, assign) UIGestureRecognizerState synthState;
@property (nonatomic, assign) CGPoint synthTranslation;
@property (nonatomic, assign) CGPoint synthLocation;
@property (nonatomic, assign) CGPoint synthVelocity;
@end
@implementation CXSynthPan
- (UIGestureRecognizerState)state { return self.synthState; }
- (CGPoint)translationInView:(UIView *)view { return self.synthTranslation; }
- (CGPoint)locationInView:(UIView *)view { return self.synthLocation; }
- (CGPoint)velocityInView:(UIView *)view { return self.synthVelocity; }
@end

// PX 的动画 block 在 dragHandle: 返回后可能仍引用合成手势，摘下后暂存以避免悬空指针。
static NSMutableArray<CXSynthPan *> *CXSynthPool(void) {
    static NSMutableArray<CXSynthPan *> *pool;
    if (!pool) pool = [NSMutableArray array];
    return pool;
}

static NSArray<NSString *> *CXMenuIDs(void) {
    CFPreferencesAppSynchronize(CFSTR("com.moxuan.parallelx"));
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("applications"), CFSTR("com.moxuan.parallelx"));
    NSArray *raw = v ? (__bridge_transfer NSArray *)v : nil;
    NSMutableArray *ids = [NSMutableArray array];
    if ([raw isKindOfClass:NSArray.class])
        for (id x in raw) if ([x isKindOfClass:NSString.class] && [x length]) [ids addObject:x];
    return ids;
}

@implementation CXArcWakeGesture {
    CXSynthPan *_synth;
    id _entry;
    NSArray<UIView *> *_icons;
    CGPoint _start;
    CGPoint _lastPoint;
    BOOL _armed;
    BOOL _left;
    BOOL _rearranged;
    CFTimeInterval _lastArrange;
}

- (instancetype)init {
    if ((self = [super initWithTarget:nil action:NULL])) {
        self.delegate = self;
        self.maximumNumberOfTouches = 1;
        self.minimumNumberOfTouches = 1;
        self.cancelsTouchesInView = NO;
        self.delaysTouchesBegan = NO;
        self.delaysTouchesEnded = NO;
        [self addTarget:self action:@selector(handle:)];
    }
    return self;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
    // 系统通道下全屏每个触摸都会进这里，异常绝不能漏回 UIKit，否则 SpringBoard 直接安全模式
    @try {
        if (CXIsPXHandleWindow(touch.window)) return NO;
        CGPoint point = CXArcTouchPoint(touch);
        NSInteger side = CXArcSideAtPoint(point);
        if (side < 0 || CXPXEntryFlag(CXLiveEntry, "deviceLocked")) return NO;
        if (_synth || (CXActiveArc && CXActiveArc != self)) return NO;
        _start = point;
        _lastPoint = point;
        _left = side == 1;
        _armed = YES;
        return YES;
    } @catch (NSException *e) { _armed = NO; return NO; }
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    @try {
        return _armed && CXArcEnabled() && (!CXActiveArc || CXActiveArc == self);
    } @catch (NSException *e) { return NO; }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other { return YES; }

- (UIWindow *)handleWindow { return CXMenuWindows().firstObject; }

- (void)cleanup {
    CXSynthPan *synth = _synth;
    [synth.view removeGestureRecognizer:synth];
    if (synth) {
        [CXSynthPool() addObject:synth];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [CXSynthPool() removeObjectIdenticalTo:synth];
        });
    }
    _synth = nil;
    _entry = nil;
    _icons = nil;
    _armed = NO;
    _start = CGPointZero;
    _lastPoint = CGPointZero;
    _rearranged = NO;
    if (CXActiveArc == self) CXActiveArc = nil;
}

- (void)cancelForwarding { [self cleanup]; }

// PX 布局会覆盖位置，每次转发后重新排成扇形
- (void)rearrange {
    _lastArrange = CACurrentMediaTime();
    @try {
        NSArray<UIWindow *> *windows = CXMenuWindows();
        if (!windows.count) {
            CXLog(@"[arc] rearrange no PX windows");
            return;
        }
        NSArray<UIView *> *icons = CXFanIconsInWindows(windows);
        if (!icons.count) {
            CXLog(@"[arc] rearrange no PXPanelIcon windows=%lu", (unsigned long)windows.count);
            return;
        }
        UIWindow *window = icons.firstObject.window ?: windows.firstObject;
        _icons = icons;
        CXFanArrange(icons, window, _left);
        _rearranged = YES;
    } @catch (__unused NSException *e) { }
}

- (void)handle:(UIPanGestureRecognizer *)g {
    @try { [self handleUnsafe:g]; }
    @catch (NSException *e) { CXLog(@"[arc] handle 异常：%@", e.reason); [self cleanup]; }
}

- (void)handleUnsafe:(UIPanGestureRecognizer *)g {
    if (!CXArcEnabled()) { [self cleanup]; return; }
    CGPoint point = CXArcGesturePoint(g);
    if (!CXArcPointIsZero(point)) _lastPoint = point;
    else if (!CXArcPointIsZero(_lastPoint)) point = _lastPoint;
    if (g.state == UIGestureRecognizerStateBegan) {
        if (!_armed || (CXActiveArc && CXActiveArc != self)) return;
        id entry = CXFindPanelEntry();
        UIWindow *window = nil;
        for (UIWindow *w in CXMenuWindows()) if (w.rootViewController) { window = w; break; }
        if (!entry || !window || !CXPXVoidSelector(entry, @"dragHandle:", 1)) {
            CXLog(@"[arc] begin skipped: entry=%d root=%d", entry != nil, window.rootViewController != nil);
            _armed = NO;
            return;
        }
        CXActiveArc = self;
        _entry = entry;
        _synth = [CXSynthPan new];
        _synth.enabled = NO;
        [CXPXEntryObject(entry, _left ? "leftHandle" : "handle", UIView.class) addGestureRecognizer:_synth];
        if (!_synth.view) [CXPXEntryObject(entry, "handle", UIView.class) addGestureRecognizer:_synth];
        if (!_synth.view) { CXLog(@"[arc] begin skipped: no handle view"); [self cleanup]; return; }
        _synth.synthState = UIGestureRecognizerStateBegan;
        _synth.synthLocation = point;
        _synth.synthTranslation = CGPointZero;
        CXLog(@"[arc] begin side=%@ %.0f,%.0f", _left ? @"left" : @"right", point.x, point.y);
        @try { ((void (*)(id, SEL, id))objc_msgSend)(entry, NSSelectorFromString(@"dragHandle:"), _synth); }
        @catch (__unused NSException *e) { [self cleanup]; return; }
        // 立刻排，并在 PX 入场动画期间持续压住，避免先露出边缘半圆
        [self rearrange];
        for (NSNumber *delay in @[@0.03, @0.06, @0.10, @0.16, @0.24, @0.34, @0.46, @0.70, @0.95]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ if (_synth) [self rearrange]; });
        }
        return;
    }
    if (!_synth || !_entry) return;
    _synth.synthTranslation = CGPointMake(point.x - _start.x, point.y - _start.y);
    _synth.synthLocation = point;
    _synth.synthVelocity = [g velocityInView:nil];
    BOOL ended = g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled ||
                 g.state == UIGestureRecognizerStateFailed;
    _synth.synthState = ended ? g.state : UIGestureRecognizerStateChanged;
    @try { ((void (*)(id, SEL, id))objc_msgSend)(_entry, NSSelectorFromString(@"dragHandle:"), _synth); }
    @catch (__unused NSException *e) { [self cleanup]; return; }
    if (!ended && CACurrentMediaTime() - _lastArrange > 0.06) [self rearrange];
    if (ended) {
        UIWindow *window = _icons.firstObject.window ?: [self handleWindow];
        CGPoint local = window ? [window convertPoint:point fromCoordinateSpace:UIScreen.mainScreen.coordinateSpace] : point;
        NSInteger index = g.state == UIGestureRecognizerStateEnded ? CXFanNearest(_icons, local) : -1;
        NSArray *ids = CXMenuIDs();
        NSString *picked = (index >= 0 && index < (NSInteger)ids.count) ? ids[index] : nil;
        CXLog(@"[arc] end state=%ld index=%ld picked=%@", (long)g.state, (long)index, picked ?: @"(none)");
        // 让 PX 收起菜单但不用它的半圆命中；选中由扇形结果决定
        _synth.synthState = UIGestureRecognizerStateCancelled;
        @try { ((void (*)(id, SEL, id))objc_msgSend)(_entry, NSSelectorFromString(@"dragHandle:"), _synth); }
        @catch (__unused NSException *e) { }
        [self cleanup];
        if (picked.length) CXOpenMenuItem(picked);
    }
}

@end

static CXArcWakeGesture *CXArcGesture;
static id CXSystemGestureManager;
static id CXCachedDisplayIdentity; // 改名避免与下面函数冲突
static BOOL CXSystemRegistered;
static NSMapTable<UIWindow *, CXArcWakeGesture *> *CXFallbackGestures;
static NSMapTable<UIWindow *, UIView *> *CXDebugViews;
@class CXArcDebugWindow;
static CXArcDebugWindow *CXDebugWindow;
static BOOL CXArcStarted;

@interface CXArcDebugView : UIView
@end
@implementation CXArcDebugView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event { return NO; }
@end

// 独立透传窗口：整个窗口不接收触摸，底层图标/按钮照常点
@interface CXArcDebugWindow : UIWindow
@end
@implementation CXArcDebugWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
@end

id CXArcWakeEntry(void) { return CXFindPanelEntry(); }

static void CXArcDrawDebugUnsafe(void);

static void CXArcDrawDebug(void) {
    @try { CXArcDrawDebugUnsafe(); } @catch (__unused NSException *e) { CXDebugWindow.hidden = YES; CXDebugWindow = nil; }
}

static void CXArcDrawDebugUnsafe(void) {
    if (CXDebugWindow) { CXDebugWindow.hidden = YES; CXDebugWindow = nil; }
    if (!CXArcEnabled() || ![CXPrefs.shared boolForKey:@"CXArcDebug" defaultValue:NO]) return;
    UIWindow *host = CXMenuWindows().firstObject;
    if (!host.windowScene) return;
    CXArcDebugWindow *window = [[CXArcDebugWindow alloc] initWithWindowScene:host.windowScene];
    window.frame = UIScreen.mainScreen.bounds;
    window.windowLevel = UIWindowLevelAlert + 5;
    window.backgroundColor = UIColor.clearColor;
    window.userInteractionEnabled = NO; // 不拦任何触摸
    UIViewController *vc = [[UIViewController alloc] init];
    CXArcDebugView *view = [[CXArcDebugView alloc] initWithFrame:window.bounds];
    view.userInteractionEnabled = NO;
    vc.view = view;
    window.rootViewController = vc;
    NSInteger side = (NSInteger)CXArcNumber(@"CXArcSide");
    for (NSNumber *leftValue in @[@NO, @YES]) {
        BOOL left = leftValue.boolValue;
        if ((left && side == 0) || (!left && side == 1)) continue;
        UIBezierPath *path = [CXArcPath(left) copy];
        CAShapeLayer *layer = [CAShapeLayer layer];
        layer.path = path.CGPath;
        layer.fillColor = [UIColor.systemOrangeColor colorWithAlphaComponent:0.20].CGColor;
        layer.strokeColor = UIColor.systemOrangeColor.CGColor;
        layer.lineWidth = 1;
        [view.layer addSublayer:layer];
    }
    window.hidden = NO;
    CXDebugWindow = window;
}

static BOOL CXIsPXHandleWindow(UIWindow *window) {
    if (!window) return NO;
    NSString *name = NSStringFromClass(window.class);
    if ([name containsString:@"PXHandleWindow"]) return YES;
    UIWindow *handle = CXPXEntryObject(CXLiveEntry, "handleWindow", UIWindow.class);
    return handle == window;
}

static void CXArcFallbackSyncUnsafe(BOOL want);

static void CXArcFallbackSync(BOOL want) {
    @try { CXArcFallbackSyncUnsafe(want); } @catch (__unused NSException *e) { }
}

static void CXArcFallbackSyncUnsafe(BOOL want) {
    if (!CXFallbackGestures) CXFallbackGestures = [NSMapTable weakToStrongObjectsMapTable];
    for (UIWindow *window in CXFallbackGestures.keyEnumerator.allObjects) {
        CXArcWakeGesture *gesture = [CXFallbackGestures objectForKey:window];
        if (!want || window.hidden || CXIsPXHandleWindow(window)) {
            [gesture cancelForwarding];
            [window removeGestureRecognizer:gesture];
            [CXFallbackGestures removeObjectForKey:window];
        }
    }
    if (!want) return;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.hidden || !window.windowScene || CXIsPXHandleWindow(window) ||
            [CXFallbackGestures objectForKey:window]) continue;
        CXArcWakeGesture *gesture = [CXArcWakeGesture new];
        [window addGestureRecognizer:gesture];
        [CXFallbackGestures setObject:gesture forKey:window];
    }
}

static CFTimeInterval CXSystemRetryAt = 0;
static NSInteger CXSystemFailures = 0;

static id CXSystemManager(void) {
    @try {
        Class cls = NSClassFromString(@"_UISystemGestureManager");
        if (!cls) return nil;
        SEL sel = NSSelectorFromString(@"sharedInstance");
        if (![cls respondsToSelector:sel]) return nil;
        return ((id (*)(id, SEL))objc_msgSend)(cls, sel);
    } @catch (__unused NSException *e) { return nil; }
}

// 原版取 UIScreen.displayIdentity；缺失时按旧 Twin 的候选链再找一次。
static id CXGetDisplayIdentity(void) { // 改名避免与全局变量冲突
    @try {
        id identity = CXPXGetObject(UIScreen.mainScreen, @"displayIdentity");
        if (identity) return identity;
        Class fbdm = NSClassFromString(@"FBDisplayManager");
        if (!fbdm) return nil;
        id display = CXPXGetObject(fbdm, @"mainDisplay") ?: CXPXGetObject(fbdm, @"sharedInstance");
        return CXPXGetObject(display, @"identity") ?: CXPXGetObject(display, @"displayIdentity");
    } @catch (__unused NSException *e) { return nil; }
}

// 通道自愈：连续两次启动都死在稳定点（25s）之前，多半已经进了安全模式。
// 这时先停用系统通道，只留窗口手势，避免一开就再崩；设置页可一键重置。
static BOOL CXChannelBlocked(void) {
    return [CXPrefs.shared boolForKey:@"CXArcChannelBlocked" defaultValue:NO];
}

static void CXArcChannelBoot(void) {
    BOOL pending = [CXPrefs.shared boolForKey:@"CXArcChannelPending" defaultValue:NO];
    NSInteger failures = [[CXPrefs.shared objectForKey:@"CXArcChannelFailures"] integerValue];
    if (pending) {
        failures++;
        [CXPrefs.shared setObject:@(failures) forKey:@"CXArcChannelFailures"];
        CXLog(@"[arc] 上次启动未到稳定点，累计=%ld", (long)failures);
        if (failures >= 2 && !CXChannelBlocked()) {
            [CXPrefs.shared setObject:@YES forKey:@"CXArcChannelBlocked"];
            CXLog(@"[arc] 系统通道两次不稳定，本次起只走窗口手势");
        }
    }
    [CXPrefs.shared setObject:@YES forKey:@"CXArcChannelPending"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [CXPrefs.shared setObject:@NO forKey:@"CXArcChannelPending"];
    });
}

// YES=已挂上系统通道；NO=本轮到不了，调用方退回窗口手势。
// 私有 API 任何一步异常都只记日志并冷却重试，绝不把 SpringBoard 拖进安全模式。
static BOOL CXTryRegisterSystemGesture(void) {
    if (CXSystemRegistered || !CXArcGesture) return CXSystemRegistered;
    CFTimeInterval now = CACurrentMediaTime();
    if (now < CXSystemRetryAt) return NO;
    if (CXChannelBlocked()) {
        static BOOL told;
        if (!told) { CXLog(@"[arc] 系统通道已停用（安全模式保护），只用窗口手势"); told = YES; }
        return NO;
    }
    @try {
        id manager = CXSystemManager();
        id identity = CXGetDisplayIdentity(); // 调用改名后的函数
        if (!manager || !identity ||
            !CXPXVoidSelector(manager, @"addGestureRecognizer:toDisplayWithIdentity:", 2) ||
            !CXPXVoidSelector(manager, @"removeGestureRecognizer:fromDisplayWithIdentity:", 2)) {
            CXSystemFailures++;
            CXSystemRetryAt = now + MIN(60.0, 5.0 * (double)CXSystemFailures);
            static BOOL reported;
            if (!reported)
                CXLog(@"[arc] system gesture unavailable manager=%d identity=%d; window fallback",
                      manager != nil, identity != nil);
            reported = YES;
            return NO;
        }
        // 同一个手势重复挂到同一管理器会断言：先摘一次，没挂过也无副作用
        @try {
            ((void (*)(id, SEL, id, id))objc_msgSend)(manager,
                NSSelectorFromString(@"removeGestureRecognizer:fromDisplayWithIdentity:"), CXArcGesture, identity);
        } @catch (__unused NSException *e) { }
        ((void (*)(id, SEL, id, id))objc_msgSend)(manager,
            NSSelectorFromString(@"addGestureRecognizer:toDisplayWithIdentity:"), CXArcGesture, identity);
        CXSystemGestureManager = manager;
        CXCachedDisplayIdentity = identity; // 改为新名字
        CXSystemRegistered = YES;
        CXSystemFailures = 0;
        CXLog(@"[arc] system gesture registered");
        return YES;
    } @catch (__unused NSException *e) {
        CXSystemRegistered = NO;
        CXSystemFailures++;
        CXSystemRetryAt = now + MIN(60.0, 5.0 * (double)CXSystemFailures);
        CXLog(@"[arc] system gesture register exception (%ld)", (long)CXSystemFailures);
        return NO;
    }
}

// 显示身份会随前后台、投屏和重连变化，旧身份失效后挂着的通道收不到触摸。
// 身份变了就摘旧挂新；重挂失败直接退回窗口手势，不在半坏状态里凑合。
static void CXRefreshSystemGesture(void) {
    if (!CXSystemRegistered || !CXArcGesture) return;
    @try {
        id identity = CXGetDisplayIdentity();
        if (!identity || identity == CXCachedDisplayIdentity) return;
        id manager = CXSystemManager();
        if (!manager || !CXPXVoidSelector(manager, @"addGestureRecognizer:toDisplayWithIdentity:", 2)) return;
        if (CXSystemGestureManager && CXCachedDisplayIdentity &&
            CXPXVoidSelector(CXSystemGestureManager, @"removeGestureRecognizer:fromDisplayWithIdentity:", 2)) {
            @try {
                ((void (*)(id, SEL, id, id))objc_msgSend)(CXSystemGestureManager,
                    NSSelectorFromString(@"removeGestureRecognizer:fromDisplayWithIdentity:"), CXArcGesture, CXCachedDisplayIdentity);
            } @catch (__unused NSException *e) { }
        }
        ((void (*)(id, SEL, id, id))objc_msgSend)(manager,
            NSSelectorFromString(@"addGestureRecognizer:toDisplayWithIdentity:"), CXArcGesture, identity);
        CXSystemGestureManager = manager;
        CXCachedDisplayIdentity = identity;
        CXLog(@"[arc] display identity changed, re-registered");
    } @catch (__unused NSException *e) {
        CXSystemRegistered = NO;
        CXSystemRetryAt = CACurrentMediaTime() + 10.0;
        CXLog(@"[arc] re-register exception, window fallback");
    }
}

void CXArcWakeSync(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ CXArcWakeSync(); }); return; }
    @try {
        (void)CXFindPanelEntry(); // 若初始化早于插件载入，先从原版手势 target 找真实实例
        BOOL want = CXArcEnabled();
        if (want && !CXArcGesture) CXArcGesture = [CXArcWakeGesture new];
        BOOL keepFallback = NO;
        if (!want) {
            if (!CXArcGesture) { CXArcFallbackSync(NO); CXArcDrawDebug(); return; }
            [CXArcGesture cancelForwarding];
            CXArcGesture.enabled = NO;
            if (CXSystemRegistered && CXPXVoidSelector(CXSystemGestureManager,
                 @"removeGestureRecognizer:fromDisplayWithIdentity:", 2)) {
                @try {
                    ((void (*)(id, SEL, id, id))objc_msgSend)(CXSystemGestureManager,
                        NSSelectorFromString(@"removeGestureRecognizer:fromDisplayWithIdentity:"), CXArcGesture, CXCachedDisplayIdentity); // 改为新名字
                    CXSystemRegistered = NO;
                } @catch (__unused NSException *e) { keepFallback = YES; }
            }
            CXArcFallbackSync(!keepFallback);
            CXArcDrawDebug();
            return;
        }
        CXArcGesture.enabled = YES;
        if (!CXSystemRegistered) CXTryRegisterSystemGesture();
        else CXRefreshSystemGesture();
        CXArcFallbackSync(!CXSystemRegistered);
        CXArcDrawDebug();
    } @catch (__unused NSException *e) {
        CXLog(@"[arc] sync exception, window fallback");
        if (CXArcGesture) CXArcGesture.enabled = YES;
        CXArcFallbackSync(YES);
    }
}

void CXArcWakeInstall(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ CXArcWakeInstall(); }); return; }
    if (CXArcStarted) { CXArcWakeSync(); return; }
    CXArcStarted = YES;
    CXArcChannelBoot(); // 先判上次是否崩在稳定点前，再决定要不要碰系统通道
    CXSystemRetryAt = CACurrentMediaTime() + 3.0; // SpringBoard 启动早期先只挂窗口手势，系统通道延后
    CXArcWakeSync();
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { CXArcWakeSync(); }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceOrientationDidChangeNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { CXArcWakeSync(); }];
}
