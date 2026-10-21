// TWArcCoordinator.m
#import "TWArcCoordinator.h"
#import "TWArcMenuView.h"
#import "TWArcGeometry.h"
#import "TWArcWindow.h"
#import "TWArcPXBridge.h"
#import "TWPrefs.h"
#import "TWCraneBridge.h"
#import "TWPath.h"
#import "TWRuntimeLog.h"
#import "TWSceneInject.h"
#import "TWSystemGesture.h"
#import <AudioToolbox/AudioServices.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <notify.h>
#import <string.h>
#import <math.h>
#import <CoreFoundation/CoreFoundation.h>

static void TWArcLockStateChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[TWArcCoordinator sharedInstance] refreshEnabledState];
    });
}

static const char *TWArcType(const char *type) {
    while (type && *type && strchr("rnNoORV", *type)) type++;
    return type ?: "";
}

static NSMethodSignature *TWArcSignature(id target, SEL selector, NSUInteger arguments) {
    @try {
        if (!target || ![target respondsToSelector:selector]) return nil;
        NSMethodSignature *sig = [target methodSignatureForSelector:selector];
        return sig.numberOfArguments == arguments ? sig : nil;
    } @catch (__unused NSException *exception) { return nil; }
}

static id TWArcObject(id target, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *sig = TWArcSignature(target, selector, 2);
    if (!sig || TWArcType(sig.methodReturnType)[0] != '@') return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(target, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static id TWArcValue(id target, NSString *key) {
    @try { return [target valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

// 显示名：LSApplicationProxy.localizedName，取不到就用 bundleID。
static NSString *TWArcDisplayName(NSString *bundleID) {
    @try {
        Class proxyClass = NSClassFromString(@"LSApplicationProxy");
        SEL selector = NSSelectorFromString(@"applicationProxyForIdentifier:");
        if (proxyClass && [proxyClass respondsToSelector:selector]) {
            id (*fn)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
            id proxy = fn(proxyClass, selector, bundleID);
            NSString *name = TWArcValue(proxy, @"localizedName");
            if ([name isKindOfClass:[NSString class]] && name.length) return name;
        }
    } @catch (__unused NSException *exception) {}
    return [bundleID isKindOfClass:[NSString class]] ? bundleID : @"";
}

static BOOL TWArcBool(id target, NSString *name, BOOL *known) {
    *known = NO;
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *sig = TWArcSignature(target, selector, 2);
    if (!sig) return YES;
    @try {
        const char *type = TWArcType(sig.methodReturnType);
        if (!strcmp(type, @encode(BOOL))) {
            BOOL result = ((BOOL (*)(id, SEL))objc_msgSend)(target, selector);
            *known = YES; return result;
        }
        if (!strcmp(type, @encode(signed char))) {
            signed char result = ((signed char (*)(id, SEL))objc_msgSend)(target, selector);
            *known = YES; return result != 0;
        }
    } @catch (__unused NSException *exception) {}
    return YES;
}

// 0.9.9：改成"只有确认锁屏才拒绝"。旧实现里如果 SBLockScreenManager 取不到，
// TWArcBool 会按 YES 兜底 → 被判成"锁屏中" → 所有手势静默失效，
// 表现就是"角落怎么拖都没反应"，而且没有任何日志。
static BOOL TWArcDeviceUnlocked(void) {
    id manager = TWArcObject(NSClassFromString(@"SBLockScreenManager"), @"sharedInstance");
    if (!manager) return YES;
    BOOL known = NO;
    BOOL locked = TWArcBool(manager, @"isLocked", &known);
    if (known && locked) return NO;
    known = NO;
    locked = TWArcBool(manager, @"isUILocked", &known);
    if (known && locked) return NO;
    return YES;
}


#pragma mark - 角落触发窗口（每个角落一个小窗口）

// 0.9.6：彻底不做全屏窗口。
//   0.9.4 的全屏触发窗口把整块屏幕的触摸都吃掉（桌面图标点不动），根因是
//   UIView.hitTest 在"无子视图命中"时返回窗口自己。
//   现在每个启用的角落只开一个 cornerSize×cornerSize 的小窗口，物理上不可能
//   覆盖到角落以外，桌面/App 的其余区域一个像素都不受影响。
// 0.9.8：再加一层保险 —— 小窗口在个别系统状态（锁屏/场景重建）下可能收不到
//   触摸，于是在主窗口上再挂一条"只在角落热区内成立"的备用手势。它不取消
//   触摸（cancelsTouchesInView=NO），热区之外一律拒绝，因此不抢桌面图标。

typedef struct {
    CGRect rects[4];
    NSInteger mask;
} TWArcHotAreas;

// ARC 唤醒方向属于 ScreenCore 配置域；launcherSide 是 PX 手柄侧边键，二者不可混用。
// arcSide: 0=右下，1=左下，2=两侧（原版触发设置页枚举）。
static NSInteger TWArcTriggerMask(void) {
    NSInteger side = (NSInteger)TWArcOrigNumber(@"arcSide", 0);
    if (side == 1) return (NSInteger)1 << TWCornerBottomLeft;
    if (side == 2) return ((NSInteger)1 << TWCornerBottomLeft) | ((NSInteger)1 << TWCornerBottomRight);
    return (NSInteger)1 << TWCornerBottomRight;
}

static UIBezierPath *TWArcRegionPath(NSInteger corner, CGRect bounds) {
    return [TWArcGeometry triggerPathForCorner:corner
        mode:(NSInteger)TWArcOrigNumber(@"arcTriggerRegionMode", 0)
        radius:TWArcOrigNumber(@"arcRadius", 40)
        length:TWArcOrigNumber(@"arcRectangleLength", 40)
        height:TWArcOrigNumber(@"arcRectangleHeight", 40)
        cornerRadius:TWArcOrigNumber(@"arcRectangleCornerRadius", 12)
        offsetX:TWArcOrigNumber(@"arcOffsetX", 0) offsetY:TWArcOrigNumber(@"arcOffsetY", 0)
        bounds:bounds];
}

static TWArcHotAreas TWArcComputeHotAreas(void) {
    TWArcHotAreas out;
    memset(&out, 0, sizeof(out));
    CGRect screen = UIScreen.mainScreen.bounds;
    out.mask = TWArcTriggerMask();
    for (NSInteger corner = 0; corner < 4; corner++) {
        if (!(out.mask & ((NSInteger)1 << corner))) continue;
        CGRect rect = CGRectIntersection(TWArcRegionPath(corner, screen).bounds, screen);
        out.rects[corner] = CGRectIsNull(rect) ? CGRectZero : rect;
    }
    return out;
}

static BOOL TWArcPointInRegion(CGPoint point, CGRect rect, NSInteger corner) {
    // Reject the other three quadrants too: a circle-distance test alone did not.
    if (!CGRectContainsPoint(rect, point)) return NO;
    return [TWArcRegionPath(corner, UIScreen.mainScreen.bounds) containsPoint:point];
}

static NSInteger TWArcCornerAtScreenPoint(CGPoint point) {
    TWArcHotAreas areas = TWArcComputeHotAreas();
    for (NSInteger corner = 0; corner < 4; corner++) {
        if (!(areas.mask & ((NSInteger)1 << corner))) continue;
        if (TWArcPointInRegion(point, areas.rects[corner], corner)) return corner;
    }
    return -1;
}

@interface TWArcCoordinator (TWRawTouch)
- (void)rawTouchBegan:(UITouch *)touch corner:(NSInteger)corner;
- (void)rawTouchMoved:(UITouch *)touch;
- (void)rawTouchEnded:(UITouch *)touch;
- (void)rawTouchCancelled;
@end

// Debug overlays have no raw-touch forwarding or recognizers, even if another
// caller accidentally toggles userInteractionEnabled.
@interface TWArcDebugView : UIView @end
@implementation TWArcDebugView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event { return NO; }
@end

@interface TWArcTriggerView : UIView
@property (nonatomic, weak) TWArcCoordinator *coordinator;
@property (nonatomic) NSInteger corner;
@end

@implementation TWArcTriggerView
// 原始触摸事件：窗口层级在手势之前拿到的就是它，
// 没有 UIGestureRecognizer 的判定/竞争，SpringBoard 的图标手势抢不走。
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self.coordinator rawTouchBegan:[touches anyObject] corner:self.corner];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self.coordinator rawTouchMoved:[touches anyObject]];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self.coordinator rawTouchEnded:[touches anyObject]];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self.coordinator rawTouchCancelled];
}
@end

