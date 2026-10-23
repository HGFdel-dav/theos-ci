#import <UIKit/UIKit.h>
#import "RoutePilotConfig.h"
#import "RoutePilotPrivate.h"

// This sample matches the default SpringBoard filter. Replace both together.
%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    if (![[RoutePilotConfig routepilot_app_shared] routepilot_app_isEnabled]) {
        return;
    }
    // Add the plugin's launch behavior here.
}

%end

%ctor {
    @autoreleasepool {
        // Readers load a snapshot; they never write default preferences.
        [RoutePilotConfig routepilot_app_shared];
    }
}
