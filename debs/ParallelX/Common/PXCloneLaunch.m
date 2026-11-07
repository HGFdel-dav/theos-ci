#import "PXCloneLaunch.h"
#import "PXCloneFlow.h"
#import "PXCloneCrane.h"
#import "PXCloneRuntime.h"
#import "PXClonePaths.h"
#import "PXCloneTrace.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <unistd.h>

NSString *const PXCloneLaunchTraceKey = @"CXLaunchTrace";
static void (*PXOriginalHostedOpen)(id, SEL, id, id, id, void (^)(BOOL));
static BOOL (*PXOriginalFullscreenOpen)(id, SEL, id);

static Class PXLaunchClass(NSString *name) {
    Class cls = NSClassFromString(name);
    if (cls) return cls;
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int index = 0; index < count; index++) {
        NSString *candidate = @(class_getName(classes[index]));
        if ([candidate hasSuffix:name]) { cls = classes[index]; break; }
    }
    free(classes);
    return cls;
}

static id PXLaunchSharedBridge(void) {
    Class cls = PXLaunchClass(@"PXSceneBridge");
    SEL selector = NSSelectorFromString(@"sharedBridge");
    return PXCloneClassMethodMatches(cls, selector, @encode(id), @[], NULL) ?
           PXCloneSendId((id)cls, selector) : nil;
}

static id PXLaunchObject(id target, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return PXCloneInstanceMethodMatches(target, selector, @encode(id), @[]) ?
           PXCloneSendId(target, selector) : nil;
}

static BOOL PXLaunchBool(id target, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return PXCloneInstanceMethodMatches(target, selector, @encode(BOOL), @[]) &&
           PXCloneSendBool(target, selector);
}

static NSError *PXLaunchError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"com.niubiprass.parallelxclone.launch"
                               code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

// Match FBSystemService's actual scalar ABI, rather than casting an integer
// return/argument as id. ScreenCore uses this targeted termination API.
static BOOL PXRequestTermination(NSString *bundle) {
    Class cls = NSClassFromString(@"FBSystemService");
    SEL shared = NSSelectorFromString(@"sharedInstance");
    if (!PXCloneClassMethodMatches(cls, shared, @encode(id), @[], NULL)) return NO;
    id service = PXCloneSendId((id)cls, shared);
    SEL selector = NSSelectorFromString(@"terminateApplication:forReason:andReport:withDescription:completion:");
    NSString *boolean = [NSString stringWithUTF8String:@encode(BOOL)];
    void (^completion)(void) = ^{}; // reference Block descriptor: v8@?0
    @try {
        NSArray *wide = @[@"@", [NSString stringWithUTF8String:@encode(NSInteger)], boolean, @"@", @"@?"];
        NSArray *narrow = @[@"@", [NSString stringWithUTF8String:@encode(int)], boolean, @"@", @"@?"];
        if (PXCloneInstanceMethodMatches(service, selector, @encode(void), wide)) {
            ((void (*)(id, SEL, id, NSInteger, BOOL, id, id))objc_msgSend)(
                service, selector, bundle, 1, YES, @"ParallelX account switch", completion);
        } else if (PXCloneInstanceMethodMatches(service, selector, @encode(void), narrow)) {
            ((void (*)(id, SEL, id, int, BOOL, id, id))objc_msgSend)(
                service, selector, bundle, 1, YES, @"ParallelX account switch", completion);
        } else { return NO; }
    } @catch (__unused NSException *exception) { return NO; }
    return YES; // request accepted, NOT proof that the old process has exited
}