@interface TWArcTriggerWindow : UIWindow
- (void)refreshLevel;
@end

@implementation TWArcTriggerWindow
// 和 Arc-X / 菜单窗口同一层级：UIWindowLevelAlert - 2 + 视图优先级。
// 0.9.15 用的是 Alert-3（1997），在 App 前台时会被系统窗口压住，角落划不出来。
- (void)refreshLevel {
    [[TWPrefs shared] reload];
    NSInteger priority = [[TWPrefs shared] integerForKey:TWKeyArcWindowPriority defaultValue:TWArcPriorityDefault];
    if (priority < 0) priority = 0;
    if (priority > 2200) priority = 2200;
    CGFloat level = UIWindowLevelAlert - 2.0 + (CGFloat)priority;
    if (fabs((double)(self.windowLevel - level)) > 0.01) self.windowLevel = level;
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;   // 窗口自身不拦，只有热区视图接
}
@end

@interface TWArcTriggerRootController : UIViewController
@end

@implementation TWArcTriggerRootController
- (void)loadView {
    TWArcTriggerView *view = [[TWArcTriggerView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    view.backgroundColor = UIColor.clearColor;
    self.view = view;
}
- (BOOL)prefersStatusBarHidden { return NO; }
@end

// ensureCornerViewsInPresentationView: 的声明在 TWArcCoordinator.h（TWSceneInject.m 也要看到）。

@interface TWArcCoordinator ()
- (UIWindowScene *)activeWindowScene;
- (void)pressReset;
- (void)trackLongPress;
- (void)launchEntry:(NSDictionary *)entry fullscreen:(BOOL)fullscreen;
- (void)performVerifiedLaunch:(NSString *)bundleID fullscreen:(BOOL)fullscreen;
@end

@implementation TWArcCoordinator {
    UIPanGestureRecognizer *_pan;
    TWArcMenuView *_menu;
    CGPoint _startPoint;
    NSInteger _startCorner;
    BOOL _hasStartPoint;
    BOOL _tracking;
    BOOL _didPresent;
    BOOL _started;
    NSInteger _sceneRetries;
    __weak UIWindow *_pxHostWindow;
    NSInteger _pressedIndex;
    NSTimeInterval _pressedSince;
    BOOL _longPressActive;
    CGPoint _menuPoint;
    CGPoint _pressLastPoint;
    NSArray<NSString *> *_cachedBundleIDs;
}

+ (instancetype)sharedInstance {
    static TWArcCoordinator *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _cachedBundleIDs = @[];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshEnabledState)
                                                     name:UIApplicationDidBecomeActiveNotification object:nil];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            TWArcLockStateChanged, CFSTR("com.apple.springboard.lockstate"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        // 面板改设置后立刻生效（Darwin 通知 com.niubiprass.twin/preferences-changed，
        // 设置进程与 SpringBoard 两边都会发）。以前只有回到桌面时才刷新，
        // 面板里关掉的开关（比如调试模式）在 App 里不立刻反映出来。
        static int prefsToken = -1;
        __block BOOL pending = NO;
        notify_register_dispatch(TWPrefsChangedNotification, &prefsToken, dispatch_get_main_queue(), ^(int token) {
            if (pending) return;              // 0.35s 内的多次改动合并成一次
            pending = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                pending = NO;
                [[TWArcCoordinator sharedInstance] refreshEnabledState];
            });
        });
    }
    return self;
}

#pragma mark - lifecycle

// 0.9.26：TWArcRadius 的含义从「菜单半径」改成原版的「触发区半径」。
// 老版本用户存的是 80~220，如果不迁走，触发区会变成半个屏幕。
static void TWArcMigrateRadiusKeys(void) {
    TWPrefs *prefs = TWPrefs.shared;
    id menu = [prefs objectForKey:TWKeyArcMenuRadius];
    if (menu) return;
    CGFloat old = [prefs floatForKey:TWKeyArcRadius defaultValue:0];
    if (old > 60) {
        [prefs setObject:@(old) forKey:TWKeyArcMenuRadius];
        [prefs setObject:@(40) forKey:TWKeyArcRadius];
        [prefs synchronize];
    }
}

- (void)start {
    if (_started) return;
    _started = YES;
    TWRuntimeLog(@"[arc] start enabled=%@ arcEnabled=%@ wakeMode=%ld prefs=%@",
                 @([[TWPrefs shared] boolForKey:TWKeyEnabled defaultValue:YES]),
                 @([[TWPrefs shared] boolForKey:TWKeyArcEnabled defaultValue:YES]),
                 (long)[[TWPrefs shared] integerForKey:TWKeyWakeMode defaultValue:TWWakeModeCorner],
                 TWPrefsFilePath() ?: @"(nil)");
    TWArcMigrateRadiusKeys();
    [self applyWakeMode];
    [self scheduleContainerPrefetch];
    // attach may have been too early (no window yet); retry briefly.
    if (!_pan) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self applyWakeMode];
        });
    }
}

// 唤醒方式二选一（用户定稿）：
//   0 = Arc 角落唤醒 —— Twin 接管手势（从屏幕角落起手）
//   1 = ParallelX 原生边缘手柄 —— Twin 完全不接管手势，原版手柄照旧
- (void)applyWakeMode {
    NSInteger mode = [[TWPrefs shared] integerForKey:TWKeyWakeMode defaultValue:TWWakeModeCorner];
    if (mode == TWWakeModeHandle || !TWArcDeviceUnlocked() ||
        ![[TWPrefs shared] boolForKey:TWKeyEnabled defaultValue:YES] ||
        ![[TWPrefs shared] boolForKey:TWKeyArcEnabled defaultValue:YES]) {
        [self detachRecognizer];
        TWSceneInjectSync();   // 边缘手柄模式：把 App 内的角落热区一并撤掉
        TWSystemGestureSync(); // 内部按偏好判断：角落模式关闭时反注册
        return;
    }
    [self attachRecognizer];
    TWSceneInjectSync();
    TWSystemGestureSync();     // App 内唤醒：系统手势通道（原版同款机制）
}

- (void)detachRecognizer {
    NSArray *pans = objc_getAssociatedObject(self, "TWArcTriggerPans");
    for (UIPanGestureRecognizer *pan in pans) {
        UIView *view = pan.view;
        if (view) [view removeGestureRecognizer:pan];
    }
    objc_setAssociatedObject(self, "TWArcTriggerPans", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIPanGestureRecognizer *backup = objc_getAssociatedObject(self, "TWArcBackupPan");
    if (backup.view) [backup.view removeGestureRecognizer:backup];
    objc_setAssociatedObject(self, "TWArcBackupPan", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    _pan = nil;
    [self cancelCurrentGesture];
    [[TWArcWindow sharedWindow] hideForGestures];
    // 关键：切到「ParallelX 边缘手柄」后必须把四角热区窗口全部隐藏。
    // 0.9.15~0.9.19 只移除了手势，窗口还留着 —— 四个 66×66 的透明窗口
    // 正好压在屏幕边缘的 App 图标上，点不动就是这么来的。
    for (TWArcTriggerWindow *w in objc_getAssociatedObject(self, "TWArcTriggerWindows")) {
        if ([w isKindOfClass:UIWindow.class]) w.hidden = YES;
    }
    objc_setAssociatedObject(self, "TWArcTriggerWindows", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSMutableArray *list = objc_getAssociatedObject(self, "TWArcTriggerWindowList");
    for (TWArcTriggerWindow *w in list) {
        if ([w isKindOfClass:UIWindow.class]) w.hidden = YES;
    }
}

// 只在屏幕四个角落的一块方形区域里接管触摸：不碰状态栏、不碰 Home 条，
// 也不与 ParallelX 的边缘手柄抢地方（手柄在边中间，Arc 在角上）。
// SpringBoard 里取当前可用场景：优先已挂窗口的场景，其次前台激活场景，
// 最后退回任意 UIWindowScene。取不到就别建窗口（建了也是瞎的）。
- (UIWindowScene *)activeWindowScene {
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.windowScene) return w.windowScene;
    }
    UIWindowScene *fallback = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)scene;
        if (!fallback) fallback = (UIWindowScene *)scene;
    }
    return fallback;
}

