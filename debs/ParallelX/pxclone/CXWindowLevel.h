// CXWindowLevel.h - ParallelX 可调层级模块
// 用途：让 PX 的菜单窗口和分屏窗口可以盖过 Dock/控制中心等

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// 获取当前层级设置（从配置读取）
FOUNDATION_EXPORT CGFloat CXGetWindowLevel(void);

// 应用层级到窗口
FOUNDATION_EXPORT void CXApplyWindowLevel(UIWindow *window);

// 层级模式
typedef NS_ENUM(NSInteger, CXWindowLevelMode) {
    CXWindowLevelModeNormal = 0,        // 普通（默认）
    CXWindowLevelModeHigh = 1,          // 高层级（2046，盖过大部分界面）
    CXWindowLevelModeCustom = 2         // 自定义（0~2200）
};

// 从配置读取层级模式
FOUNDATION_EXPORT CXWindowLevelMode CXGetWindowLevelMode(void);

// 从配置读取自定义层级值
FOUNDATION_EXPORT CGFloat CXGetCustomWindowLevel(void);
