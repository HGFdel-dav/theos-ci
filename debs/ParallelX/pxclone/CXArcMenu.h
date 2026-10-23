// CXArcMenu.h — 不改 PX 菜单本体，只把它自己的图标重新排成角落扇形。
#import <UIKit/UIKit.h>

// PX 自己创建的菜单图标（PXPanelIcon），按其在父视图中的顺序
FOUNDATION_EXPORT NSArray<UIView *> *CXFanIcons(UIWindow *window);
// 按角落扇形重排；只改 center，保留 PX 自己的缩放/高亮动画
FOUNDATION_EXPORT void CXFanArrange(NSArray<UIView *> *icons, UIWindow *window, BOOL left);
// 手指附近最近的图标索引，-1 = 未命中
FOUNDATION_EXPORT NSInteger CXFanNearest(NSArray<UIView *> *icons, CGPoint pointInWindow);