- (void)attachRecognizer {
    NSArray *existingPans = objc_getAssociatedObject(self, "TWArcTriggerPans");
    if (_pan && _pan.view) return;
    if (existingPans.count) return;

    UIWindowScene *scene = [self activeWindowScene];
    UIWindow *reference = nil;
    if (scene) {
        for (UIWindow *w in scene.windows) {
            if (w.bounds.size.width > 200) { reference = w; break; }
        }
    }
    if (!reference) reference = [UIApplication sharedApplication].windows.firstObject;
    if (!scene || !reference) {
        if (_sceneRetries < 40) {
            _sceneRetries++;
            TWRuntimeLog(@"[arc] no scene yet (retry %ld)", (long)_sceneRetries);
            __weak TWArcCoordinator *weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf detachRecognizer];
                [weakSelf attachRecognizer];
            });
        } else {
            TWRuntimeLog(@"[arc] no scene after %ld retries; corner wake inactive", (long)_sceneRetries);
        }
        return;
    }
    _sceneRetries = 0;

    // 0.9.22：不建任何热区窗口（它们会压住图标），把 pan 挂到"真正承载图标"的窗口上。
    // 0.9.21 只挂了 reference.rootViewController.view，实机证明那个视图不是图标的祖先，
    // 手势收不到触摸 → 角落完全没反应。这里给**所有可见窗口**都挂一份：
    // 图标是窗口的子视图，窗口是它们的祖先，所以一定能收到触摸；
    // 再靠 delegate 只接受"从角落起手"，其它触摸一律放行。
    for (TWArcTriggerWindow *w in objc_getAssociatedObject(self, "TWArcTriggerWindowList")) {
        if ([w isKindOfClass:UIWindow.class]) w.hidden = YES;
    }

    NSMutableArray *pans = [NSMutableArray array];
    NSMutableArray *hosts = [NSMutableArray array];
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (![window isKindOfClass:UIWindow.class]) continue;
        if ([window isKindOfClass:NSClassFromString(@"TWArcTriggerWindow")]) continue;
        if ([window isKindOfClass:NSClassFromString(@"TWArcWindow")]) continue;
        if (window.hidden || window.alpha < 0.01 || window.bounds.size.width < 200) continue;
        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        pan.delegate = self;
        pan.maximumNumberOfTouches = 1;
        pan.minimumNumberOfTouches = 1;
        // 识别成功才取消底层触摸（从角落拖动＝确实要菜单）；
        // 轻点图标时 pan 永远不识别，触摸照常交给图标，不会出现"点好几下"。
        pan.cancelsTouchesInView = YES;
        [window addGestureRecognizer:pan];
        [pans addObject:pan];
        [hosts addObject:[NSString stringWithFormat:@"%@(%.0f)", NSStringFromClass(window.class), window.windowLevel]];
    }
    if (!pans.count) {
        UIView *hostView = reference.rootViewController.view ?: reference;
        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        pan.delegate = self;
        pan.maximumNumberOfTouches = 1;
        pan.cancelsTouchesInView = YES;
        [hostView addGestureRecognizer:pan];
        [pans addObject:pan];
        [hosts addObject:NSStringFromClass(hostView.class) ?: @"?"];
    }
    _pan = pans.firstObject;
    objc_setAssociatedObject(self, "TWArcTriggerPans", pans, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    TWArcHotAreas areas = TWArcComputeHotAreas();
    TWRuntimeLog(@"[arc] window gesture attached mask=%ld rect=%@ hosts=%@",
                 (long)areas.mask, NSStringFromCGRect(areas.rects[TWCornerBottomRight]),
                 [hosts componentsJoinedByString:@" | "]);
}

