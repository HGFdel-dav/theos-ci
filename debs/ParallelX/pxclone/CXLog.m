// CXLog.m
#import "CXLog.h"
#import <stdarg.h>

#define CX_LOG_MAX (256 * 1024)

static NSString *CXLogDirectory(void) {
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    if (bundleID.length && ![bundleID isEqualToString:@"com.apple.springboard"]) {
        NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                                 NSUserDomainMask, YES).firstObject;
        if (support.length) return [support stringByAppendingPathComponent:@"CloneX"];
    }
    return @"/var/mobile/Library/Application Support/CloneX";
}

NSString *CXLogPath(void) {
    return [CXLogDirectory() stringByAppendingPathComponent:@"runtime.log"];
}

void CXLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message) return;
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"MM-dd HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:NSDate.date], message];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:CXLogDirectory() withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = CXLogPath();
    NSLog(@"[CloneX] %@", message);
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    if (attrs && [attrs[NSFileSize] unsignedLongLongValue] > CX_LOG_MAX) {
        [fm removeItemAtPath:path error:nil];
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    @try {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    } @catch (__unused NSException *e) {}
}
