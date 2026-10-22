// CXLog.h — 运行日志（SpringBoard 与设置进程共写一份）
#import <Foundation/Foundation.h>

FOUNDATION_EXPORT void CXLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
FOUNDATION_EXPORT NSString *CXLogPath(void);
