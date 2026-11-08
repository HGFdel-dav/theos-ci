#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <notify.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
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

// Only synchronous original-IMP forwarding owns this main-thread stack depth.
// It expires on return (including exceptions), never on a timer or another process.
static NSUInteger PXURLForwardDepth;
#define PX_FORWARD_URL(expression) do { \
    BOOL pxMainForward = NSThread.isMainThread; \
    if (pxMainForward) ++PXURLForwardDepth; \
    @try { expression; } \
    @finally { if (pxMainForward) --PXURLForwardDepth; } \
} while (0)

typedef void (*PXOpenRequestIMP)(id, SEL, id, id, id);
typedef void (*PXWorkspaceRequestIMP)(id, SEL, id, id, id, id, id);
typedef void (*PXOpenURLCoreIMP)(id, SEL, id, BOOL, BOOL, id, id, id);
static PXOpenRequestIMP PXOrigHandleOpenRequest;
static PXWorkspaceRequestIMP PXOrigWorkspaceRequest;
static PXOpenURLCoreIMP PXOrigOpenURLCore;
static BOOL PXServiceRequestInstalled;
static BOOL PXWorkspaceRequestInstalled;
static BOOL PXOpenURLCoreInstalled;

// Private callback argument signatures are unknown. A confirmed @? is copied
// as an object and passed only to its original IMP; it is never invoked here.
static void PXHandleOpenRequest(id self, SEL command, id service, id request, id completion) {
    if (!PXOrigHandleOpenRequest) return;
    if (!NSThread.isMainThread || PXURLForwardDepth ||
        ![PXCloneURLRouter paymentURLForRequest:request options:nil]) {
        PX_FORWARD_URL(PXOrigHandleOpenRequest(self, command, service, request, completion));
        return;
    }
    id ownedCompletion = [completion copy];
    void (^proceed)(void) = ^{
        PX_FORWARD_URL(PXOrigHandleOpenRequest(self, command, service, request, ownedCompletion));
    };
    [PXCloneProbe log:@"FBREQ payment=1"];
    if ([PXCloneURLRouter handleOpenRequest:request options:nil proceed:proceed]) return;
    proceed();
}

static void PXHandleWorkspaceRequest(id self, SEL command, id request, id options,
                                     id settings, id origin, id result) {
    if (!PXOrigWorkspaceRequest) return;
    // Notification/bundle-only requests have no actual target payment URL.
    // This test precedes block copy, proceed creation and all catalog work.
    if (!NSThread.isMainThread || PXURLForwardDepth ||
        ![PXCloneURLRouter paymentURLForRequest:request options:options]) {
        PX_FORWARD_URL(PXOrigWorkspaceRequest(self, command, request, options, settings, origin, result));
        return;
    }
    id ownedResult = [result copy];
    void (^proceed)(void) = ^{
        PX_FORWARD_URL(PXOrigWorkspaceRequest(self, command, request, options, settings, origin, ownedResult));
    };
    [PXCloneProbe log:@"SBREQ payment=1"];
    if ([PXCloneURLRouter handleOpenRequest:request options:options proceed:proceed]) return;
    proceed();
}

// The URL-bearing SpringBoard entry predates the bundle-only workspace entry.
// Runtime @? confirms block ownership, not the block's internal call signature.
static void PXHandleOpenURLCore(id self, SEL command, id url, BOOL display,
                                BOOL animating, id settings, id origin, id result) {
    if (!PXOrigOpenURLCore) return;
    if (!NSThread.isMainThread || PXURLForwardDepth ||
        ![url isKindOfClass:NSURL.class] || ![PXCloneURLRouter isPaymentURL:(NSURL *)url]) {
        PX_FORWARD_URL(PXOrigOpenURLCore(self, command, url, display, animating, settings, origin, result));
        return;
    }
    id ownedResult = [result copy];
    void (^proceed)(void) = ^{
        PX_FORWARD_URL(PXOrigOpenURLCore(self, command, url, display, animating, settings, origin, ownedResult));
    };
    [PXCloneProbe log:@"SBCORE payment=1"];
    if ([PXCloneURLRouter handleOpenURL:(NSURL *)url proceed:proceed]) return;
    proceed();
}