static NSArray *PXRunningProcesses(NSString *bundle, NSError **error) {
    Class cls = NSClassFromString(@"FBProcessManager");
    SEL shared = NSSelectorFromString(@"sharedInstance");
    if (!PXCloneClassMethodMatches(cls, shared, @encode(id), @[], NULL)) {
        if (error) *error = PXLaunchError(11, @"进程查询接口不可用");
        return nil;
    }
    id manager = PXCloneSendId((id)cls, shared);
    if (!manager) {
        if (error) *error = PXLaunchError(11, @"进程管理器不可用");
        return nil;
    }
    id raw = nil;
    BOOL available = NO;
    for (NSString *name in @[@"applicationProcessesForBundleIdentifier:", @"processesForBundleIdentifier:"]) {
        SEL selector = NSSelectorFromString(name);
        if (!PXCloneInstanceMethodMatches(manager, selector, @encode(id), @[@"@"])) continue;
        available = YES;
        @try { raw = ((id (*)(id, SEL, id))objc_msgSend)(manager, selector, bundle); }
        @catch (__unused NSException *exception) {
            if (error) *error = PXLaunchError(12, @"进程列表查询异常");
            return nil;
        }
        break;
    }
    if (!available || (raw && ![raw isKindOfClass:NSArray.class] && ![raw isKindOfClass:NSSet.class])) {
        if (error) *error = PXLaunchError(12, @"进程列表返回值不可用");
        return nil;
    }
    // Like ScreenCore's enumerator, a genuine nil from an available manager
    // means no matching process. Exceptions and missing APIs above are errors;
    // previously captured process objects/PIDs are still checked separately.
    NSMutableArray *running = [NSMutableArray array];
    for (id process in raw) {
        SEL selector = NSSelectorFromString(@"isRunning");
        if (!PXCloneInstanceMethodMatches(process, selector, @encode(BOOL), @[])) {
            if (error) *error = PXLaunchError(13, @"无法确认旧进程是否退出");
            return nil;
        }
        @try {
            if (((BOOL (*)(id, SEL))objc_msgSend)(process, selector)) [running addObject:process];
        } @catch (__unused NSException *exception) {
            if (error) *error = PXLaunchError(13, @"进程存活状态查询异常");
            return nil;
        }
        if (running.count > 8) {
            if (error) *error = PXLaunchError(14, @"应用进程数量异常");
            return nil;
        }
    }
    return running;
}

static pid_t PXProcessPID(id process) {
    SEL selector = NSSelectorFromString(@"pid");
    if (!PXCloneInstanceMethodMatches(process, selector, @encode(int), @[])) return 0;
    @try { return ((int (*)(id, SEL))objc_msgSend)(process, selector); }
    @catch (__unused NSException *exception) { return 0; }
}

@interface PXCloneLaunchController () {
    PXCloneFlow _flow;
    uint64_t _nextToken;
    NSString *_bundle;
    NSString *_container;
    NSDictionary *_pending;
    NSMutableDictionary<NSString *, NSHashTable *> *_bridges;
    NSMutableDictionary<NSString *, NSString *> *_hostedContainers;
    NSMutableDictionary<NSString *, NSNumber *> *_hostedPIDs;
    NSArray *_oldProcesses;
    NSArray<NSNumber *> *_oldPIDs;
    id _openingBridge;
    BOOL _nativeOpenReturned;
    BOOL _reuse;
    BOOL _terminationRequested;
    NSUInteger _attempt;
    PXCloneTraceState _reportedTraceState;
    NSMutableArray *_trace;
}
- (void)startPending;
- (void)pollClosed:(uint64_t)token;
- (void)pollTerminated:(uint64_t)token;
- (void)authenticate:(uint64_t)token;
- (void)verify:(uint64_t)token;
- (void)openSplit:(uint64_t)token;
- (void)pollOpened:(uint64_t)token;
- (void)finish:(uint64_t)token error:(NSError * _Nullable)error;
- (void)record:(NSString *)stage code:(NSInteger)code;
- (void)trackBridge:(id)bridge bundle:(NSString *)bundle;
- (void)nativeOpenReturned:(BOOL)ok bridge:(id)bridge token:(uint64_t)token;
- (BOOL)blocksFullscreen:(NSString *)bundle;
- (uint64_t)tokenForOpeningBundle:(id)bundle;
- (void)captureOpeningBridge:(id)bridge;
- (void)showError:(NSString *)message;
@end

