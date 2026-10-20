// TWSceneInject.h
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// hook _UIScenePresentationView 的 layoutSubviews，用于在 App 前台时
// 也能在屏幕四角收到触摸（SpringBoard 自己的窗口那时收不到触摸）。
void TWSceneInjectStart(void);

// 设置改变后重新同步一次角落热区。
void TWSceneInjectSync(void);

NS_ASSUME_NONNULL_END
