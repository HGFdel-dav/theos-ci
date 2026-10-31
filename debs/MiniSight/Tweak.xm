// MiniSight —— 屏幕顶部的小胶囊，提示「Minis 正在操作这台手机」
//
// 触发方式：Darwin 通知（无需 hook 任何 Minis 内部逻辑）
//   com.openminis.agent.started   → 淡入显示
//   com.openminis.agent.stopped   → 淡出隐藏
//
// 设计要点：
//   1. 独立 UIWindow（UIWindowLevelAlert + 1），透明背景，永不成为 key window；
//   2. 只有胶囊本身接收触摸，屏幕其它区域全部穿透给下层窗口；
//   3. 132×36 圆角胶囊 + 暖米色脉动圆点 + 白色小字；
//   4. 可以拖动，位置写 NSUserDefaults（MiniSightCenterX / MiniSightCenterY）；
//   5. 旋转时重新计算并 clamp，保证浮窗不会跑出屏幕。
//
// 目标系统：iOS 15.x（SpringBoard，arm64 / arm64e）

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreFoundation/CoreFoundation.h>
#import <ReplayKit/ReplayKit.h>
#import "MiniSightPet.h"


#pragma mark - MiniSight 配置（读 Minis 容器的偏好）

static void MiniSightHide(void);
static void MiniSightHideBubble(void);
static void MiniSightShowConfirm(void);
static void MiniSightAnswerConfirm(BOOL allow);

/// 找到 com.openminis.app 的容器（SpringBoard 不受沙盒限制，可按元数据扫描）。
static NSString *MiniSightAppContainer(void) {
    NSString *base = @"/var/mobile/Containers/Data/Application";
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *uuid in [fm contentsOfDirectoryAtPath:base error:nil]) {
        NSString *dir = [base stringByAppendingPathComponent:uuid];
        NSString *meta = [dir stringByAppendingPathComponent:
                          @".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:meta];
        if ([info[@"MCMMetadataIdentifier"] isEqualToString:@"com.openminis.app"]) {
            return dir;
        }
    }
    return nil;
}

/// 0 = 胶囊，1 = 桌宠。写在 App 的 NSUserDefaults 里。
static NSInteger MiniSightStyle(void) {
    NSString *container = MiniSightAppContainer();
    if (!container) return 0;
    NSString *plist = [container stringByAppendingPathComponent:@"Library/Preferences/com.openminis.app.plist"];
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:plist];
    return [prefs[@"minisight.style"] integerValue];
}

static NSString *MiniSightPetPath(void) {
    NSString *container = MiniSightAppContainer();
    if (!container) return nil;
    return [container stringByAppendingPathComponent:@"Documents/MiniSight/pet.png"];
}

/// 常驻开关：开着的时候不随 stopped 隐藏，桌面一直留着。
static BOOL MiniSightAlwaysShow(void) {
    NSString *container = MiniSightAppContainer();
    if (!container) return NO;
    NSString *plist = [container stringByAppendingPathComponent:@"Library/Preferences/com.openminis.app.plist"];
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:plist];
    return [prefs[@"minisight.mode"] integerValue] == 1;
}
/// 总开关（设置里的「显示桌宠」，文件里 0/1，默认开）
static BOOL MiniSightShown(void) {
    NSString *container = MiniSightAppContainer();
    if (!container) return YES;
    NSString *path = [container stringByAppendingPathComponent:@"Documents/MiniSight/shown"];
    NSString *v = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    return ![v isEqualToString:@"0"];
}

