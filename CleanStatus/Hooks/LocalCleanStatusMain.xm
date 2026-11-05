#import <UIKit/UIKit.h>
#import "LocalCleanStatusConfig.h"
#import "LocalCleanStatusPreferences.h"
#import "LocalCleanStatusRuntime.h"

static id lcsPreferenceObserver;
static NSString * const lcsVersion = @"CleanStatus 0.1.4";

%ctor {
    @autoreleasepool {
        (void)lcsVersion;
        if (![NSBundle.mainBundle.bundlePath.pathExtension isEqualToString:@"app"]) return;
        [LocalCleanStatusConfig local_cleanstatus_shared];
        dispatch_async(dispatch_get_main_queue(), ^{
            local_cleanstatus_installStatusHooks();
            local_cleanstatus_installBatteryHooks();
            local_cleanstatus_installLowPowerBridge();
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
