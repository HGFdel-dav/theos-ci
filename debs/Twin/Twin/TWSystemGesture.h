// TWSystemGesture.h
// App 内角落唤醒：把一个 pan 手势注册进系统的「系统手势管理器」。
//
// 为什么需要它：App 在前台时，App 的 scene 盖在 SpringBoard 之上，
// SpringBoard 自己的窗口/注入视图都收不到 App 内的触摸。原版也是走这条
// 通道（_UISystemGestureManager + addGestureRecognizer:toDisplayWithIdentity:，
// 身份串类似 ScreenCoreArcMenuGesture）——系统手势在 App 之上优先派发，
// 于是「App 里从角落拖出弧形菜单」才可能成立。
//
// 只有手势起点落在四角热区（TWArcCornerAtScreenPoint）时才 shouldBegin，
// 其余触摸全部放行，绝不影响 App 正常操作。
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void TWSystemGestureStart(void);   // 启动时注册（幂等）
FOUNDATION_EXPORT void TWSystemGestureSync(void);    // 设置变化后重算注册/反注册

NS_ASSUME_NONNULL_END
