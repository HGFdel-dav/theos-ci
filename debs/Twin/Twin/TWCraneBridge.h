// TWCraneBridge.h
// Dynamic bridge into Crane (libcrane.dylib / CraneManager).
// No compile-time dependency on Crane: everything is resolved at runtime,
// exactly like ScreenCore does it. If Crane is absent, all calls no-op.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TWCraneBridge : NSObject
// YES if CraneManager class is reachable (loaded or dlopened).
+ (BOOL)isCraneAvailable;
// Container ID that is currently active for a given app ("" if none/unavailable).
+ (NSString *)activeContainerForBundleID:(NSString *)bundleID;
// Completion is delivered exactly once on the main queue. YES means either
// no enabled mapping exists, or Crane confirmed and read-back verified it.
// NO must never fall through to launching the app. Failures show a UI notice.
+ (void)prepareLaunchForBundleID:(NSString *)bundleID completion:(void (^)(BOOL success))completion;
+ (NSArray<NSDictionary *> *)containersForBundleID:(NSString *)bundleID;
+ (NSArray<NSString *> *)applicationsWithNonDefaultContainers;
+ (NSString *)displayNameForContainer:(NSString *)containerID bundleID:(NSString *)bundleID;
// 指定容器打开（Arc 的"点哪个图标就用哪个容器"走这里）。completion 主线程回调一次。
+ (void)prepareLaunchForBundleID:(NSString *)bundleID containerID:(NSString *)containerID completion:(void (^)(BOOL success))completion;
// Legacy synchronous APIs fail closed: they never initiate an async switch.
+ (BOOL)setContainer:(NSString *)containerID forBundleID:(NSString *)bundleID;
+ (BOOL)applyContainerIfConfiguredForBundleID:(NSString *)bundleID;
@end

NS_ASSUME_NONNULL_END