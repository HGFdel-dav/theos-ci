// SCFloatingContainerView.h - 逆向重建自 ScreenCore 2.0.4
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class SCApplicationTarget;

@interface SCFloatingContainerView : UIView

// === 核心属性 ===
@property (nonatomic, copy) NSString *bundleIdentifier;
@property (nonatomic, copy) NSString *containerIdentifier;  // Crane 容器
@property (nonatomic, assign) BOOL craneTarget;             // 是否分身
@property (nonatomic, assign) BOOL craneSwitchFullscreenEnabled;

// 几何
@property (nonatomic, assign) CGRect containerFrame;
@property (nonatomic, assign) CGSize sceneReferenceSize;

// 状态
@property (nonatomic, assign) BOOL isFullscreen;
@property (nonatomic, assign) BOOL virtualScreenEnabled;

// === 初始化 ===
- (instancetype)initWithBundleIdentifier:(NSString *)bundleID
                          containerFrame:(CGRect)frame
                      sceneReferenceSize:(CGSize)size
                         aspectRatioMode:(NSInteger)mode
                   virtualScreenEnabled:(BOOL)enabled;

// === Crane 分身相关 ===
- (void)sc_setContainerIdentifier:(NSString *)containerID;
- (void)sc_switchToContainerFullscreen:(BOOL)fullscreen;
- (void)sc_reloadWithCraneContainer;

// === 窗口管理 ===
- (void)sc_launchApplicationFullscreen:(BOOL)fullscreen;
- (void)sc_activateFloatingWindow;
- (void)sc_closeWindow;
- (void)sc_bringToFront;

// === 几何变换 ===
- (void)sc_resizeToFrame:(CGRect)frame animated:(BOOL)animated;
- (void)sc_moveToCenter:(CGPoint)center animated:(BOOL)animated;
- (void)sc_toggleFullscreen;

// === 视觉 ===
- (void)sc_updateBackgroundEffect;
- (void)sc_setCornerRadius:(CGFloat)radius;

@end
