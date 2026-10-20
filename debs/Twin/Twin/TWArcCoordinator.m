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
#import <AudioToolbox/AudioServices.h>
#import <objc/message.h>
#import <objc/runtime.h>
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

// 触发区几何：与面板「从哪些角落唤醒 / 触发区」完全对应，两个使用者
//（小窗口和备用手势）共用一份，避免两处算法漂移。
static TWArcHotAreas TWArcComputeHotAreas(void) {
    TWArcHotAreas out;
    memset(&out, 0, sizeof(out));
    TWPrefs *prefs = TWPrefs.shared;
    NSInteger mask = [prefs integerForKey:TWKeyArcCorners defaultValue:3];
    if ([prefs boolForKey:TWKeyArcMirror defaultValue:NO]) {
        if (mask & 1) mask |= 2;
        if (mask & 2) mask |= 1;
        if (mask & 4) mask |= 8;
        if (mask & 8) mask |= 4;
    }
    CGRect screen = UIScreen.mainScreen.bounds;
    BOOL landscape = CGRectGetWidth(screen) > CGRectGetHeight(screen);
    CGFloat offX = [prefs floatForKey:TWKeyArcOffsetX defaultValue:0];
    CGFloat offY = [prefs floatForKey:TWKeyArcOffsetY defaultValue:0];
    if (landscape) offX += [prefs floatForKey:TWKeyArcLandscapeOffset defaultValue:0];
    NSInteger triggerMode = [prefs integerForKey:TWKeyArcTriggerMode defaultValue:0];
    CGFloat tw = 64, th = 64;
    if (triggerMode == 1) {
        tw = MAX(24.0, [prefs floatForKey:TWKeyArcRectLength defaultValue:40]);
        th = MAX(24.0, [prefs floatForKey:TWKeyArcRectHeight defaultValue:40]);
    } else {
        CGFloat size = [prefs floatForKey:TWKeyArcCornerSize defaultValue:64];
        tw = th = MAX(24.0, MIN(size, MIN(CGRectGetWidth(screen), CGRectGetHeight(screen)) / 3.0));
    }
    for (NSInteger corner = 0; corner < 4; corner++) {
        BOOL leftSide = (corner == TWCornerBottomLeft || corner == TWCornerTopLeft);
        BOOL topSide  = (corner == TWCornerTopLeft || corner == TWCornerTopRight);
        CGFloat ox = leftSide ? offX : CGRectGetWidth(screen) - tw - offX;
        CGFloat oy = topSide ? 28 + offY : CGRectGetHeight(screen) - 28 - th - offY;
        out.rects[corner] = CGRectMake(ox, oy, tw, th);
    }
    out.mask = mask;
    return out;
}

static NSInteger TWArcCornerAtScreenPoint(CGPoint point) {
    TWArcHotAreas areas = TWArcComputeHotAreas();
    for (NSInteger corner = 0; corner < 4; corner++) {
        if (!(areas.mask & ((NSInteger)1 << corner))) continue;
        if (CGRectContainsPoint(areas.rects[corner], point)) return corner;
    }
    return -1;
}

@interface TWArcTriggerView : UIView
@end

@implementation TWArcTriggerView
@end

@interface TWArcTriggerWindow : UIWindow
@end

@implementation TWArcTriggerWindow
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
    }
    return self;
}

#pragma mark - lifecycle