/// 双击隐藏：写 0（去设置里打开才恢复）
static void MiniSightUserHide(void) {
    NSString *container = MiniSightAppContainer();
    if (container) {
        NSString *dir = [container stringByAppendingPathComponent:@"Documents/MiniSight"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        [[@"0" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:[dir stringByAppendingPathComponent:@"shown"] atomically:YES];
    }
    MiniSightHide();
}


/// 录屏开关（App 设置里，默认关）
static BOOL MiniSightRecordingEnabled(void) {
    NSString *container = MiniSightAppContainer();
    if (!container) return NO;
    NSString *plist = [container stringByAppendingPathComponent:@"Library/Preferences/com.openminis.app.plist"];
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:plist];
    return [prefs[@"minisight.record"] boolValue];
}

static BOOL gMiniSightRecording = NO;

static NSString *MiniSightRecordingDir(void) {
    NSString *container = MiniSightAppContainer();
    NSString *dir = container
        ? [container stringByAppendingPathComponent:@"Documents/MiniSight/recordings"]
        : @"/var/mobile/Documents/MiniSight/recordings";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static void MiniSightStartRecording(void) {
    if (gMiniSightRecording) return;
    RPScreenRecorder *recorder = [RPScreenRecorder sharedRecorder];
    if (!recorder.isAvailable) {
        NSLog(@"[MiniSight] recorder unavailable");
        return;
    }
    gMiniSightRecording = YES;
    [recorder startRecordingWithHandler:^(NSError *error) {
        if (error) {
            gMiniSightRecording = NO;
            NSLog(@"[MiniSight] startRecording failed: %@", error.localizedDescription);
        }
    }];
}

static void MiniSightStopRecording(void) {
    if (!gMiniSightRecording) return;
    gMiniSightRecording = NO;
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *name = [NSString stringWithFormat:@"rec-%@.mp4", [fmt stringFromDate:[NSDate date]]];
    NSString *path = [MiniSightRecordingDir() stringByAppendingPathComponent:name];
    [[RPScreenRecorder sharedRecorder] stopRecordingWithOutputURL:[NSURL fileURLWithPath:path]
                                                completionHandler:^(NSError *error) {
        if (error) NSLog(@"[MiniSight] stopRecording failed: %@", error.localizedDescription);
        else NSLog(@"[MiniSight] saved %@", path);
    }];
}

static void MiniSightToggleRecording(void) {
    if (gMiniSightRecording) MiniSightStopRecording();
    else MiniSightStartRecording();
}

#pragma mark - 常量

static const CGFloat kMiniSightWidth      = 132.0; // 胶囊宽度
static const CGFloat kMiniSightHeight     = 36.0;  // 胶囊高度
static const CGFloat kMiniSightRadius     = 18.0;  // 圆角半径（正好是高度的一半）
static const CGFloat kMiniSightDotSize    = 7.0;   // 圆点直径
static const CGFloat kMiniSightDotLeft    = 12.0;  // 圆点左边距
static const CGFloat kMiniSightDotGap     = 8.0;   // 圆点到文字的距离
static const CGFloat kMiniSightTextRight  = 15.0;  // 文字右边距
static const CGFloat kMiniSightEdge       = 8.0;   // 拖动时距离屏幕边缘的最小留白

static NSString *const kMiniSightStarted   = @"com.openminis.agent.started";
static NSString *const kMiniSightStopped   = @"com.openminis.agent.stopped";
static NSString *const kMiniSightSettingsChanged = @"com.openminis.minisight.settings";
static NSString *const kMiniSightStatus = @"com.openminis.minisight.status";
static NSString *const kMiniSightShow = @"com.openminis.minisight.show";
static NSString *const kMiniSightConfirmNote = @"com.openminis.minisight.confirm";
static NSString *const kMiniSightBlanked = @"com.apple.springboard.hasBlankedScreen";
static NSString *const kMiniSightCenterX   = @"MiniSightCenterX";
static NSString *const kMiniSightCenterY   = @"MiniSightCenterY";
static NSString *const kMiniSightText      = @"Minis 操作中";

#pragma mark - 全局状态

static UIWindow *gMiniSightWindow = nil;   // 浮窗载体
static UIView   *gMiniSightPill   = nil;   // 胶囊本体
static UIView   *gMiniSightDot    = nil;   // 实心圆点（自身发光）
static UIView   *gMiniSightPulse  = nil;   // 圆点背后的脉动圈
static UILabel  *gMiniSightLabel  = nil;   // 文字
static id        gMiniSightGestureTarget = nil; // 手势/通知的 target（需强引用）
static BOOL      gMiniSightBuilt  = NO;
static BOOL      gMiniSightUserHidden = NO;   // 双击隐藏，下一次 MCP 调用自动恢复
static MiniSightPetView *gMiniSightPet = nil;   // 可选桌宠（存在 pet.png 时启用）
static dispatch_block_t gMiniSightMaxShow = nil; // 自保：App 没发 stopped 也要收
BOOL gMiniSightBurst = NO;   // 只在 MCP 调用期间为 YES
static UIView *gMiniSightBubble = nil;
static UILabel *gMiniSightBubbleLabel = nil;
static CAShapeLayer *gMiniSightBubbleTail = nil;
static dispatch_block_t gMiniSightBubbleHideWork = nil;
static NSString *gMiniSightLastLine = nil;

#pragma mark - 颜色 / 基础计算

/// 暖米色 #E8DCC8
static UIColor *MiniSightDotColor(void) {
    return [UIColor colorWithRed:0.91 green:0.86 blue:0.78 alpha:1.0];
}

/// 当前界面方向（优先用 windowScene，旧系统回落到状态栏方向）
static UIInterfaceOrientation MiniSightOrientation(void) {
    if (@available(iOS 13.0, *)) {
        if (gMiniSightWindow.windowScene) {
            return gMiniSightWindow.windowScene.interfaceOrientation;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [UIApplication sharedApplication].statusBarOrientation;
#pragma clang diagnostic pop
}

/// 屏幕矩形（按当前界面方向换成横/竖的宽高）
/// 说明：这里只取 UIScreen.mainScreen.bounds，不依赖 keyWindow.frame ——
///       SpringBoard 上 keyWindow 的 frame 在启动早期/旋转过程中并不总是准的。
static CGRect MiniSightScreenRect(void) {
    CGRect bounds = [UIScreen mainScreen].bounds;
    CGFloat shortSide = MIN(bounds.size.width, bounds.size.height);
    CGFloat longSide  = MAX(bounds.size.width, bounds.size.height);

    if (UIInterfaceOrientationIsLandscape(MiniSightOrientation())) {
        return CGRectMake(0.0, 0.0, longSide, shortSide);
    }
    return CGRectMake(0.0, 0.0, shortSide, longSide);
}

/// 顶部安全区高度（刘海屏 47~59，普通屏 20），带多级兜底
static CGFloat MiniSightTopInset(void) {
    CGFloat inset = 0.0;

    if (@available(iOS 11.0, *)) {
        inset = gMiniSightWindow.safeAreaInsets.top;
        if (inset <= 0.5) {
            // 窗口刚创建（还没显示）时 safeAreaInsets 可能是 0，借别的窗口算
            for (UIWindow *window in [UIApplication sharedApplication].windows) {
                if (window == gMiniSightWindow || window.hidden) continue;
                if (window.safeAreaInsets.top > inset) {
                    inset = window.safeAreaInsets.top;
                }
            }
        }
        if (inset <= 0.5) {
            // 再兜底：状态栏高度（SpringBoard 的 windowScene 上有 statusBarManager）
            if (@available(iOS 13.0, *)) {
                UIWindowScene *scene = gMiniSightWindow.windowScene;
                if (scene && scene.statusBarManager) {
                    CGFloat height = scene.statusBarManager.statusBarFrame.size.height;
                    if (height > inset) inset = height;
                }
            }
        }
    }

    if (inset <= 0.5) inset = 20.0; // 最后兜底，至少别贴到屏幕最顶上
    return inset;
}

/// 把浮窗中心点限制在屏幕内（四周留 kMiniSightEdge 的边距）
static CGPoint MiniSightClampCenter(CGPoint center) {
    CGRect bounds = gMiniSightWindow ? gMiniSightWindow.bounds : MiniSightScreenRect();
    CGFloat halfW = kMiniSightWidth / 2.0;
    CGFloat halfH = kMiniSightHeight / 2.0;

    CGFloat minX = kMiniSightEdge + halfW;
    CGFloat maxX = bounds.size.width - kMiniSightEdge - halfW;
    CGFloat minY = kMiniSightEdge + halfH;
    CGFloat maxY = bounds.size.height - kMiniSightEdge - halfH;

    // 极端情况（屏幕比浮窗还窄）时直接居中，避免 min > max
    if (maxX < minX) minX = maxX = bounds.size.width / 2.0;
    if (maxY < minY) minY = maxY = bounds.size.height / 2.0;

    center.x = MIN(MAX(center.x, minX), maxX);
    center.y = MIN(MAX(center.y, minY), maxY);
    return center;
}

/// 默认位置：屏幕顶部、水平居中，顶部距离安全区 8pt
static CGPoint MiniSightDefaultCenter(void) {
    CGRect bounds = gMiniSightWindow ? gMiniSightWindow.bounds : MiniSightScreenRect();
    // 不固定在顶部中间：每次没记住位置时就随机落点（上半屏、留边）。
    CGFloat half = 60.0;
    CGFloat minX = kMiniSightEdge + half;
    CGFloat maxX = MAX(bounds.size.width - minX, minX);
    CGFloat minY = MiniSightTopInset() + kMiniSightEdge + half;
    CGFloat maxY = MAX(bounds.size.height * 0.55, minY);
    CGFloat x = minX + (CGFloat)arc4random_uniform((uint32_t)MAX(maxX - minX, 1));
    CGFloat y = minY + (CGFloat)arc4random_uniform((uint32_t)MAX(maxY - minY, 1));
    return CGPointMake(x, y);
}

/// 取一个「不会跟着浮窗一起动」的参照窗口，用来换算拖拽位移
static UIView *MiniSightReferenceView(void) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIWindow *key = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
    if (key && key != gMiniSightWindow && !key.hidden) return key;

    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window == gMiniSightWindow || window.hidden) continue;
        return window;
    }
    return nil;
}

#pragma mark - 前置声明

static void MiniSightBuildUI(void);
static void MiniSightShow(void);
static void MiniSightHide(void);
static void MiniSightHideBubble(void);
static void MiniSightUpdateGeometry(void);
static void MiniSightApplySavedCenter(BOOL useSaved);
static void MiniSightStartPulse(void);
static void MiniSightToggleRecording(void);
static void MiniSightReloadSettings(void);
static void MiniSightBringMinisFront(void);
static void MiniSightSpeakLine(void);
static void MiniSightStopPulse(void);

#pragma mark - 窗口类

/// 浮窗用 UIWindow：永远不成为 key window，避免抢走前台应用/键盘的焦点
@interface MiniSightWindow : UIWindow
@end

@implementation MiniSightWindow

- (BOOL)canBecomeKeyWindow {
    return NO;
}

/// 空白区域返回 nil —— 让触摸继续落到下面的窗口（桌面/App），
/// 否则一个全屏透明的高优先级窗口会把整台手机点不动。
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) return nil;
    if (hit == self.rootViewController.view) return nil;
    return hit;
}

