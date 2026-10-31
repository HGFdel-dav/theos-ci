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
//   5. 旋转时重新计算并 clamp。注意 clamp 的是「子视图在整屏窗口里的位置」，
//      窗口本身永远整屏不动 —— 移窗口会让局部合法坐标在屏幕上越界（0.3.2 的坑）。
//
// 目标系统：iOS 15.x（SpringBoard，arm64 / arm64e）

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreMotion/CoreMotion.h>
#import <errno.h>
#import <math.h>
#import "MiniSightPet.h"
#import "MiniSightLayout.h"
#import "MiniSightBubbleView.h"
#import "MiniSightResources.h"
#import "MiniSightGravity.h"
#import "MiniSightBridgeIO.h"
#import "MiniSightRecorder.h"
#import <notify.h>
#import <signal.h>


#pragma mark - MiniSight 配置（读 Minis 容器的偏好）

static void MiniSightHide(void);
static void MiniSightHideBubble(void);
static void MiniSightShowConfirm(void);
static void MiniSightAnswerConfirm(BOOL allow);
static void MiniSightSay(NSString *line);
static void MiniSightShowBubble(NSString *raw);
static void MiniSightSetAnchor(CGPoint want, BOOL save);
static void MiniSightFollowBubble(void);
static void MiniSightPlaceBubble(CGFloat w, CGFloat h);

// Immutable main-thread snapshot. Resource refresh owns ALL directory/plist/image I/O.
static NSString *gMiniSightContainer;
static NSDictionary *gMiniSightPreferences;
static UIImage *gMiniSightAtlas;
static BOOL gMiniSightShown = YES, gMiniSightResourcesReady = NO;
static BOOL gMiniSightResourceLoading = NO;
static BOOL gMiniSightResourceRefreshAgain = NO;
static NSMutableArray *gMiniSightResourceCompletions;
static void MiniSightReloadSettings(void);
static void MiniSightShow(void);
static void MiniSightCancelConfirm(void);
static void MiniSightConfigureRecorder(void);
static void MiniSightReadActivitySnapshot(void);
static void MiniSightBuildUI(void);
static void MiniSightRequestResources(BOOL force, void (^completion)(void));
static BOOL gMiniSightActivityExecuting = NO;
static NSInteger gMiniSightActivityPID = 0;
static NSString *gMiniSightActivityInstanceID;
static BOOL gMiniSightRecorderCallbacksInstalled = NO;
static BOOL gMiniSightRecorderConfigured = NO;
static NSUInteger gMiniSightRecorderConfigGeneration = 0;
static NSUInteger gMiniSightActivityReadGeneration = 0;
static NSString *MiniSightRecorderIssueText(MiniSightRecorderIssue issue, NSInteger code);
static void MiniSightInstallRecorderCallbacks(void);

static NSString *MiniSightAppContainer(void) { return gMiniSightContainer; }
static NSString *MiniSightSupportDirectory(void) {
    NSString *container = MiniSightAppContainer();
    return container ? [container stringByAppendingPathComponent:@"Documents/MiniSight"] : nil;
}
static id MiniSightPref(NSString *key) { return gMiniSightPreferences[key]; }
static NSInteger MiniSightStyle(void) { return [MiniSightPref(@"minisight.style") integerValue]; }
static CGFloat MiniSightPetSize(void) {
    id v = MiniSightPref(@"minisight.petSize");
    return v ? MSClamp([v doubleValue], 36., 140.) : 96.;
}
static BOOL MiniSightAlwaysShow(void) { return [MiniSightPref(@"minisight.mode") integerValue] == 1; }
static BOOL MiniSightShown(void) { return gMiniSightShown; }
static void MiniSightUserHide(void) {
    gMiniSightShown = NO;
    [MiniSightResources writeShown:NO container:gMiniSightContainer];
    MiniSightCancelConfirm();
    MiniSightHide();
}

/// 录屏开关（App 设置里，默认关）
static BOOL MiniSightRecordingEnabled(void) {
    return [MiniSightPref(@"minisight.record") boolValue];
}

/// 长按切换录屏（App 设置里，默认开）。
/// 以前只画了这个开关、插件从没读过它 —— 关掉也照样长按生效。
static BOOL MiniSightLongPressEnabled(void) {
    id v = MiniSightPref(@"minisight.longPress");
    if (!v) return YES;
    return [v boolValue];
}

/// 短提示：直接写气泡，不走 3 秒消失逻辑（长按场景要留得住）
static void MiniSightSay(NSString *line) {
    MiniSightShowBubble(line);
}

#pragma mark - 录屏控制器接线

static BOOL gMiniSightActivityEverExecuted = NO;
static dispatch_queue_t MiniSightRecorderSetupQueue(void) {
    static dispatch_queue_t queue; static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.openminis.minisight.recorder-setup", DISPATCH_QUEUE_SERIAL); });
    return queue;
}
static dispatch_queue_t MiniSightActivityQueue(void) {
    static dispatch_queue_t queue; static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.openminis.minisight.activity", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static NSString *MiniSightRecorderIssueText(MiniSightRecorderIssue issue, NSInteger code) {
    if (code != 0) return [NSString stringWithFormat:@"录屏失败（系统错误 %ld）", (long)code];
    switch (issue) {
        case MiniSightRecorderIssueDisabled: return @"录屏功能已关闭";
        case MiniSightRecorderIssueExternalSession: return @"系统已有录屏，未接管";
        case MiniSightRecorderIssueDestination: return @"录屏目录不可用";
        case MiniSightRecorderIssueOwnershipLost: return @"录屏会话被系统中断，未伪报保存成功";
        case MiniSightRecorderIssueStartTimeout: return @"系统录屏启动超时";
        case MiniSightRecorderIssueStopTimeout: return @"系统录屏停止超时";
        case MiniSightRecorderIssueMissingArtifact: return @"系统未返回录屏文件";
        case MiniSightRecorderIssueSaveFailed: return @"录屏文件校验或保存失败";
        case MiniSightRecorderIssueSaveTimeout: return @"录屏文件校验超时";
        case MiniSightRecorderIssueCancelled: return @"录屏已取消";
        default: return @"系统录屏不可用或 ABI 检查未通过";
    }
}

static void MiniSightInstallRecorderCallbacks(void) {
    if (gMiniSightRecorderCallbacksInstalled) return;
    MiniSightRecorder *recorder = MiniSightRecorder.sharedRecorder;
    __weak MiniSightRecorder *weakRecorder = recorder;
    recorder.stateHandler = ^(MiniSightRecorderState state, MiniSightRecorderSource owner,
                              MiniSightRecorderIssue issue, BOOL quarantined) {
        __strong MiniSightRecorder *strongRecorder = weakRecorder;
        if (!strongRecorder) return;
        if (quarantined) { MiniSightSay(@"录屏状态待系统确认，暂不允许再次启动"); return; }
        switch (state) {
            case MiniSightRecorderStarting: MiniSightSay(@"正在启动系统录屏"); break;
            case MiniSightRecorderRecording: MiniSightSay(owner == MiniSightRecorderSourceAutomatic ? @"设备操作录屏中" : @"手动录屏中"); break;
            case MiniSightRecorderStopping: MiniSightSay(@"正在停止录屏"); break;
            case MiniSightRecorderSaving: MiniSightSay(@"正在验证并保存录屏"); break;
            case MiniSightRecorderError: break;
            default: break;
        }
    };
    recorder.resultHandler = ^(MiniSightRecordingResult *result) {
        if (result.success)
            MiniSightSay([NSString stringWithFormat:@"录屏已验证并保存 %.0f 秒", result.duration]);
        else if (result.issue != MiniSightRecorderIssueNone)
            MiniSightSay(MiniSightRecorderIssueText(result.issue, result.systemErrorCode));
    };
    gMiniSightRecorderCallbacksInstalled = YES;
}