static void PXHostedOpen(id self, SEL command, id bundle, id canvas, id overlay, void (^completion)(BOOL)) {
    PXCloneLaunchController *controller = PXCloneLaunchController.shared;
    if ([bundle isKindOfClass:NSString.class]) [controller trackBridge:self bundle:bundle];
    uint64_t token = [controller tokenForOpeningBundle:bundle];
    if (!token) {
        if (PXOriginalHostedOpen) PXOriginalHostedOpen(self, command, bundle, canvas, overlay, completion);
        return;
    }
    [controller captureOpeningBridge:self];
    __weak id weakBridge = self;
    void (^original)(BOOL) = [completion copy];
    __block BOOL completionDelivered = NO;
    void (^wrapped)(BOOL) = ^(BOOL ok) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completionDelivered) return;
            completionDelivered = YES;
            BOOL accepted = ok;
            // Always let PX release/update its own transaction. Its native
            // generation guards stale work; only the controller callback is
            // gated by our current transaction token.
            @try { if (original) original(accepted); }
            @catch (__unused NSException *exception) { accepted = NO; }
            if ([controller tokenForOpeningBundle:bundle] == token && weakBridge)
                [controller nativeOpenReturned:accepted bridge:weakBridge token:token];
        });
    };
    if (PXOriginalHostedOpen) PXOriginalHostedOpen(self, command, bundle, canvas, overlay, wrapped);
}

static BOOL PXFullscreenOpen(id self, SEL command, id bundle) {
    if ([bundle isKindOfClass:NSString.class] && [PXCloneLaunchController.shared blocksFullscreen:bundle]) return NO;
    return PXOriginalFullscreenOpen ? PXOriginalFullscreenOpen(self, command, bundle) : NO;
}

@implementation PXCloneLaunchController

+ (instancetype)shared {
    static PXCloneLaunchController *controller;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ controller = [self new]; });
    return controller;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _nextToken = 1;
    _bridges = [NSMutableDictionary dictionary];
    _hostedContainers = [NSMutableDictionary dictionary];
    _hostedPIDs = [NSMutableDictionary dictionary];
    _trace = [NSMutableArray array];
    _reportedTraceState = PXCloneTraceStateUnknown;
    return self;
}

+ (BOOL)installNativeHooks {
    Class cls = PXLaunchClass(@"PXSceneBridge");
    if (!cls) return NO;
    if (!PXOriginalHostedOpen) {
        SEL selector = NSSelectorFromString(@"openApplication:inView:keyboardOverlay:completion:");
        IMP original = NULL;
        if (PXCloneClassInstanceMethodMatches(cls, selector, @encode(void), @[@"@", @"@", @"@", @"@?"]) &&
            PXCloneHookMessage(cls, selector, (IMP)PXHostedOpen, &original))
            PXOriginalHostedOpen = (void (*)(id, SEL, id, id, id, void (^)(BOOL)))original;
    }
    if (!PXOriginalFullscreenOpen) {
        SEL selector = NSSelectorFromString(@"openFullscreenApplication:");
        IMP original = NULL;
        if (PXCloneClassInstanceMethodMatches(cls, selector, @encode(BOOL), @[@"@"]) &&
            PXCloneHookMessage(cls, selector, (IMP)PXFullscreenOpen, &original))
            PXOriginalFullscreenOpen = (BOOL (*)(id, SEL, id))original;
    }
    return PXOriginalHostedOpen && PXOriginalFullscreenOpen;
}

- (void)trackBridge:(id)bridge bundle:(NSString *)bundle {
    if (!NSThread.isMainThread || !bundle.length) return;
    NSHashTable *table = _bridges[bundle];
    if (!table) { table = [NSHashTable weakObjectsHashTable]; _bridges[bundle] = table; }
    [table addObject:bridge];
}

- (uint64_t)tokenForOpeningBundle:(id)bundle {
    return NSThread.isMainThread && _flow.phase == PXCloneFlowOpening && [_bundle isEqual:bundle] ? _flow.token : 0;
}

- (void)captureOpeningBridge:(id)bridge {
    if (NSThread.isMainThread) _openingBridge = bridge;
}