@end

/// 透明根视图：只有落在胶囊上的触摸才被消费，其它区域一律放行
@interface MiniSightRootView : UIView
@end

@implementation MiniSightRootView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) return nil; // 点到空白处 → 交给窗口的 hitTest 处理
    return hit;
}

@end

#pragma mark - 手势 / 旋转

@interface MiniSightGestureHandler : NSObject
- (void)handlePan:(UIPanGestureRecognizer *)pan;
- (void)handleOrientationChange:(NSNotification *)note;
@end

@implementation MiniSightGestureHandler

/// 拖动：实时改 window.center，松手后把位置写进 NSUserDefaults
- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (!gMiniSightWindow) return;

    // 关键点：窗口本身会跟着手指移动，如果用「本窗口内」的坐标算位移，
    // 坐标系会跟着窗口一起动，translation 会永远接近 0（拖不动 / 抖动）。
    // 所以这里取一个固定的参照窗口来换算位移。
    UIView *reference = MiniSightReferenceView();
    CGPoint translation = reference ? [pan translationInView:reference]
                                    : [pan translationInView:pan.view];

    CGPoint center = gMiniSightWindow.center;
    center.x += translation.x;
    center.y += translation.y;
    gMiniSightWindow.center = MiniSightClampCenter(center);

    [pan setTranslation:CGPointZero inView:(reference ? reference : pan.view)];

    if (pan.state == UIGestureRecognizerStateEnded ||
        pan.state == UIGestureRecognizerStateCancelled) {
        // 记住位置，下次显示直接恢复（只写 NSUserDefaults，不碰 plist 文件）
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setDouble:gMiniSightWindow.center.x forKey:kMiniSightCenterX];
        [defaults setDouble:gMiniSightWindow.center.y forKey:kMiniSightCenterY];
    }
}

/// 旋转：界面方向变化是异步的，稍等一下再重算并 clamp
- (void)handleSingleTap:(UITapGestureRecognizer *)tap {
    MiniSightSpeakLine();
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)tap {
    UIImpactFeedbackGenerator *feedback =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [feedback impactOccurred];
    MiniSightUserHide();
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)press {
    if (press.state != UIGestureRecognizerStateBegan) return;
    UIImpactFeedbackGenerator *feedback =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];
    MiniSightToggleRecording();
}

- (void)handleOrientationChange:(NSNotification *)note {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!gMiniSightWindow) return;

        // 尺寸没变（比如只是 face up / face down）就不折腾
        CGSize newSize = MiniSightScreenRect().size;
        if (CGSizeEqualToSize(newSize, gMiniSightWindow.bounds.size)) return;

        MiniSightUpdateGeometry();
        MiniSightApplySavedCenter(YES);
    });
}

@end

#pragma mark - 找 scene（iOS 13+ 必须挂在 scene 上窗口才会显示）

static UIWindowScene *MiniSightFindScene(void) {
    if (@available(iOS 13.0, *)) {
        // 优先用 SpringBoard 自己那个层级的窗口（层级最低的桌面窗口）
        UIWindow *candidate = nil;
        for (UIWindow *window in [UIApplication sharedApplication].windows) {
            if (window == gMiniSightWindow || !window.windowScene) continue;
            if (!candidate || window.windowLevel < candidate.windowLevel) {
                candidate = window;
            }
        }
        if (candidate.windowScene) return candidate.windowScene;

        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                return (UIWindowScene *)scene;
            }
        }
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)scene;
        }
    }
    return nil;
}

#pragma mark - 布局

