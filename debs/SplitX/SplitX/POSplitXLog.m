//
//  POSplitXLog.m
//  SplitX
//

#import "POSplitXLog.h"

static NSString *gLogPath;
static dispatch_queue_t gLogQueue;
static const unsigned long long PXLogMaxBytes = 2ULL * 1024 * 1024;

static NSString *PXLogDirectory(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (docs.length == 0) docs = @"/var/mobile/Documents";
    return [docs stringByAppendingPathComponent:@"SplitX"];
}

NSString *PXLogFilePath(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLogQueue = dispatch_queue_create("com.niubiprass.splitx.log", DISPATCH_QUEUE_SERIAL);
        NSString *dir = PXLogDirectory();
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        gLogPath = [dir stringByAppendingPathComponent:@"runtime.log"];
    });
    return gLogPath;
}

static void PXLogRotateIfNeeded(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *attrs = [fm attributesOfItemAtPath:gLogPath error:NULL];
    if (attrs.fileSize <= PXLogMaxBytes) return;
    NSString *old = [gLogPath stringByAppendingString:@".1"];
    [fm removeItemAtPath:old error:NULL];
    [fm moveItemAtPath:gLogPath toPath:old error:NULL];
}

void PXLog(NSString *module, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *path = PXLogFilePath();
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"MM-dd HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n",
                      [fmt stringFromDate:NSDate.date], module ?: @"?", body ?: @""];

    dispatch_async(gLogQueue, ^{
        PXLogRotateIfNeeded();
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [[line dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES];
            return;
        }
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (__unused NSException *exception) {}
    });
}

NSString *PXLogReadAll(void) {
    NSString *text = [NSString stringWithContentsOfFile:PXLogFilePath()
                                              encoding:NSUTF8StringEncoding error:NULL];
    return text ?: @"";
}

BOOL PXLogClear(void) {
    NSString *path = PXLogFilePath();
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:[path stringByAppendingString:@".1"] error:NULL];
    return YES;
}