- (BOOL)blocksFullscreen:(NSString *)bundle {
    return NSThread.isMainThread && _flow.phase == PXCloneFlowOpening && [_bundle isEqual:bundle];
}

- (void)requestBundle:(NSString *)bundle container:(NSString *)container {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self requestBundle:bundle container:container]; });
        return;
    }
    if (!bundle.length || !container.length) return;
    // Do not cancel Crane while it may still apply an authenticated change.
    // A→B→A during an A transaction simply supersedes pending B with A.
    if (_flow.phase != PXCloneFlowIdle && [_bundle isEqual:bundle] && [_container isEqual:container]) {
        _pending = nil;
        [self record:@"latest_same_target" code:0];
        if (_flow.phase == PXCloneFlowQuarantined)
            [self showError:@"仍在等待 Crane 验证结束，尚未打开账号"];
        return;
    }
    _pending = @{ @"bundle": [bundle copy], @"container": [container copy] };
    if (_flow.phase == PXCloneFlowIdle) [self startPending];
    else {
        [self record:@"queued_latest_target" code:0];
        if (_flow.phase == PXCloneFlowQuarantined)
            [self showError:@"已记住最新账号，等待 Crane 验证结束"];
    }
}

- (void)startPending {
    if (!_pending || _flow.phase != PXCloneFlowIdle) return;
    _bundle = _pending[@"bundle"];
    _container = _pending[@"container"];
    _pending = nil;
    uint64_t token = _nextToken++;
    if (!PXCloneFlowBegin(&_flow, token)) return;
    _attempt = 0;
    _openingBridge = nil;
    _nativeOpenReturned = NO;
    _terminationRequested = NO;
    _reuse = NO;
    [self record:@"request" code:0];
    Class panel = PXLaunchClass(@"PXPanelEntry");
    SEL close = NSSelectorFromString(@"switcherRemovedApplication:");
    SEL open = NSSelectorFromString(@"externalOpenApplication:");
    if (![self.class installNativeHooks] || !PXLaunchSharedBridge() ||
        !PXCloneClassMethodMatches(panel, close, @encode(void), @[@"@"], NULL) ||
        !PXCloneClassMethodMatches(panel, open, @encode(void), @[@"@"], NULL)) {
        [self finish:token error:PXLaunchError(1, @"ParallelX 分屏接口不可用")]; return;
    }
    if (![PXCloneCrane containerExists:_container forBundle:_bundle]) {
        [self finish:token error:PXLaunchError(2, @"账号不存在或 Crane 不可用")]; return;
    }
    NSError *error = nil;
    _oldProcesses = PXRunningProcesses(_bundle, &error);
    if (!_oldProcesses) { [self finish:token error:error]; return; }
    NSMutableArray *pids = [NSMutableArray array];
    for (id process in _oldProcesses) {
        pid_t pid = PXProcessPID(process);
        if (pid > 1 && pid != getpid()) [pids addObject:@(pid)];
    }
    _oldPIDs = pids;
    NSString *active = [PXCloneCrane activeContainerForBundle:_bundle];
    _reuse = [active isEqual:_container] && [_hostedContainers[_bundle] isEqual:_container] &&
             _oldProcesses.count == 1 && _oldPIDs.count == 1 &&
             [_hostedPIDs[_bundle] isEqual:_oldPIDs.firstObject];
    if (!_reuse) {
        [self record:@"close_native_contexts" code:0];
        @try { ((void (*)(id, SEL, id))objc_msgSend)((id)panel, close, _bundle); }
        @catch (__unused NSException *exception) {
            [self finish:token error:PXLaunchError(3, @"旧分屏窗口清理失败")]; return;
        }
    }
    [self pollClosed:token];
}

