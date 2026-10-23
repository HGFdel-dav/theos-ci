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
static UIBezierPath *CXArcPath(BOOL left) {
    return CXArcTriggerPath(left, (NSInteger)CXArcNumber(@"CXArcTriggerRegionMode"),
        CXArcNumber(@"CXArcRadius"), CXArcNumber(@"CXArcRectangleLength"),
        CXArcNumber(@"CXArcRectangleHeight"), CXArcNumber(@"CXArcRectangleCornerRadius"),
        CXArcNumber(@"CXArcOffsetX"), CXArcNumber(@"CXArcOffsetY"), UIScreen.mainScreen.bounds);
}
static NSInteger CXArcSideAtPoint(CGPoint point) {
    if (!CXArcEnabled()) return -1;
    NSInteger side = (NSInteger)CXArcNumber(@"CXArcSide");
    if ((side == 1 || side == 2) && [CXArcPath(YES) containsPoint:point]) return 1;
    if ((side == 0 || side == 2) && [CXArcPath(NO) containsPoint:point]) return 0;
    return -1;
}

static CGPoint CXArcTouchPoint(UITouch *touch) {
    UIWindow *window = touch.window;
    CGPoint point = [touch locationInView:window];
    return window ? [window convertPoint:point toCoordinateSpace:UIScreen.mainScreen.coordinateSpace] : point;
}
static CGPoint CXArcGesturePoint(UIPanGestureRecognizer *gesture) {
    UIWindow *window = gesture.view.window;
    CGPoint point = [gesture locationInView:window];
    return window ? [window convertPoint:point toCoordinateSpace:UIScreen.mainScreen.coordinateSpace] : point;
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

#pragma mark - 手势

@class CXArcWakeGesture;
static __weak CXArcWakeGesture *CXActiveArc;

@interface CXArcWakeGesture : UIPanGestureRecognizer <UIGestureRecognizerDelegate>
- (void)cancelForwarding;
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
    CGPoint point = CXArcTouchPoint(touch);
    NSInteger side = CXArcSideAtPoint(point);
    if (side < 0 || CXPXEntryFlag(CXLiveEntry, "deviceLocked")) return NO;
    if (_synth || (CXActiveArc && CXActiveArc != self)) return NO;
    _start = point;
    _left = side == 1;
    _armed = YES;
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    return _armed && CXArcEnabled() && (!CXActiveArc || CXActiveArc == self);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other { return YES; }

- (UIWindow *)handleWindow { return CXMenuWindow(); }

- (void)cleanup {
    UIView *handle = _synth.view;
    [handle removeGestureRecognizer:_synth];
    _synth = nil;
    _entry = nil;
    _icons = nil;
    _armed = NO;
    _rearranged = NO;
    if (CXActiveArc == self) CXActiveArc = nil;
}

- (void)cancelForwarding { [self cleanup]; }

// PX 布局会覆盖位置，每次转发后重新排成扇形
- (void)rearrange {
    UIWindow *window = [self handleWindow];
    if (!window) return;
    _icons = CXFanIcons(window);
    if (!_icons.count) return;
    CXFanArrange(_icons, window, _left);
    _rearranged = YES;
    _lastArrange = CACurrentMediaTime();
}

- (void)handle:(UIPanGestureRecognizer *)g {
    if (!CXArcEnabled()) { [self cleanup]; return; }
    CGPoint point = CXArcGesturePoint(g);
    if (g.state == UIGestureRecognizerStateBegan) {
        if (!_armed || (CXActiveArc && CXActiveArc != self)) return;
        id entry = CXFindPanelEntry();
        UIWindow *window = CXPXEntryObject(entry, "handleWindow", UIWindow.class);
        if (!entry || !window.rootViewController || !CXPXVoidSelector(entry, @"dragHandle:", 1)) {
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
        _synth.synthState = UIGestureRecognizerStateBegan;
        _synth.synthLocation = point;
        _synth.synthTranslation = CGPointZero;
        CXLog(@"[arc] begin side=%@ %.0f,%.0f", _left ? @"left" : @"right", point.x, point.y);
        @try { ((void (*)(id, SEL, id))objc_msgSend)(entry, NSSelectorFromString(@"dragHandle:"), _synth); }
        @catch (__unused NSException *e) { [self cleanup]; return; }
        // 立刻排，并在 PX 入场动画期间持续压住，避免先露出边缘半圆
        [self rearrange];
        for (NSNumber *delay in @[@0.03, @0.06, @0.10, @0.16, @0.24, @0.34, @0.46]) {
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
    if (!ended) [self rearrange];
    if (ended) {
        UIWindow *window = [self handleWindow];
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
static id CXDisplayIdentity;
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

static void CXArcDrawDebug(void) {
    if (CXDebugWindow) { CXDebugWindow.hidden = YES; CXDebugWindow = nil; }
    if (!CXArcEnabled() || ![CXPrefs.shared boolForKey:@"CXArcDebug" defaultValue:NO]) return;
    UIWindow *host = CXPXEntryObject(CXLiveEntry, "handleWindow", UIWindow.class);
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

static void CXArcFallbackSync(BOOL want) {
    if (!CXFallbackGestures) CXFallbackGestures = [NSMapTable weakToStrongObjectsMapTable];
    for (UIWindow *window in CXFallbackGestures.keyEnumerator.allObjects) {
        CXArcWakeGesture *gesture = [CXFallbackGestures objectForKey:window];
        if (!want || window.hidden) {
            [gesture cancelForwarding];
            [window removeGestureRecognizer:gesture];
            [CXFallbackGestures removeObjectForKey:window];
        }
    }
    if (!want) return;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.hidden || !window.windowScene || [CXFallbackGestures objectForKey:window]) continue;
        CXArcWakeGesture *gesture = [CXArcWakeGesture new];
        [window addGestureRecognizer:gesture];
        [CXFallbackGestures setObject:gesture forKey:window];
    }
}

void CXArcWakeSync(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ CXArcWakeSync(); }); return; }
    (void)CXFindPanelEntry(); // 若初始化早于插件载入，先从原版手势 target 找真实实例
    BOOL want = CXArcEnabled();
    if (!CXArcGesture) CXArcGesture = [CXArcWakeGesture new];
    BOOL keepFallback = NO;
    if (!want) {
        [CXArcGesture cancelForwarding];
        CXArcGesture.enabled = NO;
        if (CXSystemRegistered && CXPXVoidSelector(CXSystemGestureManager,
             @"removeGestureRecognizer:fromDisplayWithIdentity:", 2)) {
            @try {
                ((void (*)(id, SEL, id, id))objc_msgSend)(CXSystemGestureManager,
                    NSSelectorFromString(@"removeGestureRecognizer:fromDisplayWithIdentity:"), CXArcGesture, CXDisplayIdentity);
                CXSystemRegistered = NO;
            } @catch (__unused NSException *e) { keepFallback = YES; }
        }
        CXArcFallbackSync(!keepFallback);
        CXArcDrawDebug();
        return;
    }
    CXArcGesture.enabled = YES;
    if (!CXSystemRegistered) {
        // 照旧原版：UIScreen.mainScreen.displayIdentity；身份缺失就失败，不传nil冒充成功。
        id identity = CXPXGetObject(UIScreen.mainScreen, @"displayIdentity");
        id manager = CXPXGetObject(NSClassFromString(@"_UISystemGestureManager"), @"sharedInstance");
        BOOL interfaces = CXPXVoidSelector(manager, @"addGestureRecognizer:toDisplayWithIdentity:", 2) &&
                          CXPXVoidSelector(manager, @"removeGestureRecognizer:fromDisplayWithIdentity:", 2);
        if (manager && identity && interfaces) {
            @try {
                ((void (*)(id, SEL, id, id))objc_msgSend)(manager,
                    NSSelectorFromString(@"addGestureRecognizer:toDisplayWithIdentity:"), CXArcGesture, identity);
                CXSystemGestureManager = manager;
                CXDisplayIdentity = identity;
                CXSystemRegistered = YES;
                CXLog(@"[arc] system gesture registered");
            } @catch (__unused NSException *e) { CXLog(@"[arc] system gesture register exception"); }
        } else {
            static BOOL reported;
            if (!reported) CXLog(@"[arc] system gesture unavailable manager=%d identity=%d interface=%d; desktop fallback only",
                                  manager != nil, identity != nil, interfaces);
            reported = YES;
        }
    }
    CXArcFallbackSync(!CXSystemRegistered);
    CXArcDrawDebug();
}

void CXArcWakeInstall(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ CXArcWakeInstall(); }); return; }
    if (CXArcStarted) { CXArcWakeSync(); return; }
    CXArcStarted = YES;
    CXArcWakeSync();
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { CXArcWakeSync(); }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceOrientationDidChangeNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { CXArcWakeSync(); }];
}