static void MiniSightConfigureRecorder(void) {
    NSCAssert([NSThread isMainThread], @"recorder configuration is main-thread owned");
    MiniSightInstallRecorderCallbacks();
    NSUInteger generation = ++gMiniSightRecorderConfigGeneration;
    NSString *container = [MiniSightAppContainer() copy];
    BOOL automatic = MiniSightRecordingEnabled();
    BOOL manual = MiniSightLongPressEnabled();
    dispatch_async(MiniSightRecorderSetupQueue(), ^{
        NSURL *directory = nil;
        if (container.length) {
            NSString *path = [container stringByAppendingPathComponent:@"Documents/MiniSight/recordings"];
            NSError *error = nil;
            BOOL made = [NSFileManager.defaultManager createDirectoryAtPath:path
                withIntermediateDirectories:YES attributes:nil error:&error];
            BOOL isDirectory = NO;
            if (made && [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory)
                directory = [NSURL fileURLWithPath:path isDirectory:YES];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != gMiniSightRecorderConfigGeneration || ![container isEqualToString:gMiniSightContainer]) return;
            [MiniSightRecorder.sharedRecorder configureAutomaticEnabled:automatic
                manualEnabled:manual outputDirectory:directory];
            if (directory) gMiniSightRecorderConfigured = YES;
            if (!directory && manual) MiniSightSay(@"录屏目录不可用，录屏功能未就绪");
            if (gMiniSightRecorderConfigured)
                [MiniSightRecorder.sharedRecorder setAutomaticActive:gMiniSightActivityExecuting];
        });
    });
}

static void MiniSightApplyActivitySnapshot(NSDictionary *activity, NSUInteger generation) {
    if (generation != gMiniSightActivityReadGeneration) return;
    NSNumber *pidValue = activity[@"pid"];
    NSString *instance = activity[@"processInstanceID"];
    BOOL activeProcessAlive = gMiniSightActivityPID > 1 &&
        (kill((pid_t)gMiniSightActivityPID, 0) == 0 || errno == EPERM);
    BOOL hasSnapshot = [activity isKindOfClass:NSDictionary.class] && activity.count > 0;
    if (!hasSnapshot) {
        if (gMiniSightActivityExecuting && activeProcessAlive) return;
        pidValue = @(gMiniSightActivityPID);
        instance = gMiniSightActivityInstanceID;
    }
    NSInteger pid = pidValue.integerValue;
    BOOL alive = pid > 1 && (kill((pid_t)pid, 0) == 0 || errno == EPERM);
    BOOL instanceValid = [instance isKindOfClass:NSString.class] &&
        [[NSUUID alloc] initWithUUIDString:instance] != nil;
    // The snapshot is read from the Minis app container; SpringBoard PID must differ.
    BOOL valid = [activity[@"protocolVersion"] integerValue] == 1 && instanceValid && alive;
    if (!hasSnapshot && !activeProcessAlive) valid = NO;
    if (!valid && alive) return; // Ignore another process or malformed activity snapshot.
    NSInteger count = valid ? [activity[@"executingCount"] integerValue] : 0;
    if (count < 0 || count > 1024) return;
    BOOL active = valid && count > 0;
    if (valid) {
        gMiniSightActivityPID = pid;
        gMiniSightActivityInstanceID = [instance copy];
    }
    BOOL endedExecution = gMiniSightActivityExecuting && !active && gMiniSightActivityEverExecuted;
    gMiniSightActivityExecuting = active;
    if (active) gMiniSightActivityEverExecuted = YES;
    [MiniSightRecorder.sharedRecorder setAutomaticActive:active];
    if (endedExecution) {
        gMiniSightActivityEverExecuted = NO;
        MiniSightBringMinisFront();
    }
}

static void MiniSightReadActivitySnapshot(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ MiniSightReadActivitySnapshot(); });
        return;
    }
    NSString *container = [MiniSightAppContainer() copy];
    if (!container.length) return;
    NSUInteger generation = ++gMiniSightActivityReadGeneration;
    dispatch_async(MiniSightActivityQueue(), ^{
        NSDictionary *activity = MSBridgeRead(container, @"activity.json", 16384);
        dispatch_async(dispatch_get_main_queue(), ^{ MiniSightApplyActivitySnapshot(activity, generation); });
    });
}

