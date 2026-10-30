//
//  DNBCommon.h
//  DebsNewsBatch
//
//  路径解析与日志。所有路径都从 App 自己的沙盒（NSHomeDirectory）推导，
//  不硬编码任何容器 UUID 或 /var/mobile 绝对路径。
//

#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString *DNBAppDocumentsPath(void);
FOUNDATION_EXPORT NSString *DNBNewsPath(void);
FOUNDATION_EXPORT NSString *DNBDownloadsDir(void);
FOUNDATION_EXPORT NSString *DNBMetadataPath(void);
FOUNDATION_EXPORT NSString *DNBLogPath(void);
FOUNDATION_EXPORT BOOL DNBEnsureDirectory(NSString *path);
FOUNDATION_EXPORT void DNBLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
FOUNDATION_EXPORT NSString *DNBTimestamp(void);