static BOOL PXInstallURLRoutingHook(void) {
    if (!PXWorkspaceRequestInstalled) {
        SEL selector = NSSelectorFromString(@"_handleOpenApplicationRequest:options:activationSettings:origin:withResult:");
        Class cls = PXClassDeclaringSelector(selector, @encode(void), @[@"@", @"@", @"@", @"@", @"@?"]);
        IMP original = NULL;
        if (cls && PXCloneHookMessage(cls, selector, (IMP)PXHandleWorkspaceRequest, &original)) {
            PXOrigWorkspaceRequest = (PXWorkspaceRequestIMP)original;
            PXWorkspaceRequestInstalled = YES;
            [PXCloneProbe log:@"SBHOOK installed"];
        }
    }
    if (!PXOpenURLCoreInstalled) {
        SEL selector = NSSelectorFromString(@"_openURLCore:display:animating:activationSettings:origin:withResult:");
        NSString *boolType = [NSString stringWithUTF8String:@encode(BOOL)];
        Class cls = PXClassDeclaringSelector(selector, @encode(void),
            @[@"@", boolType, boolType, @"@", @"@", @"@?"]);
        IMP original = NULL;
        if (cls && PXCloneHookMessage(cls, selector, (IMP)PXHandleOpenURLCore, &original)) {
            PXOrigOpenURLCore = (PXOpenURLCoreIMP)original;
            PXOpenURLCoreInstalled = YES;
            [PXCloneProbe log:@"SBCOREHOOK installed"];
        }
    }
    // Optional: absence or any ABI mismatch must never keep bootstrap alive.
    if (!PXServiceRequestInstalled) {
        Class service = NSClassFromString(@"FBSystemService");
        SEL selector = NSSelectorFromString(@"systemService:handleOpenApplicationRequest:withCompletion:");
        IMP original = NULL;
        if (PXCloneClassInstanceMethodMatches(service, selector, @encode(void), @[@"@", @"@", @"@?"]) &&
            PXCloneHookMessage(service, selector, (IMP)PXHandleOpenRequest, &original)) {
            PXOrigHandleOpenRequest = (PXOpenRequestIMP)original;
            PXServiceRequestInstalled = YES;
            [PXCloneProbe log:@"FBHOOK installed"];
        }
    }
    return PXWorkspaceRequestInstalled || PXOpenURLCoreInstalled;
}

// UIKit's public completion signature is known; private callbacks above are
// deliberately opaque. Every original has one selector and one install guard.
typedef void (^PXOpenURLCompletion)(BOOL success);
typedef BOOL (*PXOpenURLIMP)(id, SEL, NSURL *);
typedef void (*PXOpenURLOptionsIMP)(id, SEL, NSURL *, NSDictionary *, PXOpenURLCompletion);
typedef BOOL (*PXWorkspaceOpenIMP)(id, SEL, id, id);
static PXOpenURLIMP PXOrigOpenURL;
static PXOpenURLOptionsIMP PXOrigOpenURLOptions;
static PXWorkspaceOpenIMP PXOrigWorkspaceSensitiveOpen;
static PXWorkspaceOpenIMP PXOrigWorkspacePublicOpen;
static BOOL PXOpenURLInstalled;
static BOOL PXOpenURLOptionsInstalled;
static BOOL PXWorkspaceSensitiveOpenInstalled;
static BOOL PXWorkspacePublicOpenInstalled;

