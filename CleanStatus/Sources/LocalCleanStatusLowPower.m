#import "LocalCleanStatusRuntime.h"
#import "LocalCleanStatusConfig.h"
#import "LocalCleanStatusPreferences.h"
#import <dlfcn.h>

static double lcsLastPowerRequest = -1;
static dispatch_queue_t lcsPowerQueue;
static BOOL lcsPowerInFlight;

static BOOL local_cleanstatus_deviceLocked(void) {
    Class cls = NSClassFromString(@"SBLockScreenManager");
    id manager = local_cleanstatus_object(cls, "sharedInstance");
    // An unknown lock state must not silently enable an interaction.
    return local_cleanstatus_boolValue(manager, "isUILocked", YES);
}

static void local_cleanstatus_toggleInSpringBoard(void) {
    NSCAssert(NSThread.isMainThread, @"CleanStatus power request must use main queue");
    if (lcsPowerInFlight || !local_cleanstatus_tapAllowed(local_cleanstatus_currentFlags(), YES, local_cleanstatus_deviceLocked(),
        NSProcessInfo.processInfo.systemUptime, lcsLastPowerRequest)) return;
    lcsLastPowerRequest = NSProcessInfo.processInfo.systemUptime;
    lcsPowerInFlight = YES;
    dispatch_async(lcsPowerQueue, ^{
        @autoreleasepool {
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                // Keep framework loaded while its ObjC methods/objects are in use.
                dlopen("/System/Library/PrivateFrameworks/CoreDuet.framework/CoreDuet", RTLD_LAZY | RTLD_LOCAL);
            });
            id saver = local_cleanstatus_object(NSClassFromString(@"_CDBatterySaver"), "batterySaver");
            SEL setPower = sel_registerName("setPowerMode:error:");
            const char *args[] = { @encode(long long), "^@" };
            BOOL success = NO;
            if (local_cleanstatus_hasFeature(local_cleanstatus_currentFlags(), LocalCleanStatusTapLowPower) &&
                local_cleanstatus_methodMatches(object_getClass(saver), setPower, @encode(BOOL), 2, args)) {
                // Match the actual pointer-to-object argument, never an id/integer guess.
                NSError *__autoreleasing error = nil;
                NSInteger mode = local_cleanstatus_integer(saver, "getPowerMode", -1);
                long long nextMode = mode == 1 ? 0 : 1;
                if (mode == 0 || mode == 1)
                    success = ((BOOL(*)(id,SEL,long long,NSError *__autoreleasing *))objc_msgSend)
                        (saver, setPower, nextMode, &error);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                lcsPowerInFlight = NO;
                if (success) {
                    UISelectionFeedbackGenerator *feedback = [[UISelectionFeedbackGenerator alloc] init];
                    [feedback selectionChanged];
                }
            });
        }
    });
}

static void local_cleanstatus_powerNotification(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                  const void *object, CFDictionaryRef info) {
    (void)center; (void)observer; (void)name; (void)object; (void)info;
    dispatch_async(dispatch_get_main_queue(), ^{ local_cleanstatus_toggleInSpringBoard(); });
}
void local_cleanstatus_installLowPowerBridge(void) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    lcsPowerQueue = dispatch_queue_create("com.local.cleanstatus.power", DISPATCH_QUEUE_SERIAL);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, local_cleanstatus_powerNotification,
        (__bridge CFStringRef)local_cleanstatus_toggleLowPowerNotification, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}
void local_cleanstatus_requestLowPowerToggle(void) {
    if (!local_cleanstatus_hasFeature(local_cleanstatus_currentFlags(), LocalCleanStatusTapLowPower)) return;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)local_cleanstatus_toggleLowPowerNotification, NULL, NULL, true);
}