- (TWArcTriggerWindow *)triggerWindowForCorner:(NSInteger)corner {
    NSMutableArray *list = objc_getAssociatedObject(self, "TWArcTriggerWindowList");
    if (!list) { list = [NSMutableArray array]; objc_setAssociatedObject(self, "TWArcTriggerWindowList", list, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    for (TWArcTriggerWindow *w in list) if (w.tag == corner) return w;

    TWArcTriggerRootController *root = [[TWArcTriggerRootController alloc] init];
    TWArcTriggerWindow *w = [[TWArcTriggerWindow alloc] initWithFrame:CGRectZero];
    w.rootViewController = root;
    if ([root.view isKindOfClass:TWArcTriggerView.class]) {
        TWArcTriggerView *v = (TWArcTriggerView *)root.view;
        v.coordinator = self;
        v.corner = corner;
    }
    w.backgroundColor = UIColor.clearColor;
    w.opaque = NO;
    w.windowLevel = UIWindowLevelAlert - 3.0;
    w.tag = corner;
    [list addObject:w];
    return w;
}

// 热区：由窗口本身的 frame 决定，无需再做点判定。
- (void)updateTriggerHotRect {
    // 只有触发区（掩码/矩形）真的变了才重挂手势。
    // 以前每改一个滑杆都 detach+attach 一次，拖一下面板就重挂上百次，
    // 手势被反复拆装，菜单自然"调了不管用"。
    TWArcHotAreas areas = TWArcComputeHotAreas();
    static NSInteger lastMask = -1;
    static CGRect lastRects[4];
    static NSInteger lastMode = -1;
    static CGFloat lastCorner = -1;
    static BOOL lastSymmetric = NO;
    NSInteger mode = (NSInteger)TWArcOrigNumber(@"arcTriggerRegionMode", 0.0);
    CGFloat radius = TWArcOrigNumber(@"arcRectangleCornerRadius", 12.0);
    BOOL symmetric = TWArcOrigBool(@"arcSymmetricMirrorEnabled", NO);
    BOOL same = (areas.mask == lastMask && mode == lastMode &&
                 fabs(radius - lastCorner) < 0.01 && symmetric == lastSymmetric);
    for (NSInteger c = 0; c < 4 && same; c++)
        if (!CGRectEqualToRect(areas.rects[c], lastRects[c])) same = NO;
    if (same) return;
    TWRuntimeLog(@"[arc] hot mode=%ld mask=%ld rect=%.0fx%.0f corner=%.0f area=%@",
                 (long)mode, (long)areas.mask,
                 (double)CGRectGetWidth(areas.rects[TWCornerBottomRight]),
                 (double)CGRectGetHeight(areas.rects[TWCornerBottomRight]),
                 (double)radius, NSStringFromCGRect(areas.rects[TWCornerBottomRight]));
    lastMask = areas.mask;
    lastMode = mode;
    lastCorner = radius;
    lastSymmetric = symmetric;
    for (NSInteger c = 0; c < 4; c++) lastRects[c] = areas.rects[c];
    [self detachRecognizer];
    [self applyWakeMode];
}

// 热区：四个角落各一块 size×size，随面板里的「触发区」设置变化。

- (void)refreshEnabledState {
    [[TWPrefs shared] reload];
    if (!TWArcDeviceUnlocked() ||
        ![[TWPrefs shared] boolForKey:TWKeyEnabled defaultValue:YES] ||
        ![[TWPrefs shared] boolForKey:TWKeyArcEnabled defaultValue:YES]) [self cancelCurrentGesture];
    // 面板改了设置：容器/应用清单可能变了，缓存在非手势时刻重建。
    TWArcInvalidateContainerCache(NO);
    [self scheduleContainerPrefetch];
    // 用户在面板里切换"Arc 角落 / 边缘手柄"要立刻生效。
    [self applyWakeMode];
    [self updateTriggerHotRect];
    // Arc-X 的「视图优先级」：层级 = 1998 + 优先级，改完立刻套到菜单窗口上，
    // 不用等下一次弹菜单才生效。
    [[TWArcWindow sharedWindow] refreshLevel];
}

#pragma mark - gesture delegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    NSArray *pans = objc_getAssociatedObject(self, "TWArcTriggerPans");
    UIPanGestureRecognizer *sysPan = objc_getAssociatedObject(self, "TWArcSysPan");
    BOOL known = pans.count ? [pans containsObject:recognizer] : (recognizer == _pan);
    if (!known && recognizer != sysPan) return NO;
    // 系统手势通道的 recognizer 没有 view（注册在显示器上），不要求 view。
    if (!recognizer.view && recognizer != sysPan) return NO;
    _hasStartPoint = NO;
    [[TWPrefs shared] reload];
    if ([[TWPrefs shared] integerForKey:TWKeyWakeMode defaultValue:TWWakeModeCorner] != TWWakeModeCorner ||
        ![[TWPrefs shared] boolForKey:TWKeyEnabled defaultValue:YES] ||
        ![[TWPrefs shared] boolForKey:TWKeyArcEnabled defaultValue:YES] ||
        !TWArcDeviceUnlocked()) return NO;
    // 统一用屏幕坐标判定：小窗口的气手和主窗口的备用手势走同一套热区。
    UIWindow *touchWindow = touch.window;
    CGPoint screenPoint = touchWindow ? [touchWindow convertPoint:[touch locationInView:touchWindow] toWindow:nil]
                                      : [touch locationInView:recognizer.view];
    NSInteger corner = TWArcCornerAtScreenPoint(screenPoint);
    if (corner < 0) {
        // 热区之外：备用手势必须放行，桌面图标/系统手势照常。
        return NO;
    }
    _startCorner = corner;
    _startPoint = screenPoint;
    _hasStartPoint = YES;
    TWRuntimeLog(@"[arc] touch corner=%ld p=%.0f,%.0f", (long)corner, screenPoint.x, screenPoint.y);
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    NSArray *pans = objc_getAssociatedObject(self, "TWArcTriggerPans");
    BOOL known = pans.count ? [pans containsObject:recognizer] : (recognizer == _pan);
    if (!known && recognizer == objc_getAssociatedObject(self, "TWArcSysPan")) known = YES;
    return known && _hasStartPoint && TWArcDeviceUnlocked() &&
        [[TWPrefs shared] boolForKey:TWKeyEnabled defaultValue:YES] &&
        [[TWPrefs shared] boolForKey:TWKeyArcEnabled defaultValue:YES];
}

- (void)cancelCurrentGesture {
    [self pressReset];
    [_menu dismissAnimated:NO];
    _hasStartPoint = NO;
    _tracking = NO;
    _didPresent = NO;
    [self releaseOverlayWindow];
}

// 菜单收起后收尾：先让收起动画画完，再把整个覆盖窗口隐藏并关掉交互。
// 隐藏即彻底让出触摸，空闲时不会挡状态栏、系统手势或前台应用。
- (void)releaseOverlayWindow {
    if (_menu.isPresented) return;
    __weak TWArcCoordinator *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        TWArcCoordinator *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf->_menu.isPresented) return;
        strongSelf->_menu.userInteractionEnabled = NO;
        strongSelf->_menu.hidden = YES;
        // 窗口本身不隐藏：它是角落手势的宿主，隐藏了就再也收不到触摸。
        [[TWArcWindow sharedWindow] hideMenuContainer];
    });
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return NO;
}

#pragma mark - pan handling

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    NSArray *pans = objc_getAssociatedObject(self, "TWArcTriggerPans");
    UIPanGestureRecognizer *sysPan = objc_getAssociatedObject(self, "TWArcSysPan");
    if (pan != sysPan) {
        if (pans.count && ![pans containsObject:pan]) return;
        if (!pans.count && pan != _pan) return;
    }
    if (!_hasStartPoint || !TWArcDeviceUnlocked() ||
        ![[TWPrefs shared] boolForKey:TWKeyEnabled defaultValue:YES] ||
        ![[TWPrefs shared] boolForKey:TWKeyArcEnabled defaultValue:YES]) {
        [self cancelCurrentGesture];
        return;
    }
    UIWindow *hostWindow = pan.view.window;
    CGPoint p = hostWindow ? [hostWindow convertPoint:[pan locationInView:hostWindow] toWindow:nil]
                           : [pan locationInView:pan.view];
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged: {
            // Began 已经过了 UIKit 的判定阈值：手指一动就直接展开菜单，
            // 不再等额外的 22pt（等太久会被系统手势判成取消）。
            if (!_tracking && !_didPresent) {
                TWRuntimeLog(@"[arc] drag %.0f,%.0f -> %.0f,%.0f (corner %ld) state=%ld",
                             _startPoint.x, _startPoint.y, p.x, p.y, (long)_startCorner, (long)pan.state);
                [self presentMenuFromPoint:_startPoint corner:_startCorner];
                _tracking = _menu.isPresented;
            }
            if (_tracking) {
                CGPoint mp = [pan locationInView:_menu];
                _menuPoint = mp;
                [_menu updateSelectionAtPoint:mp];
                [self trackLongPress];
            }
            break;
        }
        case UIGestureRecognizerStateEnded: {
            if (_tracking) {
                BOOL fullscreen = _longPressActive;
                NSDictionary *selected = [_menu finishSelectionAtPoint:[pan locationInView:_menu]];
                if ([selected isKindOfClass:[NSDictionary class]] && TWArcDeviceUnlocked()) {
                    TWRuntimeLog(@"[arc] selected %@%@", selected[@"title"] ?: selected[@"bundleID"],
                                 fullscreen ? @" (长按→全屏)" : @"");
                    [self launchEntry:selected fullscreen:fullscreen];
                }
            }
            [self pressReset];
            _hasStartPoint = NO;
            _tracking = NO;
            _didPresent = NO;
            [self releaseOverlayWindow];
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            TWRuntimeLog(@"[arc] pan ended by system state=%ld", (long)pan.state);
            [self cancelCurrentGesture];
            break;
        default: break;
    }
}

// 系统手势通道（TWSystemGesture.m 注册，App 前台也能收到触摸）：
// 与桌面 pan 共用同一套状态机——角落判定、弹菜单、选中、长按全都一样。
- (void)twSystemGestureChanged:(UIPanGestureRecognizer *)gesture {
    [self handlePan:gesture];
}

#pragma mark - 角落热区（App 内 / 桌面通用）

