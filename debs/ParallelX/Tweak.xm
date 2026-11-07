#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <notify.h>
#import "Common/PXCloneCrane.h"
#import "Common/PXCloneMenu.h"
#import "Common/PXCloneLaunch.h"
#import "Common/PXClonePrefs.h"
#import "Common/PXCloneRuntime.h"
#import "Common/PXCloneURLRouter.h"
#import "Common/PXCloneProbe.h"

#ifdef PXCLONE_STRIP_LOGS
#define NSLog(...) ((void)0)
#endif

// Both action signatures are intercepted by actual declaring class and ABI.
// alpha391 metadata places them on PXSceneBridge; no owner-class name guess
// may decide whether the clone item is consumed.
static BOOL (*PXOrigPerformAction2)(id, SEL, id, BOOL);
static BOOL (*PXOrigPerformAction1)(id, SEL, id);
static NSString *PXLastIdentifier;
static NSTimeInterval PXLastHandledTime;
static int PXNotifyToken = -1;
static void (*PXOrigDragHandle)(id, SEL, id);
static void (*PXOrigContainersChanged)(id, SEL, id);
static void (*PXOrigContainerSettingsChanged)(id, SEL, id, id);
static BOOL PXRefreshInFlight;
static BOOL PXRefreshPending;
static void (*PXOrigHandleOpenRequest)(id, SEL, id, id, id);

// Bounded retry window for the tap hook. The menu rows and the settings
// notification are installed on the first pass and stay installed even if the
// hook never appears, so a missing hook cannot hide the whole feature.
static const NSUInteger PXHookAttemptLimit = 120;
static const int64_t PXHookRetryDelayNS = 250 * NSEC_PER_MSEC;

#pragma mark - Class resolution

// The loaded class list is snapshotted once: scanning it is cheap, but the
// bootstrap retries and every scan would otherwise allocate and walk ~20k
// classes on the main queue.
static Class *PXClassSnapshot(int *outCount) {
    static Class *classes;
    static int count;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        count = objc_getClassList(NULL, 0);
        if (count > 0) {
            classes = (Class *)malloc(sizeof(Class) * (size_t)count);
            count = classes ? objc_getClassList(classes, count) : 0;
        }
    });
    if (outCount) *outCount = count;
    return classes;
}

// Swift-backed classes are registered under their mangled Objective-C name
// (for example _TtC9ParallelX12PXPanelEntry), so a plain NSClassFromString can
// return nil. Fall back to a suffix scan over the loaded classes and cache it.
static Class PXResolveClass(NSString *name) {
    if (!name.length) return Nil;
    static NSMutableDictionary<NSString *, id> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });

    @synchronized (cache) {
        id cached = cache[name];
        if (cached) return cached == NSNull.null ? Nil : (Class)cached;
    }

    Class resolved = NSClassFromString(name);
    if (!resolved) {
        int count = 0;
        Class *classes = PXClassSnapshot(&count);
        for (int i = 0; i < count; i++) {
            Class cls = classes[i];
            if (!cls) continue;
            const char *raw = class_getName(cls);
            if (!raw) continue;
            NSString *candidate = @(raw);
            if (![candidate isEqualToString:name] && ![candidate hasSuffix:name]) continue;
            resolved = cls;
            break;
        }
    }

    @synchronized (cache) { cache[name] = resolved ? (id)resolved : (id)NSNull.null; }
    return resolved;
}

#pragma mark - Virtual items

static BOOL PXRecentlyHandled(NSString *identifier) {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    BOOL duplicate = [PXLastIdentifier isEqualToString:identifier] && now - PXLastHandledTime < 0.08;
    PXLastIdentifier = [identifier copy];
    PXLastHandledTime = now;
    // Consecutive duplicate only: A→B→A must not swallow the return to A.
    return duplicate;
}

static NSString *PXIdentifierFromArgument(id argument) {
    if ([argument isKindOfClass:NSString.class]) return argument;
    if ([argument isKindOfClass:NSDictionary.class]) {
        id identifier = ((NSDictionary *)argument)[@"id"];
        if ([identifier isKindOfClass:NSString.class]) return identifier;
    }
    return nil;
}

// Handles only our virtual item. YES means PX must not continue its own path.
static BOOL PXHandleVirtualItem(id argument) {
    NSString *identifier = PXIdentifierFromArgument(argument);
    if (!identifier.length) return NO;
    NSDictionary *item = PXCloneItemForIdentifier(identifier);
    if (!item) return NO;

    NSString *bundle = item[@"bundle"];
    NSString *container = item[@"container"];
    if (!bundle.length || !container.length) return YES;
    if (PXRecentlyHandled(identifier)) return YES;

    [PXCloneLaunchController.shared requestBundle:bundle container:container];
    return YES;
}

