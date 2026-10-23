#import <UIKit/UIKit.h>

@interface _UISystemGestureManager : NSObject
+ (instancetype)sharedInstance;
- (void)addGestureRecognizer:(UIGestureRecognizer *)gesture 
           toDisplayWithIdentity:(id)displayIdentity;
@end

@interface SCSystemGesture : NSObject
+ (void)registerGesture:(UIGestureRecognizer *)gesture;
@end

@implementation SCSystemGesture

+ (void)registerGesture:(UIGestureRecognizer *)gesture {
    Class mgr = NSClassFromString(@"_UISystemGestureManager");
    if (!mgr) {
        NSLog(@"[SC] WARN: _UISystemGestureManager not found");
        return;
    }
    
    id shared = [mgr performSelector:@selector(sharedInstance)];
    if (!shared) return;
    
    // 取 displayIdentity（优先 UIScreen.mainScreen.displayIdentity）
    id identity = nil;
    UIScreen *screen = [UIScreen mainScreen];
    if ([screen respondsToSelector:@selector(displayIdentity)]) {
        identity = [screen performSelector:@selector(displayIdentity)];
    }
    
    [shared addGestureRecognizer:gesture toDisplayWithIdentity:identity];
    NSLog(@"[SC] Registered system gesture: %@", gesture);
}

@end
