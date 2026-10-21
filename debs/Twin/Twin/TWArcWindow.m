// TWArcWindow.m
#import "TWArcWindow.h"
#import "TWPrefs.h"
#import <objc/message.h>
#import "TWPrefs.h"
#import "TWPath.h"
#import <math.h>

// 基准层级与 Arc-X 的高层级窗口同一族（UIWindowLevelAlert - 2 = 1998），
// 再叠加「视图优先级」：默认 46 → 生效层级 2044，上限 2200 → 4198。
// 1998 已经高于状态栏(1000)；2044 起高于系统弹窗(2000)。层级再高也盖不过
// iOS 的安全界面（密码/支付），也不解除锁屏保护，这与 Arc-X 的说明一致。
static const CGFloat TWArcLevelOffset = -2.0;
static const NSInteger TWArcPriorityFloor = 0;
static const NSInteger TWArcPriorityCeiling = 2200;

#pragma mark - 透传容器

// 只让子视图（菜单）接管触摸：空白区域返回 nil，触摸穿透到下层窗口，
// 这样状态栏点击、系统手势、前台应用都不受影响。
@interface TWArcPassthroughView : UIView
@property (nonatomic, copy, nullable) NSArray<NSValue *> *captureRects;
@end

@implementation TWArcPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.01 || !self.userInteractionEnabled) return nil;
    // 菜单已经展开时，优先让菜单本身接收触摸。
    for (UIView *sub in self.subviews.reverseObjectEnumerator) {
        if (sub.hidden || sub.alpha < 0.01) continue;
        CGPoint local = [sub convertPoint:point fromView:self];
        UIView *hit = [sub hitTest:local withEvent:event];
        if (hit) return hit;
    }
    // 空闲时只接住四个角落的触摸：手势挂在本视图上，命中后由它独占这条触摸链，
    // 不会再被 SpringBoard 的图标/系统手势抢走（这正是之前拖不动的原因）。
    for (NSValue *value in self.captureRects) {
        if (CGRectContainsPoint(value.CGRectValue, point)) return self;
    }
    return nil;
}
@end

@interface TWArcRootViewController : UIViewController @end

@implementation TWArcRootViewController
- (void)loadView {
    TWArcPassthroughView *root = [[TWArcPassthroughView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    root.backgroundColor = UIColor.clearColor;
    root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view = root;
}
- (BOOL)prefersStatusBarHidden { return NO; }
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleDefault; }
@end

#pragma mark - 覆盖窗口

@implementation TWArcWindow

+ (instancetype)sharedWindow {
    static TWArcWindow *window;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ window = [[TWArcWindow alloc] init]; });
    return window;
}

- (instancetype)init {
    TWArcRootViewController *root = [[TWArcRootViewController alloc] init];
    if ((self = [super initWithFrame:UIScreen.mainScreen.bounds])) {
        self.rootViewController = root;
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.hidden = YES;
        self.userInteractionEnabled = YES;
        self.windowLevel = UIWindowLevelAlert + TWArcLevelOffset;
    }
    return self;
}

// 绝不抢 key 状态：前台应用/键盘/输入焦点不受影响。
- (BOOL)canBecomeKeyWindow { return NO; }

- (BOOL)attachToSceneFromWindow:(UIWindow *)reference {
    UIWindowScene *scene = nil;
    if ([reference isKindOfClass:UIWindow.class]) scene = reference.windowScene;
    if (!scene) {
        for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
            if (![candidate isKindOfClass:UIWindowScene.class]) continue;
            if (candidate.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)candidate;
                break;
            }
            if (!scene && candidate.activationState != UISceneActivationStateUnattached) {
                scene = (UIWindowScene *)candidate;
            }
        }
    }
    if (!scene) return NO;
    if (self.windowScene != scene) self.windowScene = scene;
    CGRect bounds = scene.coordinateSpace.bounds;
    if (!CGRectIsEmpty(bounds)) self.frame = bounds;
    [self refreshLevel];
    return YES;
}

- (void)refreshLevel {
    // 录屏过滤：整个覆盖窗口不参与截图/录屏（以前只对菜单视图设了，窗口仍然被录进去）
    BOOL hideCap = TWArcOrigBool(@"hideArcFromScreenCaptureEnabled", NO);
    SEL hideSel = NSSelectorFromString(@"_setHideFromCapture:");
    if ([self respondsToSelector:hideSel]) {
        @try { ((void (*)(id, SEL, BOOL))objc_msgSend)(self, hideSel, hideCap); } @catch (__unused NSException *e) {}
    }
    [[TWPrefs shared] reload];
    NSInteger priority = [[TWPrefs shared] integerForKey:TWKeyArcWindowPriority
                                            defaultValue:TWArcPriorityDefault];
    if (priority < TWArcPriorityFloor) priority = TWArcPriorityFloor;
    if (priority > TWArcPriorityCeiling) priority = TWArcPriorityCeiling;
    CGFloat level = UIWindowLevelAlert + TWArcLevelOffset + (CGFloat)priority;
    if (fabs((double)(self.windowLevel - level)) > 0.01) self.windowLevel = level;
}

- (UIView *)menuContainer { return self.rootViewController.view; }

- (void)setCaptureRects:(NSArray<NSValue *> *)rects {
    UIView *root = self.rootViewController.view;
    if ([root isKindOfClass:TWArcPassthroughView.class]) {
        ((TWArcPassthroughView *)root).captureRects = rects ?: @[];
    }
}

- (void)showForGestures {
    UIWindowScene *scene = self.windowScene;
    if (scene) {
        CGRect bounds = scene.coordinateSpace.bounds;
        if (!CGRectIsEmpty(bounds)) self.frame = bounds;
    }
    [self refreshLevel];
    self.hidden = NO;
}

- (void)showMenuContainer {
    UIWindowScene *scene = self.windowScene;
    if (scene) {
        CGRect bounds = scene.coordinateSpace.bounds;
        if (!CGRectIsEmpty(bounds)) self.frame = bounds;
    }
    [self refreshLevel];
    self.hidden = NO;
}

- (void)hideMenuContainer {
    // 空闲时整窗隐藏：菜单窗口是全屏层级，留着不隐藏就可能把桌面点击吃掉。
    // 角落手势现在挂在独立的小窗口上，不需要它常驻。
    self.hidden = YES;
}

- (void)hideForGestures {
    [self setCaptureRects:@[]];
    self.hidden = YES;
}

@end