- (void)pollClosed:(uint64_t)token {
    if (!PXCloneFlowIsCurrent(&_flow, token) || _flow.phase != PXCloneFlowClosing) return;
    BOOL closed = YES;
    if (!_reuse) {
        for (id bridge in _bridges[_bundle].allObjects)
            if (PXLaunchObject(bridge, @"scene") || PXLaunchObject(bridge, @"canvas")) { closed = NO; break; }
    }
    if (closed) {
        if (!PXCloneFlowAdvance(&_flow, token, PXCloneFlowClosing, PXCloneFlowTerminating)) return;
        _attempt = 0;
        [self pollTerminated:token];
        return;
    }
    if (++_attempt >= 30) { [self finish:token error:PXLaunchError(4, @"旧分屏场景未释放")]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self pollClosed:token]; });
}

- (void)pollTerminated:(uint64_t)token {
    if (!PXCloneFlowIsCurrent(&_flow, token) || _flow.phase != PXCloneFlowTerminating) return;
    if (_reuse) { [self authenticate:token]; return; }
    NSError *error = nil;
    NSArray *running = PXRunningProcesses(_bundle, &error);
    if (!running) { [self finish:token error:error]; return; }
    BOOL gone = running.count == 0;
    for (id process in _oldProcesses) if (PXLaunchBool(process, @"isRunning")) gone = NO;
    for (NSNumber *value in _oldPIDs) {
        errno = 0;
        // signal 0 is a liveness probe only; this code never kills by PID.
        if (kill(value.intValue, 0) == 0 || errno != ESRCH) gone = NO;
    }
    if (gone) {
        [self record:@"old_processes_exited" code:0];
        [self authenticate:token]; return;
    }
    if (!_terminationRequested) {
        _terminationRequested = YES;
        [self record:@"termination_requested" code:0];
        if (!PXRequestTermination(_bundle)) {
            [self finish:token error:PXLaunchError(5, @"无法请求旧账号退出")]; return;
        }
    }
    if (++_attempt >= 60) { [self finish:token error:PXLaunchError(6, @"旧账号进程未退出，未启动其他账号")]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self pollTerminated:token]; });
}

- (void)authenticate:(uint64_t)token {
    if (!PXCloneFlowIsCurrent(&_flow, token) || _flow.phase != PXCloneFlowTerminating) return;
    if (_pending) { [self finish:token error:nil]; return; }
    if ([[PXCloneCrane activeContainerForBundle:_bundle] isEqual:_container]) {
        if (!PXCloneFlowAdvance(&_flow, token, PXCloneFlowTerminating, PXCloneFlowVerifying)) return;
        _attempt = 0;
        [self verify:token]; return;
    }
    if (!PXCloneFlowAdvance(&_flow, token, PXCloneFlowTerminating, PXCloneFlowAuthenticating)) return;
    [self record:@"authenticate_without_reload" code:0];
    NSError *error = nil;
    BOOL started = [PXCloneCrane requestSwitchToContainer:_container forBundle:_bundle reply:^(BOOL rawAuthenticationFlag) {
        if (!PXCloneFlowIsCurrent(&self->_flow, token)) return;
        [self record:rawAuthenticationFlag ? @"crane_reply_yes" : @"crane_reply_no" code:0];
        if (self->_flow.phase == PXCloneFlowQuarantined) {
            [self record:@"late_authentication_returned" code:0];
            [self finish:token error:nil]; return;
        }
        if (!PXCloneFlowAcceptCraneReply(&self->_flow, token, rawAuthenticationFlag)) return;
        self->_attempt = 0;
        [self verify:token];
    } error:&error];
    if (!started) { [self finish:token error:error ?: PXLaunchError(7, @"Crane 切换请求未启动")]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 45 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!PXCloneFlowIsCurrent(&self->_flow, token) || self->_flow.phase != PXCloneFlowAuthenticating) return;
        PXCloneFlowTimeout(&self->_flow, token);
        [self record:@"authentication_quarantined" code:8];
        [self showError:@"Crane 验证超时，等待验证结束后可重试"];
    });
}

