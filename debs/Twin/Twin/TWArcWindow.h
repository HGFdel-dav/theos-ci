// TWArcWindow.h
// Twin 自己的弧形覆盖窗口。
//
// 为什么需要它：旧实现把弧形菜单 addSubview 进 SpringBoard 的普通窗口
// （UIWindowLevelNormal = 0），所以会被状态栏、系统界面、其它插件的高层级
// 窗口盖住。Arc-X 的做法是自建 UIWindow 并把层级抬得很高（它的提示窗口
// 用的是 UIWindowLevelAlert - 2 = 1998，另配「视图优先级」0～2200）。
// 这里采用同样的结构：独立窗口 + 可调优先级。
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TWArcWindow : UIWindow
// 单例；首次访问即创建（此时可能还没有 windowScene）。
+ (instancetype)sharedWindow;
// 绑定到 reference 所在场景（取不到时退到前台活跃场景），并刷新层级。
// 没有可用场景时返回 NO，调用方应退回旧的宿主窗口。
- (BOOL)attachToSceneFromWindow:(nullable UIWindow *)reference;
// 按偏好重新计算 windowLevel = UIWindowLevelAlert - 2 + 视图优先级(0～2200)。
- (void)refreshLevel;
// 只承载菜单的透明容器：空白区域的触摸一律穿透到下层，不劫持系统手势。
- (nullable UIView *)menuContainer;
- (void)showMenuContainer;   // 显示（菜单要出现前调用）
- (void)hideMenuContainer;   // 只收起菜单，窗口继续待命接手势
// 空闲时只在这些矩形（屏幕坐标）里接管触摸，其它地方一律穿透。
// 传空数组＝回到"整窗都不接触摸"（配合 hideForGestures 使用）。
- (void)setCaptureRects:(nullable NSArray<NSValue *> *)rects;
- (void)showForGestures;     // 显示窗口但保持透明待命
- (void)hideForGestures;     // 真正隐藏窗口（切到 PX 手柄模式时）
@end

NS_ASSUME_NONNULL_END