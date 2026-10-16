// Tweak.xm — Twin
// Arc gesture launcher + Crane container support for ParallelX split screen.
// Injects into SpringBoard only (see Twin.plist filter).
#import <UIKit/UIKit.h>
#import "TWPrefs.h"
#import "TWCraneBridge.h"
#import "TWArcCoordinator.h"
#import "TWArcMenuView.h"

#pragma mark - ParallelX integration
// Every time ParallelX opens an app from its panel, apply the configured
// Crane container (if any) before the launch proceeds. PXPanelEntry is a
// Swift @objc class-method; if ParallelX is not installed (or renames the
// method) Logos silently skips this hook and nothing breaks.
%hook PXPanelEntry

+ (void)applicationActivated:(id)bundleID {
    if ([bundleID isKindOfClass:[NSString class]]) {
        [TWCraneBridge applyContainerIfConfiguredForBundleID:bundleID];
    }
    %orig;
}

%end

#pragma mark - entry

%ctor {
    // SpringBoard's UI may not be ready at construction time; give it a beat
    // and then attach the arc recognizer (idempotent, retries without a window).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[TWArcCoordinator sharedInstance] start];
    });
}