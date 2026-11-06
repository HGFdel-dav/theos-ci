#import <UIKit/UIKit.h>
#import "LocalCleanStatusConfig.h"
#import "LocalCleanStatusPreferences.h"
#import "LocalCleanStatusRuntime.h"
#import "LocalCleanStatusCCEnvironment.h"

static id lcsPreferenceObserver;
static NSString * const lcsVersion = @"CleanStatus 0.2.1";

%ctor {
    @autoreleasepool {
        (void)lcsVersion;
        if (![NSBundle.mainBundle.bundlePath.pathExtension isEqualToString:@"app"]) return;
        local_cleanstatus_ccConsumeSafeModeFlag();
        [LocalCleanStatusConfig local_cleanstatus_shared];
        dispatch_async(dispatch_get_main_queue(), ^{
            local_cleanstatus_installStatusHooks();
            local_cleanstatus_installUnknownPartsHooks();
            local_cleanstatus_installBatteryHooks();
            local_cleanstatus_installLowPowerBridge();
            local_cleanstatus_installControlCenterHooks();
            lcsPreferenceObserver = [NSNotificationCenter.defaultCenter
                addObserverForName:local_cleanstatus_preferencesChangedNotification object:nil
                queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
                    (void)notification;
                    local_cleanstatus_refreshStatusBars();
                    local_cleanstatus_refreshBatteries();
                }];
        });
    }
}
