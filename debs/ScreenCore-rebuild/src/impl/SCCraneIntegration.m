#import "../headers/SCApplicationTarget.h"

@interface CraneManager : NSObject
+ (instancetype)sharedManager;
- (NSArray<NSString *> *)containerIdentifiersForApplicationWithIdentifier:(NSString *)bundleID;
- (NSString *)activeContainerIdentifierForApplicationWithIdentifier:(NSString *)bundleID;
- (void)setActiveContainerIdentifier:(NSString *)containerID
         forApplicationWithIdentifier:(NSString *)bundleID
     usingBiometricsIfNeededWithSuccessHandler:(void(^)(BOOL))handler;
@end

@interface SCCraneIntegration : NSObject
+ (NSArray<SCApplicationTarget *> *)targetsForApplication:(NSString *)bundleID;
+ (BOOL)switchToTarget:(SCApplicationTarget *)target completion:(void(^)(BOOL))completion;
@end

@implementation SCCraneIntegration

+ (NSArray<SCApplicationTarget *> *)targetsForApplication:(NSString *)bundleID {
    Class crane = NSClassFromString(@"CraneManager");
    if (!crane) {
        // 无 Crane，返回默认容器
        return @[[SCApplicationTarget targetWithBundleID:bundleID]];
    }
    
    id mgr = [crane performSelector:@selector(sharedManager)];
    NSArray *containers = [mgr performSelector:@selector(containerIdentifiersForApplicationWithIdentifier:)
                                    withObject:bundleID];
    
    NSMutableArray *targets = [NSMutableArray array];
    for (NSString *containerID in containers) {
        [targets addObject:[SCApplicationTarget targetWithBundleID:bundleID
                                               containerIdentifier:containerID]];
    }
    
    if (targets.count == 0) {
        [targets addObject:[SCApplicationTarget targetWithBundleID:bundleID]];
    }
    
    return targets;
}

+ (BOOL)switchToTarget:(SCApplicationTarget *)target completion:(void(^)(BOOL))completion {
    Class crane = NSClassFromString(@"CraneManager");
    if (!crane || !target.containerIdentifier) {
        if (completion) completion(NO);
        return NO;
    }
    
    id mgr = [crane performSelector:@selector(sharedManager)];
    [mgr setActiveContainerIdentifier:target.containerIdentifier
         forApplicationWithIdentifier:target.bundleID
     usingBiometricsIfNeededWithSuccessHandler:^(BOOL success) {
        NSLog(@"[SC] Crane switch %@#%@ success=%d",
              target.bundleID, target.containerIdentifier, success);
        if (completion) completion(success);
    }];
    
    return YES;
}

@end
