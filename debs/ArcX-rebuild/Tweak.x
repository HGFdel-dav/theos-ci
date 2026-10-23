#import <substrate.h>
#import "src/AXGestureEnhancer.h"

%ctor {
    NSLog(@"[ArcX] Loaded");
    [[AXGestureEnhancer alloc] init];
}
