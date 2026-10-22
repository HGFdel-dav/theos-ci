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

// 切换容器；completion 保证只在主队列回调一次。
+ (void)switchBundleID:(NSString *)bundleID
           toContainer:(NSString *)containerID
            completion:(void (^)(BOOL ok))completion;

// reload=NO：只落定容器，不重启应用（随后由 PX 启动应用，容器在启动时生效）
+ (void)switchBundleID:(NSString *)bundleID
           toContainer:(NSString *)containerID
                reload:(BOOL)reload
            completion:(void (^)(BOOL ok))completion;

+ (void)prepareLaunchForBundleID:(NSString *)bundleID
                     containerID:(NSString * _Nullable)containerID
                      completion:(void (^)(BOOL ok))completion;

// 诊断：返回尝试过的路径和是否存在（设置页展示用）
+ (NSArray<NSString *> *)diagnosticLines;
@end

NS_ASSUME_NONNULL_END