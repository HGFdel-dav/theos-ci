// PXPanelEntry.h - 逆向重建自 ParallelX alpha342
// 基于 clone0.25 中 CXHook.m 的使用证据
#import <UIKit/UIKit.h>

@interface PXPanelEntry : NSObject

// === 应用激活（clone0.4+ 使用）===
+ (void)applicationActivated:(NSString *)bundleID;

// === 外部启动（clone0.24 使用）===
+ (void)externalOpenApplication:(NSString *)bundleID;

// === 配置动作执行（clone0.25 使用）===
- (void)performConfiguredAction:(NSDictionary *)action;

@end
