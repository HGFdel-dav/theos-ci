// CXCraneBridge.h — Crane 容器桥（复用 Twin 0.9.x 验证过的调用与签名守卫）
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CXCraneBridge : NSObject
+ (BOOL)isCraneAvailable;
+ (BOOL)isApplicationSupportedByCrane:(NSString *)bundleID;
+ (NSString *)activeContainerForBundleID:(NSString *)bundleID;
+ (NSArray<NSString *> *)applicationsWithNonDefaultContainers;
+ (NSArray<NSDictionary *> *)containersForBundleID:(NSString *)bundleID;
+ (NSString *)displayNameForContainer:(NSString *)containerID bundleID:(NSString *)bundleID;

// 切到指定容器；completion 保证只在主队列回调一次。
// 目标就是当前容器时直接 completion(YES)。
+ (void)switchBundleID:(NSString *)bundleID
           toContainer:(NSString *)containerID
            completion:(void (^)(BOOL ok))completion;

// 按配置把容器落定；containerID 为空/@"DEFAULT" 时直接放行。
+ (void)prepareLaunchForBundleID:(NSString *)bundleID
                     containerID:(NSString * _Nullable)containerID
                      completion:(void (^)(BOOL ok))completion;
@end

NS_ASSUME_NONNULL_END
