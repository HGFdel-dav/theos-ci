// CXArcWake.m
//
// ScreenCore 式角落拖拽唤醒 → 驱动 ParallelX 自己的手柄手势。
//
// PX 没有公开的"打开菜单"方法；它的菜单由 -[PXPanelEntry dragHandle:] 驱动。
// 这里在角落监听拖拽，把一段合成手势喂给 dragHandle:，
// 菜单、图标、展开动画全部由 PX 自己播放。
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

// 合成对象是实际 UIPan 子类，并挂到原版左右手柄；坐标转换遵守传入view。
@interface CXSynthPan : UIPanGestureRecognizer
@property (nonatomic, assign) UIGestureRecognizerState synthState;
@property (nonatomic, assign) CGPoint synthTranslation;
@property (nonatomic, assign) CGPoint synthLocation;
@property (nonatomic, assign) CGPoint synthVelocity;
@end

static CGPoint CXArcScreenPoint(UIView *reference, CGPoint point, UIView *view) {
    if (!reference.window || !view) return point;
    CGPoint inWindow = [reference.window convertPoint:point fromCoordinateSpace:UIScreen.mainScreen.coordinateSpace];
    return [view convertPoint:inWindow fromView:reference.window];
}

@implementation CXSynthPan
- (UIGestureRecognizerState)state { return self.synthState; }
- (CGPoint)translationInView:(UIView *)view {
    CGPoint a = CXArcScreenPoint(self.view, CGPointZero, view);
    CGPoint b = CXArcScreenPoint(self.view, self.synthTranslation, view);
    return CGPointMake(b.x - a.x, b.y - a.y);
}
- (CGPoint)locationInView:(UIView *)view { return CXArcScreenPoint(self.view, self.synthLocation, view); }
- (CGPoint)velocityInView:(UIView *)view {
    CGPoint a = CXArcScreenPoint(self.view, CGPointZero, view);
    CGPoint b = CXArcScreenPoint(self.view, self.synthVelocity, view);
    return CGPointMake(b.x - a.x, b.y - a.y);
}
@end

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

static UIView *CXFindHandleView(BOOL left) {
    id entry = CXFindPanelEntry();
    UIView *handle = CXPXEntryObject(entry, left ? "leftHandle" : "handle", UIView.class);
    if (handle.window && !handle.hidden) return handle;
    // 触发侧与PX手柄侧是两个设置；不覆盖用户PX设置，转发到其实际可见手柄。
    UIView *alternate = CXPXEntryObject(entry, left ? "handle" : "leftHandle", UIView.class);
    return alternate.window && !alternate.hidden ? alternate : nil;
}

#pragma mark - 手势

@class CXArcWakeGesture;
static __weak CXArcWakeGesture *CXActiveArc;

@interface CXArcWakeGesture : UIPanGestureRecognizer <UIGestureRecognizerDelegate>
- (void)cancelForwarding;
@end