static BOOL PXPerformAction2(id self, SEL _cmd, id argument, BOOL fromSearch) {
    if (PXHandleVirtualItem(argument)) return YES;
    return PXOrigPerformAction2 ? PXOrigPerformAction2(self, _cmd, argument, fromSearch) : NO;
}

static BOOL PXPerformAction1(id self, SEL _cmd, id argument) {
    if (PXHandleVirtualItem(argument)) return YES;
    return PXOrigPerformAction1 ? PXOrigPerformAction1(self, _cmd, argument) : NO;
}

// The declaring class is discovered by ABI instead of by name: the entry point
// lives on a Swift class whose Objective-C name is not stable across builds,
// and an inherited implementation must not be hooked once per subclass. The
// method-existence check runs first so the signature matcher - the expensive
// part - is only reached for the handful of classes that implement the
// selector at all.
static Class PXClassDeclaringSelector(SEL selector, const char *returnType,
                                      NSArray<NSString *> *argumentTypes) {
    int count = 0;
    Class *classes = PXClassSnapshot(&count);
    if (!classes) return Nil;
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        if (!cls) continue;
        Method method = class_getInstanceMethod(cls, selector);
        if (!method) continue;
        if (!PXCloneClassInstanceMethodMatches(cls, selector, returnType, argumentTypes)) continue;
        Class super = class_getSuperclass(cls);
        Method inherited = super ? class_getInstanceMethod(super, selector) : NULL;
        if (inherited &&
            method_getImplementation(method) == method_getImplementation(inherited)) continue;
        return cls;
    }
    return Nil;
}

static BOOL PXInstallActionHook(void) {
    BOOL hooked = NO;

    if (PXOrigPerformAction2) {
        hooked = YES;
    } else {
        SEL selector = NSSelectorFromString(@"performConfiguredAction:fromSearchFavorites:");
        Class cls = PXClassDeclaringSelector(selector, @encode(BOOL),
                                             @[@"@", [NSString stringWithUTF8String:@encode(BOOL)]]);
        IMP original = NULL;
        if (cls && PXCloneHookMessage(cls, selector, (IMP)PXPerformAction2, &original)) {
            PXOrigPerformAction2 = (BOOL (*)(id, SEL, id, BOOL))original;
            hooked = YES;
        }
    }

    if (PXOrigPerformAction1) {
        hooked = YES;
    } else {
        SEL selector = NSSelectorFromString(@"performConfiguredAction:");
        Class cls = PXClassDeclaringSelector(selector, @encode(BOOL), @[@"@"]);
        IMP original = NULL;
        if (cls && PXCloneHookMessage(cls, selector, (IMP)PXPerformAction1, &original)) {
            PXOrigPerformAction1 = (BOOL (*)(id, SEL, id))original;
            hooked = YES;
        }
    }

    return hooked;
}

static void PXRefreshAndSync(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ PXRefreshAndSync(); }); return;
    }
    if (PXRefreshInFlight) { PXRefreshPending = YES; return; }
    PXRefreshInFlight = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        [PXClonePrefs.shared reloadSnapshot:&error];
        [PXCloneCrane refreshCatalogWithCompletion:^(NSArray<NSDictionary *> *catalog, NSError *catalogError) {
            (void)catalog;
            PXRefreshInFlight = NO;
            if (!catalogError) PXCloneSyncMenu();
            if (PXRefreshPending) {
                PXRefreshPending = NO;
                dispatch_async(dispatch_get_main_queue(), ^{ PXRefreshAndSync(); });
            }
        }];
    });
}

static void PXDragHandle(id self, SEL command, id gesture) {
    if ([gesture isKindOfClass:UIGestureRecognizer.class] &&
        ((UIGestureRecognizer *)gesture).state == UIGestureRecognizerStateBegan) PXRefreshAndSync();
    if (PXOrigDragHandle) PXOrigDragHandle(self, command, gesture);
}

static void PXContainersChanged(id self, SEL command, id bundle) {
    if (PXOrigContainersChanged) PXOrigContainersChanged(self, command, bundle);
    PXRefreshAndSync();
}

static void PXContainerSettingsChanged(id self, SEL command, id container, id bundle) {
    if (PXOrigContainerSettingsChanged) PXOrigContainerSettingsChanged(self, command, container, bundle);
    PXRefreshAndSync();
}

