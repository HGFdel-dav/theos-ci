// CXRemember.h — 分屏窗口大小记忆（按 应用+容器）
#import <Foundation/Foundation.h>

FOUNDATION_EXPORT void CXRememberStart(void);
// 记录"这次是从哪个账号打开的"，供记忆取容器用
FOUNDATION_EXPORT void CXRememberNoteLaunch(NSString *bundleID, NSString *containerID);
// 打开窗口后调用：延迟应用该账号上次记住的大小
FOUNDATION_EXPORT void CXRememberApplySoon(NSString *bundleID, NSString *containerID);
