#import <UIKit/UIKit.h>
#import <substrate.h>
#import "src/headers/SCArcGestureCoordinator.h"
#import "src/headers/SCApplicationTarget.h"

// 全局协调器实例
static SCArcGestureCoordinator *g_coordinator = nil;

// Hook SpringBoard 应用控制器
%hook SBApplicationController

- (void)applicationWithBundleIdentifier:(NSString *)bundleID didChangeWithContext:(id)context {
    %orig;
    
    // 通知应用状态变化
    NSLog(@"[SC] App %@ changed context", bundleID);
    [[SCNotificationObserver sharedObserver] postAppLaunched:bundleID];
}

%end

// Hook SpringBoard 主窗口（注入手势）
%hook SpringBoard

- (void)applicationDidFinishLaunching:(UIApplication *)app {
    %orig;
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self sc_setupGestureCoordinator];
    });
}

%new
- (void)sc_setupGestureCoordinator {
    if (g_coordinator) return;
    
    // 检查总开关
    BOOL enabled = [[SCPreferences sharedInstance] boolForKey:@"enabled" defaultValue:YES];
    if (!enabled) {
        NSLog(@"[SC] Disabled by user preference");
        return;
    }
    
    g_coordinator = [[SCArcGestureCoordinator alloc] init];
    NSLog(@"[SC] Gesture coordinator initialized");
    
    // 监听偏好变化
    [[SCNotificationObserver sharedObserver] observePrefsChanged:^(NSDictionary *userInfo) {
        [[SCPreferences sharedInstance] reload];
        NSLog(@"[SC] Preferences reloaded");
    }];
}

%end

// Hook _UIScenePresentationView（App 内热区注入，可选）
%hook _UIScenePresentationView

- (void)didMoveToWindow {
    %orig;
    
    if (!self.window) return;
    
    // TODO: 注入角落热区视图（类似 Twin TWSceneInject）
    NSLog(@"[SC] Scene presentation view moved to window: %@", self.window);
}

%end

// 构造函数
%ctor {
    NSLog(@"[ScreenCore] Loaded");
    
    // 预加载偏好
    [[SCPreferences sharedInstance] reload];
}
