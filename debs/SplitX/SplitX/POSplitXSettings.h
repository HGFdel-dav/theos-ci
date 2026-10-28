//
//  POSplitXSettings.h
//  SplitX
//
//  面板参数与备份恢复。全部走 PXLog 记录，方便按标签排查。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface POSplitXSettings : NSObject

+ (instancetype)shared;

// 面板参数（设置页可调）
@property (nonatomic, readonly) CGFloat iconSize;       // 40...72, default 56
@property (nonatomic, readonly) CGFloat tileSize;       // 52...88, default 68
@property (nonatomic, readonly) CGFloat itemSpacing;    // 0...20,  default 6
@property (nonatomic, readonly) CGFloat panelRadius;    // 12...40, default 30
@property (nonatomic, readonly) CGFloat panelAlpha;     // 0.4...1, default 1
@property (nonatomic, readonly) NSInteger panelColumns; // 1...3,  default 2

// 手势区域
@property (nonatomic, readonly) CGFloat triggerWidth;   // 8...60,  default 30
@property (nonatomic, readonly) CGFloat triggerOffsetY; // -200...200, default 0

// 角落小窗
@property (nonatomic, readonly) BOOL dockEnabled;       // default YES
@property (nonatomic, readonly) CGFloat dockScale;      // 0.2...0.5, default 0.28

- (void)reload;
- (void)setValue:(id)value forKey:(NSString *)key;

// 备份 / 恢复：导出全部键到 plist，导入时只接受白名单键
- (BOOL)exportBackupToPath:(NSString *)path error:(NSError **)error;
- (BOOL)importBackupFromPath:(NSString *)path error:(NSError **)error;
- (NSDictionary<NSString *, id> *)allValues;

/// 用户最后一次为该应用选过的容器。外部 URL / 付款按它决定落到哪个账号。
- (void)setExpectedContainer:(NSString *)container forBundleIdentifier:(NSString *)bundle;
- (nullable NSString *)expectedContainerForBundleIdentifier:(NSString *)bundle;

@end

NS_ASSUME_NONNULL_END
