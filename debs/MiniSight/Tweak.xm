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
#import "MiniSightPreferences.h"
#import "MiniSightGravity.h"
#import "MiniSightMotionPolicy.h"
#import "MiniSightBridgeIO.h"
#import "MiniSightRecorder.h"
#import "MiniSightChatPanel.h"
#import "MiniSightLog.h"
#import "MiniSightRuntimeConfig.h"
#import "MiniSightBlip.h"
#import <notify.h>
#import <signal.h>
#include <unistd.h>

#ifdef MINISIGHT_STRIP_LOGS
#define NSLog(...) ((void)0)
#define syslog(...) ((void)0)
#endif


#pragma mark - MiniSight 配置（读 Minis 容器的偏好）

static void MiniSightHide(void);
static void MiniSightHideBubble(void);
static void MiniSightShowConfirm(void);
static void MiniSightAnswerConfirm(BOOL allow);
static void MiniSightSay(NSString *line);
static void MiniSightShowBubble(NSString *raw);
static void MiniSightShowBubbleWidth(NSString *raw, CGFloat maxW, NSUInteger cap);
static void MiniSightShowStatusLine(NSString *text);
static void MiniSightSetAnchor(CGPoint want, BOOL save);
static void MiniSightFollowBubble(void);
static void MiniSightRefreshChatAnchor(void);
static void MiniSightPlaceBubble(CGFloat w, CGFloat h);
static void MiniSightDestroyUI(void);
static void MiniSightBringMinisFront(void);
static BOOL MiniSightMinisIsFrontmost(void);

// Immutable main-thread snapshot. Resource refresh owns ALL directory/plist/image I/O.
static NSString *gMiniSightContainer;
static NSDictionary *gMiniSightPreferences;
static UIImage *gMiniSightAtlas;
static BOOL gMiniSightShown = NO, gMiniSightResourcesReady = NO;
static BOOL gMiniSightResourceLoading = NO;
static BOOL gMiniSightResourceRefreshAgain = NO;
static NSMutableArray *gMiniSightResourceCompletions;
static void MiniSightReloadSettings(void);

// 0 pack, 1 whole static image, 2 legacy outer cell,
// 3 8x9 single animation sheet, 4 static 72-pose sheet.
static NSInteger MiniSightSpriteLayoutForContainer(NSString *container) {
    if (container.length == 0) return 0;
    NSString *path = [container stringByAppendingPathComponent:@"Documents/MiniSight/pet.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSDictionary *meta = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![meta isKindOfClass:NSDictionary.class] || ![meta[@"sourceKind"] isEqual:@"singleImage"]) return 0;
    NSInteger layout = [meta[@"layoutVersion"] integerValue];
    if (layout >= 4) return 4;
    if (layout == 3) return 3;
    if (layout == 2) return 2;
    return 1;
}
static void MiniSightShow(void);
static void MiniSightShowAfterOwnershipCheck(void);
static void MiniSightRefreshAppOwnership(void (^completion)(void));
static void MiniSightStopGravity(void);
static void MiniSightCancelConfirm(void);
static void MiniSightConfigureRecorder(void);
static void MiniSightConfigureRecorderWithCompletion(void (^completion)(void));
static void MiniSightReadActivitySnapshot(void);
static void MiniSightBuildUI(void);
static void MiniSightRequestResources(BOOL force, void (^completion)(void));
static BOOL gMiniSightActivityExecuting = NO;
static BOOL gMiniSightAppNativeReturn = NO;
static dispatch_block_t gMiniSightPendingReturn = nil;
static NSUInteger gMiniSightReturnGeneration = 0;
static NSInteger gMiniSightActivityPID = 0;
static NSString *gMiniSightActivityInstanceID;
static BOOL gMiniSightRecorderCallbacksInstalled = NO;
static BOOL gMiniSightRecorderConfigured = NO;
static BOOL gMiniSightRecorderAutomaticEnabled = NO;
static BOOL gMiniSightRecorderManualEnabled = YES;
static NSUInteger gMiniSightRecorderConfigGeneration = 0;
static NSUInteger gMiniSightActivityReadGeneration = 0;
static dispatch_source_t gMiniSightPresentationTimer;
static BOOL gMiniSightUserHidden = NO;
static NSInteger gMiniSightAppliedRenderer = -1;
static NSInteger gMiniSightAppliedStyle = -1;
static void MiniSightReconcileAppPresentation(void);
static NSString *MiniSightRecorderIssueText(MiniSightRecorderIssue issue, NSInteger code, MiniSightRecorderSaveStage stage);
static void MiniSightInstallRecorderCallbacks(void);
static void MiniSightInteractionEnd(void);
static void MiniSightRefreshRecorderSettingsThenReadActivity(void);

static void MiniSightReplyToPluginProbe(void);
static void MiniSightStopGravity(void);
// 浮窗载体：定义在文件前部，呈现协调（MiniSightReconcileAppPresentation）要先用到它。
static UIWindow *gMiniSightWindow = nil;
extern BOOL gMiniSightBurst;

static NSString *MiniSightAppContainer(void) { return gMiniSightContainer; }
static id MiniSightPref(NSString *key) { return gMiniSightPreferences[key]; }
static NSInteger MiniSightStyle(void) { return [MiniSightPref(@"minisight.style") integerValue]; }
static NSInteger MiniSightRenderer(void) {
    id value = MiniSightPref(@"minisight.renderer");
    return value ? [value integerValue] : 0; // Existing installs keep plugin rendering.
}
static CGFloat MiniSightPetSize(void) {
    id v = MiniSightPref(@"minisight.petSize");
    return v ? MSClamp([v doubleValue], 36., 140.) : 96.;
}
static BOOL MiniSightAlwaysShow(void) { return [MiniSightPref(@"minisight.mode") integerValue] == 1; }
static BOOL MiniSightShown(void) { return gMiniSightShown; }
static BOOL MiniSightAppOwnsPresentation(void) {
    // Renderer is an explicit global choice, not a foreground-window heuristic.
    // If App mode is selected, SpringBoard never paints a duplicate pet.
    return MiniSightRenderer() == 1 && MiniSightStyle() == 1 && MiniSightShown();
}

/// Presentation is main-thread owned. App ownership is read live from SBWorkspace
/// inside MiniSightAppOwnsPresentation, so "refreshing" only means making sure the
/// caller inspects it on the main queue before it decides anything.
static void MiniSightRefreshAppOwnership(void (^completion)(void)) {
    if (!completion) return;
    if ([NSThread isMainThread]) {
        completion();
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ completion(); });
}

