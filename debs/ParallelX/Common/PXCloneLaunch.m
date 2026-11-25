#import "PXCloneLaunch.h"
#import "PXCloneFlow.h"
#import "PXCloneCrane.h"
#import "PXCloneRuntime.h"
#import "PXClonePaths.h"
#import "PXCloneTrace.h"
#import "PXCloneLaunchDiagnostics.h"
#import "PXCloneURLRouter.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <errno.h>
#include <math.h>
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

// A closed split can leave its bridge object alive with a non-nil scene and
// canvas, so those pointers say nothing about what is actually on screen.
// Only a canvas attached to a visible window can still cover the screen.
static BOOL PXLaunchBridgeCoversScreen(id bridge) {
    id canvas = PXLaunchObject(bridge, @"canvas");
    if (![canvas isKindOfClass:UIView.class]) return NO;
    UIView *view = canvas;
    UIWindow *window = view.window;
    if (!window || window.hidden || window.alpha <= 0.1) return NO;
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview)
        if (ancestor.hidden || ancestor.alpha <= 0.1) return NO;
    CGRect rect = [view convertRect:view.bounds toView:window];
    return !CGRectIsEmpty(CGRectIntersection(rect, window.bounds));
}

// Read-only observations: pollOpened below retains its original success gates.
static id PXLaunchDiagnosticRect(CGRect rect) {
    if (CGRectIsNull(rect) || CGRectIsInfinite(rect) || !isfinite(rect.origin.x) ||
        !isfinite(rect.origin.y) || !isfinite(rect.size.width) || !isfinite(rect.size.height)) return @{ @"valid": @NO };
    return @{ @"valid": @YES, @"xywh": @[@(rect.origin.x), @(rect.origin.y), @(rect.size.width), @(rect.size.height)] };
}

