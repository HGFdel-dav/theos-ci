// SCArcGestureCoordinator.h - 逆向重建自 ScreenCore 2.0.4
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class SCArcMenuView, SCArcGestureRecognizer, SCApplicationTarget;

typedef NS_ENUM(NSInteger, SCGestureProfile) {
    SCGestureProfileOne = 1,
    SCGestureProfileTwo = 2,
    SCGestureProfileFan = 3  // 扇形
};

typedef NS_ENUM(NSInteger, SCArcMenuMode) {
    SCArcMenuModeCircular = 0,   // 圆形/扇形
    SCArcMenuModeRectangle = 1   // 矩形
};

@interface SCArcGestureCoordinator : NSObject <UIGestureRecognizerDelegate>

// === 核心属性（从偏好与反汇编推断） ===
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) SCGestureProfile gestureProfile;
@property (nonatomic, assign) SCArcMenuMode menuMode;

// 圆形/扇形参数
@property (nonatomic, assign) CGFloat arcRadius;
@property (nonatomic, assign) CGFloat arcSpacing;
@property (nonatomic, assign) NSInteger itemsPerRing;

// 矩形参数
@property (nonatomic, assign) CGFloat rectangleLength;
@property (nonatomic, assign) CGFloat rectangleHeight;
@property (nonatomic, assign) CGFloat rectangleCornerRadius;

// 调试
@property (nonatomic, assign) BOOL debugMode;

// 视图
@property (nonatomic, strong) SCArcMenuView *menuView;
@property (nonatomic, strong) SCArcGestureRecognizer *gestureRecognizer;

// === 初始化 ===
- (instancetype)initWithGestureProfile:(SCGestureProfile)profile;
- (instancetype)initWithGestureProfile:(SCGestureProfile)profile orientation:(UIInterfaceOrientation)orientation;

// === 手势处理 ===
- (void)sc_handleArcGesture:(UIGestureRecognizer *)gesture;
- (void)sc_arcGestureBegan:(CGPoint)location;
- (void)sc_arcGestureChanged:(CGPoint)location;
- (void)sc_arcGestureEnded:(CGPoint)location;
- (void)sc_arcGestureCancelled;

// === 菜单管理 ===
- (void)sc_showMenuAtLocation:(CGPoint)location withTargets:(NSArray<SCApplicationTarget *> *)targets;
- (void)sc_hideMenu;
- (void)sc_selectTarget:(SCApplicationTarget *)target;

// === 布局与动画 ===
- (void)sc_layoutMenuItemsCircular;
- (void)sc_layoutMenuItemsRectangle;
- (void)sc_animateMenuAppearance;
- (void)sc_animateMenuDismissal;

// === 偏好读取 ===
- (void)sc_loadPreferences;
- (void)sc_refreshConfiguration;

@end