- (void)start {
    if (_started) return;
    _started = YES;
    TWRuntimeLog(@"[arc] start enabled=%@ arcEnabled=%@ wakeMode=%ld prefs=%@",
                 @([[TWPrefs shared] boolForKey:TWKeyEnabled defaultValue:YES]),
                 @([[TWPrefs shared] boolForKey:TWKeyArcEnabled defaultValue:YES]),
                 (long)[[TWPrefs shared] integerForKey:TWKeyWakeMode defaultValue:TWWakeModeCorner],
                 TWPrefsFilePath() ?: @"(nil)");
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
    if (mode == TWWakeModeHandle) {
        [self detachRecognizer];
        return;
    }
    [self attachRecognizer];
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
        // 场景还没建好：建出来的窗口没有场景，永远收不到触摸。
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

    // 0.9.13：不再用四块 64×64 的小窗口 + 主窗口备用手势。
    // 小窗口里的 pan 会被 SpringBoard 自己的图标/系统手势取消（日志里只有 touch 没有 drag），
    // 主窗口的备用 pan 又会和它互相打架。改成 ScreenCore 的结构：
    // 一个全屏透明高层窗口，hitTest 只放行四个角落，手势挂在这个窗口的根视图上，
    // 命中后整条触摸链都由它独占，任何系统手势都抢不走。
    TWArcWindow *host = [TWArcWindow sharedWindow];
    if (![host attachToSceneFromWindow:reference]) {
        TWRuntimeLog(@"[arc] overlay window cannot attach to scene");
        return;
    }
    _sceneRetries = 0;

    TWArcHotAreas areas = TWArcComputeHotAreas();
    NSMutableArray<NSValue *> *rects = [NSMutableArray array];
    for (NSInteger corner = 0; corner < 4; corner++) {
        if ((areas.mask & (1 << corner)) == 0) continue;
        [rects addObject:[NSValue valueWithCGRect:areas.rects[corner]]];
    }
    [host setCaptureRects:rects];
    [host showForGestures];

    UIView *container = [host menuContainer];
    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    pan.delegate = self;
    pan.maximumNumberOfTouches = 1;
    pan.minimumNumberOfTouches = 1;
    pan.cancelsTouchesInView = NO;
    [container addGestureRecognizer:pan];
    _pan = pan;
    _pxHostWindow = host;
    objc_setAssociatedObject(self, "TWArcTriggerPans", @[pan], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    TWRuntimeLog(@"[arc] overlay ready level=%.0f mask=%ld rect=%@ size=%@",
                 host.windowLevel, (long)areas.mask,
                 NSStringFromCGRect(areas.rects[TWCornerBottomRight]),
                 NSStringFromCGSize(host.bounds.size));
}

- (TWArcTriggerWindow *)triggerWindowForCorner:(NSInteger)corner {
    NSMutableArray *list = objc_getAssociatedObject(self, "TWArcTriggerWindowList");
    if (!list) { list = [NSMutableArray array]; objc_setAssociatedObject(self, "TWArcTriggerWindowList", list, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    for (TWArcTriggerWindow *w in list) if (w.tag == corner) return w;

    TWArcTriggerRootController *root = [[TWArcTriggerRootController alloc] init];
    TWArcTriggerWindow *w = [[TWArcTriggerWindow alloc] initWithFrame:CGRectZero];
    w.rootViewController = root;
    w.backgroundColor = UIColor.clearColor;
    w.opaque = NO;
    w.windowLevel = UIWindowLevelAlert - 3.0;
    w.tag = corner;
    [list addObject:w];
    return w;
}

// 热区：由窗口本身的 frame 决定，无需再做点判定。
- (void)updateTriggerHotRect {
    [self detachRecognizer];
    [self attachRecognizer];
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
}

#pragma mark - gesture delegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    NSArray *pans = objc_getAssociatedObject(self, "TWArcTriggerPans");
    BOOL known = pans.count ? [pans containsObject:recognizer] : (recognizer == _pan);
    if (!known || !recognizer.view) return NO;
    _hasStartPoint = NO;
    [[TWPrefs shared] reload];
    if (![[TWPrefs shared] boolForKey:TWKeyEnabled defaultValue:YES] ||
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
    if (pans.count && ![pans containsObject:pan]) return;
    if (!pans.count && pan != _pan) return;
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
                [_menu updateSelectionAtPoint:[pan locationInView:_menu]];
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

- (void)pressReset {
    _pressedIndex = -1;
    _pressedSince = 0;
    _longPressActive = NO;
}

// 长按：停在同一个图标上 0.45 秒算数。面板「长按图标 = 全屏」时，
// 松手就以全屏打开（走 PX 的 +externalOpenApplication:）。
- (void)trackLongPress {
    NSInteger idx = [_menu selectedIndex];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (idx != _pressedIndex) {
        _pressedIndex = idx;
        _pressedSince = now;
        _longPressActive = NO;
        return;
    }
    if (idx < 0 || _longPressActive) return;
    if (now - _pressedSince < 0.45) return;
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
    NSInteger pxSide = [[TWPrefs shared] integerForKey:TWKeyArcSide defaultValue:0] == 1 ? 1 : 0;
    if ([[TWPrefs shared] boolForKey:TWKeyArcUsePXPanel defaultValue:YES]) {
        if (TWArcPXBridgePresent(pxSide)) {
            _didPresent = YES;
            TWRuntimeLog(@"[arc] present via PX side=%ld", (long)pxSide);
            if ([[TWPrefs shared] boolForKey:TWKeyArcSound defaultValue:YES]) {
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
    [container addSubview:_menu];

    NSArray *entries = [self menuEntries];
    CGFloat radius = [[TWPrefs shared] floatForKey:TWKeyArcRadius defaultValue:150];
    TWRuntimeLog(@"[arc] present corner=%ld entries=%lu radius=%.0f anchor=%.0f,%.0f",
                 (long)corner, (unsigned long)entries.count, radius, local.x, local.y);
    if (!entries.count) { [self cancelCurrentGesture]; return; }
    [_menu presentFromTriggerPoint:local entries:entries corner:corner radius:radius menuScale:1.0];
    if ([[TWPrefs shared] boolForKey:TWKeyArcSound defaultValue:YES]) {
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
    NSInteger limit = MAX(2, MIN(8, [prefs integerForKey:TWKeyArcItemCount defaultValue:6]));

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
            if (!enabled) continue;
            if (!containerRows[bundleID]) {
                containerRows[bundleID] = [NSMutableArray array];
                [configuredOrder addObject:bundleID];
            }
            [containerRows[bundleID] addObject:@{@"containerID": containerID}];
        }
    }

    // 应用清单：面板「显示哪些应用」＝最近使用 / 自选；空的一边自动兜底。
    NSInteger iconSource = [prefs integerForKey:TWKeyArcIconSource defaultValue:0];
    NSMutableArray<NSString *> *apps = [NSMutableArray array];
    NSArray *configuredApps = [prefs objectForKey:TWKeyCraneAppList];
    void (^addConfigured)(void) = ^{
        if (![configuredApps isKindOfClass:[NSArray class]]) return;
        for (id app in configuredApps) {
            if ([app isKindOfClass:[NSString class]] && [app length] && ![apps containsObject:app]) [apps addObject:app];
        }
    };
    if (iconSource == 1) {
        addConfigured();
        if (!apps.count) [apps addObjectsFromArray:[self cachedRecentBundleIDs]];
    } else {
        [apps addObjectsFromArray:[self cachedRecentBundleIDs]];
        if (!apps.count) addConfigured();
    }
    // 配了分身的应用必须出现在菜单里（放在最前面，方便直接点）。
    for (NSString *bundleID in configuredOrder.reverseObjectEnumerator) {
        [apps removeObject:bundleID];
        [apps insertObject:bundleID atIndex:0];
    }

    BOOL craneOn = [prefs boolForKey:TWKeyCraneEnabled defaultValue:YES];
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (NSString *bundleID in apps) {
        if ((NSInteger)entries.count >= limit) break;
        NSString *name = TWArcDisplayName(bundleID);

        NSMutableArray<NSDictionary *> *rows = craneOn ? containerRows[bundleID] : nil;
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

        // 没有面板配置时，用 Crane 导出的容器清单自动展开（一个容器一个图标）。
        NSArray<NSDictionary *> *containers = craneOn ? TWArcCachedContainers(bundleID) : @[];
        if (containers.count > 1) {
            for (NSDictionary *container in containers) {
                if ((NSInteger)entries.count >= limit) break;
                NSString *containerID = [container[@"containerID"] isKindOfClass:[NSString class]] ? container[@"containerID"] : @"";
                if (!containerID.length) continue;
                BOOL isDefault = [containerID isEqualToString:@"DEFAULT"] ||
                                 (container[@"isDefault"] ? [container[@"isDefault"] boolValue] : NO);
                NSString *containerName = [container[@"name"] isKindOfClass:[NSString class]] ? container[@"name"] : @"";
                NSString *badge = isDefault ? @"默" : (containerName.length ? containerName : @"分");
                [entries addObject:@{@"bundleID": bundleID, @"containerID": containerID,
                                     @"title": [NSString stringWithFormat:@"%@ · %@", name, badge],
                                     @"badge": badge}];
            }
            continue;
        }
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
    if ([[TWPrefs shared] boolForKey:TWKeyArcSound defaultValue:YES]) AudioServicesPlaySystemSound(1519);
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
    NSArray *cached = TWArcCachedApps();
    if (!apps.count && cached.count) [apps addObjectsFromArray:cached];
    TWArcSchedulePrefetch(apps);
}

@end