// SpringBoard asks FBSystemService to open an app for an incoming URL (an app
// handoff, a payment app jumping into WeChat, ...). Intercepting here is the
// only place where the clone account can still be chosen before the target app
// is launched. A request without a second container is forwarded immediately.
static void PXHandleOpenRequest(id self, SEL command, id service, id request, id completion) {
    [PXCloneProbe log:@"HOOK self=%@ req=%@ desc=%@",
        NSStringFromClass([self class]), NSStringFromClass([request class]),
        [[request description] substringToIndex:MIN(300u, [request description].length)]];
    void (^proceed)(void) = ^{
        if (PXOrigHandleOpenRequest) PXOrigHandleOpenRequest(self, command, service, request, completion);
    };
    if ([PXCloneURLRouter handleOpenRequest:request proceed:proceed]) return;
    proceed();
}

static BOOL PXInstallURLRoutingHook(void) {
    if (PXOrigHandleOpenRequest) return YES;
    Class service = NSClassFromString(@"FBSystemService");
    SEL selector = NSSelectorFromString(@"systemService:handleOpenApplicationRequest:withCompletion:");
    if (!service || !class_getInstanceMethod(service, selector)) return NO;
    IMP original = NULL;
    if (!PXCloneHookMessage(service, selector, (IMP)PXHandleOpenRequest, &original)) return NO;
    PXOrigHandleOpenRequest = (void (*)(id, SEL, id, id, id))original;
    return YES;
}

// Log-only probes: which lower-level entry points actually see an app->app URL
// open. They never change behavior; the routing decision stays in one place.
static BOOL (*PXOrigOpenURL)(id, SEL, id);
static void (*PXOrigOpenURLOptions)(id, SEL, id, id, id);
static BOOL (*PXOrigWorkspaceOpen)(id, SEL, id, id);

static BOOL PXInAppReentry;

static BOOL PXProbeOpenURL(id self, SEL command, id url) {
    void (^proceed)(void) = ^{
        if (!PXOrigOpenURL) return;
        PXInAppReentry = YES;
        PXOrigOpenURL(self, command, url);
        PXInAppReentry = NO;
    };
    if ([url isKindOfClass:NSURL.class] &&
        [PXCloneURLRouter handleOpenURL:(NSURL *)url proceed:proceed]) return YES;
    [PXCloneProbe log:@"UIApp.openURL passthru url=%@", url];
    if (PXOrigOpenURL) return PXOrigOpenURL(self, command, url);
    return NO;
}

static void PXProbeOpenURLOptions(id self, SEL command, id url, id options, id completion) {
    if (PXInAppReentry) {
        if (PXOrigOpenURLOptions) PXOrigOpenURLOptions(self, command, url, options, completion);
        return;
    }
    void (^proceed)(void) = ^{
        if (PXOrigOpenURLOptions) PXOrigOpenURLOptions(self, command, url, options, completion);
    };
    if ([url isKindOfClass:NSURL.class] &&
        [PXCloneURLRouter handleOpenURL:(NSURL *)url proceed:proceed]) return;
    [PXCloneProbe log:@"UIApp.openURL:options: passthru url=%@", url];
    proceed();
}

// This is the real choke point for web views: a WebContent process performs
// the open, and it has no UIApplication. Route here as well.
static BOOL PXProbeWorkspaceOpen(id self, SEL command, id url, id options) {
    [PXCloneProbe log:@"WS %@ url=%@", NSStringFromSelector(command), url];
    void (^proceed)(void) = ^{
        if (PXOrigWorkspaceOpen) PXOrigWorkspaceOpen(self, command, url, options);
    };
    if ([url isKindOfClass:NSURL.class] &&
        [PXCloneURLRouter handleOpenURL:(NSURL *)url proceed:proceed]) return YES;
    if (PXOrigWorkspaceOpen) return PXOrigWorkspaceOpen(self, command, url, options);
    return NO;
}

static BOOL PXInstallProbeHooks(void) {
    Class app = NSClassFromString(@"UIApplication");
    SEL plain = NSSelectorFromString(@"openURL:");
    if (!PXOrigOpenURL && PXCloneClassInstanceMethodMatches(app, plain, @encode(BOOL), @[@"@"])) {
        IMP original = NULL;
        if (PXCloneHookMessage(app, plain, (IMP)PXProbeOpenURL, &original))
            PXOrigOpenURL = (BOOL (*)(id, SEL, id))original;
    }
    SEL options = NSSelectorFromString(@"openURL:options:completionHandler:");
    if (!PXOrigOpenURLOptions &&
        PXCloneClassInstanceMethodMatches(app, options, @encode(void), @[@"@", @"@", @"@?"])) {
        IMP original = NULL;
        if (PXCloneHookMessage(app, options, (IMP)PXProbeOpenURLOptions, &original))
            PXOrigOpenURLOptions = (void (*)(id, SEL, id, id, id))original;
    }
    Class workspace = NSClassFromString(@"LSApplicationWorkspace");
    for (NSString *name in @[@"openSensitiveURL:withOptions:", @"openURL:withOptions:"]) {
        SEL selector = NSSelectorFromString(name);
        if (!PXCloneClassInstanceMethodMatches(workspace, selector, @encode(BOOL), @[@"@", @"@"])) continue;
        IMP original = NULL;
        if (PXCloneHookMessage(workspace, selector, (IMP)PXProbeWorkspaceOpen, &original))
            PXOrigWorkspaceOpen = (BOOL (*)(id, SEL, id, id))original;
    }
    return YES;
}