static NSDictionary *PXLaunchCandidateDiagnostic(id bridge, NSString *bundle,
                                                 BOOL completionGate, BOOL account) {
    uint32_t checked = PXLaunchDiagBridge | PXLaunchDiagCompletion | PXLaunchDiagAccount;
    uint32_t passed = (bridge ? PXLaunchDiagBridge : 0) |
                      (completionGate ? PXLaunchDiagCompletion : 0) |
                      (account ? PXLaunchDiagAccount : 0);
    NSMutableDictionary *detail = [NSMutableDictionary dictionary];
    if (bridge) {
        if (PXCloneInstanceMethodMatches(bridge, NSSelectorFromString(@"bundleID"), @encode(id), @[])) {
            checked |= PXLaunchDiagBundle;
            if ([PXLaunchObject(bridge, @"bundleID") isEqual:bundle]) passed |= PXLaunchDiagBundle;
        }
        if (PXCloneInstanceMethodMatches(bridge, NSSelectorFromString(@"scene"), @encode(id), @[])) {
            checked |= PXLaunchDiagScene;
            if (PXLaunchObject(bridge, @"scene")) passed |= PXLaunchDiagScene;
        }
        if (PXCloneInstanceMethodMatches(bridge, NSSelectorFromString(@"hasHostedSurface"), @encode(BOOL), @[])) {
            checked |= PXLaunchDiagSurface;
            if (PXLaunchBool(bridge, @"hasHostedSurface")) passed |= PXLaunchDiagSurface;
        }
        BOOL canvasKnown = PXCloneInstanceMethodMatches(bridge, NSSelectorFromString(@"canvas"), @encode(id), @[]);
        if (canvasKnown) checked |= PXLaunchDiagCanvas;
        id canvas = canvasKnown ? PXLaunchObject(bridge, @"canvas") : nil;
        if ([canvas isKindOfClass:UIView.class]) {
            passed |= PXLaunchDiagCanvas;
            UIView *view = canvas;
            UIWindow *window = view.window;
            checked |= PXLaunchDiagWindow;
            detail[@"canvasBounds"] = PXLaunchDiagnosticRect(view.bounds);
            NSUInteger depth = 0, hidden = 0, lowAlpha = 0;
            UIView *ancestor = view;
            for (; ancestor && depth < 128; ancestor = ancestor.superview, ++depth) {
                if (ancestor.hidden) ++hidden;
                if (ancestor.alpha <= 0.1) ++lowAlpha;
            }
            detail[@"hierarchyDepth"] = @(depth);
            detail[@"hierarchyHidden"] = @(hidden);
            detail[@"hierarchyLowAlpha"] = @(lowAlpha);
            detail[@"hierarchyTruncated"] = @(ancestor != nil);
            if (!ancestor) {
                checked |= PXLaunchDiagHierarchy;
                if (!hidden && !lowAlpha) passed |= PXLaunchDiagHierarchy;
            }
            if (window) {
                passed |= PXLaunchDiagWindow;
                checked |= PXLaunchDiagWindowVisible | PXLaunchDiagWindowIntersection;
                if (!window.hidden && window.alpha > 0.1) passed |= PXLaunchDiagWindowVisible;
                CGRect rect = [view convertRect:view.bounds toView:window];
                CGRect intersection = CGRectIntersection(rect, window.bounds);
                if (!CGRectIsEmpty(intersection)) passed |= PXLaunchDiagWindowIntersection;
                detail[@"windowHidden"] = @(window.hidden);
                detail[@"windowAlpha"] = @(window.alpha);
                detail[@"windowBounds"] = PXLaunchDiagnosticRect(window.bounds);
                detail[@"canvasInWindow"] = PXLaunchDiagnosticRect(rect);
                detail[@"windowIntersection"] = PXLaunchDiagnosticRect(intersection);
                // Auxiliary screen intersection is NOT an added success gate.
                UIScreen *screen = window.screen;
                detail[@"screenChecked"] = @(screen != nil);
                if (screen) {
                    CGRect onScreen = [window convertRect:rect toCoordinateSpace:screen.coordinateSpace];
                    CGRect screenIntersection = CGRectIntersection(onScreen, screen.bounds);
                    detail[@"canvasOnScreen"] = PXLaunchDiagnosticRect(onScreen);
                    detail[@"screenBounds"] = PXLaunchDiagnosticRect(screen.bounds);
                    detail[@"screenIntersection"] = PXLaunchDiagnosticRect(screenIntersection);
                    detail[@"intersectsScreen"] = @(!CGRectIsEmpty(screenIntersection));
                }
            }
        }
    }
    detail[@"checkedMask"] = @(checked);
    detail[@"passedMask"] = @(passed);
    detail[@"failedMask"] = @(PXLaunchDiagnosticFailed(checked, passed));
    detail[@"unknownMask"] = @(PXLaunchDiagnosticUnknown(checked));
    unsigned gate = PXLaunchDiagnosticFirstGate(checked, passed);
    detail[@"firstFailedGate"] = @(gate);
    detail[@"firstFailedGateName"] = [NSString stringWithUTF8String:PXLaunchDiagnosticGateName(gate)];
    return detail;
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
    BOOL _forceTerminated;
    NSUInteger _attempt;
    NSUInteger _splitRetries;
    CFAbsoluteTime _flowStart;
    PXCloneTraceState _reportedTraceState;
    NSMutableArray *_trace;
    NSDictionary *_lastOpenDiagnostic;
    NSDictionary *_recordDetail;
    PXLaunchDiagnosticThrottle _openDiagnosticThrottle;
    NSUInteger _bridgeArrivals;
    BOOL _completionReceived, _completionRawOK, _completionOriginalPresent;
    BOOL _completionForwarded, _completionThrew, _completionAccepted;
    double _completionQueueMS;
}
- (void)startPending;
- (void)pollClosed:(uint64_t)token;
- (void)pollTerminated:(uint64_t)token;
- (void)authenticate:(uint64_t)token;
- (void)verify:(uint64_t)token;
- (void)openSplit:(uint64_t)token;
- (void)retrySplit:(uint64_t)token;
- (void)pollOpened:(uint64_t)token;
- (void)finish:(uint64_t)token error:(NSError * _Nullable)error;
- (void)record:(NSString *)stage code:(NSInteger)code;
- (void)trackBridge:(id)bridge bundle:(NSString *)bundle;
- (void)nativeOpenReturned:(BOOL)ok bridge:(id)bridge token:(uint64_t)token;
- (BOOL)blocksFullscreen:(NSString *)bundle;
- (uint64_t)tokenForOpeningBundle:(id)bundle;
- (void)captureOpeningBridge:(id)bridge;
- (void)resetOpenDiagnostic;
- (void)observeOpenCandidates:(NSArray *)candidates visible:(BOOL)visible active:(NSString *)active;
- (void)recordOpenDiagnostic:(NSString *)stage force:(BOOL)force;
- (void)completionReceived:(BOOL)raw original:(BOOL)present queuedAt:(CFAbsoluteTime)time bridge:(id)bridge token:(uint64_t)token;
- (void)completionForwarded:(BOOL)accepted threw:(BOOL)threw bridge:(id)bridge token:(uint64_t)token;
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
        CFAbsoluteTime receivedAt = CFAbsoluteTimeGetCurrent();
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completionDelivered) return;
            completionDelivered = YES;
            @try { [controller completionReceived:ok original:original != nil queuedAt:receivedAt bridge:weakBridge token:token]; }
            @catch (__unused NSException *exception) { /* Observation cannot suppress the native continuation. */ }
            BOOL accepted = ok;
            BOOL originalThrew = NO;
            // Always let PX release/update its own transaction. Its native
            // generation guards stale work; only the controller callback is
            // gated by our current transaction token.
            @try { if (original) original(accepted); }
            @catch (__unused NSException *exception) { accepted = NO; originalThrew = YES; }
            @try { [controller completionForwarded:accepted threw:originalThrew bridge:weakBridge token:token]; }
            @catch (__unused NSException *exception) { /* Preserve the original accepted result. */ }
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
    if (NSThread.isMainThread) {
        _openingBridge = bridge;
        ++_bridgeArrivals;
        [self record:@"native_bridge_arrived" code:0];
    }
}