+ (void)ensureCornerViewsInPresentationView:(UIView *)host {
    if (![host isKindOfClass:UIView.class]) return;
    TWPrefs *prefs = TWPrefs.shared;
    NSMutableArray<UIView *> *existing = objc_getAssociatedObject(host, "TWSceneHotViews");
    BOOL debug = [prefs boolForKey:TWKeyArcDebug defaultValue:NO] || TWArcOrigBool(@"debugMode", NO);
    BOOL want = debug && TWArcDeviceUnlocked() &&
        [prefs integerForKey:TWKeyWakeMode defaultValue:TWWakeModeCorner] == TWWakeModeCorner &&
        [prefs boolForKey:TWKeyEnabled defaultValue:YES] &&
        [prefs boolForKey:TWKeyArcEnabled defaultValue:YES];
    // Remove legacy trigger views too; debug must never install a touch target.
    for (UIView *view in existing) [view removeFromSuperview];
    objc_setAssociatedObject(host, "TWSceneHotViews", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!want || CGRectIsEmpty(host.bounds)) return;
    UIWindow *window = host.window;
    if (!window) return;
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    CGRect screen = UIScreen.mainScreen.bounds;
    NSInteger mask = TWArcTriggerMask();
    // Map the actual screen-space path by three affine basis points. Unlike a
    // bounds-size ratio, this handles translated/scaled/rotated presentation hosts.
    CGPoint (^convert)(CGPoint) = ^CGPoint(CGPoint point) {
        CGPoint wp = [window convertPoint:point fromWindow:nil];
        return [host convertPoint:wp fromView:window];
    };
    CGPoint o = convert(CGPointZero), x = convert(CGPointMake(1, 0)), y = convert(CGPointMake(0, 1));
    CGAffineTransform transform = CGAffineTransformMake(x.x-o.x, x.y-o.y, y.x-o.x, y.y-o.y, o.x, o.y);
    for (NSInteger corner = 0; corner < 4; corner++) {
        if (!(mask & ((NSInteger)1 << corner))) continue;
        UIBezierPath *path = TWArcRegionPath(corner, screen);
        [path applyTransform:transform];
        TWArcDebugView *view = [[TWArcDebugView alloc] initWithFrame:host.bounds];
        view.bounds = host.bounds;
        view.userInteractionEnabled = NO;
        view.accessibilityElementsHidden = YES;
        view.backgroundColor = UIColor.clearColor;
        CAShapeLayer *shape = [CAShapeLayer layer];
        shape.path = path.CGPath;
        shape.fillColor = [UIColor.systemOrangeColor colorWithAlphaComponent:0.30].CGColor;
        [view.layer addSublayer:shape];
        [host addSubview:view];
        [views addObject:view];
    }
    objc_setAssociatedObject(host, "TWSceneHotViews", views, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - raw touches（四角小窗口专用，不经过手势识别器）

static CGPoint TWArcScreenPointForTouch(UITouch *touch) {
    UIWindow *window = touch.window;
    if (!window) return CGPointZero;
    return [window convertPoint:[touch locationInView:window] toWindow:nil];
}

- (void)rawTouchBegan:(UITouch *)touch corner:(NSInteger)corner {
    if (!touch) return;
    [[TWPrefs shared] reload];
    if (![[TWPrefs shared] boolForKey:TWKeyEnabled defaultValue:YES] ||
        ![[TWPrefs shared] boolForKey:TWKeyArcEnabled defaultValue:YES] ||
        !TWArcDeviceUnlocked()) return;
    _startCorner = corner;
    _startPoint = TWArcScreenPointForTouch(touch);
    _hasStartPoint = YES;
    _didPresent = NO;
    _tracking = NO;
    [self pressReset];
    TWRuntimeLog(@"[arc] touch corner=%ld p=%.0f,%.0f", (long)corner, _startPoint.x, _startPoint.y);
}

- (void)rawTouchMoved:(UITouch *)touch {
    if (!_hasStartPoint || !touch) return;
    if (![[TWPrefs shared] boolForKey:TWKeyArcEnabled defaultValue:YES]) { [self cancelCurrentGesture]; return; }
    CGPoint p = TWArcScreenPointForTouch(touch);
    if (!_didPresent) {
        CGFloat dx = p.x - _startPoint.x, dy = p.y - _startPoint.y;
        if (hypot(dx, dy) >= 3) {
            TWRuntimeLog(@"[arc] drag %.0f,%.0f -> %.0f,%.0f (corner %ld)",
                         _startPoint.x, _startPoint.y, p.x, p.y, (long)_startCorner);
            [self presentMenuFromPoint:_startPoint corner:_startCorner];
            _tracking = _menu.isPresented;
        }
    }
    if (_tracking) {
        [_menu updateSelectionAtPoint:[touch locationInView:_menu]];
        [self trackLongPress];
    }
}

- (void)rawTouchEnded:(UITouch *)touch {
    if (_tracking) {
        BOOL fullscreen = _longPressActive;
        NSDictionary *selected = [_menu finishSelectionAtPoint:[touch locationInView:_menu]];
        if ([selected isKindOfClass:[NSDictionary class]] && TWArcDeviceUnlocked()) {
            TWRuntimeLog(@"[arc] selected %@%@", selected[@"title"] ?: selected[@"bundleID"],
                         fullscreen ? @" (长按→全屏)" : @"");
            [self launchEntry:selected fullscreen:fullscreen];
        }
    }
    [self pressReset];
    _hasStartPoint = NO;
    _tracking = NO;
    _didPresent = NO;
    [self releaseOverlayWindow];
}

- (void)rawTouchCancelled {
    [self cancelCurrentGesture];
}

- (void)pressReset {
    _pressedIndex = -1;
    _pressedSince = 0;
    _longPressActive = NO;
}

// 长按：停在同一个图标上超过设定时长（默认0.45秒，面板可调）算数。
// 面板「长按图标 = 全屏」时，
// 松手就以全屏打开（走 PX 的 +externalOpenApplication:）。
- (CGPoint)_lastMenuPoint { return _menuPoint; }

- (void)trackLongPress {
    NSInteger idx = [_menu selectedIndex];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    // 手指还在动就不算长按：以前只要停在同一个图标上 0.45s 就算，
    // 拖着找图标很容易误触发"强制全屏"。
    CGPoint here = [self _lastMenuPoint];
    CGFloat moved = hypot(here.x - _pressLastPoint.x, here.y - _pressLastPoint.y);
    _pressLastPoint = here;
    if (moved > 4.0) {
        _pressedIndex = idx;
        _pressedSince = now;
        _longPressActive = NO;
        return;
    }
    if (idx != _pressedIndex) {
        _pressedIndex = idx;
        _pressedSince = now;
        _longPressActive = NO;
        return;
    }
    if (idx < 0 || _longPressActive) return;
    // 长按多久算「强制全屏」由面板说了算（默认 0.45 秒）。
    CGFloat holdSeconds = [[TWPrefs shared] floatForKey:TWKeyArcLongPressDuration defaultValue:0.45];
    if (holdSeconds < 0.1) holdSeconds = 0.1;
    if (holdSeconds > 2.0) holdSeconds = 2.0;
    if (now - _pressedSince < holdSeconds) return;
    NSInteger mode = [[TWPrefs shared] integerForKey:TWKeyArcLongPressMode defaultValue:0];
    if (mode != 0) return;
    _longPressActive = YES;
    if ([[TWPrefs shared] boolForKey:TWKeyArcHaptic defaultValue:YES]) {
        UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
        [gen impactOccurred];
    }
    TWRuntimeLog(@"[arc] long-press idx=%ld -> fullscreen", (long)idx);
}

- (void)presentMenuFromPoint:(CGPoint)point corner:(NSInteger)corner {
    if (_didPresent || !TWArcDeviceUnlocked()) return;

    TWArcWindow *host = [TWArcWindow sharedWindow];
    UIWindow *reference = [self activeWindowScene].windows.firstObject;
    if (![host attachToSceneFromWindow:reference]) {
        TWRuntimeLog(@"[arc] present: overlay has no scene");
        return;
    }
    // 层级：Arc-X 的做法是 UIWindowLevelAlert - 2 + 视图优先级（默认 46 → 2044），
    // 高于状态栏(1000)与系统弹窗(2000)。App 在前台时 App 的 scene 也在这一层之上，
    // 所以每次弹出前都重算一遍，保证菜单压在最上面。
    [host refreshLevel];
    [host showForGestures];
    UIView *container = [host menuContainer];
    if (!container) { TWRuntimeLog(@"[arc] present: no container"); return; }
    // 手势坐标是屏幕坐标；经窗口坐标转换到容器坐标系（UIView 没有 fromWindow:）。
    CGPoint local = point;
    UIWindow *containerWindow = container.window;
    if (containerWindow) {
        CGPoint windowPoint = [containerWindow convertPoint:point fromWindow:nil];
        local = [container convertPoint:windowPoint fromView:containerWindow];
    }

    // 优先让 ParallelX 自己弹面板：动画、图标、流畅度都是 PX 本体的。
    // 只有 PX 不可用（未装 / 入口没拿到）时才退回 Twin 自绘的弧形菜单。
    NSInteger pxSide = corner == TWCornerBottomLeft ? 1 : 0;
    if ([[TWPrefs shared] boolForKey:TWKeyArcUsePXPanel defaultValue:NO]) {
        if (TWArcPXBridgePresent(pxSide)) {
            _didPresent = YES;
            TWRuntimeLog(@"[arc] present via PX side=%ld", (long)pxSide);
            if (TWArcOrigBool(@"arcSoundEnabled", YES)) {
                AudioServicesPlaySystemSound(1104);
            }
            return;
        }
        TWRuntimeLog(@"[arc] PX panel unavailable: %@", TWArcPXBridgeLastResult());
    }

    _didPresent = YES;
    [self pressReset];
    if (!_menu) {
        _menu = [[TWArcMenuView alloc] initWithFrame:container.bounds];
        _menu.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    } else {
        _menu.frame = container.bounds;
    }
    _menu.hidden = NO;
    _menu.userInteractionEnabled = YES;
    __weak TWArcCoordinator *twWeak = self;
    _menu.onPickEntry = ^(NSDictionary *entry, BOOL fullscreen) {
        if ([entry isKindOfClass:NSDictionary.class] && TWArcDeviceUnlocked()) {
            [twWeak launchEntry:entry fullscreen:fullscreen];
        }
    };
    [container addSubview:_menu];

    NSArray *entries = [self menuEntries];
    // arcRadius is a trigger metric, not an extra menu-radius term.
    // Actual icon size and menu scale are resolved together by TWArcMenuView.
    CGFloat iconSize = TWArcOrigNumber(@"arcIconSize", 28);
    if (!isfinite(iconSize) || iconSize < 1) iconSize = 28;
    CGFloat spacing = TWArcOrigNumber(@"arcIconSpacing", 0);
    if (!isfinite(spacing) || spacing < 0) spacing = 0;
    CGFloat radius = MAX(104, 2 * iconSize + spacing);
    TWRuntimeLog(@"[arc] present corner=%ld entries=%lu radius=%.0f anchor=%.0f,%.0f",
                 (long)corner, (unsigned long)entries.count, radius, local.x, local.y);
    if (!entries.count) { [self cancelCurrentGesture]; return; }
    [_menu presentFromTriggerPoint:local entries:entries corner:corner radius:radius menuScale:1.0];
    if (TWArcOrigBool(@"arcSoundEnabled", YES)) {
        AudioServicesPlaySystemSound(1104);
    }
}

#pragma mark - 容器 / 应用清单缓存（手势期间绝不调用 Crane）

// 安全模式教训（2026-10-18 02:19:41 SpringBoard EXC_BREAKPOINT + libdispatch abort）：
// 手势回调里做重活（同步 XPC、反复 dispatch_resume）会卡死或直接 abort SpringBoard 主线程。
// 因此 Crane 只在"非手势时刻"（启动、面板改设置、启动完应用后）分次预热进缓存，
// 菜单渲染时只读缓存，绝不现场查询。
static NSMutableDictionary<NSString *, NSArray<NSDictionary *> *> *gTWContainerCache;
static NSMutableDictionary<NSString *, NSString *> *gTWActiveCache;
static NSArray<NSString *> *gTWAppsCache;
static NSTimeInterval gTWAppsCacheAt;
static NSMutableArray<NSString *> *gTWPendingApps;
static BOOL gTWPumping;

static NSArray<NSDictionary *> *TWArcCachedContainers(NSString *bundleID) {
    if (![bundleID isKindOfClass:[NSString class]] || !bundleID.length) return @[];
    id hit = gTWContainerCache[bundleID];
    return [hit isKindOfClass:[NSArray class]] ? hit : @[];
}

static NSString *TWArcCachedActiveContainer(NSString *bundleID) {
    if (![bundleID isKindOfClass:[NSString class]] || !bundleID.length) return @"";
    id hit = gTWActiveCache[bundleID];
    return [hit isKindOfClass:[NSString class]] ? hit : @"";
}

static void TWArcInvalidateContainerCache(BOOL keepApps) {
    if (!gTWContainerCache) gTWContainerCache = [NSMutableDictionary dictionary];
    if (!gTWActiveCache) gTWActiveCache = [NSMutableDictionary dictionary];
    [gTWContainerCache removeAllObjects];
    [gTWActiveCache removeAllObjects];
    if (!keepApps) { gTWAppsCache = nil; gTWAppsCacheAt = 0; }
}

static NSArray<NSString *> *TWArcCachedApps(void) {
    if ([gTWAppsCache isKindOfClass:[NSArray class]] && gTWAppsCache.count &&
        [NSDate date].timeIntervalSince1970 - gTWAppsCacheAt < 120) return gTWAppsCache;
    return nil;
}

static void TWArcStoreApps(NSArray<NSString *> *apps) {
    if (![apps isKindOfClass:[NSArray class]] || !apps.count) return;
    gTWAppsCache = [apps copy];
    gTWAppsCacheAt = [NSDate date].timeIntervalSince1970;
}

static void TWArcPumpNextApp(void) {
    if (!gTWPendingApps.count) { gTWPumping = NO; return; }
    NSString *bundleID = gTWPendingApps.firstObject;
    [gTWPendingApps removeObjectAtIndex:0];
    @try {
        if (bundleID.length) {
            if (!gTWContainerCache) gTWContainerCache = [NSMutableDictionary dictionary];
            if (!gTWActiveCache) gTWActiveCache = [NSMutableDictionary dictionary];
            NSArray *containers = [TWCraneBridge containersForBundleID:bundleID];
            if ([containers isKindOfClass:[NSArray class]] && containers.count) gTWContainerCache[bundleID] = containers;
            NSString *active = [TWCraneBridge activeContainerForBundleID:bundleID];
            if ([active isKindOfClass:[NSString class]] && active.length) gTWActiveCache[bundleID] = active;
        }
    } @catch (__unused NSException *e) {}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        TWArcPumpNextApp();
    });
}