static BOOL PXProbeOpenURL(id self, SEL command, NSURL *url) {
    if (!PXOrigOpenURL) return NO;
    if (!NSThread.isMainThread || PXURLForwardDepth ||
        ![url isKindOfClass:NSURL.class] || ![PXCloneURLRouter isPaymentURL:url]) {
        PX_FORWARD_URL(return PXOrigOpenURL(self, command, url));
    }
    // Preserve the synchronous BOOL if the router declines or forwards now.
    __block BOOL forwarded = NO;
    __block BOOL originalResult = NO;
    void (^proceed)(void) = ^{
        PX_FORWARD_URL(originalResult = PXOrigOpenURL(self, command, url));
        forwarded = YES;
    };
    [PXCloneProbe log:@"UIOPEN payment=1"];
    if ([PXCloneURLRouter handleOpenURL:url proceed:proceed])
        return forwarded ? originalResult : YES;
    proceed();
    return originalResult;
}

static void PXProbeOpenURLOptions(id self, SEL command, NSURL *url,
                                  NSDictionary *options, PXOpenURLCompletion completion) {
    if (!PXOrigOpenURLOptions) return;
    if (!NSThread.isMainThread || PXURLForwardDepth ||
        ![url isKindOfClass:NSURL.class] || ![PXCloneURLRouter isPaymentURL:url]) {
        PX_FORWARD_URL(PXOrigOpenURLOptions(self, command, url, options, completion));
        return;
    }
    PXOpenURLCompletion ownedCompletion = [completion copy];
    void (^proceed)(void) = ^{
        PX_FORWARD_URL(PXOrigOpenURLOptions(self, command, url, options, ownedCompletion));
    };
    [PXCloneProbe log:@"UIOPEN-OPTIONS payment=1"];
    if ([PXCloneURLRouter handleOpenURL:url proceed:proceed]) return;
    proceed();
}

// Each entry supplies its own original; the saved IMP always matches _cmd.
static BOOL PXRouteWorkspaceOpen(id self, SEL command, id url, id options, PXWorkspaceOpenIMP original) {
    if (!original) return NO;
    if (!NSThread.isMainThread || PXURLForwardDepth ||
        ![url isKindOfClass:NSURL.class] || ![PXCloneURLRouter isPaymentURL:(NSURL *)url]) {
        PX_FORWARD_URL(return original(self, command, url, options));
    }
    __block BOOL forwarded = NO;
    __block BOOL originalResult = NO;
    void (^proceed)(void) = ^{
        PX_FORWARD_URL(originalResult = original(self, command, url, options));
        forwarded = YES;
    };
    [PXCloneProbe log:@"LSOPEN payment=1"];
    if ([PXCloneURLRouter handleOpenURL:(NSURL *)url proceed:proceed])
        return forwarded ? originalResult : YES;
    proceed();
    return originalResult;
}

static BOOL PXProbeWorkspaceSensitiveOpen(id self, SEL command, id url, id options) {
    return PXRouteWorkspaceOpen(self, command, url, options, PXOrigWorkspaceSensitiveOpen);
}

static BOOL PXProbeWorkspacePublicOpen(id self, SEL command, id url, id options) {
    return PXRouteWorkspaceOpen(self, command, url, options, PXOrigWorkspacePublicOpen);
}