static void MiniSightToggleRecording(void) {
    if (!MiniSightLongPressEnabled()) return;
    if (!gMiniSightRecorderConfigured) { MiniSightSay(@"录屏控制器尚未就绪，请稍后再试"); return; }
    MiniSightInstallRecorderCallbacks();
    [MiniSightRecorder.sharedRecorder toggle];
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
static const CGFloat kMiniSightBubbleGap     = 7.0;   // 气泡与头顶的间距
static const CGFloat kMiniSightBubbleReserve = 52.0;  // 普通气泡预留在头顶的高度
static const CGFloat kMiniSightConfirmReserve = 124.0; // 确认气泡（两行按钮）预留高度

static NSString *const kMiniSightStarted   = @"com.openminis.agent.started";
static NSString *const kMiniSightStopped   = @"com.openminis.agent.stopped";
static NSString *const kMiniSightSettingsChanged = @"com.openminis.minisight.settings";
static NSString *const kMiniSightStatus = @"com.openminis.minisight.status";
static NSString *const kMiniSightShow = @"com.openminis.minisight.show";
static NSString *const kMiniSightConfirmNote = @"com.openminis.minisight.confirm";
static NSString *const kMiniSightActivityNote = @"com.openminis.minisight.activity";
static NSString *const kMiniSightConfirmCancel = @"com.openminis.minisight.confirm.cancel";
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
static dispatch_block_t gMiniSightPendingHide = nil; // 两个调用之间的 2.5 秒缓冲
BOOL gMiniSightBurst = NO;   // 只在 MCP 调用期间为 YES
BOOL gMiniSightBubbleShown = NO;   // 气泡是否显示（供桌宠决定要不要算位置）
static BOOL gMiniSightConfirming = NO;
static NSString *gMiniSightConfirmId = nil;
static UIStackView *gMiniSightConfirmBar = nil;
static dispatch_block_t gMiniSightConfirmTimeout = nil;
static UIView *gMiniSightBubble = nil;
static UIScrollView *gMiniSightBubbleScroll = nil;
static UILabel *gMiniSightBubbleLabel = nil;
static CGFloat gMiniSightBubbleContentHeight = 0.0;
static CGSize gMiniSightBubbleLayoutSize = {0, 0};
static CGFloat gMiniSightBubbleLayoutContentHeight = -1.0;
static BOOL gMiniSightBubbleLayoutValid = NO;
static CGFloat gMiniSightBubbleTailX = -1.0;
static CAShapeLayer *gMiniSightBubbleTail = nil;
static dispatch_block_t gMiniSightBubbleHideWork = nil;
static NSString *gMiniSightLastLine = nil;
static CGPoint   gMiniSightAnchor = {0, 0};   // 身体中心（整屏窗口坐标，绝不是 window.center）
static BOOL      gMiniSightAnchorValid = NO;
static CGPoint   gMiniSightDragOrigin = {0, 0}; // 本次 pan 开始时的身体中心
static BOOL      gMiniSightDragOriginValid = NO;
static BOOL gMiniSightDragging = NO;     // 拖动中：气泡不再让位移动身体

// 重力输入只存在于桌宠、可见且开启时；manager 本身不跨线程碰 UI。
static CMMotionManager *gMiniSightMotionManager = nil;
static NSUInteger gMiniSightMotionGeneration = 0;
static BOOL gMiniSightMotionRunning = NO;
static BOOL gMiniSightScreenBlanked = NO;
static CGFloat gMiniSightGravityRoll = 0.0;
static BOOL gMiniSightGravityRollValid = NO;
static BOOL gMiniSightGravityShakeLatched = NO;
static NSTimeInterval gMiniSightGravityLastImpulseTime = 0.0;
static BOOL gMiniSightGravityConfigured = NO;

static UIInterfaceOrientation MiniSightOrientation(void);
static void MiniSightUpdateGeometry(void);

static BOOL MiniSightGravityEnabled(void) {
    return gMiniSightPet != nil && gMiniSightGravityConfigured;
}

static void MiniSightRefreshGravityConfiguration(void) {
    gMiniSightGravityConfigured = gMiniSightPet != nil && MiniSightStyle() == 1 &&
        [MiniSightPref(@"minisight.gravity") boolValue];
}

static void MiniSightStopGravity(void) {
    NSCAssert([NSThread isMainThread], @"Motion UI must be stopped on main thread");
    ++gMiniSightMotionGeneration;
    gMiniSightMotionRunning = NO;
    if (gMiniSightMotionManager.deviceMotionActive) {
        [gMiniSightMotionManager stopDeviceMotionUpdates];
    }
    gMiniSightGravityRoll = 0.0;
    gMiniSightGravityRollValid = NO;
    gMiniSightGravityShakeLatched = NO;
    gMiniSightGravityLastImpulseTime = 0.0;
    if (gMiniSightPet) {
        BOOL wasOn = gMiniSightPet.gravityEnabled;
        gMiniSightPet.gravityEnabled = NO;
        gMiniSightPet.gravityRoll = 0.0;
        // 关掉后不再需要倾斜包络，收回多余留白（窗口存在时才跑布局）。
        if (wasOn && gMiniSightWindow) MiniSightUpdateGeometry();
    }
}

static void MiniSightStartGravity(void) {
    NSCAssert([NSThread isMainThread], @"Motion UI must start on main thread");
    if (!MiniSightGravityEnabled() || !gMiniSightWindow ||
        gMiniSightWindow.hidden || gMiniSightScreenBlanked ||
        [NSProcessInfo processInfo].lowPowerModeEnabled) {
        MiniSightStopGravity();
        return;
    }
    if (!gMiniSightMotionManager) gMiniSightMotionManager = [[CMMotionManager alloc] init];
    if (!gMiniSightMotionManager.isDeviceMotionAvailable) {
        gMiniSightMotionRunning = NO;
        if (!gMiniSightPet.gravityEnabled) {
            gMiniSightPet.gravityEnabled = YES;   // 传感器坏了也保留包络
            MiniSightUpdateGeometry();
        }
        return;
    }

    BOOL wasOn = gMiniSightPet.gravityEnabled;
    gMiniSightPet.gravityEnabled = YES;
    if (!wasOn && gMiniSightWindow) MiniSightUpdateGeometry();  // 先按倾斜包络预留空间
    if (gMiniSightMotionRunning) return;
    gMiniSightMotionManager.deviceMotionUpdateInterval = 1.0 / 30.0;
    NSUInteger generation = ++gMiniSightMotionGeneration;
    gMiniSightMotionRunning = YES;
    gMiniSightGravityRollValid = NO;
    __weak MiniSightPetView *weakPet = gMiniSightPet;
    [gMiniSightMotionManager startDeviceMotionUpdatesToQueue:[NSOperationQueue mainQueue]
                                                 withHandler:^(CMDeviceMotion *motion, NSError *error) {
        if (error || !motion || !gMiniSightMotionRunning ||
            generation != gMiniSightMotionGeneration) return;
        MiniSightPetView *pet = weakPet;
        if (!pet || pet != gMiniSightPet || !MiniSightGravityEnabled() ||
            !gMiniSightWindow || gMiniSightWindow.hidden || gMiniSightScreenBlanked ||
            [NSProcessInfo processInfo].lowPowerModeEnabled) {
            MiniSightStopGravity();
            return;
        }

        UIInterfaceOrientation orientation = MiniSightOrientation();
        CGFloat lateral = 0.0;
        switch (orientation) {
            case UIInterfaceOrientationLandscapeLeft:  lateral = (CGFloat)motion.gravity.y; break;
            case UIInterfaceOrientationLandscapeRight: lateral = (CGFloat)-motion.gravity.y; break;
            case UIInterfaceOrientationPortraitUpsideDown: lateral = (CGFloat)-motion.gravity.x; break;
            default: lateral = (CGFloat)motion.gravity.x; break;
        }
        CGFloat sample = MIN(1.0, MAX(-1.0, lateral / 0.72));
        if (fabs(sample) < 0.045) sample = 0.0;
        if (!gMiniSightGravityRollValid) {
            gMiniSightGravityRoll = sample;
            gMiniSightGravityRollValid = YES;
        } else {
            gMiniSightGravityRoll = gMiniSightGravityRoll * 0.82 + sample * 0.18;
        }
        pet.gravityRoll = gMiniSightGravityRoll;

        CMAcceleration a = motion.userAcceleration;
        CGFloat magnitude = sqrt((CGFloat)(a.x * a.x + a.y * a.y + a.z * a.z));
        NSTimeInterval now = CACurrentMediaTime();
        if (magnitude > 1.55) {
            if (!gMiniSightGravityShakeLatched && now - gMiniSightGravityLastImpulseTime > 0.75) {
                CGFloat direction = gMiniSightGravityRoll;
                if (fabs(direction) < 0.08) direction = (a.x >= 0.0 ? 1.0 : -1.0);
                CGFloat strength = MIN(1.0, MAX(0.25, (magnitude - 1.35) / 1.8));
                [pet triggerGravityImpulseWithDirection:direction strength:strength];
                gMiniSightGravityShakeLatched = YES;
                gMiniSightGravityLastImpulseTime = now;
            }
        } else if (magnitude < 0.85) {
            gMiniSightGravityShakeLatched = NO;
        }
    }];
}

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

/// 底部安全区（Home 指示条），取不到时保守留 8
static CGFloat MiniSightBottomInset(void) {
    if (@available(iOS 11.0, *)) {
        CGFloat inset = gMiniSightWindow.safeAreaInsets.bottom;
        if (inset > 0.5) return inset;
    }
    return 8.0;
}

/// 身体尺寸：有桌宠就是桌宠尺寸，否则是胶囊
static MSSize MiniSightBodySize(void) {
    CGSize size = gMiniSightPet
        ? (gMiniSightPet.gravityEnabled ? gMiniSightPet.gravitySafeSize : gMiniSightPet.bounds.size)
        : CGSizeMake(kMiniSightWidth, kMiniSightHeight);
    if (!(size.width > 1.0) || !(size.height > 1.0)) {
        size = CGSizeMake(kMiniSightWidth, kMiniSightHeight);
    }
    return (MSSize){size.width, size.height};
}

/// 头顶要留出的高度：确认气泡更高，普通气泡一句话
static double MiniSightBubbleReserve(void) {
    return gMiniSightConfirming ? kMiniSightConfirmReserve : kMiniSightBubbleReserve;
}

/// 统一布局：窗口整屏不动，宠物/胶囊只在这个可行范围里移动
static MSLayout MiniSightLayoutNow(void) {
    CGRect screen = MiniSightScreenRect();
    CGFloat top = MiniSightTopInset();
    CGFloat bottom = MiniSightBottomInset();
    CGFloat left = 0.0, right = 0.0;
    if (@available(iOS 11.0, *)) {
        UIEdgeInsets insets = gMiniSightWindow.safeAreaInsets;
        if (insets.left > 0.5) left = insets.left;
        if (insets.right > 0.5) right = insets.right;
    }
    MSSize body = MiniSightBodySize();
    return MSLayoutMake(screen.size.width, screen.size.height,
                        top, bottom, left, right,
                        kMiniSightEdge, body.w, body.h,
                        kMiniSightBubbleGap, MiniSightBubbleReserve());
}

/// 默认落点：没记住位置时随机撒在上半屏（范围来自同一套边界）
static CGPoint MiniSightDefaultAnchor(void) {
    MSLayout L = MiniSightLayoutNow();
    CGRect screen = MiniSightScreenRect();
    CGFloat minX = L.centers.x, maxX = L.centers.x + L.centers.w;
    CGFloat minY = L.centers.y;
    CGFloat maxY = MIN(L.centers.y + L.centers.h, screen.size.height * 0.55);
    if (maxY < minY) maxY = minY;
    CGFloat x = minX + (maxX > minX ? (CGFloat)arc4random_uniform((uint32_t)(maxX - minX)) : 0.0);
    CGFloat y = minY + (maxY > minY ? (CGFloat)arc4random_uniform((uint32_t)(maxY - minY)) : 0.0);
    return CGPointMake(x, y);
}

/// 落地锚点：更新桌宠可行范围 → 移动子视图（窗口不动）→ 气泡跟上。
/// save = YES 时写入 NSUserDefaults（只有用户拖动结束才写，随机走动不写）。
/// 这是全插件唯一能改「位置」的入口：拖动、旋转、默认落点、桌宠自己走动都走它。
static void MiniSightSetAnchor(CGPoint want, BOOL save) {
    if (!gMiniSightWindow) return;
    MSLayout L = MiniSightLayoutNow();
    MSPoint fixed = MSLayoutClamp(L, (MSPoint){want.x, want.y});
    CGPoint center = CGPointMake(fixed.x, fixed.y);

    if (gMiniSightPet) {
        // 可行中心范围交给桌宠，它的每一次移动都夹在这里面
        gMiniSightPet.centerBounds = CGRectMake(L.centers.x, L.centers.y, L.centers.w, L.centers.h);
        gMiniSightPet.center = center;
        center = gMiniSightPet.center;
    }
    if (gMiniSightPill) {
        gMiniSightPill.center = center;
    }
    gMiniSightAnchor = center;
    gMiniSightAnchorValid = YES;
    MiniSightFollowBubble();

    if (save) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setDouble:center.x forKey:kMiniSightCenterX];
        [defaults setDouble:center.y forKey:kMiniSightCenterY];
    }
}

