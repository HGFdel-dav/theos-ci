// Included by CXHook.m after request parsing and chooser presentation helpers.
// ABI source: iPhone_OS_15.5 / SpringBoard / FBSystemServiceDelegate-Protocol.h.
// withCompletion is void (^)(NSError *); never retain a borrowed stack block as id.
#import <QuartzCore/QuartzCore.h>
#include <signal.h>
#include <errno.h>
#include <stdbool.h>

#import "CXDiagnostic.inc"

static void CXForwardNextSystemRequest(CXSystemRoute *route);

static NSError *CXRouteError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:@"com.niubiprass.clonex.routing" code:code
                          userInfo:@{NSLocalizedDescriptionKey: description ?: @"Open request cancelled"}];
}

static void CXFinishSystemRoute(CXSystemRoute *route, NSError *error) {
    NSCAssert(NSThread.isMainThread, @"system route must finish on main queue");
    if (!route || route.finished) return;
    route.finished = YES; // Before callbacks: they can synchronously reenter us.
    if (CXChooserRoute == route) CXCloseChooser();
    [CXSystemRoutes() removeObjectIdenticalTo:route];
    if (CXActiveSystemRoute == route) CXActiveSystemRoute = nil;
    // A cancelled full request must not reappear later via the URL cache.
    CXMarkCurrentURLConsumed();
    if (error) {
        CXForgetRecentContainerSelection(route.bundleID);
        @synchronized (CXRequestBypassBundles()) {
            [CXRequestBypassBundles() removeObjectForKey:route.bundleID];
        }
    }
    NSArray *items = [route.items copy];
    [route.items removeAllObjects];
    for (CXSystemRequestItem *item in items) {
        // Once handed to PX, only its result callback owns completion delivery.
        if (item.forwarded || item.finished) continue;
        item.finished = YES;
        CXSystemCompletion callback = [item.completion copy];
        item.completion = nil;
        item.receiver = nil; item.service = nil; item.request = nil;
        if (callback) callback(error ?: CXRouteError(1, @"Request not forwarded"));
    }
    dispatch_async(dispatch_get_main_queue(), ^{ CXDrainSystemRoutes(); });
}

static void CXForwardNextSystemRequest(CXSystemRoute *route) {
    if (!route || route.finished || route.waitingForResult) return;
    if (route.nextIndex >= route.items.count) {
        CXFinishSystemRoute(route, nil);
        return;
    }
    CXSystemRequestItem *item = route.items[route.nextIndex++];
    route.waitingForResult = YES;
    route.selected = YES;
    item.forwarded = YES; // Lock state before the original IMP can reenter.
    CXMarkRequestBypass(route.bundleID);
    CXLog(@"[route] %@ forward queued request=%p index=%lu total=%lu", route.bundleID,
          item.request, (unsigned long)route.nextIndex, (unsigned long)route.items.count);
    CXLogRequestOptions(route.bundleID, item.request, "before-forward");
    CXLogFrontmostTimeline(route.bundleID);
    __weak CXSystemRoute *weakRoute = route;
    CXSystemCompletion result = [^(NSError *error) {
        // Also handles a synchronous result: finish only after original IMP returns.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (item.finished) return;
            item.finished = YES;
            CXSystemCompletion callback = [item.completion copy];
            item.completion = nil;
            item.receiver = nil; item.service = nil; item.request = nil;
            CXSystemRoute *current = weakRoute;
            if (callback) callback(error);
            if (!current || current.finished) return;
            current.waitingForResult = NO;
            CXLog(@"[route] %@ result error=%@", current.bundleID, error ?: @"none");
            if (error) CXFinishSystemRoute(current, error);
            else CXForwardNextSystemRequest(current);
        });
    } copy];
    id forwardedRequest = item.request; // result 可能同步回调并清空 item.request。
    CXOrigSystemRequest(item.receiver, item.selector, item.service, forwardedRequest, result);
    CXLogRequestOptions(route.bundleID, forwardedRequest, "after-forward");
    // A broken downstream plugin must not retain the entire global queue forever.
    // Timeout completes once with failure; it never retries or launches another account.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!item.finished) result(CXRouteError(6, @"System application-open result timed out"));
    });
}

