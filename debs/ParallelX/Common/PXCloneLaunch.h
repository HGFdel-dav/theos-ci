#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Serial, latest-target-wins controller. It never cancels an in-flight Crane
// authentication and never uses Crane reload/fullscreen to prepare a split.
@interface PXCloneLaunchController : NSObject
+ (instancetype)shared;
+ (BOOL)installNativeHooks;
- (void)requestBundle:(NSString *)bundle container:(NSString *)container;
@end

FOUNDATION_EXPORT NSString *const PXCloneLaunchTraceKey;

NS_ASSUME_NONNULL_END