static void MiniSightReplyToPluginProbe(void) {
    NSString *container = MiniSightAppContainer();
    if (!container.length) return;
    NSString *dir = [container stringByAppendingPathComponent:@"Documents/MiniSight"];
    NSString *path = [dir stringByAppendingPathComponent:@"plugin-probe.txt"];
    NSString *nonce = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!nonce.length || nonce.length > 64) return;
    [nonce writeToFile:[dir stringByAppendingPathComponent:@"plugin-probe-reply.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void MiniSightReconcileAppPresentation(void) {
    NSCAssert([NSThread isMainThread], @"MiniSight presentation is main-thread owned");
    BOOL appOwns = MiniSightAppOwnsPresentation();
    BOOL wantsOverlay = MiniSightShown() && (MiniSightAlwaysShow() || gMiniSightBurst);
    if (appOwns) {
        MiniSightStopGravity();
        [[MiniSightChatPanel existingPanel] hideWithoutKey];
        if (gMiniSightWindow && !gMiniSightWindow.hidden) gMiniSightWindow.hidden = YES;
    } else if (wantsOverlay) {
        if (!gMiniSightWindow || gMiniSightWindow.hidden) MiniSightShow();
    } else if (gMiniSightWindow && !gMiniSightWindow.hidden) {
        MiniSightHide();
    }
}

static void MiniSightStartPresentationTimer(void) {
    if (gMiniSightPresentationTimer) return;
    gMiniSightPresentationTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gMiniSightPresentationTimer, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                              3 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(gMiniSightPresentationTimer, ^{ MiniSightReconcileAppPresentation(); });
    dispatch_resume(gMiniSightPresentationTimer);
}

static void MiniSightUserHide(void) {
    gMiniSightShown = NO;
    gMiniSightUserHidden = YES;
    MSMiniSightSetPreference(@"MiniSightUserHidden", @YES);
    // Both transports: the App switch and every runtime reader see the hide,
    // not only the plugin's in-memory gMiniSightShown flag.
    MSMiniSightSetPreference(@"minisight.shown", @NO);
    [MiniSightResources writeShown:NO container:gMiniSightContainer];
    [[MiniSightChatPanel existingPanel] close];
    MiniSightCancelConfirm(); // hide must not be blocked by an approval bubble
    MiniSightHide();
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MiniSightUserHiddenChanged" object:nil];
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

static NSString *MiniSightRecorderSaveStageText(MiniSightRecorderSaveStage stage) {
    switch (stage) {
        case MiniSightRecorderSaveStageDestination: return @"录屏目录创建失败";
        case MiniSightRecorderSaveStageSourceMissing: return @"系统返回的录屏源文件不存在";
        case MiniSightRecorderSaveStageCopy: return @"录屏文件复制失败";
        case MiniSightRecorderSaveStageInspect: return @"录屏文件无法解析或没有视频轨";
        case MiniSightRecorderSaveStagePublish: return @"录屏文件发布落盘失败";
        default: return @"录屏文件校验或保存失败";
    }
}

static NSString *MiniSightRecorderIssueText(MiniSightRecorderIssue issue, NSInteger code,
                                            MiniSightRecorderSaveStage stage) {
    if (code != 0) return [NSString stringWithFormat:@"录屏失败（系统错误 %ld）", (long)code];
    switch (issue) {
        case MiniSightRecorderIssueDisabled: return @"录屏功能已关闭";
        case MiniSightRecorderIssueExternalSession: return @"系统已有录屏，未接管";
        case MiniSightRecorderIssueDestination: return @"录屏目录不可用";
        case MiniSightRecorderIssueOwnershipLost: return @"录屏会话被系统中断，未伪报保存成功";
        case MiniSightRecorderIssueStartTimeout: return @"系统录屏启动超时";
        case MiniSightRecorderIssueStopTimeout: return @"系统录屏停止超时";
        case MiniSightRecorderIssueMissingArtifact: return @"系统未返回录屏文件";
        case MiniSightRecorderIssueSaveFailed: return MiniSightRecorderSaveStageText(stage);
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
        MSDiag(@"recorder state=%ld owner=%ld issue=%ld quarantined=%d", (long)state, (long)owner, (long)issue, quarantined);
        MSDiagEvent(@"recording", @"state", quarantined || issue != MiniSightRecorderIssueNone ? @"failed" : @"pending", @{ @"source": @"plugin", @"mode": @(owner), @"value": @(state), @"issue": @(issue), @"reason": quarantined ? @"quarantined" : @"controller_state" });
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
        MSDiag(@"recorder result success=%d issue=%ld stage=%ld bytes=%llu dur=%.2f", result.success, (long)result.issue, (long)result.saveStage, result.byteCount, result.duration);
        MSDiagEvent(@"recording", @"finish", result.success ? @"ok" : @"failed", @{ @"source": @"plugin", @"issue": @(result.issue), @"value": @(result.saveStage), @"code": @(result.systemErrorCode), @"bytes": @(result.byteCount), @"duration_ms": @(result.duration * 1000.0) });
        if (result.success) {
            NSString *name = result.fileURL.lastPathComponent ?: @"";
            NSDictionary *entry = @{@"file": name, @"durationSeconds": @(result.duration),
                                    @"bytes": @(result.byteCount), @"savedAt": @([[NSDate date] timeIntervalSince1970])};
            NSString *container = [MiniSightAppContainer() copy];
            dispatch_async(MiniSightRecorderSetupQueue(), ^{
                if (container.length) MSBridgeWrite(container, @"recording-last.json", entry);
            });
            MiniSightShowStatusLine([NSString stringWithFormat:@"录屏已保存：%@（%.0f秒）", name, result.duration]);
        } else if (result.issue != MiniSightRecorderIssueNone) {
            MiniSightSay(MiniSightRecorderIssueText(result.issue, result.systemErrorCode, result.saveStage));
        }
    };
    gMiniSightRecorderCallbacksInstalled = YES;
}

static void MiniSightConfigureRecorder(void) {
    MiniSightConfigureRecorderWithCompletion(nil);
}

static void MiniSightConfigureRecorderWithCompletion(void (^completion)(void)) {
    NSCAssert([NSThread isMainThread], @"recorder configuration is main-thread owned");
    MiniSightInstallRecorderCallbacks();
    NSUInteger generation = ++gMiniSightRecorderConfigGeneration;
    NSString *container = [MiniSightAppContainer() copy];
    BOOL automatic = MiniSightRecordingEnabled();
    BOOL manual = MiniSightLongPressEnabled();
    gMiniSightRecorderAutomaticEnabled = automatic;
    gMiniSightRecorderManualEnabled = manual;
    // Source switches take effect now, not after asynchronous directory work.
    [MiniSightRecorder.sharedRecorder setAutomaticEnabled:automatic manualEnabled:manual];
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
            gMiniSightRecorderConfigured = directory != nil;
            NSMutableDictionary *fields = [@{@"source": @"plugin", @"setting": @"minisight.record", @"enabled": @(automatic), @"readback": @(directory != nil), @"generation": @(generation)} mutableCopy];
            if (MiniSightPref(@"minisight.settings.revision")) fields[@"revision"] = MiniSightPref(@"minisight.settings.revision");
            MSDiagEvent(@"recording", @"configure", directory ? @"ok" : @"failed", fields);
            fields[@"setting"] = @"minisight.longPress"; fields[@"enabled"] = @(manual);
            MSDiagEvent(@"recording", @"configure", directory ? @"ok" : @"failed", fields);
            if (!directory && manual) MiniSightSay(@"录屏目录不可用，录屏功能未就绪");
            if (completion) completion();
            else if (gMiniSightRecorderConfigured) MiniSightReadActivitySnapshot();
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
        gMiniSightAppNativeReturn = [activity[@"nativeReturn"] boolValue];
        gMiniSightActivityPID = pid;
        gMiniSightActivityInstanceID = [instance copy];
    }
    if (gMiniSightActivityExecuting != active) MSDiagEvent(@"activity", @"state", valid ? @"ok" : @"failed", @{ @"source": @"plugin", @"executing": @(active), @"count": @(count), @"valid": @(valid) });
    BOOL endedExecution = gMiniSightActivityExecuting && !active && gMiniSightActivityEverExecuted;
    gMiniSightActivityExecuting = active;
    if (active) gMiniSightActivityEverExecuted = YES;
    MSDiag(@"activity valid=%d active=%d count=%ld nativeReturn=%d ended=%d", valid, active, (long)count, gMiniSightAppNativeReturn, endedExecution);
    // Automatic MCP capture is independently gated by the App switch.
    // Manual long-press remains available through the separate manual flag.
    if (gMiniSightRecorderConfigured || !active || !gMiniSightRecorderAutomaticEnabled)
        [MiniSightRecorder.sharedRecorder setAutomaticActive:(active && gMiniSightRecorderAutomaticEnabled)];
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

static void MiniSightRefreshRecorderSettingsThenReadActivity(void) {
    NSCAssert([NSThread isMainThread], @"recorder refresh is main-thread owned");
    NSUInteger generation = ++gMiniSightActivityReadGeneration; // invalidate old activity reads
    [MiniSightResources refreshSnapshotPreferences:^(NSString *container, NSDictionary *preferences) {
        if (generation != gMiniSightActivityReadGeneration) return;
        if (container.length) gMiniSightContainer = [container copy];
        gMiniSightPreferences = [preferences copy] ?: @{};
        MiniSightChatPanel *panel = MiniSightChatPanel.existingPanel;
        panel.containerPath = gMiniSightContainer;
        panel.appearancePreferences = gMiniSightPreferences;
        MiniSightConfigureRecorderWithCompletion(^{ MiniSightReadActivitySnapshot(); });
    }];
}

/// Manual region picker: drag the body or any corner, then confirm.
@interface MiniSightRegionPicker : UIWindow
@property(nonatomic, copy) void (^onConfirm)(CGRect normalized);
- (void)present;
@end

@implementation MiniSightRegionPicker {
    UIView *_dim, *_box, *_dragArea;
    CGPoint _start;
    CGRect _startFrame;
    NSInteger _corner;
}
- (instancetype)init {
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:UIWindowScene.class] && s.activationState == UISceneActivationStateForegroundActive) { scene = (id)s; break; }
    if (!scene) return nil;
    self = [super initWithWindowScene:scene];
    self.windowLevel = UIWindowLevelAlert + 2;
    self.backgroundColor = UIColor.clearColor;
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.clearColor;
    self.rootViewController = vc;
    _dim = [[UIView alloc] initWithFrame:scene.coordinateSpace.bounds];
    _dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    _dim.userInteractionEnabled = YES;
    UIPanGestureRecognizer *draw = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(draw:)];
    [_dim addGestureRecognizer:draw];
    [vc.view addSubview:_dim];
    CGRect r = CGRectInset(scene.coordinateSpace.bounds, 60, scene.coordinateSpace.bounds.size.height * 0.22);
    _box = [[UIView alloc] initWithFrame:r];
    _box.backgroundColor = UIColor.clearColor;
    _box.layer.borderColor = UIColor.whiteColor.CGColor;
    _box.layer.borderWidth = 2;
    _box.layer.cornerRadius = 10;
    [vc.view addSubview:_box];
    _dragArea = [[UIView alloc] initWithFrame:CGRectInset(_box.bounds, 30, 30)];
    _dragArea.backgroundColor = UIColor.clearColor;
    [_box addSubview:_dragArea];
    UIPanGestureRecognizer *body = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
    [_dragArea addGestureRecognizer:body];
    for (NSInteger i = 0; i < 4; i++) {
        UIView *h = [[UIView alloc] initWithFrame:CGRectMake(i % 2 ? r.size.width - 30 : -6, i / 2 ? r.size.height - 30 : -6, 30, 30)];
        h.backgroundColor = UIColor.whiteColor;
        h.layer.cornerRadius = 15;
        h.tag = i + 1;
        [_box addSubview:h];
        UIPanGestureRecognizer *g = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
        [h addGestureRecognizer:g];
    }
    UIButton *reselect = [UIButton buttonWithType:UIButtonTypeSystem];
    reselect.frame = CGRectMake(20, scene.coordinateSpace.bounds.size.height - 110, 90, 44);
    [reselect setTitle:@"重画" forState:UIControlStateNormal];
    [reselect addTarget:self action:@selector(reselectTap) forControlEvents:UIControlEventTouchUpInside];
    [vc.view addSubview:reselect];
    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    cancel.frame = CGRectMake(115, scene.coordinateSpace.bounds.size.height - 110, 90, 44);
    [cancel setTitle:@"取消" forState:UIControlStateNormal];
    [cancel addTarget:self action:@selector(cancelTap) forControlEvents:UIControlEventTouchUpInside];
    [vc.view addSubview:cancel];
    UIButton *go = [UIButton buttonWithType:UIButtonTypeSystem];
    go.frame = CGRectMake(scene.coordinateSpace.bounds.size.width - 160, scene.coordinateSpace.bounds.size.height - 110, 140, 44);
    [go setTitle:@"开始录屏" forState:UIControlStateNormal];
    [go setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    go.backgroundColor = UIColor.systemBlueColor;
    go.layer.cornerRadius = 22;
    [go addTarget:self action:@selector(confirmTap) forControlEvents:UIControlEventTouchUpInside];
    [vc.view addSubview:go];
    return self;
}
- (void)present { self.hidden = NO; [self makeKeyAndVisible]; }
- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint t = [g translationInView:self.rootViewController.view];
    if (g.state == UIGestureRecognizerStateBegan) { _start = _box.frame.origin; _startFrame = _box.frame; _corner = v.tag; }
    if (g.state == UIGestureRecognizerStateChanged) {
        CGRect f = _startFrame;
        CGRect bounds = self.rootViewController.view.bounds;
        if (_corner == 0) {
            f.origin.x = _start.x + t.x; f.origin.y = _start.y + t.y;
        } else {
            BOOL left = (_corner == 1 || _corner == 3);
            BOOL top = (_corner == 1 || _corner == 2);
            BOOL right = (_corner == 2 || _corner == 4);
            BOOL bottom = (_corner == 3 || _corner == 4);
            if (left) { f.origin.x += t.x; f.size.width -= t.x; }
            if (top) { f.origin.y += t.y; f.size.height -= t.y; }
            if (right) { f.size.width += t.x; }
            if (bottom) { f.size.height += t.y; }
        }
        f.size.width = MAX(90, f.size.width); f.size.height = MAX(90, f.size.height);
        f.origin.x = MSClamp(f.origin.x, 0, bounds.size.width - f.size.width);
        f.origin.y = MSClamp(f.origin.y, 40, bounds.size.height - f.size.height);
        _box.frame = f;
        _dragArea.frame = CGRectInset(_box.bounds, 30, 30);
    }
}
- (void)draw:(UIPanGestureRecognizer *)g {
    CGPoint p = [g locationInView:self.rootViewController.view];
    if (g.state == UIGestureRecognizerStateBegan) {
        _box.hidden = NO;
        _box.frame = CGRectMake(p.x, p.y, 2, 2);
    } else if (g.state == UIGestureRecognizerStateChanged) {
        _box.frame = CGRectMake(MIN(_start.x, p.x), MIN(_start.y, p.y), fabs(p.x - _start.x), fabs(p.y - _start.y));
    } else if (g.state == UIGestureRecognizerStateEnded) {
        if (_box.frame.size.width < 40 || _box.frame.size.height < 40)
            _box.frame = CGRectInset(self.rootViewController.view.bounds, 60, 120);
        _dragArea.frame = CGRectInset(_box.bounds, 30, 30);
    }
    if (g.state == UIGestureRecognizerStateBegan) _start = p;
}
- (void)reselectTap {
    _box.frame = CGRectInset(self.rootViewController.view.bounds, 60, 120);
    _dragArea.frame = CGRectInset(_box.bounds, 30, 30);
}
- (void)cancelTap { MSDiagEvent(@"recording", @"region", @"skipped", @{ @"source": @"plugin", @"reason": @"cancel" }); self.hidden = YES; }
- (void)confirmTap {
    CGRect b = self.rootViewController.view.bounds, f = _box.frame;
    MSDiagEvent(@"recording", @"region", @"ok", @{ @"source": @"plugin", @"x": @(f.origin.x / b.size.width), @"y": @(f.origin.y / b.size.height), @"w": @(f.size.width / b.size.width), @"h": @(f.size.height / b.size.height) });
    if (self.onConfirm) self.onConfirm(CGRectMake(f.origin.x / b.size.width, f.origin.y / b.size.height,
                                                  f.size.width / b.size.width, f.size.height / b.size.height));
    self.hidden = YES;
}
@end