static void TWArcSchedulePrefetch(NSArray<NSString *> *apps) {
    if (!gTWPendingApps) gTWPendingApps = [NSMutableArray array];
    for (id app in apps) {
        if ([app isKindOfClass:[NSString class]] && [app length] && ![gTWPendingApps containsObject:app]) {
            [gTWPendingApps addObject:app];
        }
    }
    if (gTWPumping || !gTWPendingApps.count) return;
    gTWPumping = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        TWArcPumpNextApp();
    });
}

#pragma mark - 菜单条目（一个容器 = 一个图标）

// 优先用面板里配置过的容器清单；没配置就现场问 Crane 要容器；再不行退回"最近使用应用"。
- (NSArray<NSDictionary *> *)menuEntries {
    TWPrefs *prefs = [TWPrefs shared];
    // 自选应用模式：不设任何上限，你选几个就显示几个。
    // 「菜单图标数」只在"最近应用"模式下有意义（控制自动列出的数量）。
    NSInteger limit = NSIntegerMax;   // 选了就全显示；没选才用最近应用兜底

    // 面板里配置的「一个容器一个图标」：按应用分组，作为该应用的图标展开规则。
    // 之前这里直接 return，导致配了分身之后弧菜单里只剩分身、别的应用全消失。
    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *containerRows = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *configuredOrder = [NSMutableArray array];
    NSArray *configured = [prefs objectForKey:TWKeyCraneContainers];
    if ([configured isKindOfClass:[NSArray class]]) {
        for (id raw in configured) {
            if (![raw isKindOfClass:[NSDictionary class]]) continue;
            NSString *bundleID = raw[@"bundleID"];
            if (![bundleID isKindOfClass:[NSString class]] || !bundleID.length) continue;
            NSString *containerID = [raw[@"containerID"] isKindOfClass:[NSString class]] ? raw[@"containerID"] : @"";
            if (!containerID.length) containerID = @"DEFAULT";   // 老数据里的空串＝默认容器
            BOOL enabled = raw[@"enabled"] ? [raw[@"enabled"] boolValue] : YES;
            if (!containerRows[bundleID]) {
                containerRows[bundleID] = [NSMutableArray array];
                [configuredOrder addObject:bundleID];
            }
            if (enabled) [containerRows[bundleID] addObject:@{@"containerID": containerID}];
        }
    }

    // 应用清单：面板「显示哪些应用」＝最近使用 / 自选；空的一边自动兜底。
    NSInteger iconSource = 1;   // 永远"自选优先"，空了自动兜底最近应用
    NSMutableArray<NSString *> *apps = [NSMutableArray array];
    NSArray *configuredApps = [prefs objectForKey:TWKeyCraneAppList];
    void (^addConfigured)(void) = ^{
        if (![configuredApps isKindOfClass:[NSArray class]]) return;
        for (id app in configuredApps) {
            if ([app isKindOfClass:[NSString class]] && [app length] && ![apps containsObject:app]) [apps addObject:app];
        }
    };
    // 自选的（在「应用、快捷操作与排序」里加的）永远排最前——加了应用就必须
    // 能在菜单里看到。图标来源决定剩余位置由谁补：
    //   最近应用 = 自选在前 + 最近补位；自选应用 = 只显示自选（空了退最近）。
    if (iconSource == 1) {
        // 自选应用模式：只显示你选的。一个没选就是空菜单，不再偷偷回退到"最近应用"。
        addConfigured();
    } else {
        addConfigured();
        for (NSString *bid in [self cachedRecentBundleIDs]) {
            if (![apps containsObject:bid]) [apps addObject:bid];
        }
    }
    // Explicitly empty selection remains empty. Container configuration is not
    // permission to reinsert an app the user just removed from the shared list.
    if (![configuredApps isKindOfClass:NSArray.class]) {
        for (NSString *bid in configuredOrder) if (![apps containsObject:bid]) [apps addObject:bid];
    }

    if (iconSource == 1) limit = NSIntegerMax;   // 同上：自选模式不限个数

    // 没装分身插件（Crane）时，"分身"条目全是假的：点了还是同一个 App。
    // 所以只有 Crane 真的可用时才把容器展开成多条。
    BOOL craneOn = [prefs boolForKey:TWKeyCraneEnabled defaultValue:YES] &&
                   [TWCraneBridge isCraneAvailable];
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (NSString *bundleID in apps) {
        if ((NSInteger)entries.count >= limit) break;
        NSString *name = TWArcDisplayName(bundleID);

        // 配过分身的应用：一个容器一条，默认容器排最前（之前这里用 iconSource != 1
        // 判断，而 iconSource 恒为 1，导致分身永远不展开，只剩一个图标）。
        // 面板没配置时直接问 Crane 的容器缓存：有分身才多条，只有默认容器的仍是单图标。
        // 只用面板「分身应用」里明确开启的容器；不再自动把缓存里的容器全展开
        // （那会让应用清单里只选了一个 QQ，菜单里却冒出两个 QQ）。
        NSMutableArray<NSDictionary *> *rows = nil;
        if (craneOn) {
            rows = containerRows[bundleID];
            if (rows && !rows.count) continue; // all configured containers disabled
        }
        if (rows.count) {
            for (NSDictionary *row in rows) {
                if ((NSInteger)entries.count >= limit) break;
                NSString *containerID = row[@"containerID"];
                BOOL isDefault = [containerID isEqualToString:@"DEFAULT"];
                NSString *badge = isDefault ? @"默" : @"分";
                [entries addObject:@{@"bundleID": bundleID, @"containerID": containerID,
                                     @"title": [NSString stringWithFormat:@"%@ · %@", name, badge],
                                     @"badge": badge}];
            }
            continue;
        }

        // 以前这里会把 Crane 的所有容器自动展开成多条（同一个应用出现
        // 「默」「分」两条），用户看到的全是重复图标。现在一律一个应用一条，
        // 用当前所在容器；只有面板里明确配置过分身的应用才会展开。
        NSString *active = craneOn ? TWArcCachedActiveContainer(bundleID) : @"";
        [entries addObject:@{@"bundleID": bundleID,
                             @"containerID": [active isKindOfClass:[NSString class]] ? active : @"",
                             @"title": name,
                             @"badge": @""}];
    }
    return entries;
}