/// 手指按住/拖动期间：冻在真实位置（不是停“播放意图”），松手恢复
static void MiniSightInteractionBegin(void) {
    gMiniSightPet.roamingPaused = YES;
    gMiniSightPet.interactionActive = YES;
}

static void MiniSightInteractionEnd(void) {
    gMiniSightPet.interactionActive = NO;
    gMiniSightPet.roamingPaused = NO;
}

/// 取一个「不会跟着浮窗一起动」的参照视图，用来换算拖拽位移
static UIView *MiniSightReferenceView(void) {
    UIView *root = gMiniSightWindow.rootViewController.view;
    if (root) return root;
    return gMiniSightWindow;
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
static void MiniSightShowBubble(NSString *raw);
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
- (void)handleLongPress:(UILongPressGestureRecognizer *)press;
- (void)handlePowerStateChange:(NSNotification *)notification;
- (void)handleOrientationChange:(NSNotification *)notification;
@end

@implementation MiniSightGestureHandler

/// 拖动：只移动宠物/胶囊（窗口整屏不动），松手才记住位置。
/// translationInView: 是从 Began 起累计的位移；因此必须始终加到本次
/// 拖动开始时的 dragOrigin，不能在每个 Changed 又加到已更新的 anchor 上。
- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (!gMiniSightWindow) return;

    UIView *reference = MiniSightReferenceView(); // 固定的整屏 root 坐标系
    UIView *host = pan.view ?: (gMiniSightPet ?: gMiniSightPill);
    UIView *translationView = reference ?: host;
    CGPoint translation = translationView ? [pan translationInView:translationView] : CGPointZero;

    switch (pan.state) {
        case UIGestureRecognizerStateBegan: {
            // 以手势开始瞬间的真实中心为原点；这里不调用 DefaultAnchor，
            // 默认落点的上半屏策略不能限制手动拖动。
            CGPoint origin = gMiniSightAnchorValid ? gMiniSightAnchor :
                (host ? host.center : CGPointZero);
            if (host.superview && reference) {
                origin = [host.superview convertPoint:host.center toView:reference];
            }
            gMiniSightDragOrigin = origin;
            gMiniSightDragOriginValid = YES;
            gMiniSightDragging = YES;
            MiniSightInteractionBegin();
            break;
        }
        case UIGestureRecognizerStateChanged: {
            if (!gMiniSightDragOriginValid) break; // 防御异常的无 Began 回调
            CGPoint want = CGPointMake(gMiniSightDragOrigin.x + translation.x,
                                       gMiniSightDragOrigin.y + translation.y);
            MiniSightSetAnchor(want, NO);
            break;
        }
        case UIGestureRecognizerStateEnded: {
            if (gMiniSightDragOriginValid) {
                // Ended 也可能带最后一段 translation，落地一次完整的最终位置。
                CGPoint want = CGPointMake(gMiniSightDragOrigin.x + translation.x,
                                           gMiniSightDragOrigin.y + translation.y);
                // 保持 dragging 到 SetAnchor 完成，避免气泡让位把刚拖到的中心改掉。
                MiniSightSetAnchor(want, YES); // 只有用户拖动才写盘
            }
            gMiniSightDragOriginValid = NO;
            gMiniSightDragging = NO;
            MiniSightInteractionEnd();
            break;
        }
        default:   // Cancelled / Failed：当前位置保留，但本次不写盘
            gMiniSightDragOriginValid = NO;
            gMiniSightDragging = NO;
            MiniSightInteractionEnd();
            break;
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

/// 长按：手势由宿主拥有（不是桌宠内部），所以漫游动画期间也按得住。
/// 设置里「长按指示器切换录屏」关掉时，这里完全不响应。
- (void)handleLongPress:(UILongPressGestureRecognizer *)press {
    switch (press.state) {
        case UIGestureRecognizerStateBegan:
            MiniSightInteractionBegin();
            if (!MiniSightLongPressEnabled()) return;
            [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
            MiniSightToggleRecording();
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            MiniSightInteractionEnd();
            break;
        default:
            break;
    }
}

/// 低电量：桌宠只留可触摸的静止帧，不做时钟与大幅运动
- (void)handlePowerStateChange:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL low = [NSProcessInfo processInfo].lowPowerModeEnabled;
        gMiniSightPet.reducedWork = low;
        if (low) MiniSightStopGravity();
        else if (gMiniSightWindow && !gMiniSightWindow.hidden) MiniSightStartGravity();
    });
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

/// 重设窗口尺寸（永远整屏）+ 子视图位置；位置只由 MiniSightSetAnchor 决定
static void MiniSightUpdateGeometry(void) {
    if (!gMiniSightWindow) return;

    CGRect rect = MiniSightScreenRect();
    gMiniSightWindow.frame = rect;   // 整屏固定：这是全插件唯一一次改 window.frame

    UIView *root = gMiniSightWindow.rootViewController.view;
    if (root) root.frame = rect;

    if (gMiniSightPill) {
        gMiniSightPill.bounds = CGRectMake(0, 0, kMiniSightWidth, kMiniSightHeight);
        // 尺寸变了要同步阴影路径，否则阴影还是旧形状
        gMiniSightPill.layer.shadowPath =
            [UIBezierPath bezierPathWithRoundedRect:gMiniSightPill.bounds
                                       cornerRadius:kMiniSightRadius].CGPath;
    }

    // 位置统一交给锚点逻辑：旋转/换尺寸后可行范围会变，必须重新夹一次
    MiniSightSetAnchor(gMiniSightAnchorValid ? gMiniSightAnchor : MiniSightDefaultAnchor(), NO);
}

static void MiniSightApplySavedCenter(BOOL useSaved) {
    if (!gMiniSightWindow) return;

    CGPoint center = MiniSightDefaultAnchor();

    if (useSaved) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        BOOL hasX = ([defaults objectForKey:kMiniSightCenterX] != nil);
        BOOL hasY = ([defaults objectForKey:kMiniSightCenterY] != nil);
        if (hasX && hasY) {
            center = CGPointMake([defaults doubleForKey:kMiniSightCenterX],
                                 [defaults doubleForKey:kMiniSightCenterY]);
        }
    }

    // 统一入口：夹到当前可行范围后移动子视图（窗口永远不动）
    MiniSightSetAnchor(center, NO);
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

static void MiniSightRequestResources(BOOL force, void (^completion)(void)) {
    NSCAssert([NSThread isMainThread], @"Resource state is main-thread only");
    if (completion) {
        if (!gMiniSightResourceCompletions) gMiniSightResourceCompletions = [NSMutableArray array];
        [gMiniSightResourceCompletions addObject:[completion copy]];
    }
    if (gMiniSightResourceLoading) {
        if (force) gMiniSightResourceRefreshAgain = YES;
        return;
    }
    if (gMiniSightResourcesReady && !force) {
        NSArray *pending = [gMiniSightResourceCompletions copy];
        [gMiniSightResourceCompletions removeAllObjects];
        for (void (^block)(void) in pending) block();
        return;
    }
    gMiniSightResourceLoading = YES;
    [MiniSightResources refresh:^(NSString *container, NSDictionary *preferences, BOOL shown, UIImage *atlas) {
        gMiniSightResourceLoading = NO;
        gMiniSightContainer = [container copy];
        gMiniSightPreferences = [preferences copy] ?: @{};
        gMiniSightShown = shown;
        gMiniSightAtlas = atlas;
        gMiniSightResourcesReady = YES;
        MiniSightConfigureRecorder();
        MiniSightReadActivitySnapshot();
        if (!gMiniSightShown) MiniSightDestroyUI();
        if (gMiniSightResourceRefreshAgain) {
            gMiniSightResourceRefreshAgain = NO;
            MiniSightRequestResources(YES, nil);
            return;
        }
        NSArray *pending = [gMiniSightResourceCompletions copy];
        [gMiniSightResourceCompletions removeAllObjects];
        for (void (^block)(void) in pending) block();
    }];
}

static void MiniSightBuildUI(void) {
    NSCAssert([NSThread isMainThread], @"MiniSight UI must be built on main thread");
    if (!gMiniSightResourcesReady) {
        MiniSightRequestResources(NO, ^{ MiniSightBuildUI(); });
        return;
    }
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

    // ---- 桌宠（可选）：只使用资源队列预解码的快照，不在建窗热路径读文件 ----
    UIImage *petSprite = (MiniSightStyle() == 1) ? gMiniSightAtlas : nil;
    if (petSprite) {
        gMiniSightPet = [[MiniSightPetView alloc] initWithSprite:petSprite
                                                    displaySize:CGSizeMake(MiniSightPetSize(), MiniSightPetSize() * 104.0 / 96.0)];
        // 桌宠每次真实移动（漫游/跳跃/被夹住）都从这儿回报：气泡跟着它走，
        // 锚点也随之更新 —— 这比原来「自己猜窗口中心」靠谱。
        gMiniSightPet.onGeometryChanged = ^{
            if (!gMiniSightPet) return;
            gMiniSightAnchor = gMiniSightPet.center;
            gMiniSightAnchorValid = YES;
            MiniSightFollowBubble();
        };
        gMiniSightPet.longPressEnabled = MiniSightLongPressEnabled();
        gMiniSightPet.reducedWork = [NSProcessInfo processInfo].lowPowerModeEnabled;
        [root addSubview:gMiniSightPet];
        [gMiniSightPet addGestureRecognizer:pan];
        // 长按由宿主拥有：桌宠自己在漫游动画里不再碰手势，所以动起来也按得住
        UILongPressGestureRecognizer *petPress =
            [[UILongPressGestureRecognizer alloc] initWithTarget:gMiniSightGestureTarget
                                                          action:@selector(handleLongPress:)];
        petPress.minimumPressDuration = 0.9;
        petPress.allowableMovement = 10.0;
        [gMiniSightPet addGestureRecognizer:petPress];
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
        pillPress.allowableMovement = 10.0;
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

    MiniSightRefreshGravityConfiguration();
    MiniSightUpdateGeometry();
}

#pragma mark - 显示 / 隐藏

static void MiniSightShow(void) {
    if (!MiniSightShown()) return;
    // Call mode is driven only by an active MCP-owned burst. A stray show
    // notification or stale status must never wake the pet while idle.
    if (!MiniSightAlwaysShow() && !gMiniSightBurst) return;
    if (!gMiniSightResourcesReady) {
        MiniSightRequestResources(NO, ^{ MiniSightShow(); });
        return;
    }
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

    // 重力包络参与布局，必须在第一次 UpdateGeometry 前设置。
    gMiniSightPet.gravityEnabled = MiniSightGravityEnabled();
    MiniSightUpdateGeometry();
    MiniSightApplySavedCenter(YES);
    MiniSightStartPulse();
    // 每次显示都按当前设置刷新：长按开关、低电量省电、调用期间才有走动
    gMiniSightPet.longPressEnabled = MiniSightLongPressEnabled();
    gMiniSightPet.reducedWork = [NSProcessInfo processInfo].lowPowerModeEnabled;
    gMiniSightPet.activityActive = YES;
    [gMiniSightPet startPlaying];
    MiniSightInstallRecorderCallbacks();

    // 先透明再取消 hidden，然后 0.18s 淡入
    gMiniSightWindow.alpha = 0.0;
    gMiniSightWindow.hidden = NO;
    MiniSightStartGravity();
    [UIView animateWithDuration:0.18
                          delay:0.0
                        options:(UIViewAnimationOptionCurveEaseOut |
                                 UIViewAnimationOptionBeginFromCurrentState)
                     animations:^{
        gMiniSightWindow.alpha = 1.0;
    } completion:nil];
}

static void MiniSightHide(void) {
    if (gMiniSightConfirming) return;   // 等问题回答完再收，否则气泡跟着窗口一起没
    MiniSightHideBubble();
    if (MiniSightAlwaysShow() && !gMiniSightUserHidden) {
        if (gMiniSightWindow && !gMiniSightWindow.hidden) MiniSightStartGravity();
        return;   // 常驻桌宠仍可见，重力采样不能被 stopped 错误关掉
    }
    MiniSightStopGravity();
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
            gMiniSightPet.activityActive = NO;
            [gMiniSightPet stopPlaying];
        }
    }];
}