static BOOL PXInstallRefreshHooks(void) {
    // Current alpha391 metadata and the device libcrane both confirm these
    // selectors. No timer loop or Settings-only refresh is required.
    Class panel = PXResolveClass(@"PXPanelEntry");
    if (!PXOrigDragHandle) {
        SEL selector = NSSelectorFromString(@"dragHandle:");
        IMP original = NULL;
        if (PXCloneClassInstanceMethodMatches(panel, selector, @encode(void), @[@"@"]) &&
            PXCloneHookMessage(panel, selector, (IMP)PXDragHandle, &original))
            PXOrigDragHandle = (void (*)(id, SEL, id))original;
    }
    Class crane = NSClassFromString(@"CraneManager");
    if (!PXOrigContainersChanged) {
        SEL selector = NSSelectorFromString(@"_observers_didChangeContainersOfApplicationWithIdentifier:");
        IMP original = NULL;
        if (PXCloneClassInstanceMethodMatches(crane, selector, @encode(void), @[@"@"]) &&
            PXCloneHookMessage(crane, selector, (IMP)PXContainersChanged, &original))
            PXOrigContainersChanged = (void (*)(id, SEL, id))original;
    }
    if (!PXOrigContainerSettingsChanged) {
        SEL selector = NSSelectorFromString(@"_observers_didChangeContainerSettingsForContainerWithIdentifier:onApplicationWithIdentifier:");
        IMP original = NULL;
        if (PXCloneClassInstanceMethodMatches(crane, selector, @encode(void), @[@"@", @"@"]) &&
            PXCloneHookMessage(crane, selector, (IMP)PXContainerSettingsChanged, &original))
            PXOrigContainerSettingsChanged = (void (*)(id, SEL, id, id))original;
    }
    return PXOrigDragHandle && PXOrigContainersChanged && PXOrigContainerSettingsChanged;
}

// Run only after dyld returned to the main run loop. In particular, do not
// dlopen Crane or create its shared manager from the dylib initializer.
// A named bounded retry avoids scheduling a nil, weak self-referencing block.
static void PXBootstrap(NSUInteger attempt) {
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    if (attempt == 0) [PXCloneProbe log:@"BOOT-LOADED bid=%@", bundleID ?: @"(nil)"];
    BOOL springboard = [bundleID isEqualToString:@"com.apple.springboard"];
    if (!springboard) {
        // Injected into every process now; daemons get one line and nothing else.
        if (attempt == 0 && bundleID.length) {
            [PXCloneProbe log:@"APP-BOOT %@", bundleID];
            PXInstallProbeHooks();
        }
        if (!bundleID.length) return;
        BOOL ready = PXOrigOpenURL || PXOrigOpenURLOptions;
        if (ready || attempt >= PXHookAttemptLimit) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, PXHookRetryDelayNS),
                       dispatch_get_main_queue(), ^{ PXBootstrap(attempt + 1); });
        return;
    }
    if (attempt == 0) {
        (void)PXClonePrefs.shared;
        if (PXNotifyToken < 0) {
            int status = notify_register_dispatch(PXClonePrefsNotification.UTF8String, &PXNotifyToken,
                                                  dispatch_get_main_queue(), ^(int token) {
                (void)token;
                PXInstallActionHook();
                PXRefreshAndSync();
            });
            if (status != NOTIFY_STATUS_OK) PXNotifyToken = -1;
        }
        PXRefreshAndSync();
    }

    BOOL actionReady = PXInstallActionHook();
    BOOL refreshReady = PXInstallRefreshHooks();
    BOOL launchReady = [PXCloneLaunchController installNativeHooks];
    BOOL routingReady = PXInstallURLRoutingHook();
    PXInstallProbeHooks();
    if ((actionReady && refreshReady && launchReady && routingReady) || attempt >= PXHookAttemptLimit) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, PXHookRetryDelayNS),
                   dispatch_get_main_queue(), ^{ PXBootstrap(attempt + 1); });
}

%ctor {
    // ParallelXClone.plist limits this image to SpringBoard; avoid querying
    // Foundation from dyld's initializer while its Objective-C state is busy.
    dispatch_async(dispatch_get_main_queue(), ^{ PXBootstrap(0); });
}

%dtor {
    if (PXNotifyToken >= 0) notify_cancel(PXNotifyToken);
}