/// 重设窗口尺寸 + 把胶囊摆回窗口正中（胶囊的绝对位置由 window.center 决定）
static void MiniSightUpdateGeometry(void) {
    if (!gMiniSightWindow) return;

    CGRect rect = MiniSightScreenRect();
    gMiniSightWindow.frame = rect;

    if (gMiniSightPet) {
        gMiniSightPet.center = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
    }

    if (gMiniSightPill) {
        gMiniSightPill.frame = CGRectMake((rect.size.width - kMiniSightWidth) / 2.0,
                                          (rect.size.height - kMiniSightHeight) / 2.0,
                                          kMiniSightWidth, kMiniSightHeight);
        // 尺寸变了要同步阴影路径，否则阴影还是旧形状
        gMiniSightPill.layer.shadowPath =
            [UIBezierPath bezierPathWithRoundedRect:gMiniSightPill.bounds
                                       cornerRadius:kMiniSightRadius].CGPath;
    }
}

/// 恢复位置：useSaved = YES 时优先用 NSUserDefaults 里记的坐标，否则回默认顶部居中
static void MiniSightApplySavedCenter(BOOL useSaved) {
    if (!gMiniSightWindow) return;

    CGPoint center = MiniSightDefaultCenter();

    if (useSaved) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        BOOL hasX = ([defaults objectForKey:kMiniSightCenterX] != nil);
        BOOL hasY = ([defaults objectForKey:kMiniSightCenterY] != nil);
        if (hasX && hasY) {
            center = CGPointMake([defaults doubleForKey:kMiniSightCenterX],
                                 [defaults doubleForKey:kMiniSightCenterY]);
        }
    }

    // 不管来自默认值还是历史记录，都要 clamp 到当前屏幕内
    gMiniSightWindow.center = MiniSightClampCenter(center);
}

#pragma mark - 脉动动画

/// 圆点背后的扩散圈：1.0 → 2.6 放大，同时 0.7 → 0 淡出，1.6 秒一轮，无限循环
static void MiniSightStartPulse(void) {
    if (!gMiniSightPulse) return;

    CALayer *layer = gMiniSightPulse.layer;
    [layer removeAnimationForKey:@"MiniSightPulseScale"];
    [layer removeAnimationForKey:@"MiniSightPulseOpacity"];

    CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    scale.fromValue = @(1.0);
    scale.toValue = @(2.6);
    scale.duration = 1.6;
    scale.repeatCount = INFINITY;
    scale.removedOnCompletion = NO;
    scale.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [layer addAnimation:scale forKey:@"MiniSightPulseScale"];

    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @(0.7);
    fade.toValue = @(0.0);
    fade.duration = 1.6;
    fade.repeatCount = INFINITY;
    fade.removedOnCompletion = NO;
    fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [layer addAnimation:fade forKey:@"MiniSightPulseOpacity"];
}

static void MiniSightStopPulse(void) {
    if (!gMiniSightPulse) return;
    [gMiniSightPulse.layer removeAnimationForKey:@"MiniSightPulseScale"];
    [gMiniSightPulse.layer removeAnimationForKey:@"MiniSightPulseOpacity"];
}

#pragma mark - 建 UI