/// 彻底拆掉浮窗（设置变更时重建用）
static void MiniSightDestroyUI(void) {
    MiniSightStopGravity();
    gMiniSightGravityConfigured = NO;
    // 确认态要一起清，否则气泡永远"正在确认"、再也收不起来
    if (gMiniSightConfirmTimeout) { dispatch_block_cancel(gMiniSightConfirmTimeout); gMiniSightConfirmTimeout = nil; }
    gMiniSightConfirming = NO;
    gMiniSightConfirmId = nil;
    if (gMiniSightBubble) { [gMiniSightBubble removeFromSuperview]; gMiniSightBubble = nil; gMiniSightBubbleLabel = nil; gMiniSightBubbleTail = nil; }
    gMiniSightConfirmBar = nil;
    if (gMiniSightPet) { [gMiniSightPet stopPlaying]; gMiniSightPet = nil; }
    gMiniSightAnchorValid = NO;
    gMiniSightDragOriginValid = NO;
    gMiniSightDragging = NO;
    gMiniSightWindow.hidden = YES;
    gMiniSightWindow.rootViewController = nil;
    gMiniSightWindow = nil;
    gMiniSightBubble = nil; gMiniSightBubbleScroll = nil; gMiniSightBubbleLabel = nil;
    gMiniSightBubbleTail = nil; gMiniSightConfirmBar = nil;
    gMiniSightBubbleContentHeight = 0.0;
    gMiniSightPill = nil; gMiniSightDot = nil; gMiniSightPulse = nil; gMiniSightLabel = nil;
    gMiniSightBuilt = NO;
}