static MiniSightRegionPicker *gMiniSightRegionPicker;

static void MiniSightPresentRegionPicker(void) {
    MiniSightRecorder *rec = MiniSightRecorder.sharedRecorder;
    gMiniSightRegionPicker = [[MiniSightRegionPicker alloc] init];
    __weak MiniSightRegionPicker *weakPicker = gMiniSightRegionPicker;
    gMiniSightRegionPicker.onConfirm = ^(CGRect region) {
        [rec startWithSource:MiniSightRecorderSourceManual region:region];
        weakPicker.hidden = YES;
    };
    [gMiniSightRegionPicker present];
}

static void MiniSightStartManualRecording(void) {
    MiniSightRecorder *rec = MiniSightRecorder.sharedRecorder;
    if (rec.state != MiniSightRecorderIdle) { [rec toggle]; return; }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"录屏"
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"区域录屏（可画框移动）" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) { MiniSightPresentRegionPicker(); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"全屏录屏" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) { [rec startWithSource:MiniSightRecorderSourceManual region:CGRectNull]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *host = gMiniSightWindow.rootViewController;
    sheet.popoverPresentationController.sourceView = host.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(host.view.bounds.size.width / 2, host.view.bounds.size.height - 80, 1, 1);
    [host presentViewController:sheet animated:YES completion:nil];
}

static void MiniSightToggleRecording(void) {
    // Read the actual manual switch for every long-press. The App need not post
    // a new notification, and the automatic switch never gates manual capture.
    NSString *observedContainer = [gMiniSightContainer copy];
    [MiniSightResources refreshPreferences:^(NSString *container, NSDictionary *preferences) {
        if (container.length) gMiniSightContainer = [container copy];
        gMiniSightPreferences = [preferences copy] ?: @{};
        BOOL automatic = MiniSightRecordingEnabled();
        BOOL manual = MiniSightLongPressEnabled();
        gMiniSightRecorderAutomaticEnabled = automatic;
        gMiniSightRecorderManualEnabled = manual;
        // Applying two flags is in-memory; never rebuild the recording directory
        // or re-read activity.json on a manual press.
        [MiniSightRecorder.sharedRecorder setAutomaticEnabled:automatic manualEnabled:manual];
        if (!manual || !MiniSightLongPressEnabled()) {
            MSDiagEvent(@"recording", @"skip", @"skipped", @{ @"source": @"plugin", @"reason": @"manual_disabled" });
            return;
        }
        MSDiagEvent(@"recording", @"entry", @"pending", @{ @"source": @"plugin", @"reason": @"long_press" });
        BOOL sameContainer = observedContainer.length && [container isEqualToString:observedContainer];
        if (gMiniSightRecorderConfigured && sameContainer) {
            MiniSightStartManualRecording();
            return;
        }
        MiniSightConfigureRecorderWithCompletion(^{
            if (!gMiniSightRecorderManualEnabled || !MiniSightLongPressEnabled()) return;
            if (!gMiniSightRecorderConfigured) { MiniSightSay(@"录屏控制器尚未就绪，请稍后再试"); return; }
            MiniSightStartManualRecording();
        });
    }];
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
static NSString *const kMiniSightResourcesChanged = @"com.openminis.minisight.resources";
static NSString *const kMiniSightStatus = @"com.openminis.minisight.status";
static NSString *const kMiniSightShow = @"com.openminis.minisight.show";
static NSString *const kMiniSightConfirmNote = @"com.openminis.minisight.confirm";
static NSString *const kMiniSightActivityNote = @"com.openminis.minisight.activity";
static NSString *const kMiniSightAppActiveNote = @"com.openminis.minisight.app-active";
static NSString *const kMiniSightPluginProbe = @"com.openminis.minisight.plugin-probe";
static NSString *const kMiniSightConfirmCancel = @"com.openminis.minisight.confirm.cancel";
static NSString *const kMiniSightBlanked = @"com.apple.springboard.hasBlankedScreen";
static NSString *const kMiniSightCenterX   = @"MiniSightCenterX";
static NSString *const kMiniSightCenterY   = @"MiniSightCenterY";
static NSString *const kMiniSightText      = @"Minis 操作中";
// 版本号：与 DEBIAN/control 的 Version 同步。诊断日志会打印它，
// 便于装机后确认跑的是哪一版（strings MiniSight.dylib | grep 也能看到）。
static NSString *const kMiniSightVersion   = @"0.8.3";

#pragma mark - 全局状态

static UIView   *gMiniSightPill   = nil;   // 胶囊本体
static UIView   *gMiniSightDot    = nil;   // 实心圆点（自身发光）
static UIView   *gMiniSightPulse  = nil;   // 圆点背后的脉动圈
static UILabel  *gMiniSightLabel  = nil;   // 文字
static id        gMiniSightGestureTarget = nil; // 手势/通知的 target（需强引用）
static BOOL      gMiniSightBuilt  = NO;
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
static BOOL gMiniSightBubbleExpanded = NO;
static NSString *gMiniSightBubbleText = nil;
static CGFloat gMiniSightBubbleScale = 1., gMiniSightTextScale = 1., gMiniSightDwell = 1.;
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
static BOOL gMiniSightAccelerometerRunning = NO;
static CMAcceleration gMiniSightLastAcceleration;
static BOOL gMiniSightLastAccelerationValid = NO;
static BOOL gMiniSightScreenBlanked = YES;
static BOOL gMiniSightScreenKnown = NO;
static int gMiniSightScreenToken = -1;
static MSMotionAttempt gMiniSightMotionAttempt = { 0, MSMotionSourceNone, 0 };
static dispatch_block_t gMiniSightFirstSampleWatchdog;
static CGFloat gMiniSightGravityRoll = 0.0;
static BOOL gMiniSightGravityRollValid = NO;
static BOOL gMiniSightGravityShakeLatched = NO;
static NSTimeInterval gMiniSightGravityLastImpulseTime = 0.0;
static CFTimeInterval gMiniSightGravityLastSampleTime = 0.0;
static NSUInteger gMiniSightGravitySampleCount = 0;
static BOOL gMiniSightGravityConfigured = NO;
static double gMiniSightBottomGap = 12;
static UIImage *gMiniSightTintBase;
static BOOL gMiniSightDiagnosticsEnabled = NO;

static void MiniSightApplyTint(NSString *name) {
    UIImage *base = gMiniSightTintBase ?: gMiniSightAtlas;
    if (!gMiniSightPet || !base) return;
    // The colour page was removed; always show the source pixels.
    name = @"natural";
    if (!name.length || [name isEqualToString:@"natural"]) { gMiniSightPet.image = base; return; }
    UIColor *tint = @{@"warm": [UIColor colorWithRed:1 green:0.62 blue:0.38 alpha:1],
                      @"cool": [UIColor colorWithRed:0.45 green:0.66 blue:1 alpha:1],
                      @"mint": [UIColor colorWithRed:0.45 green:0.92 blue:0.72 alpha:1],
                      @"rose": [UIColor colorWithRed:1 green:0.6 blue:0.75 alpha:1]}[name];
    if (!tint) { gMiniSightPet.image = base; return; }
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:base.size];
    gMiniSightPet.image = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [base drawAtPoint:CGPointZero];
        // sourceAtop tints only opaque sprite pixels, never the transparent
        // gaps between frames (plain Color blend filled a coloured rectangle).
        CGContextSetBlendMode(ctx.CGContext, kCGBlendModeSourceAtop);
        CGContextSetFillColorWithColor(ctx.CGContext, tint.CGColor);
        UIRectFillUsingBlendMode(CGRectMake(0, 0, base.size.width, base.size.height), kCGBlendModeSourceAtop);
    }];
}

static void MiniSightLoadCostume(NSString *file) {
    if (!gMiniSightContainer.length || !file.length) return;
    NSString *path = [gMiniSightContainer stringByAppendingPathComponent:
        [@"Documents/MiniSight/costumes" stringByAppendingPathComponent:file]];
    UIImage *img = [UIImage imageWithContentsOfFile:path];
    if (img) { gMiniSightTintBase = img; MiniSightApplyTint(MiniSightRuntimeConfig.shared.tint); }
}


static UIInterfaceOrientation MiniSightOrientation(void);
static void MiniSightUpdateGeometry(void);

static BOOL MiniSightGravityEnabled(void) {
    return gMiniSightPet != nil && gMiniSightGravityConfigured;
}

static void MiniSightRefreshGravityConfiguration(void) {
    // Configuration must not depend on whether the pet view has already been built.
    // Settings notifications can arrive before the next UI rebuild.
    gMiniSightGravityConfigured = MiniSightStyle() == 1 &&
        [MiniSightPref(@"minisight.gravity") boolValue];
    gMiniSightDiagnosticsEnabled = [MiniSightPref(@"minisight.diagnostics") boolValue];
    MSDiagConfigure(gMiniSightDiagnosticsEnabled, gMiniSightContainer);
    if (gMiniSightDiagnosticsEnabled) MSDiag(@"plugin %@ diagnostics on style=%ld", kMiniSightVersion, (long)MiniSightStyle());
    static NSDictionary *lastObserved;
    if (![lastObserved isEqualToDictionary:gMiniSightPreferences ?: @{}]) {
        lastObserved = [gMiniSightPreferences copy] ?: @{};
        MSDiagSettingsSnapshot(@"receive", @"plugin", lastObserved);
        MSDiagEvent(@"runtime", @"identity", @"ok", @{ @"source": @"plugin", @"version": kMiniSightVersion });
    }
}

