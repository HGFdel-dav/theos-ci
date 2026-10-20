// TWArcCoordinator.h
// Gesture coordinator for Twin's arc launcher:
// edge pan in the trigger region -> present arc menu -> swipe-select -> launch.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TWArcCoordinator : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)sharedInstance;
- (void)start;   // idempotent; attaches the pan recognizer to the SpringBoard window
- (void)refreshEnabledState;
// 在任意 view（SpringBoard 窗口 / 注入点）上维护四角 66×66 热区。
// TWSceneInject.m 在 hook 回调里调用；实现见 TWArcCoordinator.m。
+ (void)ensureCornerViewsInPresentationView:(UIView *)host;
@end

NS_ASSUME_NONNULL_END