/// 设置变了：按新设置重建（样式/常驻立即生效，不用注销）
static void MiniSightReloadSettings(void) {
    BOOL wasVisible = gMiniSightWindow && !gMiniSightWindow.hidden;
    MiniSightStopGravity();
    MiniSightDestroyUI();
    MiniSightRequestResources(YES, ^{
        if (!MiniSightShown()) return;
        if (MiniSightAlwaysShow() || (gMiniSightBurst && wasVisible)) MiniSightShow();
        else MiniSightBuildUI();
    });
}


#pragma mark - 说话气泡（只在 MCP 调用时）

static void MiniSightHideBubble(void) {
    if (gMiniSightConfirming) return;
    gMiniSightBubble.hidden = YES;
    gMiniSightBubbleShown = NO;
}

/// 纯文字气泡：动态深浅色、小尾巴指向指示器，最多 20 字。
/// 气泡永远在上方（可行范围已经预留了头顶空间），放不下就把身体整体下移；
/// 不再「上面放不下就翻到下面」，也不再夹到屏幕外。
static void MiniSightPlaceBubble(CGFloat w, CGFloat h) {
    UIView *host = gMiniSightPet ?: gMiniSightPill;
    UIView *root = gMiniSightWindow.rootViewController.view;
    if (!host || !root || !gMiniSightBubble) return;

    static BOOL placing = NO;
    if (placing) return;    // 让位动作会再回调一次，防重入
    placing = YES;

    MSLayout L = MiniSightLayoutNow();
    MSPoint anchor = (MSPoint){host.center.x, host.center.y};
    MSPoint wanted = MSLayoutAnchorForBubble(L, anchor, (MSSize){w, h});
    if (fabs(wanted.y - anchor.y) > 0.5 && !gMiniSightDragging) {
        // 气泡比预留的还高（比如长句子/确认条）：整体下移，而不是让气泡出屏
        CGPoint moved = CGPointMake(wanted.x, wanted.y);
        host.center = moved;
        anchor = (MSPoint){host.center.x, host.center.y};
        gMiniSightAnchor = host.center;
    }

    MSRect box = MSLayoutBubble(L, anchor, (MSSize){w, h});
    gMiniSightBubble.frame = CGRectMake(box.x, box.y, box.w, box.h);

    // 圆润的聊天气泡：主体圆角不超过 16，尾巴用两段二次曲线（不是三条直线的尖三角）
    CGFloat radius = MIN(16.0, box.h / 2.0);
    gMiniSightBubble.layer.cornerRadius = radius;
    if (@available(iOS 13.0, *)) {
        gMiniSightBubble.layer.cornerCurve = kCACornerCurveContinuous;
    }

    CGSize layoutSize = CGSizeMake(box.w, box.h);
    BOOL layoutChanged = !gMiniSightBubbleLayoutValid ||
        fabs(layoutSize.width - gMiniSightBubbleLayoutSize.width) > 0.25 ||
        fabs(layoutSize.height - gMiniSightBubbleLayoutSize.height) > 0.25 ||
        fabs(gMiniSightBubbleContentHeight - gMiniSightBubbleLayoutContentHeight) > 0.25;
    if (layoutChanged) {
        CGFloat pad = 6.0;
        CGFloat bottomSpace = gMiniSightConfirming ? 46.0 : 8.0;
        CGRect textViewport = CGRectMake(10.0, pad, box.w - 20.0,
                                         MAX(box.h - pad - bottomSpace, 1.0));
        gMiniSightBubbleScroll.frame = textViewport;
        gMiniSightBubbleScroll.contentSize = CGSizeMake(textViewport.size.width,
            MAX(gMiniSightBubbleContentHeight, textViewport.size.height));
        gMiniSightBubbleLabel.frame = CGRectMake(0.0, 0.0, gMiniSightBubbleScroll.contentSize.width,
                                                  gMiniSightBubbleScroll.contentSize.height);
        gMiniSightBubbleScroll.scrollEnabled = gMiniSightBubbleContentHeight > textViewport.size.height + 0.5;
        if (gMiniSightConfirming && gMiniSightConfirmBar)
            gMiniSightConfirmBar.frame = CGRectMake(10.0, box.h - 40.0, box.w - 20.0, 30.0);
        gMiniSightBubbleLayoutSize = layoutSize;
        gMiniSightBubbleLayoutContentHeight = gMiniSightBubbleContentHeight;
        gMiniSightBubbleLayoutValid = YES;
    }

    CGFloat cx = MIN(MAX(host.center.x - box.x, radius + 4.0), box.w - radius - 4.0);
    if (fabs(cx - gMiniSightBubbleTailX) > 0.5) {
        UIBezierPath *path = [UIBezierPath bezierPath];
        [path moveToPoint:CGPointMake(cx - 6.0, box.h)];
        [path addQuadCurveToPoint:CGPointMake(cx, box.h + 6.0)
                     controlPoint:CGPointMake(cx - 3.2, box.h + 4.4)];
        [path addQuadCurveToPoint:CGPointMake(cx + 6.0, box.h)
                     controlPoint:CGPointMake(cx + 3.2, box.h + 4.4)];
        [path closePath];
        gMiniSightBubbleTail.path = path.CGPath;
        gMiniSightBubbleTail.frame = gMiniSightBubble.bounds;
        gMiniSightBubbleTailX = cx;
    }

    placing = NO;
}

static void MiniSightShowBubbleWidth(NSString *raw, CGFloat maxW, NSUInteger cap) {
    UIView *host = gMiniSightPet ?: gMiniSightPill;
    UIView *root = gMiniSightWindow.rootViewController.view;
    if (!host || !root || raw.length == 0) return;

    NSString *text = raw;
    if (cap > 0 && raw.length > cap)
        text = [[raw substringToIndex:cap] stringByAppendingString:@"…"];

    if (!gMiniSightBubble) {
        UIView *b = [[UIView alloc] init];
        b.backgroundColor = [UIColor systemBackgroundColor];
        b.layer.cornerRadius = 18;
        b.layer.cornerCurve = kCACornerCurveContinuous;
        b.layer.borderWidth = 0.5;
        b.layer.borderColor = [UIColor separatorColor].CGColor;
        b.userInteractionEnabled = NO;
        b.hidden = YES;

        UIScrollView *scroll = [[UIScrollView alloc] init];
        scroll.backgroundColor = UIColor.clearColor;
        scroll.showsHorizontalScrollIndicator = NO;
        scroll.showsVerticalScrollIndicator = YES;
        scroll.alwaysBounceVertical = NO;
        scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        UILabel *l = [[UILabel alloc] init];
        l.font = [UIFont systemFontOfSize:11];
        l.textColor = [UIColor labelColor];
        l.numberOfLines = 0;
        l.userInteractionEnabled = NO;
        [scroll addSubview:l];
        [b addSubview:scroll];
        gMiniSightBubbleScroll = scroll;
        gMiniSightBubbleLabel = l;

        CAShapeLayer *tail = [CAShapeLayer layer];
        tail.fillColor = [UIColor systemBackgroundColor].CGColor;
        [b.layer addSublayer:tail];
        gMiniSightBubbleTail = tail;

        [root addSubview:b];
        gMiniSightBubble = b;
    }

    gMiniSightBubble.hidden = NO;
    gMiniSightBubbleShown = YES;
    gMiniSightBubble.backgroundColor = [UIColor systemBackgroundColor];
    gMiniSightBubbleLabel.textColor = [UIColor labelColor];
    gMiniSightBubbleTail.fillColor = [UIColor systemBackgroundColor].CGColor;
    gMiniSightBubbleLabel.text = text;

    CGFloat textWidth = MAX(1.0, maxW - 20.0);
    CGSize fit = [gMiniSightBubbleLabel sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)];
    gMiniSightBubbleContentHeight = ceil(MAX(fit.height, gMiniSightBubbleLabel.font.lineHeight));
    CGFloat minWidth = gMiniSightConfirming ? 180.0 : 44.0;
    CGFloat w = MIN(maxW, MAX(minWidth, ceil(fit.width) + 20.0));
    CGFloat visibleTextHeight = MIN(gMiniSightBubbleContentHeight, gMiniSightConfirming ? 180.0 : 96.0);
    CGFloat h = visibleTextHeight + (gMiniSightConfirming ? 52.0 : 14.0);
    gMiniSightBubbleScroll.contentOffset = CGPointZero;
    MiniSightPlaceBubble(w, h);
}