- (void)resetOpenDiagnostic {
    _lastOpenDiagnostic = nil;
    _openDiagnosticThrottle = (PXLaunchDiagnosticThrottle){0};
    _bridgeArrivals = 0;
    _completionReceived = _completionRawOK = _completionOriginalPresent = NO;
    _completionForwarded = _completionThrew = _completionAccepted = NO;
    _completionQueueMS = 0;
}

- (void)completionReceived:(BOOL)raw original:(BOOL)present queuedAt:(CFAbsoluteTime)time bridge:(id)bridge token:(uint64_t)token {
    if (!PXCloneFlowIsCurrent(&_flow, token) || _flow.phase != PXCloneFlowOpening || bridge != _openingBridge) return;
    _completionReceived = YES;
    _completionRawOK = raw;
    _completionOriginalPresent = present;
    _completionQueueMS = (CFAbsoluteTimeGetCurrent() - time) * 1000.0;
    _recordDetail = @{ @"rawOK": @(raw), @"originalPresent": @(present), @"queueMS": @(_completionQueueMS) };
    [self record:@"native_completion_received" code:0];
    _recordDetail = nil;
}

- (void)completionForwarded:(BOOL)accepted threw:(BOOL)threw bridge:(id)bridge token:(uint64_t)token {
    if (!PXCloneFlowIsCurrent(&_flow, token) || _flow.phase != PXCloneFlowOpening || bridge != _openingBridge) return;
    _completionForwarded = YES;
    _completionThrew = threw;
    _completionAccepted = accepted;
    _recordDetail = @{ @"accepted": @(accepted), @"originalThrew": @(threw) };
    [self record:@"native_completion_forwarded" code:0];
    _recordDetail = nil;
}

