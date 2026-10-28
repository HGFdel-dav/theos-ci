//
//  POSplitTarget.h
//  SplitX
//
//  一个目标 = 应用 + 明确容器。只带 bundle 的旧接口视为“默认容器”。
//  身份键使用 bundle + 稳定容器 ID；显示名不参与身份比较。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const POSplitDefaultContainerIdentifier;

@interface POSplitTarget : NSObject <NSCopying>

@property (nonatomic, copy, readonly) NSString *bundleIdentifier;
/// DEFAULT 是明确目标，不代表“随便哪个账号”。
@property (nonatomic, copy, readonly) NSString *containerIdentifier;
@property (nonatomic, copy, readonly) NSString *containerDisplayName;
@property (nonatomic, assign, readonly) BOOL isDefaultContainer;

+ (instancetype)targetWithBundleIdentifier:(NSString *)bundleIdentifier
                                  container:(NSString *)containerIdentifier
                                displayName:(nullable NSString *)displayName;

/// 旧接口语义：只指定应用，落到 DEFAULT。
+ (instancetype)targetWithBundleIdentifier:(NSString *)bundleIdentifier;

- (NSString *)identityKey;
- (NSString *)displayTitle;
- (BOOL)isEqualToTarget:(nullable POSplitTarget *)other;

@end

NS_ASSUME_NONNULL_END
