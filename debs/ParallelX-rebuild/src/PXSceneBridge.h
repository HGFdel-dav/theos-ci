// PXSceneBridge.h - 逆向重建自 ParallelX alpha342
// 基于 clone0.25 中 CXHook.m 的使用证据
#import <UIKit/UIKit.h>

@interface PXSceneBridge : NSObject

// === clone0.25 中已验证的接口 ===

// 单例
+ (instancetype)sharedBridge;

// 窗口宿主视图
@property (nonatomic, strong) UIView *hostView;
@property (nonatomic, strong) UIView *keyboardOverlay;

// 应用启动（clone0.6+ 使用）
- (void)openApplication:(NSString *)bundleID
                 inView:(UIView *)hostView
        keyboardOverlay:(UIView *)overlay
             completion:(void (^)(BOOL success))completion;

// 窗口准备（clone0.4 使用）
- (void)prepareWindowForBundleID:(NSString *)bundleID
                  wasFullscreen:(BOOL)fullscreen
                     completion:(void (^)(BOOL success))completion;

// 应用判断
- (BOOL)hasSceneForApplication:(NSString *)bundleID;

@end