#pragma mark - app launching

// 选中一个"应用 + 容器"条目：先把容器切过去（Crane 可能弹认证），确认后才打开；
// 打开方式看面板里的「ARC 打开方式」（分屏启动 / 全屏启动）。
- (void)launchEntry:(NSDictionary *)entry {
    [self launchEntry:entry fullscreen:NO];
}

- (void)launchEntry:(NSDictionary *)entry fullscreen:(BOOL)fullscreen {
    NSString *bundleID = entry[@"bundleID"];
    if (![bundleID isKindOfClass:[NSString class]] || !bundleID.length || !TWArcDeviceUnlocked()) return;
    NSString *containerID = [entry[@"containerID"] isKindOfClass:[NSString class]] ? entry[@"containerID"] : @"";
    if (TWArcOrigBool(@"arcSoundEnabled", YES)) AudioServicesPlaySystemSound(1519);
    if (containerID.length) {
        // 记忆模块据此知道"这次打开的是哪个容器"（面板窗口出现时只有 bundleID）。
        [[TWPrefs shared] setObject:@{@"bundleID": bundleID, @"containerID": containerID, @"at": [NSDate date]}
                              forKey:TWKeyLastLaunch];
    }
    __weak TWArcCoordinator *weakSelf = self;
    [TWCraneBridge prepareLaunchForBundleID:bundleID containerID:containerID completion:^(BOOL success) {
        if (!success || !TWArcDeviceUnlocked()) return;
        [weakSelf scheduleContainerPrefetch];
        [weakSelf performVerifiedLaunch:bundleID fullscreen:fullscreen];
    }];
}

// Actual launch, called from the Crane completion on the main queue only.
- (void)performVerifiedLaunch:(NSString *)bundleID {
    [self performVerifiedLaunch:bundleID fullscreen:NO];
}

// 打开方式真正落到 ParallelX 的入口上（探针实测的类方法）：
//   +applicationActivated:      分屏打开（PX 自己开窗、动画、缩小小窗全套）
//   +externalOpenApplication:   全屏打开
// 旧代码用的 openFullscreenApplication: 在 PX 里根本不存在 → 全屏那条永远失败，
// 静默回退系统启动，用户看到的就是"全屏打开没反应/不对"。
- (void)performVerifiedLaunch:(NSString *)bundleID fullscreen:(BOOL)fullscreen {
    NSInteger openMode = [[TWPrefs shared] integerForKey:TWKeyArcOpenMode defaultValue:0];
    BOOL wantFullscreen = fullscreen || (openMode == 1);
    if (wantFullscreen) {
        if ([self performParallelXLaunch:bundleID selector:@"externalOpenApplication:"]) {
            TWRuntimeLog(@"[launch] %@ fullscreen via PX", bundleID);
            return;
        }
        TWRuntimeLog(@"[launch] %@ fullscreen via system (PX entry missing)", bundleID);
        [self performSystemLaunch:bundleID];
        return;
    }
    if ([self performParallelXLaunch:bundleID selector:@"applicationActivated:"]) {
        TWRuntimeLog(@"[launch] %@ split via PX", bundleID);
        return;
    }
    TWRuntimeLog(@"[launch] %@ system fallback", bundleID);
    [self performSystemLaunch:bundleID];
}

