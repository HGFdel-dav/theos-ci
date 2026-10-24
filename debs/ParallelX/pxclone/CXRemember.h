// CXRemember.h — 分屏窗口大小记忆（按 应用+容器）
#import <Foundation/Foundation.h>

@class UIView;

// 记录真实开窗桥与容器视图；普通应用也使用 DEFAULT 容器，不能跳过。
FOUNDATION_EXPORT void CXRememberBindOpen(id bridge, UIView *canvas, NSString *bundleID, NSString *containerID);

FOUNDATION_EXPORT NSString *const CXRememberEnabledKey;
FOUNDATION_EXPORT void CXRememberStart(void);
// 记录"这次是从哪个账号打开的"，供记忆取容器用
FOUNDATION_EXPORT void CXRememberNoteLaunch(NSString *bundleID, NSString *containerID);
// 打开窗口后调用：延迟应用该账号上次记住的大小
FOUNDATION_EXPORT void CXRememberApplySoon(NSString *bundleID, NSString *containerID);
// PX 真正开始建窗（prepareWindow）后调用：从这里开始等卡片挂载，只套一次
FOUNDATION_EXPORT void CXRememberApplyAfterPrepare(NSString *bundleID);
