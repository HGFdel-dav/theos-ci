#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <notify.h>
#import "Common/PXCloneCrane.h"
#import "Common/PXCloneMenu.h"
#import "Common/PXClonePolicy.h"
#import "Common/PXClonePrefs.h"
#import "Common/PXCloneRuntime.h"

#ifdef PXCLONE_STRIP_LOGS
#define NSLog(...) ((void)0)
#endif

// ParallelX moved its action entry point between versions: older builds call
// -performConfiguredAction: on the scene bridge, newer ones call
// -performConfiguredAction:fromSearchFavorites: on the panel entry. Both are
// intercepted when present; the first one reached consumes the identifier.
static BOOL (*PXOrigPerformAction2)(id, SEL, id, BOOL);
static BOOL (*PXOrigPerformAction1)(id, SEL, id);
static NSMutableSet<NSString *> *PXRecent;
static NSMutableSet<PXCloneTransition *> *PXLiveTransitions;
static PXCloneTransition *PXCurrentTransition;
static int PXNotifyToken = -1;

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

    @synchronized (cache) { cache[name] = resolved ?: NSNull.null; }
    return resolved;
}

#pragma mark - ParallelX surfaces

static BOOL PXAppRunning(NSString *bundleID) {
    // PXPanelEntry owns +sharedBridge; the returned PXSceneBridge owns
    // -hasSceneForApplication:.
    Class panel = PXResolveClass(@"PXPanelEntry");
    SEL shared = NSSelectorFromString(@"sharedBridge");
    SEL hasScene = NSSelectorFromString(@"hasSceneForApplication:");
    if (!PXCloneClassMethodMatches(panel, shared, @encode(id), @[], NULL)) return NO;
    id bridge = PXCloneSendId((id)panel, shared);
    if (!bridge || !PXCloneInstanceMethodMatches(bridge, hasScene, @encode(BOOL), @[@"@"])) return NO;
    return PXCloneSendBool1(bridge, hasScene, bundleID);
}

static void PXOpenApplication(NSString *bundleID) {
    if (!bundleID.length) return;
    Class entry = PXResolveClass(@"PXPanelEntry");
    SEL selector = NSSelectorFromString(@"externalOpenApplication:");
    if (!PXCloneClassMethodMatches(entry, selector, @encode(void), @[@"@"], NULL)) return;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)((id)entry, selector, bundleID);
    } @catch (__unused NSException *exception) { }
}

#pragma mark - Virtual items

static BOOL PXRecentlyHandled(NSString *identifier) {
    if (!PXRecent) PXRecent = [NSMutableSet set];
    if ([PXRecent containsObject:identifier]) return YES;
    [PXRecent addObject:identifier];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [PXRecent removeObject:identifier]; });
    return NO;
}

static NSString *PXIdentifierFromArgument(id argument) {
    if ([argument isKindOfClass:NSString.class]) return argument;
    if ([argument isKindOfClass:NSDictionary.class]) {
        id identifier = ((NSDictionary *)argument)[@"id"];
        if ([identifier isKindOfClass:NSString.class]) return identifier;
    }
    return nil;
}

static void PXTrackTransition(PXCloneTransition *transition) {
    if (!PXLiveTransitions) PXLiveTransitions = [NSMutableSet set];
    [PXLiveTransitions addObject:transition];
}

static void PXUntrackTransition(PXCloneTransition *transition) {
    [PXLiveTransitions removeObject:transition];
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

    NSString *active = [PXCloneCrane activeContainerForBundle:bundle];
    if ([active isEqualToString:container]) {
        PXOpenApplication(bundle);
        return YES;
    }

    if (PXCurrentTransition) [PXCurrentTransition cancel];
    __block PXCloneTransition *blockTransition = nil;
    PXCloneTransition *transition =
        [[PXCloneTransition alloc] initWithBundle:bundle
                                       container:container
                                           queue:dispatch_get_main_queue()
                                      completion:^(BOOL ok, NSError *error) {
        PXUntrackTransition(blockTransition);
        if (PXCurrentTransition == blockTransition) PXCurrentTransition = nil;
        if (ok) PXOpenApplication(bundle);
        else if (error) NSLog(@"[parallelxclone] open %@ failed: %@", bundle, error.localizedDescription);
    }];
    blockTransition = transition;
    PXCurrentTransition = transition;
    PXTrackTransition(transition);

    [transition beginWithSwitch:^(void (^done)(BOOL)) {
        NSError *error = nil;
        if (![PXCloneCrane selectContainer:container forBundle:bundle error:&error]) {
            done(NO);
            return;
        }
        if (![PXCloneCrane requestReloadForBundle:bundle error:&error]) {
            done(NO);
            return;
        }
        done(YES);
    } verify:^NSString *{
        NSString *now = [PXCloneCrane activeContainerForBundle:bundle];
        if (![now isEqualToString:container]) return nil;
        // Correct config but the old scene is still draining: keep retrying,
        // and let the policy accept it at the deadline instead of failing.
        if (PXAppRunning(bundle)) return PXClonePolicySettlingStatus;
        return now;
    }];
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
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        // The menu sync reads visibility from the cache; make sure the first
        // sync cannot run against an unloaded (fail-closed) store.
        [PXClonePrefs.shared reloadSnapshot:&error];
        [PXCloneCrane refreshCatalogWithCompletion:^(NSArray<NSDictionary *> *catalog, NSError *catalogError) {
            if (!catalogError) PXCloneSyncMenu();
        }];
    });
}

// Run only after dyld returned to the main run loop. In particular, do not
// dlopen Crane or create its shared manager from the dylib initializer.
// A named bounded retry avoids scheduling a nil, weak self-referencing block.
static void PXBootstrap(NSUInteger attempt) {
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

    if (PXInstallActionHook() || attempt >= PXHookAttemptLimit) return;
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