static BOOL PXInstallProbeHooks(void) {
    Class app = NSClassFromString(@"UIApplication");
    SEL plain = NSSelectorFromString(@"openURL:");
    if (!PXOpenURLInstalled && PXCloneClassInstanceMethodMatches(app, plain, @encode(BOOL), @[@"@"])) {
        IMP original = NULL;
        if (PXCloneHookMessage(app, plain, (IMP)PXProbeOpenURL, &original)) {
            PXOrigOpenURL = (PXOpenURLIMP)original;
            PXOpenURLInstalled = YES;
        }
    }
    SEL options = NSSelectorFromString(@"openURL:options:completionHandler:");
    if (!PXOpenURLOptionsInstalled &&
        PXCloneClassInstanceMethodMatches(app, options, @encode(void), @[@"@", @"@", @"@?"])) {
        IMP original = NULL;
        if (PXCloneHookMessage(app, options, (IMP)PXProbeOpenURLOptions, &original)) {
            PXOrigOpenURLOptions = (PXOpenURLOptionsIMP)original;
            PXOpenURLOptionsInstalled = YES;
        }
    }
    Class workspace = NSClassFromString(@"LSApplicationWorkspace");
    SEL sensitive = NSSelectorFromString(@"openSensitiveURL:withOptions:");
    if (!PXWorkspaceSensitiveOpenInstalled &&
        PXCloneClassInstanceMethodMatches(workspace, sensitive, @encode(BOOL), @[@"@", @"@"])) {
        IMP original = NULL;
        if (PXCloneHookMessage(workspace, sensitive, (IMP)PXProbeWorkspaceSensitiveOpen, &original)) {
            PXOrigWorkspaceSensitiveOpen = (PXWorkspaceOpenIMP)original;
            PXWorkspaceSensitiveOpenInstalled = YES;
        }
    }
    SEL publicOpen = NSSelectorFromString(@"openURL:withOptions:");
    if (!PXWorkspacePublicOpenInstalled &&
        PXCloneClassInstanceMethodMatches(workspace, publicOpen, @encode(BOOL), @[@"@", @"@"])) {
        IMP original = NULL;
        if (PXCloneHookMessage(workspace, publicOpen, (IMP)PXProbeWorkspacePublicOpen, &original)) {
            PXOrigWorkspacePublicOpen = (PXWorkspaceOpenIMP)original;
            PXWorkspacePublicOpenInstalled = YES;
        }
    }
    return YES;
}

#undef PX_FORWARD_URL

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

static BOOL PXDylibImageLoaded(const char *needle) {
    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index++) {
        const char *name = _dyld_get_image_name(index);
        if (name && strstr(name, needle)) return YES;
    }
    return NO;
}

// The hosted panel normally starts from its own SpringBoard constructor. When
// that image is present but never built its UI (no handle, no panel, no
// split-screen), re-open it here and call the documented class entry instead
// of guessing: the class registration is the only reliable "already running"
// signal, and dlopen of a loaded image is a no-op.
static void PXEnsureOriginalPanel(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    if (NSClassFromString(@"ParallelX.PXPanelEntry") || NSClassFromString(@"PXPanelEntry")) {
        [PXCloneProbe log:@"ORIG-PRESENT image=%d", (int)PXDylibImageLoaded("ParallelX.dylib")];
        return;
    }
    BOOL image = PXDylibImageLoaded("ParallelX.dylib");
    [PXCloneProbe log:@"ORIG-MISSING image=%d", (int)image];
    if (image) return; // present but classless: a real load fault, not a skip
    void *handle = dlopen("/usr/lib/TweakInject/ParallelX.dylib", RTLD_NOW);
    if (!handle) handle = dlopen("/Library/MobileSubstrate/DynamicLibraries/ParallelX.dylib", RTLD_NOW);
    if (!handle) {
        const char *why = dlerror();
        [PXCloneProbe log:@"ORIG-DLOPEN-FAIL %s", why ?: "(nil)"];
        return;
    }
    Class panel = NSClassFromString(@"ParallelX.PXPanelEntry");
    SEL start = NSSelectorFromString(@"start");
    if (panel && [panel respondsToSelector:start]) {
        [PXCloneProbe log:@"ORIG-START-CALL"];
        ((void (*)(id, SEL))objc_msgSend)((id)panel, start);
    } else {
        [PXCloneProbe log:@"ORIG-START-MISSING class=%d", (int)(panel != nil)];
    }
}

// Run only after dyld returned to the main run loop. In particular, do not
// dlopen Crane or create its shared manager from the dylib initializer.
// A named bounded retry avoids scheduling a nil, weak self-referencing block.
static void PXBootstrap(NSUInteger attempt) {
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    if (attempt == 0) [PXCloneProbe log:@"BOOT-LOADED bid=%@", bundleID ?: @"(nil)"];
    BOOL springboard = [bundleID isEqualToString:@"com.apple.springboard"];
    // Match the SpringBoard-only image filter; never install in app/extensions.
    if (!springboard) return;
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
        PXEnsureOriginalPanel();
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