@implementation CXArcWakeGesture {
    CXSynthPan *_synth;
    id _entry;
    CGPoint _start;
    BOOL _armed;
    BOOL _left;
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

- (void)finishForwarding {
    UIView *handle = _synth.view;
    [handle removeGestureRecognizer:_synth];
    _synth = nil;
    _entry = nil;
    _armed = NO;
    if (CXActiveArc == self) CXActiveArc = nil;
}

- (void)cancelForwarding {
    if (_synth && _entry && CXPXVoidSelector(_entry, @"dragHandle:", 1)) {
        _synth.synthState = UIGestureRecognizerStateCancelled;
        @try { ((void (*)(id, SEL, id))objc_msgSend)(_entry, NSSelectorFromString(@"dragHandle:"), _synth); }
        @catch (__unused NSException *e) { }
    }
    [self finishForwarding];
}

- (void)handle:(UIPanGestureRecognizer *)g {
    if (!CXArcEnabled()) { [self cancelForwarding]; return; }
    CGPoint point = CXArcGesturePoint(g);
    if (g.state == UIGestureRecognizerStateBegan) {
        if (!_armed || (CXActiveArc && CXActiveArc != self)) return;
        id entry = CXFindPanelEntry();
        UIView *handle = CXFindHandleView(_left);
        UIWindow *window = CXPXEntryObject(entry, "handleWindow", UIWindow.class);
        if (!entry || !handle || !window.rootViewController || !CXPXVoidSelector(entry, @"dragHandle:", 1)) {
            CXLog(@"[arc] begin skipped: real entry=%d handle=%d root=%d", entry != nil,
                  handle != nil, window.rootViewController != nil);
            _armed = NO;
            return;
        }
        CXActiveArc = self;
        _entry = entry;
        _synth = [CXSynthPan new];
        _synth.enabled = NO; // 不接受第二组真实触摸，只承载本次转发的状态
        [handle addGestureRecognizer:_synth];
        _synth.synthState = UIGestureRecognizerStateBegan;
        _synth.synthLocation = _start;
        _synth.synthTranslation = CGPointZero;
        CXLog(@"[arc] begin side=%@ %.0f,%.0f", _left ? @"left" : @"right", point.x, point.y);
        @try { ((void (*)(id, SEL, id))objc_msgSend)(entry, NSSelectorFromString(@"dragHandle:"), _synth); }
        @catch (__unused NSException *e) { [self finishForwarding]; return; }
    }
    if (!_synth || !_entry) return;
    _synth.synthTranslation = CGPointMake(point.x - _start.x, point.y - _start.y);
    _synth.synthLocation = point;
    _synth.synthVelocity = [g velocityInView:nil];
    BOOL ended = g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled ||
                 g.state == UIGestureRecognizerStateFailed;
    _synth.synthState = ended ? g.state : UIGestureRecognizerStateChanged;
    @try { ((void (*)(id, SEL, id))objc_msgSend)(_entry, NSSelectorFromString(@"dragHandle:"), _synth); }
    @catch (__unused NSException *e) { [self finishForwarding]; return; }
    if (ended) {
        CXLog(@"[arc] end state=%ld", (long)g.state);
        [self finishForwarding];
    }
}

@end

static CXArcWakeGesture *CXArcGesture;
static id CXSystemGestureManager;
static id CXDisplayIdentity;
static BOOL CXSystemRegistered;
static NSMapTable<UIWindow *, CXArcWakeGesture *> *CXFallbackGestures;
static NSMapTable<UIWindow *, UIView *> *CXDebugViews;
static BOOL CXArcStarted;

@interface CXArcDebugView : UIView
@end
@implementation CXArcDebugView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event { return NO; }
@end

id CXArcWakeEntry(void) { return CXFindPanelEntry(); }

static void CXArcDrawDebug(void) {
    if (!CXDebugViews) CXDebugViews = [NSMapTable weakToStrongObjectsMapTable];
    for (UIWindow *window in CXDebugViews.keyEnumerator.allObjects) {
        [[CXDebugViews objectForKey:window] removeFromSuperview];
        [CXDebugViews removeObjectForKey:window];
    }
    if (!CXArcEnabled() || ![CXPrefs.shared boolForKey:@"CXArcDebug" defaultValue:NO]) return;
    UIWindow *window = CXPXEntryObject(CXLiveEntry, "handleWindow", UIWindow.class);
    if (!window || window.hidden) return;
    CXArcDebugView *view = [[CXArcDebugView alloc] initWithFrame:window.bounds];
    view.userInteractionEnabled = NO;
    view.backgroundColor = UIColor.clearColor;
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    NSInteger side = (NSInteger)CXArcNumber(@"CXArcSide");
    for (NSNumber *leftValue in @[@NO, @YES]) {
        BOOL left = leftValue.boolValue;
        if ((left && side == 0) || (!left && side == 1)) continue;
        UIBezierPath *path = [CXArcPath(left) copy];
        CGPoint zero = [window convertPoint:CGPointZero fromCoordinateSpace:UIScreen.mainScreen.coordinateSpace];
        CGPoint x = [window convertPoint:CGPointMake(1, 0) fromCoordinateSpace:UIScreen.mainScreen.coordinateSpace];
        CGPoint y = [window convertPoint:CGPointMake(0, 1) fromCoordinateSpace:UIScreen.mainScreen.coordinateSpace];
        [path applyTransform:CGAffineTransformMake(x.x - zero.x, x.y - zero.y,
            y.x - zero.x, y.y - zero.y, zero.x, zero.y)];
        CAShapeLayer *layer = [CAShapeLayer layer];
        layer.path = path.CGPath;
        layer.fillColor = [UIColor.systemOrangeColor colorWithAlphaComponent:0.22].CGColor;
        layer.strokeColor = UIColor.systemOrangeColor.CGColor;
        layer.lineWidth = 1;
        [view.layer addSublayer:layer];
    }
    [window addSubview:view];
    [CXDebugViews setObject:view forKey:window];
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