static void MiniSightBuildUI(void) {
    if (gMiniSightBuilt) return;
    gMiniSightBuilt = YES;

    CGRect screen = MiniSightScreenRect();

    // ---- 透明浮窗 ----
    MiniSightWindow *window = [[MiniSightWindow alloc] initWithFrame:screen];
    window.windowLevel = UIWindowLevelAlert + 1.0; // 盖在系统弹窗之上
    window.backgroundColor = [UIColor clearColor];
    window.opaque = NO;
    window.hidden = YES;                            // 默认不显示，等 started 通知
    window.clipsToBounds = NO;

    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = MiniSightFindScene();
        if (scene) window.windowScene = scene;
    }

    MiniSightRootView *root = [[MiniSightRootView alloc] initWithFrame:screen];
    root.backgroundColor = [UIColor clearColor];
    root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIViewController *controller = [[UIViewController alloc] init];
    controller.view = root;                          // 透明 rootViewController
    window.rootViewController = controller;

    // ---- 胶囊本体：132 × 36，圆角 18 ----
    UIView *pill = [[UIView alloc] initWithFrame:CGRectMake((screen.size.width - kMiniSightWidth) / 2.0,
                                                           (screen.size.height - kMiniSightHeight) / 2.0,
                                                           kMiniSightWidth, kMiniSightHeight)];
    pill.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.88];
    pill.layer.cornerRadius = kMiniSightRadius;
    pill.layer.borderWidth = 0.5;
    pill.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.10].CGColor;
    pill.clipsToBounds = NO;                          // 阴影要露出来
    pill.layer.masksToBounds = NO;
    pill.layer.shadowColor = [UIColor blackColor].CGColor;
    pill.layer.shadowOffset = CGSizeMake(0.0, 6.0);
    pill.layer.shadowRadius = 22.0;
    pill.layer.shadowOpacity = 0.34;
    pill.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:pill.bounds
                                                          cornerRadius:kMiniSightRadius].CGPath;
    if (@available(iOS 13.0, *)) {
        pill.layer.cornerCurve = kCACornerCurveContinuous;
    }

    // ---- 圆点：先放脉动圈，再压实心点（实心点在上面） ----
    CGFloat dotY = (kMiniSightHeight - kMiniSightDotSize) / 2.0;

    UIView *pulse = [[UIView alloc] initWithFrame:CGRectMake(kMiniSightDotLeft, dotY,
                                                             kMiniSightDotSize, kMiniSightDotSize)];
    pulse.backgroundColor = MiniSightDotColor();
    pulse.layer.cornerRadius = kMiniSightDotSize / 2.0;
    pulse.userInteractionEnabled = NO;

    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(kMiniSightDotLeft, dotY,
                                                           kMiniSightDotSize, kMiniSightDotSize)];
    dot.backgroundColor = MiniSightDotColor();
    dot.layer.cornerRadius = kMiniSightDotSize / 2.0;
    dot.layer.shadowColor = MiniSightDotColor().CGColor; // 自身发光
    dot.layer.shadowOffset = CGSizeZero;
    dot.layer.shadowOpacity = 0.85;
    dot.layer.shadowRadius = 4.0;
    dot.userInteractionEnabled = NO;

    // ---- 文字：12.5pt Medium 白色，字距 0.2 ----
    CGFloat textX = kMiniSightDotLeft + kMiniSightDotSize + kMiniSightDotGap;
    CGFloat textW = kMiniSightWidth - textX - kMiniSightTextRight;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(textX, 0.0, textW, kMiniSightHeight)];
    UIFont *font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    NSDictionary *attributes = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: [UIColor whiteColor],
        NSKernAttributeName: @(0.2)
    };
    label.attributedText = [[NSAttributedString alloc] initWithString:kMiniSightText
                                                          attributes:attributes];
    label.backgroundColor = [UIColor clearColor];
    label.textAlignment = NSTextAlignmentLeft;
    label.numberOfLines = 1;
    label.userInteractionEnabled = NO;

    [pill addSubview:pulse];
    [pill addSubview:dot];
    [pill addSubview:label];
    [root addSubview:pill];

    // ---- 拖动 ----
    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:gMiniSightGestureTarget
                                                action:@selector(handlePan:)];

    // ---- 桌宠（可选）：放了 /var/mobile/Documents/MiniSight/pet.png 就用它，否则仍是胶囊 ----
    NSString *petPath = MiniSightPetPath();
    UIImage *petSprite = (MiniSightStyle() == 1 && petPath.length > 0)
        ? [UIImage imageWithContentsOfFile:petPath] : nil;
    if (petSprite) {
        gMiniSightPet = [[MiniSightPetView alloc] initWithSprite:petSprite
                                                    displaySize:CGSizeMake(96.0, 104.0)];
        gMiniSightPet.center = CGPointMake(CGRectGetMidX(root.bounds), CGRectGetMidY(root.bounds));
        gMiniSightPet.onLongPress = ^{
            MiniSightToggleRecording();
        };
        [root addSubview:gMiniSightPet];
        [gMiniSightPet addGestureRecognizer:pan];
        UITapGestureRecognizer *petDouble =
            [[UITapGestureRecognizer alloc] initWithTarget:gMiniSightGestureTarget
                                                    action:@selector(handleDoubleTap:)];
        petDouble.numberOfTapsRequired = 2;
        [gMiniSightPet addGestureRecognizer:petDouble];
        UITapGestureRecognizer *petSingle =
            [[UITapGestureRecognizer alloc] initWithTarget:gMiniSightGestureTarget
                                                    action:@selector(handleSingleTap:)];
        [petSingle requireGestureRecognizerToFail:petDouble];
        [gMiniSightPet addGestureRecognizer:petSingle];
        pill.hidden = YES;
    } else {
        [pill addGestureRecognizer:pan];
        UILongPressGestureRecognizer *pillPress =
            [[UILongPressGestureRecognizer alloc] initWithTarget:gMiniSightGestureTarget
                                                          action:@selector(handleLongPress:)];
        pillPress.minimumPressDuration = 0.9;
        [pill addGestureRecognizer:pillPress];
        UITapGestureRecognizer *pillDouble =
            [[UITapGestureRecognizer alloc] initWithTarget:gMiniSightGestureTarget
                                                    action:@selector(handleDoubleTap:)];
        pillDouble.numberOfTapsRequired = 2;
        [pill addGestureRecognizer:pillDouble];
        UITapGestureRecognizer *pillSingle =
            [[UITapGestureRecognizer alloc] initWithTarget:gMiniSightGestureTarget
                                                    action:@selector(handleSingleTap:)];
        [pillSingle requireGestureRecognizerToFail:pillDouble];
        [pill addGestureRecognizer:pillSingle];
    }

    gMiniSightWindow = window;
    gMiniSightPill   = pill;
    gMiniSightDot    = dot;
    gMiniSightPulse  = pulse;
    gMiniSightLabel  = label;

    MiniSightUpdateGeometry();
}

#pragma mark - 显示 / 隐藏

