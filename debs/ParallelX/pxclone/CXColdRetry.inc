// CXColdRetry.inc
//
// 分屏冷启动失败自动重试（仅冷启动；最多 2 次重试；总共 3 次尝试）
//
// 根因：iOS 后台场景创建的 CPU watchdog 额度只有 0.2~1.9 秒，但某些 App
// （如抖音）冷启动本身需要约 5 秒，导致被 FRONTBOARD 0x8BADF00D 杀掉。
//
// 设计要求：
//   1. 只在冷启动生效（CXAppRunning 为假时）；已运行/热启动照旧直开。
//   2. 请求发出后轮询进程/场景存活（约每 0.5s，总窗口 5s）；检测到进程消失
//      或始终无场景 → 自动重发同一开窗请求，最多两次，绝不无限循环。
//   3. 只要自动重试，不要自动全屏兜底。
//   4. 付款 / 选账号 / 容器切换路径一律不动。
//   5. 需要防重入：重试期间用户又点、或容器切换尚未完成时，不要叠加新序列；
//      失败要收敛（停手并记日志），成功要有明确终止条件。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <sys/types.h>
#include <string.h>

@interface CXRetryState : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, assign) NSUInteger attempt;          // 1=第一次，2/3=重试
@property (nonatomic, assign) NSTimeInterval startTime;
@property (nonatomic, assign) NSInteger pollCount;
@property (nonatomic, assign) pid_t lastSeenPid;
@property (nonatomic, assign) BOOL cancelled;
@end
@implementation CXRetryState
@end

static NSMutableDictionary<NSString *, CXRetryState *> *CXRetryingApps(void) {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

// 获取应用的当前进程 PID（0=不在运行）
static pid_t CXPidForApp(NSString *bundleID) {
    if (!bundleID.length) return 0;
    Class cls = NSClassFromString(@"SBApplicationController");
    SEL shared = NSSelectorFromString(@"sharedInstance");
    if (!cls || ![cls respondsToSelector:shared]) return 0;
    id controller = ((id (*)(id, SEL))objc_msgSend)(cls, shared);
    SEL appSel = NSSelectorFromString(@"applicationWithBundleIdentifier:");
    if (!controller || ![controller respondsToSelector:appSel]) return 0;
    id app = ((id (*)(id, SEL, id))objc_msgSend)(controller, appSel, bundleID);
    if (!app) return 0;
    
    SEL stateSel = NSSelectorFromString(@"processState");
    if (![app respondsToSelector:stateSel]) return 0;
    id state = ((id (*)(id, SEL))objc_msgSend)(app, stateSel);
    if (!state) return 0;
    
    SEL pidSel = NSSelectorFromString(@"pid");
    if (![state respondsToSelector:pidSel]) return 0;
    
    // iOS 15.5 SBApplicationProcessState.pid 是 int 类型
    NSMethodSignature *sig = [state methodSignatureForSelector:pidSel];
    if (!sig || sig.numberOfArguments != 2) return 0;
    const char *retType = sig.methodReturnType;
    if (strcmp(retType, @encode(int)) == 0 || strcmp(retType, @encode(pid_t)) == 0) {
        return (pid_t)((int (*)(id, SEL))objc_msgSend)(state, pidSel);
    }
    return 0;
}

// 应用是否有场景（复用已有函数）
static BOOL CXHasScene(NSString *bundleID) {
    Class cls = NSClassFromString(@"PXSceneBridge");
    SEL shared = NSSelectorFromString(@"sharedBridge");
    if (!cls || ![cls respondsToSelector:shared]) return NO;
    id bridge = ((id (*)(id, SEL))objc_msgSend)(cls, shared);
    SEL sel = NSSelectorFromString(@"hasSceneForApplication:");
    if (!bridge || ![bridge respondsToSelector:sel]) return NO;
    NSMethodSignature *sig = [bridge methodSignatureForSelector:sel];
    if (!sig || sig.numberOfArguments != 3 || sig.methodReturnType[0] != 'B') return NO;
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(bridge, sel, bundleID) != 0;
}

// 重新发起开窗请求。
// 走 CXOpenInSplitImpl 而不是直接调 externalOpenApplication:，这样签名核验、
// bypass 标记、日志都和首次请求一致；外面包一层 CXInternalOpen，避免重试的
// externalOpen 又被 CXExternalOpen 的路由/弹选账号逻辑接管。
static void CXRetryOpenApp(NSString *bundleID, NSUInteger attempt) {
    if (!bundleID.length) return;
    CXLog(@"[retry] %@ attempt %lu: reissuing split open", bundleID, (unsigned long)attempt);
    BOOL wasInternal = CXInternalOpen;
    CXInternalOpen = YES;
    @try { CXOpenInSplitImpl(bundleID); }
    @catch (NSException *e) {
        CXLog(@"[retry] %@ reissue exception: %@", bundleID, e.reason ?: @"unknown");
    }
    @finally { CXInternalOpen = wasInternal; }
}

// 轮询检查（每 0.5s 一次）
static void CXPollRetryState(CXRetryState *state);

static void CXScheduleNextPoll(CXRetryState *state, NSTimeInterval delay) {
    if (!state || state.cancelled) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CXPollRetryState(state);
    });
}