// 让 ParallelX 自己打开应用（窗口 / 动画 / 小窗全部是它的）。
- (BOOL)performParallelXLaunch:(NSString *)bundleID selector:(NSString *)selectorName {
    Class pxEntry = NSClassFromString(@"PXPanelEntry");
    SEL pxSelector = NSSelectorFromString(selectorName);
    NSMethodSignature *pxSig = TWArcSignature(pxEntry, pxSelector, 3);
    @try {
        if (pxSig && !strcmp(TWArcType(pxSig.methodReturnType), @encode(void)) &&
            TWArcType([pxSig getArgumentTypeAtIndex:2])[0] == '@') {
            ((void (*)(id, SEL, id))objc_msgSend)(pxEntry, pxSelector, bundleID);
            return YES;
        }
    } @catch (__unused NSException *exception) { /* 交给系统回退 */ }
    return NO;
}

// 系统启动回退（没装 ParallelX，或它的接口签名不匹配时）。
- (void)performSystemLaunch:(NSString *)bundleID {
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        SEL selector = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
        NSMethodSignature *sig = TWArcSignature(app, selector, 4);
        if (!sig || TWArcType([sig getArgumentTypeAtIndex:2])[0] != '@') return;
        const char *argument = TWArcType([sig getArgumentTypeAtIndex:3]);
        BOOL boolArgument = !strcmp(argument, @encode(BOOL));
        if (!boolArgument && strcmp(argument, @encode(signed char))) return;
        const char *result = TWArcType(sig.methodReturnType);
        if (strcmp(result, @encode(BOOL)) && strcmp(result, @encode(signed char)) &&
            strcmp(result, @encode(int)) && strcmp(result, @encode(void))) return;
        // NSInvocation marshals the verified return encoding instead of guessing id.
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
        invocation.target = app;
        invocation.selector = selector;
        [invocation setArgument:&bundleID atIndex:2];
        BOOL suspended = NO;
        signed char charSuspended = 0;
        if (boolArgument) [invocation setArgument:&suspended atIndex:3];
        else [invocation setArgument:&charSuspended atIndex:3];
        [invocation invoke];
    } @catch (__unused NSException *exception) { /* Private API failure: no launch. */ }
}

#pragma mark - recent apps

- (NSArray<NSString *> *)recentBundleIDs {
    NSMutableArray *ids = [NSMutableArray array];
    // SpringBoard switcher: most recently used apps first.
    Class switcherClass = NSClassFromString(@"SBMainSwitcherViewController");
    if (switcherClass) {
        id shared = TWArcObject(switcherClass, @"sharedInstance");
        id layouts = TWArcObject(shared, @"recentAppLayouts");
        if ([layouts isKindOfClass:[NSArray class]]) {
            for (id layout in layouts) {
                id items = TWArcValue(layout, @"allItems");
                if (![items isKindOfClass:[NSArray class]]) continue;
                for (id item in items) {
                    NSString *bundleID = TWArcValue(item, @"bundleIdentifier");
                    if ([bundleID isKindOfClass:[NSString class]] && bundleID.length && ![ids containsObject:bundleID]) {
                        [ids addObject:bundleID];
                    }
                }
            }
        }
    }
    // Fallback: installed user apps (ordered by localized name).
    if (ids.count < 4) {
        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        if (workspaceClass) {
            id workspace = TWArcObject(workspaceClass, @"defaultWorkspace");
            id apps = TWArcObject(workspace, @"allApplications");
            if ([apps isKindOfClass:[NSArray class]]) {
                NSMutableArray *extras = [NSMutableArray array];
                for (id proxy in apps) {
                    NSString *bundleID = TWArcValue(proxy, @"bundleIdentifier");
                    NSString *name = TWArcValue(proxy, @"localizedName");
                    if (![bundleID isKindOfClass:[NSString class]] || !bundleID.length) continue;
                    if ([bundleID hasPrefix:@"com.apple."]) continue; // skip most system apps
                    if (![name isKindOfClass:[NSString class]] || !name.length) name = bundleID;
                    [extras addObject:@{@"id": bundleID, @"name": name}];
                }
                [extras sortUsingComparator:^NSComparisonResult(id a, id b) {
                    return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
                }];
                for (NSDictionary *entry in extras) {
                    if (ids.count >= 8) break;
                    if (![ids containsObject:entry[@"id"]]) [ids addObject:entry[@"id"]];
                }
            }
        }
    }
    return ids;
}

// 菜单渲染用的应用清单：只读缓存；缓存没就绪就用"最近使用"的轻量版本
// （不扫全部已装应用，避免手势期间做重活）。
- (NSArray<NSString *> *)cachedRecentBundleIDs {
    NSArray *cached = TWArcCachedApps();
    if (cached.count) return cached;
    return [self fastRecentBundleIDs];
}

- (NSArray<NSString *> *)fastRecentBundleIDs {
    NSMutableArray *ids = [NSMutableArray array];
    Class switcherClass = NSClassFromString(@"SBMainSwitcherViewController");
    if (switcherClass) {
        id shared = TWArcObject(switcherClass, @"sharedInstance");
        id layouts = TWArcObject(shared, @"recentAppLayouts");
        if ([layouts isKindOfClass:[NSArray class]]) {
            for (id layout in layouts) {
                id items = TWArcValue(layout, @"allItems");
                if (![items isKindOfClass:[NSArray class]]) continue;
                for (id item in items) {
                    NSString *bundleID = TWArcValue(item, @"bundleIdentifier");
                    if ([bundleID isKindOfClass:[NSString class]] && bundleID.length && ![ids containsObject:bundleID]) {
                        [ids addObject:bundleID];
                    }
                }
            }
        }
    }
    return ids;
}

// 预热容器清单：主线程分次完成（每个应用间隔 0.25s），只在不影响手势的时刻调用。
- (void)scheduleContainerPrefetch {
    if (![[TWPrefs shared] boolForKey:TWKeyCraneEnabled defaultValue:YES]) return;
    static NSTimeInterval lastScanAt;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    BOOL scanApps = (now - lastScanAt >= 8.0) || ![gTWAppsCache isKindOfClass:[NSArray class]];
    NSMutableArray<NSString *> *apps = [NSMutableArray array];
    NSArray *configured = [[TWPrefs shared] objectForKey:TWKeyCraneAppList];
    if ([configured isKindOfClass:[NSArray class]]) {
        for (id app in configured) {
            if ([app isKindOfClass:[NSString class]] && [app length] && ![apps containsObject:app]) [apps addObject:app];
        }
    }
    if (scanApps) {
        lastScanAt = now;
        NSArray *recent = [self recentBundleIDs];
        TWArcStoreApps(recent);
        for (NSString *app in recent) if (![apps containsObject:app]) [apps addObject:app];
    }
    // 有分身的应用优先预热：Crane 一次就能列出"带非默认容器"的应用，
    // 这样第一次弹菜单也能看到分身图标，而不是等缓存慢慢补齐。
    if ([TWCraneBridge isCraneAvailable]) {
        NSArray<NSString *> *cloned = [TWCraneBridge applicationsWithNonDefaultContainers];
        for (NSString *app in cloned) if (![apps containsObject:app]) [apps insertObject:app atIndex:0];
        TWRuntimeLog(@"[crane] prefetch available=1 cloned=%lu apps=%lu",
                     (unsigned long)cloned.count, (unsigned long)apps.count);
    } else {
        TWRuntimeLog(@"[crane] prefetch available=0");
    }
    NSArray *cached = TWArcCachedApps();
    if (!apps.count && cached.count) [apps addObjectsFromArray:cached];
    TWArcSchedulePrefetch(apps);
}

@end