static void MiniSightShow(void) {
    if (!MiniSightShown()) return;
    if (gMiniSightUserHidden) {
        gMiniSightUserHidden = NO;
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"MiniSightUserHidden"];
    }
    MiniSightBuildUI();
    if (!gMiniSightWindow) return;

    // SpringBoard 重启或场景切换后窗口可能掉出 scene，重新挂一次
    if (@available(iOS 13.0, *)) {
        if (!gMiniSightWindow.windowScene) {
            UIWindowScene *scene = MiniSightFindScene();
            if (scene) gMiniSightWindow.windowScene = scene;
        }
    }

    MiniSightUpdateGeometry();
    MiniSightApplySavedCenter(YES);
    MiniSightStartPulse();
    [gMiniSightPet startPlaying];
    if (MiniSightRecordingEnabled()) MiniSightStartRecording();

    // 自保：即使 App 被杀/信号丢了，3 分钟后也自动收起来
    if (gMiniSightMaxShow) dispatch_block_cancel(gMiniSightMaxShow);
    gMiniSightMaxShow = dispatch_block_create(DISPATCH_BLOCK_DETACHED, ^{ MiniSightHide(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(180 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), gMiniSightMaxShow);

    // 先透明再取消 hidden，然后 0.18s 淡入
    gMiniSightWindow.alpha = 0.0;
    gMiniSightWindow.hidden = NO;
    [UIView animateWithDuration:0.18
                          delay:0.0
                        options:(UIViewAnimationOptionCurveEaseOut |
                                 UIViewAnimationOptionBeginFromCurrentState)
                     animations:^{
        gMiniSightWindow.alpha = 1.0;
    } completion:nil];
}

static void MiniSightHide(void) {
    MiniSightHideBubble();
    if (MiniSightAlwaysShow() && !gMiniSightUserHidden) return;   // 常驻且未手动隐藏
    if (gMiniSightMaxShow) { dispatch_block_cancel(gMiniSightMaxShow); gMiniSightMaxShow = nil; }
    if (!gMiniSightWindow || gMiniSightWindow.hidden) return;

    [UIView animateWithDuration:0.18
                          delay:0.0
                        options:(UIViewAnimationOptionCurveEaseOut |
                                 UIViewAnimationOptionBeginFromCurrentState)
                     animations:^{
        gMiniSightWindow.alpha = 0.0;
    } completion:^(BOOL finished) {
        // 动画结束后才真正隐藏窗口
        if (finished && gMiniSightWindow.alpha < 0.01) {
            gMiniSightWindow.hidden = YES;
            gMiniSightWindow.alpha = 1.0; // 下次显示从 0 开始淡入
            MiniSightStopPulse();
            [gMiniSightPet stopPlaying];
        }
    }];
}

/// 彻底拆掉浮窗（设置变更时重建用）
static void MiniSightDestroyUI(void) {
    if (gMiniSightBubble) { [gMiniSightBubble removeFromSuperview]; gMiniSightBubble = nil; gMiniSightBubbleLabel = nil; gMiniSightBubbleTail = nil; }
    if (gMiniSightPet) { [gMiniSightPet stopPlaying]; gMiniSightPet = nil; }
    MiniSightStopRecording();
    gMiniSightWindow.hidden = YES;
    gMiniSightWindow.rootViewController = nil;
    gMiniSightWindow = nil;
    gMiniSightPill = nil; gMiniSightDot = nil; gMiniSightPulse = nil; gMiniSightLabel = nil;
    gMiniSightBuilt = NO;
}

/// 设置变了：按新设置重建（样式/常驻立即生效，不用注销）
static void MiniSightReloadSettings(void) {
    BOOL wasVisible = gMiniSightWindow && !gMiniSightWindow.hidden;
    MiniSightDestroyUI();
    if (!MiniSightShown()) return;
    if ((gMiniSightBurst && MiniSightShown()) || MiniSightAlwaysShow()) MiniSightShow();
}


#pragma mark - 说话气泡（只在 MCP 调用时）

static BOOL gMiniSightConfirming = NO;
static NSString *gMiniSightConfirmId = nil;
static UIStackView *gMiniSightConfirmBar = nil;
static dispatch_block_t gMiniSightConfirmTimeout = nil;

static void MiniSightHideBubble(void) {
    if (gMiniSightConfirming) return;
    gMiniSightBubble.hidden = YES;
}

/// 纯文字气泡：动态深浅色、小尾巴指向指示器，最多 20 字。
static void MiniSightShowBubbleWidth(NSString *raw, CGFloat maxW, NSUInteger cap) {
    UIView *host = gMiniSightPet ?: gMiniSightPill;
    UIView *root = gMiniSightWindow.rootViewController.view;
    if (!host || !root || raw.length == 0) return;

    NSString *text = raw.length > cap ? [[raw substringToIndex:cap] stringByAppendingString:@"…"] : raw;

    if (!gMiniSightBubble) {
        UIView *b = [[UIView alloc] init];
        b.backgroundColor = [UIColor systemBackgroundColor];
        b.layer.cornerRadius = 16;
        b.layer.borderWidth = 0.5;
        b.layer.borderColor = [UIColor separatorColor].CGColor;
        b.userInteractionEnabled = NO;
        b.hidden = YES;

        UILabel *l = [[UILabel alloc] init];
        l.font = [UIFont systemFontOfSize:11];
        l.textColor = [UIColor labelColor];
        l.numberOfLines = 0;
        l.userInteractionEnabled = NO;
        [b addSubview:l];
        gMiniSightBubbleLabel = l;

        CAShapeLayer *tail = [CAShapeLayer layer];
        tail.fillColor = [UIColor systemBackgroundColor].CGColor;
        [b.layer addSublayer:tail];
        gMiniSightBubbleTail = tail;

        [root addSubview:b];
        gMiniSightBubble = b;
    }

    gMiniSightBubble.hidden = NO;
    gMiniSightBubble.backgroundColor = [UIColor systemBackgroundColor];
    gMiniSightBubbleLabel.textColor = [UIColor labelColor];
    gMiniSightBubbleTail.fillColor = [UIColor systemBackgroundColor].CGColor;
    gMiniSightBubbleLabel.text = text;

    CGSize fit = [gMiniSightBubbleLabel sizeThatFits:CGSizeMake(maxW, 60)];
    CGFloat w = MIN(maxW, fit.width) + 16;
    CGFloat h = fit.height + 12;

    CGFloat x = host.center.x - w / 2.0;
    x = MAX(8, MIN(x, root.bounds.size.width - w - 8));
    BOOL above = CGRectGetMinY(host.frame) > (h + 14);
    CGFloat y = above ? CGRectGetMinY(host.frame) - h - 7
                      : CGRectGetMaxY(host.frame) + 7;
    gMiniSightBubble.frame = CGRectMake(x, y, w, h);
    gMiniSightBubbleLabel.frame = CGRectMake(8, 6, w - 16, h - 12);

    UIBezierPath *path = [UIBezierPath bezierPath];
    CGFloat cx = MIN(MAX(host.center.x - x, 14), w - 14);
    if (above) {
        [path moveToPoint:CGPointMake(cx - 5, h)];
        [path addLineToPoint:CGPointMake(cx, h + 6)];
        [path addLineToPoint:CGPointMake(cx + 5, h)];
    } else {
        [path moveToPoint:CGPointMake(cx - 5, 0)];
        [path addLineToPoint:CGPointMake(cx, -6)];
        [path addLineToPoint:CGPointMake(cx + 5, 0)];
    }
    [path closePath];
    gMiniSightBubbleTail.path = path.CGPath;
    gMiniSightBubbleTail.frame = gMiniSightBubble.bounds;
}

static void MiniSightShowBubble(NSString *raw) {
    MiniSightShowBubbleWidth(raw, 220.0, 20);
}

/// 允许/拒绝两个按钮的宿主
@interface MiniSightConfirmTarget : NSObject
@end
@implementation MiniSightConfirmTarget
- (void)allow:(UIButton *)b { MiniSightAnswerConfirm(YES); }
- (void)deny:(UIButton *)b { MiniSightAnswerConfirm(NO); }
@end
static MiniSightConfirmTarget *gMiniSightConfirmTarget = nil;

static void MiniSightWriteConfirmResult(BOOL allow) {
    NSString *container = MiniSightAppContainer();
    if (!container || !gMiniSightConfirmId) return;
    NSString *path = [container stringByAppendingPathComponent:@"Documents/MiniSight/confirm-result.txt"];
    NSString *text = [NSString stringWithFormat:@"%@:%d", gMiniSightConfirmId, allow ? 1 : 0];
    [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)@"com.openminis.minisight.confirm.result", NULL, NULL, true);
}