static void CXPollRetryState(CXRetryState *state) {
    if (!state || state.cancelled) return;
    
    NSString *bundleID = state.bundleID;
    @synchronized (CXRetryingApps()) {
        // 检查是否已被取消
        CXRetryState *current = CXRetryingApps()[bundleID];
        if (!current || current != state || current.cancelled) {
            return;
        }
    }
    
    state.pollCount++;
    NSTimeInterval elapsed = [NSDate date].timeIntervalSince1970 - state.startTime;
    pid_t pid = CXPidForApp(bundleID);
    BOOL hasScene = CXHasScene(bundleID);
    
    CXLog(@"[retry] %@ attempt %lu poll %ld: elapsed %.1fs pid=%d hasScene=%d",
          bundleID, (unsigned long)state.attempt, (long)state.pollCount,
          elapsed, (int)pid, hasScene);
    
    // 成功条件：场景在且进程活着。
    // 进程被看门狗杀掉后 PX 可能留下旧场景，只有场景不能算成功。
    if (hasScene && pid > 0) {
        CXLog(@"[retry] %@ attempt %lu success: scene ready pid=%d",
              bundleID, (unsigned long)state.attempt, (int)pid);
        @synchronized (CXRetryingApps()) {
            [CXRetryingApps() removeObjectForKey:bundleID];
        }
        return;
    }
    
    // 失败条件：进程曾经起来过，现在没了（场景残留也照样按死亡处理）
    BOOL processDied = (pid == 0 && state.lastSeenPid > 0);
    if (processDied) {
        CXLog(@"[retry] %@ attempt %lu: process died (was %d, now 0)",
              bundleID, (unsigned long)state.attempt, state.lastSeenPid);
        
        if (state.attempt >= 3) {
            CXLog(@"[retry] %@ exhausted attempts, giving up", bundleID);
            @synchronized (CXRetryingApps()) {
                [CXRetryingApps() removeObjectForKey:bundleID];
            }
            return;
        }
        
        // 重试
        state.attempt++;
        state.pollCount = 0;
        state.lastSeenPid = 0;
        state.startTime = [NSDate date].timeIntervalSince1970;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!state.cancelled) CXRetryOpenApp(bundleID, state.attempt);
        });
        CXScheduleNextPoll(state, 0.9);
        return;
    }
    
    // 更新最近看到的 PID
    if (pid > 0) {
        state.lastSeenPid = pid;
    }
    
    // 超时条件：5 秒内始终无场景
    if (elapsed >= 5.0) {
        if (state.attempt >= 3) {
            CXLog(@"[retry] %@ timeout after 3 attempts (pid=%d but no scene), giving up",
                  bundleID, (int)pid);
            @synchronized (CXRetryingApps()) {
                [CXRetryingApps() removeObjectForKey:bundleID];
            }
            return;
        }
        
        // 重试
        CXLog(@"[retry] %@ attempt %lu timeout (5s no scene), retrying",
              bundleID, (unsigned long)state.attempt);
        state.attempt++;
        state.pollCount = 0;
        state.lastSeenPid = pid;
        state.startTime = [NSDate date].timeIntervalSince1970;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!state.cancelled) CXRetryOpenApp(bundleID, state.attempt);
        });
        CXScheduleNextPoll(state, 0.9);
        return;
    }
    
    // 继续轮询
    CXScheduleNextPoll(state, 0.5);
}

// 启动冷启动重试序列（在 CXOpenInSplitImpl 调用后调用）
static void CXStartColdRetryIfNeeded(NSString *bundleID) {
    if (!bundleID.length) return;
    
    // 只在冷启动时启动重试
    if (CXAppRunning(bundleID)) return;
    
    // 选择器还开着 / 系统请求还没选完账号：让那条路径自己走，不叠加序列
    if (CXShowingChooser) {
        CXLog(@"[retry] %@ chooser on screen, no retry", bundleID);
        return;
    }
    if (CXSystemRoutePending(bundleID)) {
        CXLog(@"[retry] %@ system route pending, no retry", bundleID);
        return;
    }
    
    @synchronized (CXRetryingApps()) {
        // 防重入：已经在重试中
        CXRetryState *existing = CXRetryingApps()[bundleID];
        if (existing && !existing.cancelled) {
            CXLog(@"[retry] %@ already retrying (attempt %lu), ignoring duplicate request",
                  bundleID, (unsigned long)existing.attempt);
            return;
        }
        
        // 创建新的重试状态
        CXRetryState *state = [[CXRetryState alloc] init];
        state.bundleID = bundleID;
        state.attempt = 1;  // 第一次尝试
        state.startTime = [NSDate date].timeIntervalSince1970;
        state.pollCount = 0;
        state.lastSeenPid = 0;
        state.cancelled = NO;
        
        CXRetryingApps()[bundleID] = state;
        CXLog(@"[retry] %@ cold start: monitoring for 5s (max 3 attempts)", bundleID);
        
        // 0.5 秒后开始第一次轮询（给进程一点启动时间）
        CXScheduleNextPoll(state, 0.5);
    }
}

// 取消重试序列（在 prepareWindow 成功时调用）
static void CXCancelColdRetry(NSString *bundleID) {
    if (!bundleID.length) return;
    
    @synchronized (CXRetryingApps()) {
        CXRetryState *state = CXRetryingApps()[bundleID];
        if (state) {
            state.cancelled = YES;
            [CXRetryingApps() removeObjectForKey:bundleID];
            CXLog(@"[retry] %@ cancelled (prepareWindow arrived, attempt %lu poll %ld)",
                  bundleID, (unsigned long)state.attempt, (long)state.pollCount);
        }
    }
}
