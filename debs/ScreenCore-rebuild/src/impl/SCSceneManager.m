#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// FrontBoardServices 桥接
@interface FBSOpenApplicationOptions : NSObject
+ (instancetype)optionsWithDictionary:(NSDictionary *)dict;
- (void)setActions:(NSSet *)actions;
@end

@interface FBSOpenApplicationService : NSObject
+ (instancetype)serviceWithDefaultShellEndpoint;
- (void)openApplication:(NSString *)bundleID
            withOptions:(FBSOpenApplicationOptions *)options
             completion:(void(^)(NSError *))completion;
@end

@interface SBApplication : NSObject
@property (nonatomic, copy, readonly) NSString *bundleIdentifier;
@end

@interface SBApplicationController : NSObject
+ (instancetype)sharedInstance;
- (SBApplication *)applicationWithBundleIdentifier:(NSString *)bundleID;
@end

@interface SCSceneManager : NSObject
+ (void)openApplication:(NSString *)bundleID
               inWindow:(UIView *)window
             completion:(void(^)(BOOL success))completion;

+ (void)openApplication:(NSString *)bundleID
             fullscreen:(BOOL)fullscreen
             completion:(void(^)(BOOL success))completion;

+ (NSDictionary *)optionsForFloatingWindow:(UIView *)window;
+ (NSDictionary *)optionsForFullscreen:(BOOL)fullscreen;
@end

@implementation SCSceneManager

+ (void)openApplication:(NSString *)bundleID
               inWindow:(UIView *)window
             completion:(void(^)(BOOL success))completion {
    NSDictionary *opts = [self optionsForFloatingWindow:window];
    [self _openApplication:bundleID options:opts completion:completion];
}

+ (void)openApplication:(NSString *)bundleID
             fullscreen:(BOOL)fullscreen
             completion:(void(^)(BOOL success))completion {
    NSDictionary *opts = [self optionsForFullscreen:fullscreen];
    [self _openApplication:bundleID options:opts completion:completion];
}

+ (void)_openApplication:(NSString *)bundleID
                 options:(NSDictionary *)opts
              completion:(void(^)(BOOL success))completion {
    Class svc = NSClassFromString(@"FBSOpenApplicationService");
    if (!svc) {
        NSLog(@"[SC] ERROR: FBSOpenApplicationService not found");
        if (completion) completion(NO);
        return;
    }
    
    id service = [svc performSelector:@selector(serviceWithDefaultShellEndpoint)];
    if (!service) {
        if (completion) completion(NO);
        return;
    }
    
    Class optClass = NSClassFromString(@"FBSOpenApplicationOptions");
    id fbsOpts = [optClass optionsWithDictionary:opts];
    
    [service openApplication:bundleID
                 withOptions:fbsOpts
                  completion:^(NSError *error) {
        BOOL success = (error == nil);
        NSLog(@"[SC] openApplication %@ success=%d error=%@", bundleID, success, error);
        if (completion) completion(success);
    }];
}

+ (NSDictionary *)optionsForFloatingWindow:(UIView *)window {
    return @{
        @"__ActivateSuspended": @NO,
        @"__PromptUnlockDevice": @YES,
        @"__LaunchOrigin": @"ScreenCore",
        // TODO: 补充 window 参数（需 FBScene / FBSSceneSpecification）
    };
}

+ (NSDictionary *)optionsForFullscreen:(BOOL)fullscreen {
    return @{
        @"__ActivateSuspended": @NO,
        @"__PromptUnlockDevice": @YES,
        @"__LaunchOrigin": @"ScreenCore",
        @"__LaunchInClassic": @(fullscreen),
    };
}

@end