/// 点按钮：写结果、收起气泡；超时自动拒绝，免得对面一直等。
static void MiniSightAnswerConfirm(BOOL allow) {
    if (!gMiniSightConfirming) return;
    gMiniSightConfirming = NO;
    if (gMiniSightConfirmTimeout) { dispatch_block_cancel(gMiniSightConfirmTimeout); gMiniSightConfirmTimeout = nil; }
    MiniSightWriteConfirmResult(allow);
    gMiniSightConfirmId = nil;
    gMiniSightConfirmBar.hidden = YES;
    gMiniSightBubble.userInteractionEnabled = NO;
    gMiniSightBubble.hidden = YES;
}

/// 读 confirm.json，把问题+命令塞进气泡，底下挂两个按钮。
static void MiniSightShowConfirm(void) {
    NSString *container = MiniSightAppContainer();
    if (!container) return;
    NSString *path = [container stringByAppendingPathComponent:@"Documents/MiniSight/confirm.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return;
    NSDictionary *info = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSString *ident = info[@"id"], *action = info[@"action"], *command = info[@"command"];
    if (!ident.length) return;
    if (!gMiniSightWindow || gMiniSightWindow.hidden) MiniSightShow();

    gMiniSightConfirmId = ident;
    gMiniSightConfirming = YES;
    NSString *shortCmd = command.length > 34 ? [[command substringToIndex:34] stringByAppendingString:@"…"] : command;
    NSString *text = action.length ? [NSString stringWithFormat:@"%@\n%@", action, shortCmd] : shortCmd;
    MiniSightShowBubbleWidth(text, 260.0, 80);

    gMiniSightBubble.userInteractionEnabled = YES;
    if (!gMiniSightConfirmBar) {
        if (!gMiniSightConfirmTarget) gMiniSightConfirmTarget = [MiniSightConfirmTarget new];
        UIStackView *bar = [[UIStackView alloc] init];
        bar.axis = UILayoutConstraintAxisHorizontal;
        bar.distribution = UIStackViewDistributionFillEqually;
        bar.spacing = 8;
        for (int i = 0; i < 2; i++) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
            b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
            b.layer.cornerRadius = 9;
            b.clipsToBounds = YES;
            if (i == 0) {
                [b setTitle:@"拒绝" forState:UIControlStateNormal];
                [b setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
                b.backgroundColor = [UIColor tertiarySystemFillColor];
                [b addTarget:gMiniSightConfirmTarget action:@selector(deny:) forControlEvents:UIControlEventTouchUpInside];
            } else {
                [b setTitle:@"允许" forState:UIControlStateNormal];
                [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                b.backgroundColor = [UIColor systemBlueColor];
                [b addTarget:gMiniSightConfirmTarget action:@selector(allow:) forControlEvents:UIControlEventTouchUpInside];
            }
            [bar addArrangedSubview:b];
        }
        [gMiniSightBubble addSubview:bar];
        gMiniSightConfirmBar = bar;
    }
    gMiniSightConfirmBar.hidden = NO;

    // 加高气泡，文字上、按钮下
    CGRect f = gMiniSightBubble.frame;
    f.origin.y -= 38; f.size.height += 38;
    gMiniSightBubble.frame = f;
    CGFloat w = f.size.width;
    gMiniSightBubbleLabel.frame = CGRectMake(8, 6, w - 16, f.size.height - 50);
    gMiniSightConfirmBar.frame = CGRectMake(8, f.size.height - 38, w - 16, 30);

    if (gMiniSightConfirmTimeout) dispatch_block_cancel(gMiniSightConfirmTimeout);
    gMiniSightConfirmTimeout = dispatch_block_create(DISPATCH_BLOCK_DETACHED, ^{ MiniSightAnswerConfirm(NO); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(55 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), gMiniSightConfirmTimeout);
}

static void MiniSightReadStatus(void) {
    NSString *container = MiniSightAppContainer();
    if (!container) return;
    NSString *path = [container stringByAppendingPathComponent:@"Documents/MiniSight/status.txt"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (text.length) MiniSightShowBubble(text);
}


/// 气泡显示一句话，3 秒后消失。
static void MiniSightShowLine(NSString *line) {
    if ((!gMiniSightWindow || gMiniSightWindow.hidden) && !gMiniSightBurst) return;
    MiniSightShowBubble(line);
    if (gMiniSightBubbleHideWork) dispatch_block_cancel(gMiniSightBubbleHideWork);
    gMiniSightBubbleHideWork = dispatch_block_create(DISPATCH_BLOCK_DETACHED, ^{
        MiniSightHideBubble();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), gMiniSightBubbleHideWork);
}

/// 预置句子（AI 失败时兜底）。
static void MiniSightSayPresetLine(void) {
    static NSArray<NSString *> *lines = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lines = @[@"你在干嘛呀？", @"想我了没啊？", @"摸摸我嘛", @"今天也要加油哦",
                  @"我在这儿呢", @"别太久不理我", @"有点困了…", @"你在忙什么？",
                  @"陪我一会儿嘛", @"有我在呢", @"别累坏了", @"我乖乖的",
                  @"记得喝水哦", @"早点休息呀", @"我又来啦", @"看看我嘛"];
    });
    NSString *line = lines[arc4random_uniform((uint32_t)lines.count)];
    if ([line isEqualToString:gMiniSightLastLine]) {
        line = lines[arc4random_uniform((uint32_t)lines.count)];
    }
    gMiniSightLastLine = line;
    MiniSightShowLine(line);
}

/// 单击：有配置就请求 AI 说一句，失败/超时用预置。
static void MiniSightSpeakLine(void) {
    NSString *container = MiniSightAppContainer();
    NSString *path = [container stringByAppendingPathComponent:@"Documents/MiniSight/ai.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSDictionary *cfg = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString *base = cfg[@"url"], *key = cfg[@"key"], *model = cfg[@"model"];
    if (![base isKindOfClass:[NSString class]] || base.length == 0 ||
        ![key isKindOfClass:[NSString class]] || key.length == 0 ||
        ![model isKindOfClass:[NSString class]] || model.length == 0) {
        MiniSightSayPresetLine();
        return;
    }
    NSString *full = [base hasSuffix:@"/chat/completions"] ? base
                                                           : [base stringByAppendingString:@"/chat/completions"];
    NSURL *url = [NSURL URLWithString:full];
    if (!url) { MiniSightSayPresetLine(); return; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 4.0;
    [req setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *body = @{ @"model": model, @"max_tokens": @40,
        @"messages": @[ @{@"role": @"system", @"content": @"你是可爱的桌宠，说一句不超过20字的中文撒娇话，不要引号。"},
                        @{@"role": @"user", @"content": @"说一句"} ] };
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSString *line = nil;
        if (d) {
            id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                NSArray *choices = obj[@"choices"];
                if ([choices isKindOfClass:[NSArray class]] && choices.count) {
                    id msg = choices[0][@"message"];
                    if ([msg isKindOfClass:[NSDictionary class]] && [msg[@"content"] isKindOfClass:[NSString class]]) {
                        line = [msg[@"content"] stringByTrimmingCharactersInSet:
                                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    }
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (line.length) MiniSightShowLine(line);
            else MiniSightSayPresetLine();
        });
    }] resume];
}

#pragma mark - Darwin 通知

/// 注意：Darwin 通知的回调线程不保证是主线程，所有 UI 操作统一切回主线程
static void MiniSightDarwinCallback(CFNotificationCenterRef center,
                                    void *observer,
                                    CFNotificationName name,
                                    const void *object,
                                    CFDictionaryRef userInfo) {
    NSString *note = (__bridge NSString *)name;
    if (note.length == 0) return;

    if ([note isEqualToString:kMiniSightShow]) {
        dispatch_async(dispatch_get_main_queue(), ^{ MiniSightShow(); });
        return;
    }
    if ([note isEqualToString:kMiniSightStatus]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gMiniSightBurst || MiniSightAlwaysShow()) MiniSightReadStatus();
        });
        return;
    }
    if ([note isEqualToString:kMiniSightConfirmNote]) {
        dispatch_async(dispatch_get_main_queue(), ^{ MiniSightShowConfirm(); });
        return;
    }
    if ([note isEqualToString:kMiniSightBlanked]) {
        // 熄灭/点亮各来一次，翻转即可：熄灭时暂停定时器，点亮再续。
        static BOOL blanked = NO;
        blanked = !blanked;
        BOOL b = blanked;
        dispatch_async(dispatch_get_main_queue(), ^{ [gMiniSightPet setSuspended:b]; });
        return;
    }
    if ([note isEqualToString:kMiniSightSettingsChanged]) {
        dispatch_async(dispatch_get_main_queue(), ^{ MiniSightReloadSettings(); });
        return;
    }

    BOOL shouldShow = [note isEqualToString:kMiniSightStarted];
    BOOL shouldHide = [note isEqualToString:kMiniSightStopped];
    if (!shouldShow && !shouldHide) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (shouldShow) {
            gMiniSightBurst = YES;
            MiniSightShow();
        } else {
            gMiniSightBurst = NO;
            MiniSightHide();
            MiniSightStopRecording();
            MiniSightBringMinisFront();
        }
    });
}