// SBApplicationProcessState.pid is int on iOS 15.5. Do not treat a missing
// runtime API as 'process exited'; unknown identity must fail closed on switching.
static pid_t CXApplicationPID(NSString *bundleID, BOOL *known) {
    if (known) *known = NO;
    Class cls = NSClassFromString(@"SBApplicationController");
    SEL shared = NSSelectorFromString(@"sharedInstance");
    SEL lookup = NSSelectorFromString(@"applicationWithBundleIdentifier:");
    if (!cls || ![cls respondsToSelector:shared]) return 0;
    id controller = ((id (*)(id, SEL))objc_msgSend)(cls, shared);
    if (![controller respondsToSelector:lookup]) return 0;
    id app = ((id (*)(id, SEL, id))objc_msgSend)(controller, lookup, bundleID);
    id state = CXRequestObjectValue(app, @"processState");
    SEL pidSelector = NSSelectorFromString(@"pid");
    SEL runningSelector = NSSelectorFromString(@"isRunning");
    NSMethodSignature *runningSig = [state methodSignatureForSelector:runningSelector];
    if (runningSig && runningSig.numberOfArguments == 2 &&
        (!strcmp(runningSig.methodReturnType, @encode(BOOL)) ||
         !strcmp(runningSig.methodReturnType, @encode(bool))) &&
        !((BOOL (*)(id, SEL))objc_msgSend)(state, runningSelector)) {
        if (known) *known = YES;
        return 0; // Explicit non-running state, not a missing-method fallback.
    }
    NSMethodSignature *sig = [state methodSignatureForSelector:pidSelector];
    if (!sig || sig.numberOfArguments != 2 || strcmp(sig.methodReturnType, @encode(int))) return 0;
    int pid = ((int (*)(id, SEL))objc_msgSend)(state, pidSelector);
    if (pid < 0) return 0;
    if (known) *known = YES;
    return (pid_t)pid;
}

static void CXWaitForOldProcess(CXSystemRoute *route, pid_t oldPID, CFTimeInterval deadline) {
    if (route.finished) return;
    if (oldPID <= 0 || (kill(oldPID, 0) < 0 && errno == ESRCH)) {
        CXLog(@"[route] %@ old pid=%d exited; deliver original payload", route.bundleID, oldPID);
        CXForwardNextSystemRequest(route);
        return;
    }
    if (CACurrentMediaTime() >= deadline) {
        CXLog(@"[route] %@ old pid=%d still alive; abort, never deliver to wrong account", route.bundleID, oldPID);
        CXFinishSystemRoute(route, CXRouteError(3, @"Previous account process has not exited"));
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5), dispatch_get_main_queue(), ^{
        CXWaitForOldProcess(route, oldPID, deadline);
    });
}

