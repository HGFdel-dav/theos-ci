// TWPlusUI.h — Twin 增强设置分区（注入 Preferences 进程）
// 不链接 Preferences 框架：全部通过 NSClassFromString + objc_msgSend 动态调用，
// 避免 dylib 注入 SpringBoard 时因 Preferences 符号未解析而加载失败。
#import <Foundation/Foundation.h>

FOUNDATION_EXPORT void TWPlusUIStart(void); // idempotent; safe no-op when Preferences not loaded