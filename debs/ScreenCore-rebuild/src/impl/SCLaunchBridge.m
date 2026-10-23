#import "../headers/SCApplicationTarget.h"
#import <objc/runtime.h>

// ScreenCore 启动应用的底层桥接（Hook SBApplicationController）

@interface SBApplication : NSObject
@property (nonatomic, copy, readonly) NSString *bundleIdentifier;
@end

@interface SBApplicationController : NSObject
+ (instancetype)sharedInstance;
- (SBApplication *)applicationWithBundleIdentifier:(NSString *)bundleID;
@end

@interface SCLaunchBridge : NSObject
+ (BOOL)launchTarget:(SCApplicationTarget *)target inFloatingView:(UIView *)view;
@end

@implementation SCLaunchBridge

+ (BOOL)launchTarget:(SCApplicationTarget *)target inFloatingView:(UIView *)view {
    // TODO: 调用 SBApplicationController 启动应用
    // 若有 containerIdentifier，需先切换 Crane 容器
    NSLog(@"[SC] launchTarget %@ in view %@", target, view);
    
    Class sbAppCtrl = NSClassFromString(@"SBApplicationController");
    if (!sbAppCtrl) {
        NSLog(@"[SC] ERROR: SBApplicationController not found");
        return NO;
    }
    
    id ctrl = [sbAppCtrl performSelector:@selector(sharedInstance)];
    if (!ctrl) return NO;
    
    id app = [ctrl performSelector:@selector(applicationWithBundleIdentifier:) 
                         withObject:target.bundleID];
    if (!app) {
        NSLog(@"[SC] ERROR: app %@ not found", target.bundleID);
        return NO;
    }
    
    // TODO: 构造 FBSOpenApplicationOptions 并注入 view
    NSLog(@"[SC] app found: %@", app);
    return YES;
}

@end