- (void)observeOpenCandidates:(NSArray *)candidates visible:(BOOL)visible active:(NSString *)active {
    @try {
    NSMutableArray *samples = [NSMutableArray array];
    BOOL verified = [active isEqual:_container];
    uint64_t signature = PXLaunchDiagnosticMix(0, candidates.count);
    signature = PXLaunchDiagnosticMix(signature, (uint64_t)visible | ((uint64_t)verified << 1) |
        ((uint64_t)_completionReceived << 2) | ((uint64_t)_completionForwarded << 3) |
        ((uint64_t)_completionRawOK << 4) | ((uint64_t)_completionAccepted << 5) |
        ((uint64_t)_completionThrew << 6) | ((uint64_t)(active.length > 0) << 7));
    NSUInteger count = MIN(candidates.count, (NSUInteger)4);
    for (NSUInteger index = 0; index < MAX(count, (NSUInteger)1); ++index) {
        NSDictionary *sample = PXLaunchCandidateDiagnostic(count ? candidates[index] : nil, _bundle,
                                                           _reuse || _nativeOpenReturned, verified);
        [samples addObject:sample];
        signature = PXLaunchDiagnosticMix(signature, [sample[@"checkedMask"] unsignedIntValue]);
        signature = PXLaunchDiagnosticMix(signature, [sample[@"passedMask"] unsignedIntValue]);
        signature = PXLaunchDiagnosticMix(signature, [sample[@"intersectsScreen"] boolValue]);
    }
    _lastOpenDiagnostic = @{ @"candidateCount": @(candidates.count), @"sampleTruncated": @(candidates.count > count),
        @"candidates": samples, @"bridgeArrivals": @(_bridgeArrivals), @"openingBridge": @(_openingBridge != nil),
        @"poll": @(_attempt + 1), @"retry": @(_splitRetries), @"reuse": @(_reuse),
        @"completionReceived": @(_completionReceived), @"completionRawOK": @(_completionRawOK),
        @"completionOriginalPresent": @(_completionOriginalPresent), @"completionForwarded": @(_completionForwarded),
        @"completionThrew": @(_completionThrew), @"completionAccepted": @(_completionAccepted),
        @"nativeOpenReturned": @(_nativeOpenReturned), @"completionQueueMS": @(_completionQueueMS),
        @"accountReadbackPresent": @(active.length > 0), @"accountMatches": @(verified),
        @"visibleGate": @(visible), @"signature": @(signature),
        @"elapsedMS": @((CFAbsoluteTimeGetCurrent() - _flowStart) * 1000.0) };
    } @catch (__unused NSException *exception) {
        _lastOpenDiagnostic = @{ @"observationException": @YES, @"unknownMask": @(PXLaunchDiagAll),
                                 @"poll": @(_attempt + 1), @"retry": @(_splitRetries) };
    }
}

- (void)recordOpenDiagnostic:(NSString *)stage force:(BOOL)force {
    if (!_lastOpenDiagnostic) return;
    if (!PXLaunchDiagnosticShouldWrite(&_openDiagnosticThrottle,
        [_lastOpenDiagnostic[@"signature"] unsignedLongLongValue],
        [_lastOpenDiagnostic[@"poll"] unsignedIntValue], force)) return;
    _recordDetail = _lastOpenDiagnostic;
    [self record:stage code:0];
    _recordDetail = nil;
}

- (BOOL)blocksFullscreen:(NSString *)bundle {
    return NSThread.isMainThread && _flow.phase == PXCloneFlowOpening && [_bundle isEqual:bundle];
}

- (BOOL)isBusy {
    return _flow.phase != PXCloneFlowIdle || _pending != nil;
}