- (void)verify:(uint64_t)token {
    if (!PXCloneFlowIsCurrent(&_flow, token) || _flow.phase != PXCloneFlowVerifying) return;
    if (_pending) { [self finish:token error:nil]; return; }
    NSString *active = [PXCloneCrane activeContainerForBundle:_bundle];
    BOOL verified = [active isEqual:_container];
    if (PXCloneFlowMayOpen(&_flow, token, verified, _pending != nil)) {
        [self record:@"container_verified" code:0];
        [self openSplit:token]; return;
    }
    if (_attempt == 0)
        [self record:active.length ? @"container_readback_mismatch" : @"container_readback_empty" code:9];
    if (++_attempt >= 12) {
        [self record:@"container_readback_timeout" code:9];
        NSString *message = active.length ? @"当前账号未切到目标，已停止打开" : @"Crane 当前账号回读不可用，已停止打开";
        [self finish:token error:PXLaunchError(9, message)]; return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self verify:token]; });
}

- (void)openSplit:(uint64_t)token {
    if (!PXCloneFlowMayOpen(&_flow, token,
        [[PXCloneCrane activeContainerForBundle:_bundle] isEqual:_container], _pending != nil)) return;
    if (![PXCloneCrane containerExists:_container forBundle:_bundle]) {
        [self finish:token error:PXLaunchError(15, @"账号已被删除，未打开其他账号")]; return;
    }
    if (!PXCloneFlowAdvance(&_flow, token, PXCloneFlowVerifying, PXCloneFlowOpening)) return;
    [self record:@"native_split_requested" code:0];
    _attempt = 0;
    // This is alpha391's own complete host/canvas/overlay builder. Do not call
    // openApplication with nil views, a nil continuation, or applicationActivated.
    Class panel = PXLaunchClass(@"PXPanelEntry");
    SEL selector = NSSelectorFromString(@"externalOpenApplication:");
    @try { ((void (*)(id, SEL, id))objc_msgSend)((id)panel, selector, _bundle); }
    @catch (__unused NSException *exception) {
        [self finish:token error:PXLaunchError(16, @"原生分屏打开发生异常")]; return;
    }
    [self pollOpened:token];
}

- (void)nativeOpenReturned:(BOOL)ok bridge:(id)bridge token:(uint64_t)token {
    if (!PXCloneFlowIsCurrent(&_flow, token) || _flow.phase != PXCloneFlowOpening || bridge != _openingBridge) return;
    _nativeOpenReturned = ok;
    [self record:ok ? @"native_completion_ok" : @"native_completion_failed" code:ok ? 0 : 17];
    if (!ok) [self finish:token error:PXLaunchError(17, @"原生分屏托管失败，没有转为全屏")];
}

- (void)pollOpened:(uint64_t)token {
    if (!PXCloneFlowIsCurrent(&_flow, token) || _flow.phase != PXCloneFlowOpening) return;
    // Reused parked contexts need not issue another openApplication callback.
    NSArray *candidates = _openingBridge ? @[_openingBridge] : _bridges[_bundle].allObjects;
    BOOL visible = NO;
    for (id bridge in candidates) {
        if (![PXLaunchObject(bridge, @"bundleID") isEqual:_bundle] || !PXLaunchObject(bridge, @"scene") ||
            !PXLaunchBool(bridge, @"hasHostedSurface")) continue;
        id canvas = PXLaunchObject(bridge, @"canvas");
        if (![canvas isKindOfClass:UIView.class]) continue;
        UIView *view = canvas;
        BOOL visibleHierarchy = view.window && (_reuse || _nativeOpenReturned);
        for (UIView *ancestor = view; ancestor && visibleHierarchy; ancestor = ancestor.superview)
            if (ancestor.hidden || ancestor.alpha <= 0.1) visibleHierarchy = NO;
        if (visibleHierarchy && !view.window.hidden && view.window.alpha > 0.1) {
            CGRect rect = [view convertRect:view.bounds toView:view.window];
            if (!CGRectIsEmpty(CGRectIntersection(rect, view.window.bounds))) { visible = YES; break; }
        }
    }
    if (_pending) {
        Class panel = PXLaunchClass(@"PXPanelEntry");
        SEL selector = NSSelectorFromString(@"switcherRemovedApplication:");
        @try { ((void (*)(id, SEL, id))objc_msgSend)((id)panel, selector, _bundle); }
        @catch (__unused NSException *exception) { }
        [self record:@"newer_target_before_visible" code:0];
        [self finish:token error:nil];
        return;
    }
    BOOL verified = [[PXCloneCrane activeContainerForBundle:_bundle] isEqual:_container];
    if (PXCloneFlowMaySucceed(&_flow, token, verified, visible)) {
        _hostedContainers[_bundle] = _container;
        NSArray *processes = PXRunningProcesses(_bundle, NULL);
        _hostedPIDs[_bundle] = @(processes.count == 1 ? PXProcessPID(processes.firstObject) : 0);
        [self record:@"split_visible_verified" code:0];
        [self finish:token error:nil]; return;
    }
    if (!verified) { [self finish:token error:PXLaunchError(18, @"打开期间账号发生变化，已停止分屏")]; return; }
    if (++_attempt >= 100) { [self finish:token error:PXLaunchError(19, @"未确认分屏窗口可见，没有转为全屏")]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self pollOpened:token]; });
}

