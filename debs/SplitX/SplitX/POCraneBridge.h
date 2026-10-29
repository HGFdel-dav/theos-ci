//
//  POCraneBridge.h
//  SplitX
//
//  容器枚举与切换。切换顺序照 ScreenCore 2.0.5 已验证链路：
//  关闭由调用方先做 → 终止旧进程 → 等真实 PID 退出 → Crane 正常认证切换
//  → 回读 activeContainer 必须等于目标。任何一步失败都不继续启动。
//
//  Crane 是可选依赖：未安装时 containers 返回空，switch 直接成功放行。
//

#import <Foundation/Foundation.h>
#import "POSplitTarget.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const POCraneErrorDomain;

typedef NS_ENUM(NSInteger, POCraneErrorCode) {
    POCraneUnavailable = 1,
    POCraneUnsupportedABI,
    POCraneInvalidData,
    POCraneTerminationFailed,
    POCraneVerificationFailed,
    POCraneTimedOut,
};

@interface POCraneBridge : NSObject

+ (BOOL)isAvailable;
+ (BOOL)isBundleSupported:(NSString *)bundleIdentifier;

/// 原始枚举：设置页始终列出全部真实账号，不受显示开关、菜单数量或全局分身开关过滤。
+ (NSArray<POSplitTarget *> *)allTargetsForBundleIdentifier:(NSString *)bundleIdentifier;
+ (NSArray<NSString *> *)applicationsWithNonDefaultContainers;
+ (NSString *)visibilityKeyForTarget:(POSplitTarget *)target;

/// 菜单枚举：在原始结果上应用默认号/逐账号显示开关。全部关闭时允许返回空数组。
+ (NSArray<POSplitTarget *> *)targetsForBundleIdentifier:(NSString *)bundleIdentifier;

+ (nullable NSString *)activeContainerForBundleIdentifier:(NSString *)bundleIdentifier;

/// 主队列回调且只回调一次。YES 表示容器已切换并经回读确认。
+ (void)activateTarget:(POSplitTarget *)target
            completion:(void (^)(BOOL success, NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
