// TWArcCoordinator.h
// Gesture coordinator for Twin's arc launcher:
// edge pan in the trigger region -> present arc menu -> swipe-select -> launch.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TWArcCoordinator : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)sharedInstance;
- (void)start;   // idempotent; attaches the pan recognizer to the SpringBoard window
- (void)refreshEnabledState;
@end

NS_ASSUME_NONNULL_END