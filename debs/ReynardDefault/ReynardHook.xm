#import <objc/runtime.h>
#import <substrate.h>
#import "Common/Common.h"
#import "Common/RDNativeLink.h"

%ctor {
    @autoreleasepool {
        NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
        if ([bundleID isEqualToString:@"com.apple.springboard"]) return;
        if (![bundleID isEqualToString:@"com.minh-ton.Reynard"]) return;
        RDNativeInstallXULHook();
    }
}
