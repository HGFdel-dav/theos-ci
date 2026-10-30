//
//  DNBCommon.m
//  DebsNewsBatch
//

#import "DNBCommon.h"

static const unsigned long long kDNBLogMaxBytes = 1024ull * 1024ull;   /* 超过 1MB 触发滚动 */
static NSString *const kDNBLogFileName = @"debsnewsbatch.log";

NSString *DNBAppDocumentsPath(void)
{
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
}

NSString *DNBNewsPath(void)
{
    return [DNBAppDocumentsPath() stringByAppendingPathComponent:@"news.plist"];
}

NSString *DNBDownloadsDir(void)
{
    return [[DNBAppDocumentsPath() stringByAppendingPathComponent:@"Downloads"]
            stringByAppendingPathComponent:@"DEBs"];
}

NSString *DNBMetadataPath(void)
{
    return [DNBAppDocumentsPath() stringByAppendingPathComponent:@"downloaded_metadata.plist"];
}

NSString *DNBLogPath(void)
{
    return [DNBAppDocumentsPath() stringByAppendingPathComponent:kDNBLogFileName];
}

BOOL DNBEnsureDirectory(NSString *path)
{
    if (path.length == 0) {
        return NO;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:path isDirectory:&isDir] && isDir) {
        return YES;
    }
    NSError *error = nil;
    BOOL ok = [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error];
    if (!ok) {
        NSLog(@"[DebsNewsBatch] 创建目录失败 %@: %@", path, error.localizedDescription);
    }
    return ok;
}

NSString *DNBTimestamp(void)
{
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"MM-dd HH:mm:ss.SSS";
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return [fmt stringFromDate:[NSDate date]];
}

void DNBLog(NSString *format, ...)
{
    if (format.length == 0) {
        return;
    }
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[DebsNewsBatch] %@", message);

    static dispatch_queue_t logQueue = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        logQueue = dispatch_queue_create("com.niubiprass.debsnewsbatch.log", DISPATCH_QUEUE_SERIAL);
    });

    dispatch_async(logQueue, ^{
        @autoreleasepool {
            NSString *line = [NSString stringWithFormat:@"%@ %@\n", DNBTimestamp(), message];
            NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
            if (!data) {
                return;
            }
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *path = DNBLogPath();

            /* 简单滚动：超过上限时只保留尾部一半，避免无限增长 */
            NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
            unsigned long long size = [attrs fileSize];
            if (size > kDNBLogMaxBytes) {
                NSData *old = [NSData dataWithContentsOfFile:path];
                if (old.length > kDNBLogMaxBytes / 2) {
                    NSData *tail = [old subdataWithRange:NSMakeRange(old.length - kDNBLogMaxBytes / 2,
                                                                     kDNBLogMaxBytes / 2)];
                    [tail writeToFile:path atomically:YES];
                }
            }

            if (![fm fileExistsAtPath:path]) {
                [data writeToFile:path atomically:YES];
                return;
            }
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
            if (!handle) {
                [data writeToFile:path atomically:YES];
                return;
            }
            @try {
                [handle seekToEndOfFile];
                [handle writeData:data];
            } @catch (__unused NSException *exception) {
                /* 日志写失败不影响主流程 */
            } @finally {
                [handle closeFile];
            }
        }
    });
}