static void CXDrainSystemRoutes(void) {
    NSCAssert(NSThread.isMainThread, @"chooser must run on main queue");
    if (CXActiveSystemRoute || CXSystemRoutes().count == 0) return;
    if (CXShowingChooser) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{
            CXDrainSystemRoutes();
        });
        return;
    }
    CXSystemRoute *route = CXSystemRoutes().firstObject;
    CXActiveSystemRoute = route;
    CXChooserRoute = route;
    CXPresentSystemRequestChooser(route.bundleID, route.containers, ^(NSString *containerID) {
        if (route.finished || route.containerID.length) return;
        route.containerID = [containerID copy];
        NSString *active = [CXCraneBridge activeContainerForBundleID:route.bundleID] ?: @"DEFAULT";
        BOOL same = [active isEqualToString:containerID];
        BOOL known = NO;
        pid_t oldPID = CXApplicationPID(route.bundleID, &known);
        if (!same && !known) {
            CXLog(@"[route] %@ cannot identify previous process; refuse unsafe account switch", route.bundleID);
            CXFinishSystemRoute(route, CXRouteError(4, @"Unable to identify previous account process"));
            return;
        }
        CXLog(@"[route] %@ selected=%@ same=%d oldPID=%d requests=%lu", route.bundleID,
              containerID, same, oldPID, (unsigned long)route.items.count);
        [CXCraneBridge switchBundleID:route.bundleID toContainer:containerID reload:!same completion:^(BOOL ok) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (route.finished) return;
                if (!ok) {
                    CXFinishSystemRoute(route, CXRouteError(2, @"Account switch failed"));
                    return;
                }
                // Do not wait for a new scene: the original request creates it.
                if (same) CXForwardNextSystemRequest(route);
                else CXWaitForOldProcess(route, oldPID, CACurrentMediaTime() + 5.0);
            });
        }];
    }, ^{
        if (route.finished) return;
        CXLog(@"[route] %@ cancelled; reject %lu requests, no forward", route.bundleID,
              (unsigned long)route.items.count);
        CXFinishSystemRoute(route, CXRouteError(NSUserCancelledError, @"User cancelled application jump"));
    });
}

static void CXSystemRequestHook(id self, SEL _cmd, id service, id request, CXSystemCompletion completion) {
    if (!CXOrigSystemRequest) return;
    NSString *bundleID = CXRequestTargetBundle(request);
    BOOL hasPayload = CXRequestHasURLPayload(request);
    NSArray<NSDictionary *> *containers = bundleID.length ? [CXCraneBridge containersForBundleID:bundleID] : @[];
    if (bundleID.length || hasPayload) {
        CXLog(@"[route] request=%p class=%@ target=%@ payload=%d containers=%lu main=%d", request,
              NSStringFromClass([request class]), bundleID ?: @"?", hasPayload,
              (unsigned long)containers.count, NSThread.isMainThread);
    }
    if (CXInternalOpen || !bundleID.length || !hasPayload || containers.count < 2) {
        BOOL diag = bundleID.length && hasPayload && !CXInternalOpen;
        if (diag) CXLogRequestOptions(bundleID, request, "passthrough-before");
        CXOrigSystemRequest(self, _cmd, service, request, completion);
        // PX 若拦截，会在调用原函数前同步改写 options，此处能看到改动结果。
        if (diag) CXLogRequestOptions(bundleID, request, "passthrough-after");
        return;
    }
    // Copy BEFORE returning from this hook, regardless of incoming queue.
    CXSystemRequestItem *item = [CXSystemRequestItem new];
    item.completion = [completion copy];
    item.receiver = self; item.service = service; item.request = request; item.selector = _cmd;
    void (^enqueue)(void) = ^{
        CXSystemRoute *route = CXRouteForBundle(bundleID);
        if (!route) {
            route = [CXSystemRoute new];
            route.bundleID = bundleID; route.containers = containers;
            route.items = [NSMutableArray array];
            [CXSystemRoutes() addObject:route];
            __weak CXSystemRoute *weakRoute = route;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                CXSystemRoute *pending = weakRoute;
                if (pending && !pending.finished && !pending.selected) {
                    CXLog(@"[route] %@ selection/switch timeout; reject without opening", pending.bundleID);
                    CXFinishSystemRoute(pending, CXRouteError(5, @"Application selection timed out"));
                }
            });
        }
        [route.items addObject:item];
        CXLog(@"[route] %@ queued request=%p count=%lu; no pre-selection forward", bundleID,
              request, (unsigned long)route.items.count);
        CXDrainSystemRoutes();
    };
    if (NSThread.isMainThread) enqueue();
    else dispatch_async(dispatch_get_main_queue(), enqueue);
}
