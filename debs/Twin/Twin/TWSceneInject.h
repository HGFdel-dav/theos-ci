// TWSceneInject.h
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// 必须用 FOUNDATION_EXPORT：Tweak.xm 是 ObjC++，FOUNDATION_EXPORT 在 C++
// 下展开就是 extern "C"——否则实现文件里的普通 C 符号会被 C++ 改名，链接时报
// "TWSceneInjectStart() not found"（与 TWRemember.h 等保持同一约定）。

// hook _UIScenePresentationView 的 layoutSubviews，用于在 App 前台时
// 也能在屏幕四角收到触摸（SpringBoard 自己的窗口那时收不到触摸）。
FOUNDATION_EXPORT void TWSceneInjectStart(void);

// 设置改变后重新同步一次角落热区。
FOUNDATION_EXPORT void TWSceneInjectSync(void);

NS_ASSUME_NONNULL_END
