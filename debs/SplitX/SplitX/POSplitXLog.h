//
//  POSplitXLog.h
//  SplitX
//
//  统一诊断日志。模块标签：[boot] [panel] [dock] [gesture] [prefs] [clone] [scene] [backup]
//  写 /var/mobile/Documents/SplitX/runtime.log，超 2MB 转 .1，不无限增长。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void PXLog(NSString *module, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);
FOUNDATION_EXPORT NSString *PXLogFilePath(void);
FOUNDATION_EXPORT NSString *PXLogReadAll(void);
FOUNDATION_EXPORT BOOL PXLogClear(void);

NS_ASSUME_NONNULL_END