- (void)requestBundle:(NSString *)bundle container:(NSString *)container {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self requestBundle:bundle container:container]; });
        return;
    }
    if (!bundle.length || !container.length) return;
    if ([PXCloneURLRouter hasActivePayment]) {
        [self showError:@"请先完成当前付款账号操作，再打开其他分身"];
        return;
    }
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
    _splitRetries = 0;
    _openingBridge = nil;
    _nativeOpenReturned = NO;
    [self resetOpenDiagnostic];
    _terminationRequested = NO;
    _forceTerminated = NO;
    _reuse = NO;
    _flowStart = CFAbsoluteTimeGetCurrent();
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
    BOOL windowGone = YES;
    for (id bridge in _bridges[_bundle].allObjects)
        if (PXLaunchBridgeCoversScreen(bridge)) { windowGone = NO; break; }
    BOOL exactHost = [_hostedContainers[_bundle] isEqual:_container] &&
                     _oldProcesses.count == 1 && _oldPIDs.count == 1 &&
                     [_hostedPIDs[_bundle] isEqual:_oldPIDs.firstObject];
    // The window was swiped away but the account is still alive, so its
    // notifications keep working: bring the window back instead of tearing the
    // account down. Only when nothing of this app is on screen; a split that is
    // still visible keeps the original strict check to avoid double hosting.
    _reuse = [active isEqual:_container] && _oldProcesses.count >= 1 &&
             (windowGone || exactHost);
    [self record:[NSString stringWithFormat:@"reuse_check hit=%d proc=%lu gone=%d exact=%d",
                  (int)_reuse, (unsigned long)_oldProcesses.count,
                  (int)windowGone, (int)exactHost] code:0];
    if (!_reuse) {
        [self record:@"close_native_contexts" code:0];
        @try { ((void (*)(id, SEL, id))objc_msgSend)((id)panel, close, _bundle); }
        @catch (__unused NSException *exception) {
            [self finish:token error:PXLaunchError(3, @"旧分屏窗口清理失败")]; return;
        }
        // Ask the old account to exit while the window is closing, so its own
        // clean-up time overlaps ours instead of being paid twice.
        _terminationRequested = YES;
        [self record:@"termination_requested" code:0];
        PXRequestTermination(_bundle);
    }
    [self pollClosed:token];
}

- (NSString *)closeTimeoutDetail {
    NSArray *bridges = _bridges[_bundle].allObjects;
    NSInteger scenes = 0, canvases = 0, visible = 0;
    for (id bridge in bridges) {
        if (PXLaunchObject(bridge, @"scene")) scenes++;
        if ([PXLaunchObject(bridge, @"canvas") isKindOfClass:UIView.class]) canvases++;
        if (PXLaunchBridgeCoversScreen(bridge)) visible++;
    }
    NSError *error = nil;
    NSArray *running = PXRunningProcesses(_bundle, &error);
    return [NSString stringWithFormat:@"close_timeout b=%lu scene=%ld canvas=%ld visible=%ld proc=%lu",
            (unsigned long)bridges.count, (long)scenes, (long)canvases, (long)visible,
            (unsigned long)(running ? running.count : 0)];
}

- (void)pollClosed:(uint64_t)token {
    if (!PXCloneFlowIsCurrent(&_flow, token) || _flow.phase != PXCloneFlowClosing) return;
    BOOL closed = YES;
    if (!_reuse) {
        for (id bridge in _bridges[_bundle].allObjects)
            if (PXLaunchBridgeCoversScreen(bridge)) { closed = NO; break; }
    }
    if (closed) {
        if (!PXCloneFlowAdvance(&_flow, token, PXCloneFlowClosing, PXCloneFlowTerminating)) return;
        _attempt = 0;
        [self pollTerminated:token];
        return;
    }
    if (++_attempt >= 30) {
        [self record:[self closeTimeoutDetail] code:4];
        [self finish:token error:PXLaunchError(4, @"旧分屏场景未释放")]; return;
    }
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
    // Switching accounts is exclusive by design: the account the user left must
    // end, otherwise the target one cannot start. Keep asking through the panel's
    // own termination API instead of giving up and showing an error.
    if (!_forceTerminated && _attempt >= 5) {
        _forceTerminated = YES;
        [self record:[NSString stringWithFormat:@"termination_repeat proc=%lu",
                      (unsigned long)running.count] code:0];
        PXRequestTermination(_bundle);
    }
    if (++_attempt >= 150) {
        [self record:[NSString stringWithFormat:@"terminate_timeout proc=%lu",
                      (unsigned long)running.count] code:6];
        [self finish:token error:PXLaunchError(6, @"旧账号进程未退出，未启动其他账号")]; return;
    }
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
    // Let the original build its complete host/canvas/overlay. Do not call
    // openApplication with nil views, a nil continuation, or applicationActivated.
    Class panel = PXLaunchClass(@"PXPanelEntry");
    SEL selector = NSSelectorFromString(@"externalOpenApplication:");
    @try { ((void (*)(id, SEL, id))objc_msgSend)((id)panel, selector, _bundle); }
    @catch (__unused NSException *exception) {
        [self finish:token error:PXLaunchError(16, @"原生分屏打开发生异常")]; return;
    }
    [self pollOpened:token];
}

