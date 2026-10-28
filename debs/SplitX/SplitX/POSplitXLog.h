//
//  POSplitXLog.h
//  SplitX
//
//  统一诊断日志。目标是“事后能按时间把用户做了什么、插件做了什么完整读出来”。
//
//  行格式：MM-dd HH:mm:ss.SSS #seq [L] [thread] [module] 内容
//  文件：/var/mobile/Documents/SplitX/runtime.log，单文件 2MB，滚动保留 3 份。
//  崩溃：未捕获异常会把内存尾部 200 行写进 crash.log，下次启动可读。
//
//  模块：[boot] [env] [heartbeat] [gesture] [panel] [ui] [prefs] [clone] [switch]
//        [scene] [host] [route] [hook] [dock] [backup] [error]
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PXLogLevel) {
    PXLogLevelDebug = 0,
    PXLogLevelInfo,
    PXLogLevelWarn,
    PXLogLevelError,
};

FOUNDATION_EXPORT void PXLogSetLevel(PXLogLevel level);
FOUNDATION_EXPORT void PXLogMessage(PXLogLevel level, NSString *module, NSString *format, ...)
    NS_FORMAT_FUNCTION(3, 4);

#define PXLog(mod, fmt, ...)        PXLogMessage(PXLogLevelInfo, mod, fmt, ##__VA_ARGS__)
#define PXLogD(mod, fmt, ...)       PXLogMessage(PXLogLevelDebug, mod, fmt, ##__VA_ARGS__)
#define PXLogW(mod, fmt, ...)       PXLogMessage(PXLogLevelWarn, mod, fmt, ##__VA_ARGS__)
#define PXLogE(mod, fmt, ...)       PXLogMessage(PXLogLevelError, mod, fmt, ##__VA_ARGS__)

/// 开始一次会话：记构建标识、装异常钩子、清空内存缓冲。
FOUNDATION_EXPORT void PXLogBeginSession(NSString *buildTag);
/// 环境快照（机型/系统/越狱/Crane 版本/设置）。只在启动写一次。
FOUNDATION_EXPORT void PXLogEnvironment(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
/// 耗时告警：超过阈值的操作单独记一条 [error]。
FOUNDATION_EXPORT void PXLogSlow(NSString *module, double seconds, NSString *what);
/// 上次会话是否崩过；返回崩溃尾部（没有则空串）。
FOUNDATION_EXPORT NSString *PXLogCrashTail(void);

FOUNDATION_EXPORT NSString *PXLogFilePath(void);
FOUNDATION_EXPORT NSString *PXLogReadAll(void);
FOUNDATION_EXPORT NSString *PXLogReadPrevious(void);
FOUNDATION_EXPORT BOOL PXLogClear(void);

NS_ASSUME_NONNULL_END