/// 操作结束时把 Minis 拉回前台。App 自己在后台 open 自己的 scheme
/// 不会前台化（实测），SpringBoard 里用 LSApplicationWorkspace 才可靠。
static void MiniSightBringMinisFront(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        if (!workspaceClass) return;
        id workspace = [workspaceClass performSelector:@selector(defaultWorkspace)];
        if ([workspace respondsToSelector:@selector(openApplicationWithBundleID:)]) {
            [workspace performSelector:@selector(openApplicationWithBundleID:)
                           withObject:@"com.openminis.app"];
        }
    });
}

#pragma mark - 入口

%ctor {
    @autoreleasepool {
        // 手势 / 旋转通知的 target（NSNotificationCenter 不持有 observer，必须自己保活）
        gMiniSightGestureTarget = [[MiniSightGestureHandler alloc] init];
        gMiniSightUserHidden = [[NSUserDefaults standardUserDefaults] boolForKey:@"MiniSightUserHidden"];

        // 立刻注册 Darwin 通知：回调里会懒加载 UI，不会漏掉启动早期的事件
        CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(center,
                                        (__bridge const void *)kMiniSightStarted,
                                        MiniSightDarwinCallback,
                                        (__bridge CFStringRef)kMiniSightStarted,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(center,
                                        (__bridge const void *)kMiniSightConfirmNote,
                                        MiniSightDarwinCallback,
                                        (__bridge CFStringRef)kMiniSightConfirmNote,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(center,
                                        (__bridge const void *)kMiniSightBlanked,
                                        MiniSightDarwinCallback,
                                        (__bridge CFStringRef)kMiniSightBlanked,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(center,
                                        (__bridge const void *)kMiniSightShow,
                                        MiniSightDarwinCallback,
                                        (__bridge CFStringRef)kMiniSightShow,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(center,
                                        (__bridge const void *)kMiniSightStatus,
                                        MiniSightDarwinCallback,
                                        (__bridge CFStringRef)kMiniSightStatus,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(center,
                                        (__bridge const void *)kMiniSightSettingsChanged,
                                        MiniSightDarwinCallback,
                                        (__bridge CFStringRef)kMiniSightSettingsChanged,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(center,
                                        (__bridge const void *)kMiniSightStopped,
                                        MiniSightDarwinCallback,
                                        (__bridge CFStringRef)kMiniSightStopped,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        // SpringBoard 刚启动时 UI 还没准备好，延迟 2 秒再建浮窗 + 注册旋转监听
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (MiniSightAlwaysShow() && MiniSightShown()) MiniSightShow();
            else MiniSightBuildUI();

            [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
            [[NSNotificationCenter defaultCenter] addObserver:gMiniSightGestureTarget
                                                     selector:@selector(handleOrientationChange:)
                                                         name:UIDeviceOrientationDidChangeNotification
                                                       object:nil];
        });
    }
}