/// 只重算位置：气泡在，宠物怎么动它就跟到哪。
extern "C" void MiniSightFollowBubble(void) {
    UIView *host = gMiniSightPet ?: gMiniSightPill;
    UIView *root = gMiniSightWindow.rootViewController.view;
    if (!gMiniSightBubble || gMiniSightBubble.hidden || !gMiniSightBubble.superview) return;
    if (!host || !root) return;
    static CGPoint last;
    if (CGPointEqualToPoint(last, host.center) && gMiniSightBubble.frame.size.height > 0) return;
    last = host.center;
    MiniSightPlaceBubble(gMiniSightBubble.bounds.size.width, gMiniSightBubble.bounds.size.height);
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

/// Hiding/disabling the pet cancels the owned prompt as an explicit denial.
static void MiniSightCancelConfirm(void) {
    if (gMiniSightConfirming) MiniSightAnswerConfirm(NO);
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
    gMiniSightBubbleShown = NO;
    // 确认态结束：把头顶空间收回普通值，桌宠可行范围也跟着还原
    MiniSightSetAnchor(gMiniSightAnchor, NO);
    if (!gMiniSightBurst && !MiniSightAlwaysShow()) MiniSightHide();
}

/// 读 confirm.json，把问题+命令塞进气泡，底下挂两个按钮。
static void MiniSightShowConfirm(void) {
    if (!MiniSightShown() || (!MiniSightAlwaysShow() && !gMiniSightBurst)) return;
    @try {
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
    if (![action isKindOfClass:NSString.class] || ![command isKindOfClass:NSString.class] ||
        [command lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 65536) {
        gMiniSightConfirmId = ident;
        gMiniSightConfirming = YES;
        MiniSightAnswerConfirm(NO);
        return;
    }
    NSString *text = action.length ? [NSString stringWithFormat:@"%@\n%@", action, command] : command;
    MiniSightShowBubbleWidth(text, 260.0, 0);

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

    // 加高气泡：走统一布局（头顶按确认态预留，必要时身体整体下移），
    // 不再手改 origin.y —— 手改就等于再引入一次「气泡出屏」。
    CGFloat w = gMiniSightBubble.bounds.size.width;
    CGFloat h = gMiniSightBubble.bounds.size.height;
    MiniSightPlaceBubble(w, h);

    if (gMiniSightConfirmTimeout) dispatch_block_cancel(gMiniSightConfirmTimeout);
    gMiniSightConfirmTimeout = dispatch_block_create(DISPATCH_BLOCK_DETACHED, ^{ MiniSightAnswerConfirm(NO); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(55 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), gMiniSightConfirmTimeout);
    } @catch (NSException *e) {
        NSLog(@"MiniSight: 确认气泡失败 %@", e);
    }
}

static void MiniSightReadStatus(void) {
    NSString *container = MiniSightAppContainer();
    if (!container) return;
    NSString *path = [container stringByAppendingPathComponent:@"Documents/MiniSight/status.txt"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (text.length) MiniSightShowBubble(text);
}


/// Status updates never own visibility; only started/stopped activity edges do.
static void MiniSightArmIdleHide(void) {}

static void MiniSightShowLine(NSString *line) {
    if ((!gMiniSightWindow || gMiniSightWindow.hidden) && !gMiniSightBurst) return;
    MiniSightShowBubble(line);
    if (gMiniSightBubbleHideWork) { dispatch_block_cancel(gMiniSightBubbleHideWork); gMiniSightBubbleHideWork = nil; }
    if (gMiniSightBurst) return;   // 调用期间常亮，只换字，不在动作之间收
    gMiniSightBubbleHideWork = dispatch_block_create(DISPATCH_BLOCK_DETACHED, ^{
        MiniSightHideBubble();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), gMiniSightBubbleHideWork);
}

/// 诊断/状态行：比撒娇话长（最多 60 字），多留两秒才收
static void MiniSightShowStatusLine(NSString *text) {
    if (!text.length) return;
    if ((!gMiniSightWindow || gMiniSightWindow.hidden) && !gMiniSightBurst) return;
    MiniSightShowBubbleWidth(text, 280.0, 60.0);
    if (gMiniSightBubbleHideWork) { dispatch_block_cancel(gMiniSightBubbleHideWork); gMiniSightBubbleHideWork = nil; }
    if (gMiniSightBurst) return;
    gMiniSightBubbleHideWork = dispatch_block_create(DISPATCH_BLOCK_DETACHED, ^{
        MiniSightHideBubble();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
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

/// 取出报错体里的一句话（OpenAI 风格 error.message / 纯文本都吃），顺手删掉 key
static NSString *MiniSightAIDetail(NSData *data, NSString *key) {
    if (!data.length) return @"";
    NSString *text = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([obj isKindOfClass:[NSDictionary class]]) {
        id err = obj[@"error"];
        if ([err isKindOfClass:[NSDictionary class]]) text = err[@"message"];
        else if ([err isKindOfClass:[NSString class]]) text = err;
        if (![text isKindOfClass:[NSString class]]) text = obj[@"message"];
    }
    if (![text isKindOfClass:[NSString class]]) {
        text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    if (![text isKindOfClass:[NSString class]]) return @"";
    text = [[text stringByReplacingOccurrencesOfString:@"\n" withString:@" "]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // 报错体可能回显请求头/地址，绝不把 key 带进气泡、日志或诊断文件
    if (key.length >= 8) text = [text stringByReplacingOccurrencesOfString:key withString:@"***"];
    if (text.length > 120) text = [[text substringToIndex:120] stringByAppendingString:@"…"];
    return text;
}

/// 一句话说清是哪种毛病（气泡一行，最多 60 字，够诊断又不糊一屏）
static NSString *MiniSightAIShortReason(NSInteger status, NSString *detail) {
    if (status == 401 || status == 403) return @"AI 鉴权失败，检查 Key";
    if (status == 404) return @"AI 地址不对（404），看设置里的地址";
    if (status == 429) {
        return detail.length ? [NSString stringWithFormat:@"AI 被限流（429）：%@", detail]
                             : @"AI 被限流（429），等一会儿再点";
    }
    if (status == 400 || status == 422) {
        return detail.length ? [NSString stringWithFormat:@"AI 说请求不对（%ld）：%@", (long)status, detail]
                             : [NSString stringWithFormat:@"AI 说请求不对（%ld）", (long)status];
    }
    if (status >= 500) return [NSString stringWithFormat:@"AI 服务出错（%ld），过会儿再试", (long)status];
    if (status > 0) {
        return detail.length ? [NSString stringWithFormat:@"AI 报错（%ld）：%@", (long)status, detail]
                             : [NSString stringWithFormat:@"AI 报错（%ld）", (long)status];
    }
    return @"AI 这次没回话";
}

/// 把完整诊断写进 App 容器的 Documents/MiniSight/ai-last.txt（Files 里能直接翻）
static void MiniSightAIWriteDiagnosis(NSInteger status, NSString *path, NSString *detail) {
    NSString *dir = MiniSightSupportDirectory();
    if (!dir) return;
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSString *text = [NSString stringWithFormat:@"%@\nstatus=%ld\npath=%@\ndetail=%@\n",
                      [fmt stringFromDate:[NSDate date]], (long)status,
                      path.length ? path : @"(none)", detail.length ? detail : @"(empty)"];
    [text writeToFile:[dir stringByAppendingPathComponent:@"ai-last.txt"]
           atomically:YES encoding:NSUTF8StringEncoding error:nil];
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
        // 填过但没填全 → 明说；从来没配过 → 照旧说预设话
        if (data.length) MiniSightShowStatusLine(@"AI 设置没填全（地址/Key/模型）");
        else MiniSightSayPresetLine();
        return;
    }
    // Mirror the settings page endpoint builder and preserve gateway paths/queries.
    NSURLComponents *parts = [NSURLComponents componentsWithString:
        [base stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
    NSString *scheme = parts.scheme.lowercaseString;
    if (!parts || !scheme.length || ![@[@"http", @"https"] containsObject:scheme] ||
        parts.host.length == 0 || parts.user.length || parts.password.length ||
        parts.fragment.length) {
        MiniSightShowStatusLine(@"AI 地址不合法，请检查 http(s) 地址");
        return;
    }
    parts.scheme = scheme;
    NSString *path = parts.percentEncodedPath ?: @"";
    while ([path hasSuffix:@"/"]) path = [path substringToIndex:path.length - 1];
    if (path.length == 0) path = @"/v1/chat/completions";
    else if (![path hasSuffix:@"/chat/completions"]) path = [path stringByAppendingString:@"/chat/completions"];
    parts.percentEncodedPath = path;
    NSURL *url = parts.URL;
    if (!url) { MiniSightShowStatusLine(@"AI 地址不对，填不出可用链接"); return; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 6.0;
    [req setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *body = @{ @"model": model, @"max_tokens": @40,
        @"messages": @[ @{@"role": @"system", @"content": @"你是可爱的桌宠，说一句不超过20字的中文撒娇话，不要引号。"},
                        @{@"role": @"user", @"content": @"说一句"} ] };
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        // 先看 HTTP 状态码：以前不看，429/401 的报错体解析不出 choices，
        // 就静默换成预设话，用户只看到「AI 没反应」。
        NSInteger status = [r isKindOfClass:[NSHTTPURLResponse class]]
            ? ((NSHTTPURLResponse *)r).statusCode : 0;
        NSString *line = nil;
        NSString *why = nil;
        if (!e && status >= 200 && status < 300) {
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
            if (!line.length) why = @"AI 返回了空内容（200）";
        } else if (e) {
            why = (e.code == NSURLErrorTimedOut)
                ? @"AI 超时了（6 秒没回）"
                : [NSString stringWithFormat:@"AI 连不上（%ld）", (long)e.code];
            NSLog(@"[MiniSight] ai network error %@ %ld", e.domain, (long)e.code);
        } else {
            NSString *detail = MiniSightAIDetail(d, key);
            why = MiniSightAIShortReason(status, detail);
            NSLog(@"[MiniSight] ai status=%ld path=%@ detail=%@", (long)status, url.path, detail);
            MiniSightAIWriteDiagnosis(status, url.path, detail);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (line.length) MiniSightShowLine(line);
            else if (why.length) MiniSightShowStatusLine(why);   // 出错就说清楚，不悄悄换预设话
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
            if (gMiniSightBurst || MiniSightAlwaysShow()) {
                MiniSightArmIdleHide();
                MiniSightReadStatus();
            }
        });
        return;
    }
    if ([note isEqualToString:kMiniSightConfirmNote]) {
        dispatch_async(dispatch_get_main_queue(), ^{ MiniSightShowConfirm(); });
        return;
    }
    if ([note isEqualToString:kMiniSightConfirmCancel]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *container = MiniSightAppContainer();
            NSString *path = [container stringByAppendingPathComponent:@"Documents/MiniSight/confirm-cancel.txt"];
            NSString *ident = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
            if (gMiniSightConfirming && [ident isEqualToString:gMiniSightConfirmId])
                MiniSightAnswerConfirm(NO);
        });
        return;
    }
    if ([note isEqualToString:kMiniSightActivityNote]) {
        MiniSightReadActivitySnapshot();
        return;
    }
    if ([note isEqualToString:kMiniSightBlanked]) {
        // 熄灭/点亮各来一次，翻转即可：熄灭时暂停定时器，点亮再续。
        static BOOL blanked = NO;
        blanked = !blanked;
        BOOL b = blanked;
        dispatch_async(dispatch_get_main_queue(), ^{
            gMiniSightScreenBlanked = b;
            [gMiniSightPet setSuspended:b];
            if (b) MiniSightStopGravity();
            else if (gMiniSightWindow && !gMiniSightWindow.hidden) MiniSightStartGravity();
        });
        return;
    }
    if ([note isEqualToString:kMiniSightSettingsChanged]) {
        // 设置是异步落盘的，等一拍再读；否则第一次收到通知读到的还是旧值，
        // 表现为要拨两次开关才生效。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ MiniSightReloadSettings(); });
        return;
    }

    BOOL shouldShow = [note isEqualToString:kMiniSightStarted];
    BOOL shouldHide = [note isEqualToString:kMiniSightStopped];
    if (!shouldShow && !shouldHide) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (shouldShow) {
            gMiniSightBurst = YES;
            if (gMiniSightPendingHide) { dispatch_block_cancel(gMiniSightPendingHide); gMiniSightPendingHide = nil; }
            MiniSightArmIdleHide();
            MiniSightShow();
            MiniSightReadActivitySnapshot();
        } else {
            // 工具是一条接一条的，隔一两秒就 hide 会闪；等 2.5 秒没下一条再收。
            gMiniSightBurst = NO;
            if (gMiniSightPendingHide) dispatch_block_cancel(gMiniSightPendingHide);
            gMiniSightPendingHide = dispatch_block_create(DISPATCH_BLOCK_DETACHED, ^{
                MiniSightHide();
            });
            MiniSightReadActivitySnapshot();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), gMiniSightPendingHide);
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
                                        (__bridge const void *)kMiniSightActivityNote,
                                        MiniSightDarwinCallback,
                                        (__bridge CFStringRef)kMiniSightActivityNote,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(center,
                                        (__bridge const void *)kMiniSightConfirmCancel,
                                        MiniSightDarwinCallback,
                                        (__bridge CFStringRef)kMiniSightConfirmCancel,
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
            @try {
                MiniSightConfigureRecorder();
                MiniSightReadActivitySnapshot();
                if (MiniSightAlwaysShow() && MiniSightShown()) MiniSightShow();
                else MiniSightBuildUI();
            } @catch (NSException *e) {
                NSLog(@"MiniSight: 启动建窗失败 %@", e);
            }

            [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
            [[NSNotificationCenter defaultCenter] addObserver:gMiniSightGestureTarget
                                                     selector:@selector(handleOrientationChange:)
                                                         name:UIDeviceOrientationDidChangeNotification
                                                       object:nil];
            // 低电量变化：桌宠立刻降档（不再按帧播放/大幅走动），省电但不能看不出效果
            [[NSNotificationCenter defaultCenter] addObserver:gMiniSightGestureTarget
                                                     selector:@selector(handlePowerStateChange:)
                                                         name:NSProcessInfoPowerStateDidChangeNotification
                                                       object:nil];
        });
    }
}