- (void)retrySplit:(uint64_t)token {
    if (!PXCloneFlowIsCurrent(&_flow, token) || _flow.phase != PXCloneFlowOpening) return;
    _attempt = 0;
    _openingBridge = nil;
    _nativeOpenReturned = NO;
    [self resetOpenDiagnostic];
    [self record:@"native_retry" code:(NSInteger)_splitRetries];
    // A failed host can leave a half-built context behind. Clear it first so
    // the retry starts from the same state a fresh open would see.
    Class panel = PXLaunchClass(@"PXPanelEntry");
    SEL close = NSSelectorFromString(@"switcherRemovedApplication:");
    @try { ((void (*)(id, SEL, id))objc_msgSend)((id)panel, close, _bundle); }
    @catch (__unused NSException *exception) { }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(900 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        if (!PXCloneFlowIsCurrent(&self->_flow, token) || self->_flow.phase != PXCloneFlowOpening) return;
        if (_pending) { [self finish:token error:nil]; return; }
        NSString *active = [PXCloneCrane activeContainerForBundle:self->_bundle];
        if (![active isEqual:self->_container]) {
            [self record:@"native_retry_account_mismatch" code:18];
            [self finish:token error:PXLaunchError(18, @"重试前账号已变化，已停止分屏")]; return;
        }
        Class target = PXLaunchClass(@"PXPanelEntry");
        SEL open = NSSelectorFromString(@"externalOpenApplication:");
        @try { ((void (*)(id, SEL, id))objc_msgSend)((id)target, open, self->_bundle); }
        @catch (__unused NSException *exception) {
            [self finish:token error:PXLaunchError(16, @"原生分屏打开发生异常")]; return;
        }
        [self pollOpened:token];
    });
}