static void MiniSightGravityDiagnostic(NSString *state, NSString *detail) {
    MSDiag(@"gravity %@ %@", state ?: @"", detail ?: @"");
    NSString *result = [@[@"unavailable", @"source-failed"] containsObject:state] ? @"failed" :
        ([@[@"disabled", @"deferred"] containsObject:state] ? @"skipped" :
         ([@[@"first-sample", @"shake"] containsObject:state] ? @"ok" : @"pending"));
    static NSString *lastState;
    static CFTimeInterval lastTime;
    CFTimeInterval now = CACurrentMediaTime();
    if (![lastState isEqualToString:state] || now - lastTime >= 10.0) {
        lastState = [state copy]; lastTime = now;
        MSDiagEvent(@"gravity", @"state", result, @{ @"source": @"plugin", @"reason": state ?: @"unknown", @"generation": @(gMiniSightMotionAttempt.generation), @"enabled": @(gMiniSightGravityConfigured), @"visible": @(gMiniSightWindow && !gMiniSightWindow.hidden), @"samples": @(gMiniSightGravitySampleCount) });
    }
    NSString *container = [MiniSightAppContainer() copy];
    if (!container.length) return;
    NSDictionary *entry = @{
        @"state": state ?: @"",
        @"detail": detail ?: @"",
        @"lowPower": @([NSProcessInfo processInfo].lowPowerModeEnabled),
        @"time": @([[NSDate date] timeIntervalSince1970])
    };
    dispatch_async(MiniSightActivityQueue(), ^{
        MSBridgeWrite(container, @"gravity-last.json", entry);
    });
}

static BOOL MiniSightReadScreenState(void) {
    NSCAssert([NSThread isMainThread], @"Screen state is main-thread owned");
    uint64_t raw = UINT64_MAX;
    uint32_t status = NOTIFY_STATUS_FAILED;
    if (gMiniSightScreenToken < 0) {
        int token = -1;
        status = notify_register_check(kMiniSightBlanked.UTF8String, &token);
        if (status == NOTIFY_STATUS_OK) gMiniSightScreenToken = token;
    }
    if (gMiniSightScreenToken >= 0) {
        status = notify_get_state(gMiniSightScreenToken, &raw);
        if (status != NOTIFY_STATUS_OK) {
            notify_cancel(gMiniSightScreenToken);
            gMiniSightScreenToken = -1;
        }
    }
    MSScreenState state = MSScreenReadResult(status == NOTIFY_STATUS_OK, raw);
    const BOOL changed = gMiniSightScreenKnown != state.known || gMiniSightScreenBlanked != state.blanked;
    gMiniSightScreenKnown = state.known;
    gMiniSightScreenBlanked = state.blanked;
    // A newly rebuilt pet also gets the current suspension state, not just transitions.
    [gMiniSightPet setSuspended:!state.known || state.blanked];
    if (changed || !state.known) {
        MSDiag(@"screen known=%d blanked=%d notify_status=%u", state.known, state.blanked, status);
    }
    return state.known;
}

static void MiniSightApplyGravitySample(double gx, double gy,
                                        double ux, double uy, double uz,
                                        MiniSightPetView *pet) {
    UIInterfaceOrientation orientation = MiniSightOrientation();
    MSPoint projected = MSGravityProject(gx, gy, (int)orientation);
    double sample = MSGravityRollFromProjected(projected.x);
    CFTimeInterval now = CACurrentMediaTime();
    double dt = gMiniSightGravityLastSampleTime > 0.0
        ? now - gMiniSightGravityLastSampleTime : 1.0 / 30.0;
    gMiniSightGravityLastSampleTime = now;
    gMiniSightGravityRoll = MSGravityFilter(gMiniSightGravityRoll, sample, dt);
    gMiniSightGravityRollValid = YES;
    pet.gravityRoll = gMiniSightGravityRoll;

    CGFloat magnitude = sqrt((CGFloat)(ux * ux + uy * uy + uz * uz));
    if (++gMiniSightGravitySampleCount == 1 || gMiniSightGravitySampleCount % 60 == 0) {
        MiniSightGravityDiagnostic(@"sample", [NSString stringWithFormat:
            @"generation=%lu received=%lu applied=%lu orientation=%ld projected=%.3f roll=%.3f shakeG=%.3f",
            gMiniSightMotionAttempt.generation, gMiniSightMotionAttempt.samples,
            (unsigned long)gMiniSightGravitySampleCount,
            (long)orientation, projected.x, gMiniSightGravityRoll, magnitude]);
    }
    if (MSGravityShakeShouldTrigger(magnitude, gMiniSightGravityShakeLatched) &&
        now - gMiniSightGravityLastImpulseTime > 0.75) {
        CGFloat direction = gMiniSightGravityRoll;
        if (fabs(direction) < 0.08) direction = (ux >= 0.0 ? 1.0 : -1.0);
        CGFloat strength = MSGravityShakeStrength(magnitude);
        [pet triggerGravityImpulseWithDirection:direction strength:strength];
        gMiniSightGravityShakeLatched = YES;
        gMiniSightGravityLastImpulseTime = now;
        MiniSightGravityDiagnostic(@"shake", [NSString stringWithFormat:@"g=%.2f", magnitude]);
        [MiniSightBlip playIfEnabled:MiniSightRuntimeConfig.shared.sound];
    } else if (MSGravityShakeShouldReset(magnitude, gMiniSightGravityShakeLatched)) {
        gMiniSightGravityShakeLatched = NO;
    }
}

static void MiniSightStopGravity(void) {
    NSCAssert([NSThread isMainThread], @"Motion UI must be stopped on main thread");
    ++gMiniSightMotionGeneration;
    MSMotionStop(&gMiniSightMotionAttempt);
    if (gMiniSightFirstSampleWatchdog) dispatch_block_cancel(gMiniSightFirstSampleWatchdog);
    gMiniSightFirstSampleWatchdog = nil;
    gMiniSightMotionRunning = NO;
    gMiniSightAccelerometerRunning = NO;
    gMiniSightLastAccelerationValid = NO;
    if (gMiniSightMotionManager.deviceMotionActive) {
        [gMiniSightMotionManager stopDeviceMotionUpdates];
    }
    if (gMiniSightMotionManager.accelerometerActive) {
        [gMiniSightMotionManager stopAccelerometerUpdates];
    }
    gMiniSightGravityRoll = 0.0;
    gMiniSightGravityRollValid = NO;
    gMiniSightGravityShakeLatched = NO;
    gMiniSightGravityLastImpulseTime = 0.0;
    gMiniSightGravityLastSampleTime = 0.0;
    gMiniSightGravitySampleCount = 0;
    if (gMiniSightPet) {
        BOOL wasOn = gMiniSightPet.gravityEnabled;
        gMiniSightPet.gravityEnabled = NO;
        gMiniSightPet.gravityRoll = 0.0;
        // 关掉后不再需要倾斜包络，收回多余留白（窗口存在时才跑布局）。
        if (wasOn && gMiniSightWindow) MiniSightUpdateGeometry();
    }
}

static BOOL MiniSightMotionGateOpen(void) {
    MSScreenState screen = { gMiniSightScreenKnown, gMiniSightScreenBlanked };
    return MSScreenAllowsMotion(screen,
        gMiniSightWindow && !gMiniSightWindow.hidden && gMiniSightPet != nil,
        MiniSightGravityEnabled());
}

static void MiniSightStartAccelerometerSource(void);

static void MiniSightFailMotionSource(unsigned long generation, NSString *reason, NSInteger errorCode) {
    if (generation != gMiniSightMotionAttempt.generation || !MiniSightMotionGateOpen()) return;
    if (gMiniSightFirstSampleWatchdog) dispatch_block_cancel(gMiniSightFirstSampleWatchdog);
    gMiniSightFirstSampleWatchdog = nil;
    [gMiniSightMotionManager stopDeviceMotionUpdates];
    [gMiniSightMotionManager stopAccelerometerUpdates];
    gMiniSightMotionRunning = NO;
    gMiniSightAccelerometerRunning = NO;
    BOOL fallback = MSMotionFail(&gMiniSightMotionAttempt, generation,
                                gMiniSightMotionManager.isAccelerometerAvailable);
    MiniSightGravityDiagnostic(@"source-failed", [NSString stringWithFormat:
        @"generation=%lu reason=%@ code=%ld fallback=%d", generation, reason, (long)errorCode, fallback]);
    if (fallback) MiniSightStartAccelerometerSource();
    else {
        gMiniSightGravityRoll = 0;
        gMiniSightPet.gravityRoll = 0;
        MiniSightGravityDiagnostic(@"unavailable", @"sources exhausted; toggle or show again to retry");
        MiniSightShowStatusLine(@"重力没有收到传感器数据，请重新开关重力再试");
    }
}

