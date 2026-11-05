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

static BOOL (*PXOrigPerformAction)(id, SEL, id, BOOL);
static NSMutableSet<NSString *> *PXRecent;
static NSMutableSet<PXCloneTransition *> *PXLiveTransitions;
static PXCloneTransition *PXCurrentTransition;
static int PXNotifyToken = -1;

static BOOL PXAppRunning(NSString *bundleID) {
    // PXPanelEntry owns +sharedBridge; the returned PXSceneBridge owns
    // -hasSceneForApplication:.
    Class panel = NSClassFromString(@"PXPanelEntry");
    SEL shared = NSSelectorFromString(@"sharedBridge");
    SEL hasScene = NSSelectorFromString(@"hasSceneForApplication:");
    if (!PXCloneClassMethodMatches(panel, shared, @encode(id), @[], NULL)) return NO;
    id bridge = PXCloneSendId((id)panel, shared);
    if (!bridge || !PXCloneInstanceMethodMatches(bridge, hasScene, @encode(BOOL), @[@"@"])) return NO;
    return PXCloneSendBool1(bridge, hasScene, bundleID);
}

static void PXOpenApplication(NSString *bundleID) {
    if (!bundleID.length) return;
    Class entry = NSClassFromString(@"PXPanelEntry");
    SEL selector = NSSelectorFromString(@"externalOpenApplication:");
    if (!PXCloneClassMethodMatches(entry, selector, @encode(void), @[@"@"], NULL)) return;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)((id)entry, selector, bundleID);
    } @catch (__unused NSException *exception) { }
}

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

static BOOL PXPerformAction(id self, SEL _cmd, id argument, BOOL fromSearch) {
    if (PXHandleVirtualItem(argument)) return YES;
    return PXOrigPerformAction ? PXOrigPerformAction(self, _cmd, argument, fromSearch) : NO;
}

static BOOL PXInstallActionHook(void) {
    Class cls = NSClassFromString(@"PXPanelEntry");
    SEL selector = NSSelectorFromString(@"performConfiguredAction:fromSearchFavorites:");
    if (!PXCloneClassInstanceMethodMatches(cls, selector, @encode(BOOL),
                                           @[@"@", [NSString stringWithUTF8String:@encode(BOOL)]]))
        return NO;
    IMP original = NULL;
    if (!PXCloneHookMessage(cls, selector, (IMP)PXPerformAction, &original)) return NO;
    PXOrigPerformAction = (BOOL (*)(id, SEL, id, BOOL))original;
    return YES;
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
    if (!PXInstallActionHook()) {
        if (attempt >= 25) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ PXBootstrap(attempt + 1); });
        return;
    }

    (void)PXClonePrefs.shared;
    int status = notify_register_dispatch(PXClonePrefsNotification.UTF8String, &PXNotifyToken,
                                          dispatch_get_main_queue(), ^(int token) {
        (void)token;
        PXRefreshAndSync();
    });
    if (status != NOTIFY_STATUS_OK) PXNotifyToken = -1;
    PXRefreshAndSync();
}

%ctor {
    // ParallelXClone.plist limits this image to SpringBoard; avoid querying
    // Foundation from dyld's initializer while its Objective-C state is busy.
    dispatch_async(dispatch_get_main_queue(), ^{ PXBootstrap(0); });
}

%dtor {
    if (PXNotifyToken >= 0) notify_cancel(PXNotifyToken);
}