- (void)nativeOpenReturned:(BOOL)ok bridge:(id)bridge token:(uint64_t)token {
    if (!PXCloneFlowIsCurrent(&_flow, token) || _flow.phase != PXCloneFlowOpening || bridge != _openingBridge) return;
    _nativeOpenReturned = ok;
    [self record:ok ? @"native_completion_ok" : @"native_completion_failed" code:ok ? 0 : 17];
    if (!ok) {
        [self observeOpenCandidates:bridge ? @[bridge] : @[] visible:NO
                            active:[PXCloneCrane activeContainerForBundle:_bundle]];
        [self recordOpenDiagnostic:@"open_before_retry_or_failure" force:YES];
        // Record what the panel actually handed us before deciding anything.
        id canvas = PXLaunchObject(bridge, @"canvas");
        NSArray *live = PXRunningProcesses(_bundle, NULL);
        [self record:[NSString stringWithFormat:@"open_detail bridge=%d canvas=%d visible=%d proc=%lu retry=%lu",
                      (int)(bridge != nil), (int)[canvas isKindOfClass:UIView.class],
                      (int)PXLaunchBridgeCoversScreen(bridge),
                      (unsigned long)(live ? live.count : 0), (unsigned long)_splitRetries] code:17];
        // Right after a respring the panel can refuse the first host request
        // because its own machinery is not up yet. Retry instead of making the
        // user tap again and wait.
        if (_splitRetries < 2) { _splitRetries++; [self retrySplit:token]; return; }
        [self finish:token error:PXLaunchError(17, @"原生分屏托管失败，没有转为全屏")];
    }
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
    NSString *active = [PXCloneCrane activeContainerForBundle:_bundle];
    BOOL verified = [active isEqual:_container];
    [self observeOpenCandidates:candidates visible:visible active:active];
    [self recordOpenDiagnostic:@"open_visibility" force:NO];
    if (PXCloneFlowMaySucceed(&_flow, token, verified, visible)) {
        _hostedContainers[_bundle] = _container;
        NSArray *processes = PXRunningProcesses(_bundle, NULL);
        _hostedPIDs[_bundle] = @(processes.count == 1 ? PXProcessPID(processes.firstObject) : 0);
        [self record:@"split_visible_verified" code:0];
        [self record:[NSString stringWithFormat:@"done ms=%d ok=1 reuse=%d",
                      (int)((CFAbsoluteTimeGetCurrent() - _flowStart) * 1000.0), (int)_reuse] code:0];
        [self finish:token error:nil]; return;
    }
    if (!verified) { [self finish:token error:PXLaunchError(18, @"打开期间账号发生变化，已停止分屏")]; return; }
    if (++_attempt >= 100) {
        if (!_reuse && _openingBridge && !_completionReceived && _splitRetries < 2) {
            [self recordOpenDiagnostic:@"open_timeout_before_retry" force:YES];
            _splitRetries++;
            [self record:@"native_completion_timeout_retry" code:(NSInteger)_splitRetries];
            [self retrySplit:token];
            return;
        }
        [self finish:token error:PXLaunchError(19, @"未确认分屏窗口可见，没有转为全屏")]; return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self pollOpened:token]; });
}

- (void)finish:(uint64_t)token error:(NSError *)error {
    if (!PXCloneFlowIsCurrent(&_flow, token)) return;
    if (error) {
        if (_flow.phase == PXCloneFlowOpening) {
            if (!_lastOpenDiagnostic)
                [self observeOpenCandidates:_openingBridge ? @[_openingBridge] : _bridges[_bundle].allObjects
                                    visible:NO active:[PXCloneCrane activeContainerForBundle:_bundle]];
            // The latest poll is kept in memory even when its disk write was
            // throttled. Save it BEFORE cleanup destroys the evidence.
            [self recordOpenDiagnostic:@"open_before_cleanup" force:YES];
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
        [self record:[NSString stringWithFormat:@"done ms=%d ok=0",
                      (int)((CFAbsoluteTimeGetCurrent() - _flowStart) * 1000.0)] code:error.code];
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
                             @"build": @"clone0.107", @"token": @(_flow.token),
                             @"stage": stage, @"code": @(code),
                             @"bundle": _bundle ?: @"", @"targetHash": @(_container.hash) };
    NSMutableDictionary *entry = [event mutableCopy];
    if (_recordDetail) entry[@"detail"] = _recordDetail;
    if ([stage isEqual:@"failed"]) {
        NSString *failureID = NSUUID.UUID.UUIDString;
        entry[@"failureID"] = failureID;
        entry[@"summary"] = @{ @"phase": @(_flow.phase), @"retry": @(_splitRetries),
            @"elapsedMS": @((CFAbsoluteTimeGetCurrent() - _flowStart) * 1000.0),
            @"lastOpen": _lastOpenDiagnostic ?: @{} };
    }
    [_trace addObject:[entry copy]];
    if (_trace.count > 32) [_trace removeObjectAtIndex:0];
    NSArray *snapshot = [_trace copy];
    [PXCloneTrace writeEvents:snapshot completion:^(PXCloneTraceState state, NSError *error) {
        (void)error;
        // Saving and readback stay in the diagnostic channel. The user should
        // never have to read a toast ID or wait for logging to see an error.
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