static void MiniSightArmFirstSampleWatchdog(unsigned long generation) {
    if (gMiniSightFirstSampleWatchdog) dispatch_block_cancel(gMiniSightFirstSampleWatchdog);
    gMiniSightFirstSampleWatchdog = dispatch_block_create((dispatch_block_flags_t)0, ^{
        if (MSMotionFirstSampleDeadline(&gMiniSightMotionAttempt, generation) && MiniSightMotionGateOpen()) {
            MiniSightFailMotionSource(generation, @"first-sample-timeout", 0);
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), gMiniSightFirstSampleWatchdog);
}

static MiniSightPetView *MiniSightAcceptMotionSample(unsigned long generation, MSMotionSource source) {
    if (!MSMotionAccepts(&gMiniSightMotionAttempt, generation, source, MiniSightMotionGateOpen())) return nil;
    if (gMiniSightMotionAttempt.samples++ == 0) {
        if (gMiniSightFirstSampleWatchdog) dispatch_block_cancel(gMiniSightFirstSampleWatchdog);
        gMiniSightFirstSampleWatchdog = nil;
        MiniSightGravityDiagnostic(@"first-sample", [NSString stringWithFormat:
            @"generation=%lu source=%ld", generation, (long)source]);
    }
    return gMiniSightPet;
}

static void MiniSightStartAccelerometerSource(void) {
    const unsigned long generation = gMiniSightMotionAttempt.generation;
    if (!MSMotionAccepts(&gMiniSightMotionAttempt, generation, MSMotionSourceAccelerometer,
                        MiniSightMotionGateOpen())) return;
    gMiniSightLastAccelerationValid = NO;
    gMiniSightAccelerometerRunning = YES;
    gMiniSightMotionManager.accelerometerUpdateInterval = 1.0 / 30.0;
    MiniSightArmFirstSampleWatchdog(generation);
    MiniSightGravityDiagnostic(@"started", [NSString stringWithFormat:
        @"accelerometer generation=%lu", generation]);
    [gMiniSightMotionManager startAccelerometerUpdatesToQueue:NSOperationQueue.mainQueue
        withHandler:^(CMAccelerometerData *data, NSError *error) {
        if (!MSMotionAccepts(&gMiniSightMotionAttempt, generation, MSMotionSourceAccelerometer,
                            MiniSightMotionGateOpen())) return;
        if (error) { MiniSightFailMotionSource(generation, @"accelerometer-error", error.code); return; }
        if (!data) return;
        MiniSightPetView *pet = MiniSightAcceptMotionSample(generation, MSMotionSourceAccelerometer);
        if (!pet) return;
        CMAcceleration a = data.acceleration;
        double ux = 0., uy = 0., uz = 0.;
        if (gMiniSightLastAccelerationValid) {
            ux = a.x - gMiniSightLastAcceleration.x;
            uy = a.y - gMiniSightLastAcceleration.y;
            uz = a.z - gMiniSightLastAcceleration.z;
        }
        gMiniSightLastAcceleration = a;
        gMiniSightLastAccelerationValid = YES;
        MiniSightApplyGravitySample(a.x, a.y, ux, uy, uz, pet);
    }];
}

static void MiniSightStartGravity(void) {
    NSCAssert([NSThread isMainThread], @"Motion UI must start on main thread");
    MiniSightReadScreenState();
    if (!MiniSightGravityEnabled()) {
        MiniSightGravityDiagnostic(@"disabled", [NSString stringWithFormat:
            @"style=%ld enabled=%d pet=%d", (long)MiniSightStyle(),
            [MiniSightPref(@"minisight.gravity") boolValue], gMiniSightPet != nil]);
        MiniSightStopGravity();
        return;
    }
    if (!MiniSightMotionGateOpen()) {
        MiniSightGravityDiagnostic(@"deferred", [NSString stringWithFormat:
            @"window=%d hidden=%d blanked=%d known=%d", gMiniSightWindow != nil,
            gMiniSightWindow ? gMiniSightWindow.hidden : YES, gMiniSightScreenBlanked, gMiniSightScreenKnown]);
        MiniSightStopGravity();
        return;
    }
    if (gMiniSightMotionAttempt.source == MSMotionSourceFailed) return;
    if (gMiniSightMotionRunning || gMiniSightAccelerometerRunning) return;
    if (!gMiniSightMotionManager) gMiniSightMotionManager = [[CMMotionManager alloc] init];
    BOOL wasOn = gMiniSightPet.gravityEnabled;
    gMiniSightPet.gravityEnabled = YES;
    if (!wasOn) MiniSightUpdateGeometry();
    MSMotionStart(&gMiniSightMotionAttempt, gMiniSightMotionManager.isDeviceMotionAvailable,
                  gMiniSightMotionManager.isAccelerometerAvailable);
    if (gMiniSightMotionAttempt.source == MSMotionSourceFailed) {
        MiniSightGravityDiagnostic(@"unavailable", @"deviceMotion=0 accelerometer=0");
        MiniSightShowStatusLine(@"重力已开，但运动传感器不可用");
        return;
    }
    if (gMiniSightMotionAttempt.source == MSMotionSourceAccelerometer) {
        MiniSightStartAccelerometerSource();
        return;
    }
    const unsigned long generation = gMiniSightMotionAttempt.generation;
    gMiniSightMotionRunning = YES;
    gMiniSightMotionManager.deviceMotionUpdateInterval = 1.0 / 30.0;
    MiniSightArmFirstSampleWatchdog(generation);
    MiniSightGravityDiagnostic(@"started", [NSString stringWithFormat:
        @"deviceMotion generation=%lu", generation]);
    [gMiniSightMotionManager startDeviceMotionUpdatesToQueue:NSOperationQueue.mainQueue
        withHandler:^(CMDeviceMotion *motion, NSError *error) {
        if (!MSMotionAccepts(&gMiniSightMotionAttempt, generation, MSMotionSourceDevice,
                            MiniSightMotionGateOpen())) return;
        if (error) { MiniSightFailMotionSource(generation, @"deviceMotion-error", error.code); return; }
        if (!motion) return;
        MiniSightPetView *pet = MiniSightAcceptMotionSample(generation, MSMotionSourceDevice);
        if (!pet) return;
        CMAcceleration a = motion.userAcceleration;
        MiniSightApplyGravitySample(motion.gravity.x, motion.gravity.y, a.x, a.y, a.z, pet);
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
        CGFloat inset = gMiniSightWindow.safeAreaInsets.bottom + gMiniSightBottomGap;
        if (inset > 0.5) return inset;
    }
    return 8.0 + gMiniSightBottomGap;
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
static void MiniSightApplyRuntimeConfig(void) {
    MiniSightRuntimeConfig *c = MiniSightRuntimeConfig.shared;
    if (gMiniSightPet) {
        CGFloat size = MiniSightPetSize();
        if (fabs(gMiniSightPet.bounds.size.width - size) > 0.5) {
            gMiniSightPet.bounds = CGRectMake(0, 0, size, size);
        }
        gMiniSightPet.roamPace = c.activity == 0 ? 0.6 : (c.activity == 1 ? 3.0 : 0.0);
        gMiniSightPet.roamInterval = c.activity == 2 ? 0 : c.activityInterval;
        gMiniSightPet.gravityStrength = MSClamp(c.gravityStrength, 0.4, 1.6);
        gMiniSightPet.preferredFPS = c.frameLimit == 1 ? 30 : (c.frameLimit == 2 ? 60 : (c.frameLimit == 3 ? 120 : 0));
        gMiniSightPet.activityActive = YES;
        gMiniSightPet.soundEnabled = c.sound;
    }
    gMiniSightBubbleScale = MSClamp(c.bubbleScale, 0.8, 1.6);
    gMiniSightTextScale = MSClamp(c.textScale, 0.8, 1.6);
    gMiniSightDwell = MSClamp(c.dwell, 0.5, 3.0);
    if (gMiniSightBubble && !gMiniSightBubble.hidden && gMiniSightBubbleText.length)
        MiniSightShowBubbleWidth(gMiniSightBubbleText, 260.0, 600);
    gMiniSightBottomGap = MSClamp(c.bottomGap, 0, 40);
    if (c.costume.length) MiniSightLoadCostume(c.costume);
    MiniSightApplyTint(c.tint);
    MiniSightUpdateGeometry();
}

static void MiniSightRefreshChatAnchor(void) {
    MiniSightChatPanel *panel = MiniSightChatPanel.existingPanel;
    if (!panel || !panel.isVisible) return;
    panel.anchorView = gMiniSightPet ?: gMiniSightPill;
    [panel refreshAnchorLocation];
}

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
    MiniSightRefreshChatAnchor();

    if (save) {
        MSMiniSightSetPreference(kMiniSightCenterX, @(center.x));
        MSMiniSightSetPreference(kMiniSightCenterY, @(center.y));
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
static BOOL MiniSightOpenChat(void);
static void MiniSightSayPresetLine(void);
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

static BOOL MiniSightGestureEnabled(NSString *key) {
    if (!MiniSightRuntimeConfig.shared.interaction) return NO;
    NSString *action = [key isEqualToString:@"singleTap"] ? MiniSightRuntimeConfig.shared.singleTap
        : ([key isEqualToString:@"doubleTap"] ? MiniSightRuntimeConfig.shared.doubleTap
                                              : MiniSightRuntimeConfig.shared.longPress);
    return action.length && ![action isEqualToString:@"none"];
}

static void MiniSightRunGesture(NSString *action, BOOL allowSecondTap) {
    MiniSightChatPanel *panel = MiniSightChatPanel.existingPanel;
    if ([action isEqualToString:@"input"]) {
        if (!MiniSightOpenChat()) return;
        [MiniSightChatPanel.existingPanel showInput]; return;
    }
    if ([action isEqualToString:@"conversation"]) { MiniSightOpenChat(); return; }
    if ([action isEqualToString:@"voice"]) {
        if (!MiniSightOpenChat()) return;
        [MiniSightChatPanel.existingPanel beginVoiceInput]; return;
    }
    if ([action isEqualToString:@"menu"]) {
        if (!MiniSightOpenChat()) return;
        [MiniSightChatPanel.existingPanel showMenu]; return;
    }
    if ([action isEqualToString:@"record"]) { MiniSightToggleRecording(); return; }
    if (allowSecondTap && panel.isVisible && !panel.sending) { [panel revealComposerIfNeeded]; return; }
    MiniSightSayPresetLine();
}

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
            [MiniSightBlip playIfEnabled:MiniSightRuntimeConfig.shared.sound];
            if (gMiniSightPet) [gMiniSightPet beginDraggingWithDirection:1];
            MSDiagEvent(@"drag", @"begin", @"ok", @{ @"source": @"plugin", @"x": @(origin.x), @"y": @(origin.y) });
            MiniSightInteractionBegin();
            break;
        }
        case UIGestureRecognizerStateChanged: {
            if (!gMiniSightDragOriginValid) break; // 防御异常的无 Began 回调
            if (gMiniSightPet && fabs(translation.x) > 4)
                [gMiniSightPet beginDraggingWithDirection:translation.x];
            CGFloat gain = MiniSightRuntimeConfig.shared.dragResponse ? 1.0 : 0.20;
            CGPoint want = CGPointMake(gMiniSightDragOrigin.x + translation.x * gain,
                                       gMiniSightDragOrigin.y + translation.y * gain);
            MiniSightSetAnchor(want, NO);
            break;
        }
        case UIGestureRecognizerStateEnded: {
            if (gMiniSightDragOriginValid) {
                // Ended 也可能带最后一段 translation。必须沿用与 Changed
                // 相同的增益，否则关掉「增强拖动响应」后松手会突然跳到全速位置。
                CGFloat gain = MiniSightRuntimeConfig.shared.dragResponse ? 1.0 : 0.20;
                CGPoint want = CGPointMake(gMiniSightDragOrigin.x + translation.x * gain,
                                           gMiniSightDragOrigin.y + translation.y * gain);
                // 保持 dragging 到 SetAnchor 完成，避免气泡让位把刚拖到的中心改掉。
                MiniSightSetAnchor(want, YES); // 只有用户拖动才写盘
                MSDiagEvent(@"drag", @"end", @"ok", @{ @"source": @"plugin", @"x": @(gMiniSightAnchor.x), @"y": @(gMiniSightAnchor.y) });
            }
            gMiniSightDragOriginValid = NO;
            gMiniSightDragging = NO;
            [gMiniSightPet endDragging];
            MiniSightInteractionEnd();
            break;
        }
        default:   // Cancelled / Failed：当前位置保留，但本次不写盘
            gMiniSightDragOriginValid = NO;
            gMiniSightDragging = NO;
            [gMiniSightPet endDragging];
            MiniSightInteractionEnd();
            break;
    }
}

/// 旋转：界面方向变化是异步的，稍等一下再重算并 clamp
- (void)handleSingleTap:(UITapGestureRecognizer *)tap {
    (void)tap;
    [MiniSightBlip playIfEnabled:MiniSightRuntimeConfig.shared.sound];
    if (!MiniSightGestureEnabled(@"singleTap")) {
        MSDiagEvent(@"gesture", @"single", @"skipped", @{ @"reason": @"disabled" });
        return;
    }
    MSDiagEvent(@"gesture", @"single", @"ok", @{ @"action": MiniSightRuntimeConfig.shared.singleTap ?: @"" });
    MiniSightRunGesture(MiniSightRuntimeConfig.shared.singleTap, YES);
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)tap {
    (void)tap;
    [MiniSightBlip playIfEnabled:MiniSightRuntimeConfig.shared.sound];
    if (!MiniSightGestureEnabled(@"doubleTap")) {
        MSDiagEvent(@"gesture", @"double", @"skipped", @{ @"reason": @"disabled" });
        return;
    }
    MSDiagEvent(@"gesture", @"double", @"ok", @{ @"action": MiniSightRuntimeConfig.shared.doubleTap ?: @"" });
    UIImpactFeedbackGenerator *feedback =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [feedback impactOccurred];
    MiniSightRunGesture(MiniSightRuntimeConfig.shared.doubleTap, NO);
}

/// 长按：手势由宿主拥有（不是桌宠内部），所以漫游动画期间也按得住。
/// 设置里「长按指示器切换录屏」关掉时，这里完全不响应。
- (void)handleLongPress:(UILongPressGestureRecognizer *)press {
    switch (press.state) {
        case UIGestureRecognizerStateBegan:
            // The current switch is checked asynchronously by the plugin entry.
            MiniSightInteractionBegin();
            [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
            [MiniSightBlip playIfEnabled:MiniSightRuntimeConfig.shared.sound];
            if (!MiniSightGestureEnabled(@"longPress")) {
                MSDiagEvent(@"gesture", @"long", @"skipped", @{ @"reason": @"disabled" });
                break;
            }
            MSDiagEvent(@"gesture", @"long", @"ok", @{ @"action": MiniSightRuntimeConfig.shared.longPress ?: @"" });
            if ([MiniSightRuntimeConfig.shared.longPress isEqualToString:@"record"]) MiniSightToggleRecording();
            else MiniSightRunGesture(MiniSightRuntimeConfig.shared.longPress, NO);
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
        gMiniSightPet.reducedWork = low; // Extend idle roaming delay; keep enabled sensor input.
        if (!low && gMiniSightWindow && !gMiniSightWindow.hidden) MiniSightStartGravity();
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
        NSNumber *savedX = MSMiniSightPreference(kMiniSightCenterX);
        NSNumber *savedY = MSMiniSightPreference(kMiniSightCenterY);
        if ([savedX respondsToSelector:@selector(doubleValue)] &&
            [savedY respondsToSelector:@selector(doubleValue)]) {
            center = CGPointMake(savedX.doubleValue, savedY.doubleValue);
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
        MiniSightChatPanel *panel = MiniSightChatPanel.existingPanel;
        panel.containerPath = gMiniSightContainer;
        panel.appearancePreferences = gMiniSightPreferences;
        gMiniSightShown = shown;
        gMiniSightAtlas = atlas;
        gMiniSightTintBase = atlas;
        NSInteger spriteLayout = MiniSightSpriteLayoutForContainer(container);
        MSDiagEvent(@"assets", @"layout", @"ok", @{ @"source": @"plugin", @"layout": @(spriteLayout), @"container": @(container.length > 0) });
        if (gMiniSightPet) {
            gMiniSightPet.spriteLayout = spriteLayout;
            if (atlas) {
                gMiniSightPet.image = atlas;
                MiniSightApplyTint(MiniSightRuntimeConfig.shared.tint);
            }
        }
        [MiniSightRuntimeConfig.shared reloadWithContainer:container];
        MSDiagConfigure([preferences[@"minisight.diagnostics"] boolValue], container);
        MSDiagSettingsSnapshot(@"receive", @"plugin", gMiniSightPreferences);
        MSDiagEvent(@"assets", @"load", atlas ? @"ok" : @"skipped", @{ @"source": @"plugin", @"setting": @"pet", @"reason": atlas ? @"atlas_decoded" : @"missing_or_invalid_atlas" });
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

static NSTimer *gMiniSightSettingsWatch = nil;
static NSString *gMiniSightWatchedRevision = nil;

/// The Darwin notification can be missed while SpringBoard is busy. Watch the
/// revision the App writes (and the shown file) so size/visibility still apply
/// within half a second. Reads two small files, no atlas work.
static void MiniSightStartSettingsWatch(void) {
    [gMiniSightSettingsWatch invalidate];
    gMiniSightSettingsWatch = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        if (!gMiniSightContainer.length) return;
        NSString *snapPath = [gMiniSightContainer stringByAppendingPathComponent:@"Documents/MiniSight/runtime.json"];
        NSData *snapData = [NSData dataWithContentsOfFile:snapPath];
        NSDictionary *snap = snapData ? [NSJSONSerialization JSONObjectWithData:snapData options:0 error:nil] : nil;
        NSString *revision = [snap[@"revision"] isKindOfClass:NSString.class] ? snap[@"revision"] : nil;
        NSString *shownPath = [gMiniSightContainer stringByAppendingPathComponent:@"Documents/MiniSight/shown"];
        NSString *shownText = [NSString stringWithContentsOfFile:shownPath encoding:NSUTF8StringEncoding error:nil];
        BOOL shown = ![shownText isEqualToString:@"0"];
        if (!gMiniSightWatchedRevision.length) {
            gMiniSightWatchedRevision = [revision copy];
            return;
        }
        BOOL revisionChanged = revision && ![revision isEqualToString:gMiniSightWatchedRevision];
        if (!revisionChanged && shown == gMiniSightShown) return;
        MSDiagEvent(@"settings", @"change", @"pending", @{ @"source": @"plugin", @"revision": revision ?: @"none", @"shown": @(shown) });
        gMiniSightWatchedRevision = [revision copy];
        MiniSightReloadSettings();
    }];
    [NSRunLoop.mainRunLoop addTimer:gMiniSightSettingsWatch forMode:NSRunLoopCommonModes];
}

static void MiniSightStopSettingsWatch(void) {
    [gMiniSightSettingsWatch invalidate];
    gMiniSightSettingsWatch = nil;
    gMiniSightWatchedRevision = nil;
}

static void MiniSightBuildUI(void) {
    NSCAssert([NSThread isMainThread], @"MiniSight UI must be built on main thread");
    if (!gMiniSightResourcesReady) {
        MiniSightRequestResources(NO, ^{ MiniSightBuildUI(); });
        return;
    }
    if (gMiniSightBuilt) return;
    gMiniSightBuilt = YES;
    MiniSightStartSettingsWatch();

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
            MiniSightRefreshChatAnchor();
        };
        gMiniSightPet.longPressEnabled = MiniSightLongPressEnabled();
        NSInteger builtLayout = MiniSightSpriteLayoutForContainer(gMiniSightContainer);
        gMiniSightPet.spriteLayout = builtLayout;
        MSDiagEvent(@"assets", @"layout", @"ok", @{ @"source": @"plugin", @"layout": @(builtLayout), @"reason": @"build" });
        NSString *variantPath = [gMiniSightContainer stringByAppendingPathComponent:@"Documents/MiniSight/variant"];
        gMiniSightPet.variantIndex = [[NSString stringWithContentsOfFile:variantPath encoding:NSUTF8StringEncoding error:nil] integerValue];
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

static void MiniSightTracePresentationGate(NSString *reason) {
    static NSString *last;
    NSString *stamp = [NSString stringWithFormat:@"%@|%@", MiniSightPref(@"minisight.settings.revision") ?: @"none", reason];
    if ([last isEqualToString:stamp]) return;
    last = stamp;
    NSMutableDictionary *fields = [@{@"source": @"plugin", @"reason": reason, @"renderer": @(MiniSightRenderer()), @"style": @(MiniSightStyle()), @"mode": @(MiniSightAlwaysShow())} mutableCopy];
    if (MiniSightPref(@"minisight.settings.revision")) fields[@"revision"] = MiniSightPref(@"minisight.settings.revision");
    MSDiagEvent(@"runtime", @"show", @"skipped", fields);
}

static void MiniSightShow(void) {
    // Call mode is driven only by an active MCP-owned burst. A stray show
    // notification or stale status must never wake the pet while idle.
    if (!MiniSightAlwaysShow() && !gMiniSightBurst) { MiniSightTracePresentationGate(@"idle_call_mode"); return; }
    if (!gMiniSightResourcesReady) {
        MiniSightRequestResources(NO, ^{ MiniSightShow(); });
        return;
    }
    MiniSightRefreshAppOwnership(^{
        if (MiniSightAppOwnsPresentation()) {
            MiniSightTracePresentationGate(@"app_owns_presentation");
            [[MiniSightChatPanel existingPanel] hideWithoutKey];
            MiniSightStopGravity();
            if (gMiniSightWindow) gMiniSightWindow.hidden = YES;
            return;
        }
        MiniSightShowAfterOwnershipCheck();
    });
}

static void MiniSightShowAfterOwnershipCheck(void) {
    if (!MiniSightShown()) { MiniSightTracePresentationGate(@"user_hidden"); return; }
    // Call mode is driven only by an active MCP-owned burst. A stray show
    // notification or stale status must never wake the pet while idle.
    if (!MiniSightAlwaysShow() && !gMiniSightBurst) { MiniSightTracePresentationGate(@"idle_call_mode"); return; }
    if (!gMiniSightResourcesReady) {
        MiniSightRequestResources(NO, ^{ MiniSightShow(); });
        return;
    }
    if (gMiniSightUserHidden) {
        gMiniSightUserHidden = NO;
        MSMiniSightSetPreference(@"MiniSightUserHidden", @NO);
    }
    MiniSightBuildUI();
    if (!gMiniSightWindow) { MiniSightTracePresentationGate(@"host_build_failed"); return; }

    // SpringBoard 重启或场景切换后窗口可能掉出 scene，重新挂一次
    if (@available(iOS 13.0, *)) {
        if (!gMiniSightWindow.windowScene) {
            UIWindowScene *scene = MiniSightFindScene();
            if (scene) gMiniSightWindow.windowScene = scene;
        }
    }

    // 重力包络参与布局，必须在第一次 UpdateGeometry 前设置。
    gMiniSightAppliedRenderer = MiniSightRenderer();
    gMiniSightAppliedStyle = MiniSightStyle();
    gMiniSightPet.gravityEnabled = MiniSightGravityEnabled();
    MiniSightUpdateGeometry();
    MiniSightApplySavedCenter(YES);
    MiniSightApplyRuntimeConfig();
    MiniSightStartPulse();
    // 每次显示都按当前设置刷新：长按开关、低电量省电、调用期间才有走动
    gMiniSightPet.longPressEnabled = MiniSightLongPressEnabled();
    gMiniSightPet.reducedWork = [NSProcessInfo processInfo].lowPowerModeEnabled;
    gMiniSightPet.activityActive = YES;
    [gMiniSightPet startPlaying];
    MiniSightInstallRecorderCallbacks();

    // 先透明再取消 hidden，然后 0.18s 淡入
    gMiniSightWindow.alpha = 0.0;
    MSDiagEvent(@"runtime", @"show", @"ok", @{ @"source": @"plugin", @"size": @(MiniSightPetSize()), @"layout": @(gMiniSightPet.spriteLayout) });
    gMiniSightWindow.hidden = NO;
    MiniSightStartGravity();
    MSDiagEvent(@"runtime", @"show", @"ok", @{ @"source": @"plugin", @"visible": @YES, @"style": @(MiniSightStyle()) });
    NSString *revision = [MiniSightPref(@"minisight.settings.revision") isKindOfClass:NSString.class] ? MiniSightPref(@"minisight.settings.revision") : @"legacy";
    for (NSString *key in @[@"minisight.style", @"minisight.mode", @"minisight.petSize", @"minisight.longPress"]) {
        BOOL missingPet = MiniSightStyle() == 1 && !gMiniSightPet;
        BOOL available = !missingPet || [key isEqualToString:@"minisight.mode"];
        MSDiagEvent(@"settings", @"configure", available ? @"ok" : @"skipped", @{ @"setting": key, @"source": @"plugin", @"revision": revision, @"visible": @YES, @"reason": missingPet ? @"pet_unavailable_capsule_fallback" : @"host_configured", @"style": @(gMiniSightPet ? 1 : 0) });
    }
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
    [[MiniSightChatPanel existingPanel] hideWithoutKey];
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
    [[MiniSightChatPanel existingPanel] hideWithoutKey];
    MiniSightChatPanel.existingPanel.anchorView = nil;
    gMiniSightPet.onGeometryChanged = nil;
    MSDiagEvent(@"runtime", @"hide", @"ok", @{ @"source": @"plugin", @"reason": @"destroy" });
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
    MSDiagEvent(@"runtime", @"hide", @"ok", @{ @"source": @"plugin" });
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
static void MiniSightApplySettingsLive(void) {
    if (!gMiniSightWindow) {
        if (MiniSightShown() && !MiniSightAppOwnsPresentation()) MiniSightShow();
        return;
    }
    if (gMiniSightContainer.length) {
        NSString *shownPath = [gMiniSightContainer stringByAppendingPathComponent:@"Documents/MiniSight/shown"];
        NSString *t = [NSString stringWithContentsOfFile:shownPath encoding:NSUTF8StringEncoding error:nil];
        gMiniSightShown = ![t isEqualToString:@"0"];
    }
    NSInteger appearanceMode = MiniSightRuntimeConfig.shared.darkMode;
    gMiniSightWindow.overrideUserInterfaceStyle =
        appearanceMode == 1 ? UIUserInterfaceStyleLight
        : (appearanceMode == 2 ? UIUserInterfaceStyleDark : UIUserInterfaceStyleUnspecified);
    MiniSightChatPanel *panel = MiniSightChatPanel.existingPanel;
    panel.appearancePreferences = gMiniSightPreferences ?: @{};
    if (!MiniSightShown() || MiniSightAppOwnsPresentation()) { MiniSightHide(); return; }
    BOOL wasVisible = gMiniSightWindow && !gMiniSightWindow.hidden;
    if (MiniSightAlwaysShow()) {
        if (!wasVisible) { MiniSightShow(); return; }
    } else if (!gMiniSightBurst) {
        if (wasVisible) MiniSightHide();
        MiniSightBuildUI();
        return;
    }
    if (gMiniSightPet) {
        gMiniSightPet.gravityEnabled = MiniSightGravityEnabled();
        gMiniSightPet.longPressEnabled = MiniSightLongPressEnabled();
        gMiniSightPet.interactionActive = NO;
        gMiniSightPet.reducedWork = [NSProcessInfo processInfo].lowPowerModeEnabled;
    }
    MiniSightApplyRuntimeConfig();
    MSDiagEvent(@"settings", @"apply", @"ok", @{ @"source": @"plugin",
        @"size": @(MiniSightPetSize()), @"interval": @(MiniSightRuntimeConfig.shared.activityInterval),
        @"bubble": @(MiniSightRuntimeConfig.shared.bubbleScale),
        @"text": @(MiniSightRuntimeConfig.shared.textScale),
        @"gravity": @(MiniSightRuntimeConfig.shared.gravityStrength),
        @"sound": @(MiniSightRuntimeConfig.shared.sound), @"shown": @(MiniSightShown()) });
    MiniSightRefreshChatAnchor();
}

static void MiniSightReloadSettings(void) {
    // Preferences-only refresh. The old path forced a full atlas request and
    // destroyed the window before a rebuild, which is what made every switch
    // take 10+ seconds. Only a renderer/style change needs that rebuild.
    [MiniSightResources refreshPreferences:^(NSString *container, NSDictionary *preferences) {
        if (container.length) gMiniSightContainer = [container copy];
        gMiniSightPreferences = [preferences copy] ?: @{};
        if (container.length) {
            NSString *shownPath = [container stringByAppendingPathComponent:@"Documents/MiniSight/shown"];
            NSString *shownText = [NSString stringWithContentsOfFile:shownPath encoding:NSUTF8StringEncoding error:nil];
            gMiniSightShown = ![shownText isEqualToString:@"0"];
        }
        [MiniSightRuntimeConfig.shared reloadWithContainer:gMiniSightContainer];
        MiniSightConfigureRecorder();
        MSDiagSettingsSnapshot(@"receive", @"plugin", gMiniSightPreferences);
        MSDiagEvent(@"settings", @"reload", @"ok", @{ @"source": @"plugin", @"reason": @"darwin_notification" });

        NSInteger renderer = MiniSightRenderer();
        NSInteger style = MiniSightStyle();
        BOOL structural = renderer != gMiniSightAppliedRenderer || style != gMiniSightAppliedStyle;
        if (structural) {
            gMiniSightAppliedRenderer = renderer;
            gMiniSightAppliedStyle = style;
            BOOL shouldShow = gMiniSightBurst || MiniSightAlwaysShow();
            MiniSightStopGravity();
            MiniSightDestroyUI();
            MiniSightRequestResources(YES, ^{
                if (!MiniSightShown() || MiniSightAppOwnsPresentation()) return;
                if (shouldShow) MiniSightShow(); else MiniSightBuildUI();
            });
            return;
        }
        MiniSightApplySettingsLive();
    }];
}

#pragma mark - 说话气泡（只在 MCP 调用时）

static void MiniSightHideBubble(void) {
    if (gMiniSightConfirming) return;
    gMiniSightBubble.hidden = YES;
    gMiniSightBubbleShown = NO;
    gMiniSightBubbleExpanded = NO;
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
        gMiniSightBubbleLayoutSize = layoutSize;
        gMiniSightBubbleLayoutContentHeight = gMiniSightBubbleContentHeight;
        gMiniSightBubbleLayoutValid = YES;
    }
    // The bar is created AFTER the first sizing pass, so a same-size second
    // pass used to skip this and leave its frame at zero until the pet moved.
    if (gMiniSightConfirming && gMiniSightConfirmBar) {
        gMiniSightConfirmBar.frame = CGRectMake(10.0, box.h - 40.0, box.w - 20.0, 30.0);
        [gMiniSightBubble bringSubviewToFront:gMiniSightConfirmBar];
        gMiniSightConfirmBar.hidden = NO;
        [gMiniSightConfirmBar setNeedsLayout];
        [gMiniSightConfirmBar layoutIfNeeded];
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

/// Tap the bubble itself to expand it to the screen width (and back).
@interface MiniSightBubbleTapTarget : NSObject
@end
@implementation MiniSightBubbleTapTarget
- (void)toggleBubbleSize:(UITapGestureRecognizer *)tap {
    if (tap.state != UIGestureRecognizerStateEnded) return;
    gMiniSightBubbleExpanded = !gMiniSightBubbleExpanded;
    if (gMiniSightBubbleText.length) MiniSightShowBubbleWidth(gMiniSightBubbleText, 260.0, 600);
}
@end
static MiniSightBubbleTapTarget *gMiniSightBubbleTapTarget = nil;

static void MiniSightShowBubbleWidth(NSString *raw, CGFloat maxW, NSUInteger cap) {
    UIView *host = gMiniSightPet ?: gMiniSightPill;
    UIView *root = gMiniSightWindow.rootViewController.view;
    if (!host || !root || ![raw isKindOfClass:NSString.class]) return;
    if (MiniSightChatPanel.existingPanel.isVisible && !gMiniSightConfirming) return;
    NSString *text = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length) { MiniSightHideBubble(); return; }
    if (cap > 0 && text.length > cap)
        text = [[text substringWithRange:[text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, cap)]] stringByAppendingString:@"…"];

    if (!gMiniSightBubble) {
        UIView *b = [[UIView alloc] init];
        b.backgroundColor = [UIColor systemBackgroundColor];
        b.layer.cornerRadius = 18;
        b.layer.cornerCurve = kCACornerCurveContinuous;
        b.layer.borderWidth = 0.5;
        b.layer.borderColor = [UIColor separatorColor].CGColor;
        b.userInteractionEnabled = YES;
        b.hidden = YES;

        UIScrollView *scroll = [[UIScrollView alloc] init];
        scroll.backgroundColor = UIColor.clearColor;
        scroll.showsHorizontalScrollIndicator = NO;
        scroll.showsVerticalScrollIndicator = YES;
        scroll.alwaysBounceVertical = NO;
        scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        UILabel *l = [[UILabel alloc] init];
        l.font = [UIFont systemFontOfSize:14. * gMiniSightTextScale];
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

        if (!gMiniSightBubbleTapTarget) gMiniSightBubbleTapTarget = [MiniSightBubbleTapTarget new];
        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:gMiniSightBubbleTapTarget
                                                   action:@selector(toggleBubbleSize:)];
        [b addGestureRecognizer:tap];
        [root addSubview:b];
        gMiniSightBubble = b;
    }

    gMiniSightBubble.hidden = NO;
    gMiniSightBubbleShown = YES;
    gMiniSightBubble.backgroundColor = [UIColor systemBackgroundColor];
    gMiniSightBubbleLabel.textColor = [UIColor labelColor];
    gMiniSightBubbleTail.fillColor = [UIColor systemBackgroundColor].CGColor;
    gMiniSightBubbleText = text;
    gMiniSightBubbleLabel.text = text;

    CGFloat screenW = root.bounds.size.width;
    // Panel, not a tooltip: short lines stay compact, long text grows wider
    // and taller by itself; only past 42% of the screen does it scroll.
    CGFloat scaledMax = maxW * gMiniSightBubbleScale;
    CGFloat effectiveW = gMiniSightBubbleExpanded
        ? MAX(240.0, screenW - 32.0) : MIN(scaledMax, screenW - 32.0);
    CGFloat textWidth = MAX(1.0, effectiveW - 20.0);
    CGSize fit = [gMiniSightBubbleLabel sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)];
    gMiniSightBubbleContentHeight = ceil(MAX(fit.height, gMiniSightBubbleLabel.font.lineHeight));
    CGFloat minWidth = gMiniSightConfirming ? 180.0 : 44.0;
    CGFloat wanted = ceil(fit.width) + 24.0;
    CGFloat w = MIN(effectiveW, MAX(minWidth, wanted));
    CGFloat maxVisible = gMiniSightConfirming ? 180.0 : root.bounds.size.height * 0.34 * gMiniSightBubbleScale;
    CGFloat visibleTextHeight = MIN(gMiniSightBubbleContentHeight, maxVisible);
    CGFloat h = visibleTextHeight + (gMiniSightConfirming ? 52.0 : 16.0);
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
    gMiniSightBubbleExpanded = NO;
    MiniSightShowBubbleWidth(raw, 260.0, 600);
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
    MSDiagEvent(@"approval", @"answer", allow ? @"allow" : @"deny", @{ @"source": @"plugin" });
    gMiniSightConfirming = NO;
    if (gMiniSightConfirmTimeout) { dispatch_block_cancel(gMiniSightConfirmTimeout); gMiniSightConfirmTimeout = nil; }
    MiniSightWriteConfirmResult(allow);
    gMiniSightConfirmId = nil;
    gMiniSightConfirmBar.hidden = YES;
    gMiniSightBubble.userInteractionEnabled = NO;
    gMiniSightBubble.hidden = YES;
    gMiniSightBubbleShown = NO;
    gMiniSightBubbleExpanded = NO;
    // 确认态结束：把头顶空间收回普通值，桌宠可行范围也跟着还原
    MiniSightSetAnchor(gMiniSightAnchor, NO);
    if (!gMiniSightBurst && !MiniSightAlwaysShow()) MiniSightHide();
}

/// 读 confirm.json，把问题+命令塞进气泡，底下挂两个按钮。
static void MiniSightShowConfirm(void) {
    [[MiniSightChatPanel existingPanel] hideWithoutKey];
    if (!MiniSightShown() || (!MiniSightAlwaysShow() && !gMiniSightBurst)) {
        MSDiagEvent(@"approval", @"show", @"skipped", @{ @"reason": MiniSightShown() ? @"not_burst" : @"pet_hidden" });
        return;
    }
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
    MSDiagEvent(@"approval", @"show", @"ok", @{ @"source": @"plugin", @"chars": @([command length]) });
    if (![action isKindOfClass:NSString.class] || ![command isKindOfClass:NSString.class] ||
        [command lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 65536) {
        gMiniSightConfirmId = ident;
        gMiniSightConfirming = YES;
        MiniSightAnswerConfirm(NO);
        return;
    }
    NSString *text = action.length ? [NSString stringWithFormat:@"%@\n%@", action, command] : command;
    MiniSightShowBubbleWidth(text, 260.0, 600);

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
    if (gMiniSightBubbleShown) {
        NSString *ack = [container stringByAppendingPathComponent:@"Documents/MiniSight/confirm-shown.txt"];
        [ident writeToFile:ack atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }

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
    // The App owns the native approval UI; never stack a duplicate pet status bubble.
    if ([text isEqualToString:@"等待你确认"]) {
        MiniSightHideBubble(); // clear the old status too; do not dismiss an owned approval
        return;
    }
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * gMiniSightDwell * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), gMiniSightBubbleHideWork);
}

/// 诊断/状态行：比撒娇话长（最多 60 字），多留两秒才收
static void MiniSightShowStatusLine(NSString *text) {
    if (!text.length) return;
    if ((!gMiniSightWindow || gMiniSightWindow.hidden) && !gMiniSightBurst) return;
    MiniSightShowBubbleWidth(text, 260.0, 600);
    if (gMiniSightBubbleHideWork) { dispatch_block_cancel(gMiniSightBubbleHideWork); gMiniSightBubbleHideWork = nil; }
    if (gMiniSightBurst) return;
    gMiniSightBubbleHideWork = dispatch_block_create(DISPATCH_BLOCK_DETACHED, ^{
        MiniSightHideBubble();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * gMiniSightDwell * NSEC_PER_SEC)),
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

static BOOL MiniSightOpenChat(void) {
    if (!gMiniSightContainer.length || !gMiniSightWindow) {
        MiniSightSayPresetLine();
        return NO;
    }
    MiniSightChatPanel *panel = MiniSightChatPanel.sharedPanel;
    panel.containerPath = gMiniSightContainer;
    panel.appearancePreferences = gMiniSightPreferences ?: @{};
    panel.hidePetHandler = ^{ MiniSightUserHide(); };
    panel.anchorView = gMiniSightPet ?: gMiniSightPill;
    if (gMiniSightConfirming) {
        MSDiagEvent(@"chat", @"show", @"skipped", @{ @"reason": @"approval_visible" });
        return NO;
    }
    MiniSightHideBubble();
    MSDiagEvent(@"chat", @"entry", @"pending", @{ @"source": @"plugin_double_tap" });
    BOOL opened = [MiniSightChatPanel showInWindowScene:gMiniSightWindow.windowScene];
    if (!opened) MiniSightSayPresetLine();
    return opened;
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
        dispatch_async(dispatch_get_main_queue(), ^{ MiniSightRefreshRecorderSettingsThenReadActivity(); });
        return;
    }
    if ([note isEqualToString:kMiniSightBlanked]) {
        // Notifications may merge or repeat. Always read the current system value.
        dispatch_async(dispatch_get_main_queue(), ^{
            MiniSightReadScreenState();
            MSDiagEvent(@"screen", @"state", gMiniSightScreenKnown ? @"ok" : @"failed", @{ @"source": @"plugin", @"enabled": @(!gMiniSightScreenBlanked), @"valid": @(gMiniSightScreenKnown) });
            if (!gMiniSightScreenKnown || gMiniSightScreenBlanked) {
                [[MiniSightChatPanel existingPanel] hideWithoutKey];
                MiniSightStopGravity();
            }
            else if (gMiniSightWindow && !gMiniSightWindow.hidden) MiniSightStartGravity();
        });
        return;
    }
    if ([note isEqualToString:kMiniSightPluginProbe]) {
        dispatch_async(dispatch_get_main_queue(), ^{ MiniSightReplyToPluginProbe(); });
        return;
    }
    if ([note isEqualToString:kMiniSightAppActiveNote]) {
        dispatch_async(dispatch_get_main_queue(), ^{ MiniSightReconcileAppPresentation(); });
        return;
    }
    if ([note isEqualToString:kMiniSightSettingsChanged]) {
        // App 在发通知前已经写好 plist/runtime.json，读盘不再需要 0.25s 等待；
        // 立即回主线程应用，开关随拨随生效。
        dispatch_async(dispatch_get_main_queue(), ^{ MiniSightReloadSettings(); });
        return;
    }
    if ([note isEqualToString:kMiniSightResourcesChanged]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL visible = gMiniSightWindow && !gMiniSightWindow.hidden;
            [MiniSightResources releaseCachedAtlas];
            gMiniSightResourcesReady = NO;
            MiniSightRequestResources(YES, ^{
                if (!visible || MiniSightAppOwnsPresentation()) return;
                if (!gMiniSightWindow || gMiniSightWindow.hidden) MiniSightShow();
                else MiniSightApplySettingsLive();
            });
            MSDiagEvent(@"assets", @"load", @"pending", @{ @"source": @"plugin", @"reason": @"catalog_changed" });
        });
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
            MiniSightRefreshRecorderSettingsThenReadActivity();
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

/// 当前前台是否已经是 Minis。取不到私有接口时返回 NO，保留旧版兜底。
static BOOL MiniSightMinisIsFrontmost(void) {
    Class workspaceClass = NSClassFromString(@"SBWorkspace");
    if (!workspaceClass) return NO;
    id workspace = nil;
    if ([workspaceClass respondsToSelector:@selector(mainWorkspace)])
        workspace = [workspaceClass performSelector:@selector(mainWorkspace)];
    else if ([workspaceClass respondsToSelector:@selector(sharedWorkspace)])
        workspace = [workspaceClass performSelector:@selector(sharedWorkspace)];
    if (![workspace respondsToSelector:@selector(frontmostApplication)]) return NO;
    id application = [workspace performSelector:@selector(frontmostApplication)];
    if (![application respondsToSelector:@selector(bundleIdentifier)]) return NO;
    NSString *bundle = [application performSelector:@selector(bundleIdentifier)];
    return [bundle isKindOfClass:NSString.class] && [bundle isEqualToString:@"com.openminis.app"];
}

/// 操作结束时把 Minis 拉回前台。新版 App 已在快照里声明 nativeReturn，
/// 此时完全交给 App；旧版才用 SpringBoard 的 LSApplicationWorkspace 兜底。
/// 多次 stopped/endedExecution 只保留一个延迟任务，避免重复拉前台跟按 Home 抢。
static void MiniSightBringMinisFront(void) {
    MSDiag(@"front request native=%d frontmost=%d", gMiniSightAppNativeReturn, MiniSightMinisIsFrontmost());
    if (gMiniSightAppNativeReturn) return;
    if (gMiniSightPendingReturn) dispatch_block_cancel(gMiniSightPendingReturn);
    NSUInteger generation = ++gMiniSightReturnGeneration;
    gMiniSightPendingReturn = dispatch_block_create(DISPATCH_BLOCK_DETACHED, ^{
        if (generation != gMiniSightReturnGeneration) return;
        gMiniSightPendingReturn = nil;
        if (gMiniSightAppNativeReturn || MiniSightMinisIsFrontmost()) return;
        MSDiag(@"front opening Minis");
        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        if (!workspaceClass) return;
        id workspace = [workspaceClass performSelector:@selector(defaultWorkspace)];
        if ([workspace respondsToSelector:@selector(openApplicationWithBundleID:)]) {
            [workspace performSelector:@selector(openApplicationWithBundleID:)
                           withObject:@"com.openminis.app"];
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), gMiniSightPendingReturn);
}

#pragma mark - 入口

%ctor {
    @autoreleasepool {
        // 手势 / 旋转通知的 target（NSNotificationCenter 不持有 observer，必须自己保活）
        gMiniSightGestureTarget = [[MiniSightGestureHandler alloc] init];
        gMiniSightUserHidden = [MSMiniSightPreference(@"MiniSightUserHidden") boolValue];

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
                                        (__bridge const void *)kMiniSightAppActiveNote,
                                        MiniSightDarwinCallback,
                                        (__bridge CFStringRef)kMiniSightAppActiveNote,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(center,
                                        (__bridge const void *)kMiniSightPluginProbe,
                                        MiniSightDarwinCallback,
                                        (__bridge CFStringRef)kMiniSightPluginProbe,
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
                                        (__bridge const void *)kMiniSightResourcesChanged,
                                        MiniSightDarwinCallback,
                                        (__bridge CFStringRef)kMiniSightResourcesChanged,
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
                MiniSightStartPresentationTimer();
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