- (void)finish:(uint64_t)token error:(NSError *)error {
    if (!PXCloneFlowIsCurrent(&_flow, token)) return;
    if (error) {
        if (_flow.phase == PXCloneFlowOpening) {
            // Invalidate PX's native generation and remove this bundle's
            // context before a newer transaction may start. Late callbacks
            // cannot resurrect the stale account or launch it fullscreen.
            Class panel = PXLaunchClass(@"PXPanelEntry");
            SEL selector = NSSelectorFromString(@"switcherRemovedApplication:");
            @try { ((void (*)(id, SEL, id))objc_msgSend)((id)panel, selector, _bundle); }
            @catch (__unused NSException *exception) { }
        }
        [_hostedContainers removeObjectForKey:_bundle];
        [_hostedPIDs removeObjectForKey:_bundle];
        [self record:@"failed" code:error.code];
        [self showError:error.localizedDescription ?: @"账号切换失败"];
    } else if (_flow.phase != PXCloneFlowOpening) {
        [self record:@"superseded_without_open" code:0];
    }
    PXCloneFlowRelease(&_flow, token);
    _openingBridge = nil;
    _oldProcesses = nil;
    _oldPIDs = nil;
    _bundle = nil;
    _container = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ [self startPending]; });
}

- (void)record:(NSString *)stage code:(NSInteger)code {
    // A bounded, content-free event ring survives a missed live log capture.
    // No account display names, credentials, messages or app content.
    NSDictionary *event = @{ @"time": @(NSDate.date.timeIntervalSince1970),
                             @"build": @"clone0.24", @"token": @(_flow.token),
                             @"stage": stage, @"code": @(code),
                             @"bundle": _bundle ?: @"", @"targetHash": @(_container.hash) };
    [_trace addObject:event];
    if (_trace.count > 32) [_trace removeObjectAtIndex:0];
    NSArray *snapshot = [_trace copy];
    [PXCloneTrace writeEvents:snapshot completion:^(PXCloneTraceState state, NSError *error) {
        (void)error;
        // Diagnostics must never interrupt: the state is already published
        // through Darwin notify and rendered in the settings page. A respring
        // starts a fresh process, so the old first-write toast reappeared
        // after EVERY respring even though the switch itself was fine.
        self->_reportedTraceState = state;
    }];
}

- (void)showError:(NSString *)message {
    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    window.windowLevel = UIWindowLevelAlert + 1;
    window.userInteractionEnabled = NO;
    window.backgroundColor = UIColor.clearColor;
    UIViewController *controller = [UIViewController new];
    window.rootViewController = controller;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(20, 90, window.bounds.size.width - 40, 72)];
    label.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.94];
    label.textColor = UIColor.whiteColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    label.numberOfLines = 3;
    label.layer.cornerRadius = 14;
    label.clipsToBounds = YES;
    label.text = [@"分身：" stringByAppendingString:message];
    [controller.view addSubview:label];
    window.hidden = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        window.hidden = YES;
        window.rootViewController = nil;
    });
}

@end
