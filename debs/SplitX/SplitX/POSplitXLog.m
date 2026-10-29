//
//  POSplitXLog.m
//  SplitX
//

#import "POSplitXLog.h"
#include <sys/time.h>
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>

static char gSignalRing[64 * 1024];
static unsigned long long gSignalHead;

static NSString *gLogPath;
static dispatch_queue_t gLogQueue;
static PXLogLevel gMinLevel = PXLogLevelInfo;
static NSMutableArray<NSString *> *gTail;
static unsigned long long gSeq;
static NSString *gSessionId;
static const NSUInteger PXLogTailLimit = 200;
static const unsigned long long PXLogMaxBytes = 2ULL * 1024 * 1024;
static const int PXLogKeepFiles = 3;

static NSString *PXLogDirectory(void) {
    // SpringBoard 与 Preferences 必须写同一份日志，否则设置页操作会丢在各自沙盒里。
    NSString *shared = @"/var/mobile/Documents/SplitX";
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:shared withIntermediateDirectories:YES attributes:nil error:NULL];
    if ([fm isWritableFileAtPath:shared]) {
        return shared;
    }
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (docs.length == 0) docs = @"/var/mobile/Documents";
    return [docs stringByAppendingPathComponent:@"SplitX"];
}

static NSString *PXLogPathForIndex(int index) {
    if (index <= 0) return gLogPath;
    return [gLogPath stringByAppendingFormat:@".%d", index];
}

void PXLogSetLevel(PXLogLevel level) {
    gMinLevel = level;
}

static void PXLogRotateIfNeeded(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *attrs = [fm attributesOfItemAtPath:gLogPath error:NULL];
    if (attrs.fileSize <= PXLogMaxBytes) return;
    [fm removeItemAtPath:PXLogPathForIndex(PXLogKeepFiles) error:NULL];
    for (int i = PXLogKeepFiles - 1; i >= 1; i--) {
        NSString *from = PXLogPathForIndex(i);
        if ([fm fileExistsAtPath:from]) {
            [fm moveItemAtPath:from toPath:PXLogPathForIndex(i + 1) error:NULL];
        }
    }
    [fm moveItemAtPath:gLogPath toPath:PXLogPathForIndex(1) error:NULL];
}

static void PXLogAppendLine(NSString *line) {
    @synchronized (gTail) {
        [gTail addObject:line];
        while (gTail.count > PXLogTailLimit) [gTail removeObjectAtIndex:0];
    }

    // 信号崩溃时来不及用 ObjC，先往静态环里拷一份。
    const char *bytes = line.UTF8String;
    size_t len = bytes ? strlen(bytes) : 0;
    if (len > 0) {
        unsigned long long start = __sync_fetch_and_add(&gSignalHead, len);
        size_t off = (size_t)(start % sizeof(gSignalRing));
        size_t first = MIN(len, sizeof(gSignalRing) - off);
        memcpy(gSignalRing + off, bytes, first);
        if (len > first) memcpy(gSignalRing, bytes + first, len - first);
    }
    NSString *path = PXLogFilePath();
    dispatch_async(gLogQueue, ^{
        @autoreleasepool {
            PXLogRotateIfNeeded();
            NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
            if (!data) return;
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            if (!fh) {
                [data writeToFile:path atomically:YES];
                return;
            }
            @try {
                [fh seekToEndOfFile];
                [fh writeData:data];
                [fh closeFile];
            } @catch (__unused NSException *exception) {}
        }
    });
}

void PXLogMessage(PXLogLevel level, NSString *module, NSString *format, ...) {
    if (level < gMinLevel) return;
    @autoreleasepool {
        va_list args;
        va_start(args, format);
        NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);

        struct timeval tv;
        gettimeofday(&tv, NULL);
        struct tm tm;
        localtime_r(&tv.tv_sec, &tm);
        char stamp[32];
        strftime(stamp, sizeof(stamp), "%m-%d %H:%M:%S", &tm);

        unsigned long long seq = __sync_fetch_and_add(&gSeq, 1);
        char mark = 'I';
        switch (level) {
            case PXLogLevelDebug: mark = 'D'; break;
            case PXLogLevelWarn: mark = 'W'; break;
            case PXLogLevelError: mark = 'E'; break;
            default: break;
        }
        NSString *line = [NSString stringWithFormat:@"%s.%03d #%llu %c [%@] [%@] %@\n",
                          stamp, (int)(tv.tv_usec / 1000), seq, mark,
                          NSThread.isMainThread ? @"M" : @"B",
                          module ?: @"?", body ?: @""];
        PXLogAppendLine(line);
    }
}

static void PXLogExceptionHandler(NSException *exception) {
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"=== crash %@ session=%@ name=%@\nreason: %@\n",
        NSDate.date, gSessionId ?: @"?", exception.name, exception.reason];
    for (NSString *frame in exception.callStackSymbols) {
        [text appendFormat:@"  %@\n", frame];
    }
    [text appendString:@"--- tail ---\n"];
    @synchronized (gTail) {
        for (NSString *line in gTail) [text appendString:line];
    }
    [text writeToFile:[PXLogDirectory() stringByAppendingPathComponent:@"crash.log"]
           atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static const char *PXLogSignalName(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV";
        case SIGBUS: return "SIGBUS";
        case SIGABRT: return "SIGABRT";
        case SIGILL: return "SIGILL";
        case SIGFPE: return "SIGFPE";
        case SIGTRAP: return "SIGTRAP";
        default: return "SIGNAL";
    }
}

/// 信号上下文里只用 open/write/close 和静态缓冲。
static void PXLogSignalHandler(int sig) {
    const char *path = "/var/mobile/Documents/SplitX/crash.signal.log";
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        char header[96];
        int length = snprintf(header, sizeof(header), "=== signal %s pid=%d ===\n",
                              PXLogSignalName(sig), getpid());
        if (length > 0) write(fd, header, (size_t)length);
        unsigned long long head = gSignalHead;
        size_t len = (size_t)MIN(head, (unsigned long long)sizeof(gSignalRing));
        if (len > 0) {
            size_t start = (size_t)((head - len) % sizeof(gSignalRing));
            size_t first = MIN(len, sizeof(gSignalRing) - start);
            write(fd, gSignalRing + start, first);
            if (len > first) write(fd, gSignalRing, len - first);
        }
        close(fd);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static void PXLogInstallSignalHandlers(void) {
    int signals[] = {SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP};
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
        signal(signals[i], PXLogSignalHandler);
    }
}

void PXLogBeginSession(NSString *buildTag) {
    PXLogFilePath();   // 确保队列与缓冲已建
    gSessionId = [[NSUUID UUID].UUIDString substringToIndex:8];
    gSeq = 0;
    @synchronized (gTail) { [gTail removeAllObjects]; }
    NSSetUncaughtExceptionHandler(&PXLogExceptionHandler);
    PXLogInstallSignalHandlers();
    PXLog(@"boot", @"===== session %@ build=%@ =====", gSessionId, buildTag ?: @"?");
}

void PXLogEnvironment(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    PXLogMessage(PXLogLevelInfo, @"env", @"%@", body);
}

void PXLogSlow(NSString *module, double seconds, NSString *what) {
    if (seconds < 0.25) return;
    PXLogMessage(PXLogLevelWarn, module, @"SLOW %.0fms %@", seconds * 1000.0, what ?: @"");
}

NSString *PXLogFilePath(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLogQueue = dispatch_queue_create("com.niubiprass.splitx.log", DISPATCH_QUEUE_SERIAL);
        NSString *dir = PXLogDirectory();
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        gLogPath = [dir stringByAppendingPathComponent:@"runtime.log"];
        gTail = [NSMutableArray array];
    });
    return gLogPath;
}

NSString *PXLogCrashTail(void) {
    NSString *path = [PXLogDirectory() stringByAppendingPathComponent:@"crash.log"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    return text ?: @"";
}

NSString *PXLogReadAll(void) {
    NSString *text = [NSString stringWithContentsOfFile:PXLogFilePath()
                                              encoding:NSUTF8StringEncoding error:NULL];
    return text ?: @"";
}

NSString *PXLogReadPrevious(void) {
    NSString *text = [NSString stringWithContentsOfFile:PXLogPathForIndex(1)
                                              encoding:NSUTF8StringEncoding error:NULL];
    return text ?: @"";
}

BOOL PXLogClear(void) {
    PXLogFilePath();
    NSFileManager *fm = NSFileManager.defaultManager;
    for (int i = 0; i <= PXLogKeepFiles; i++) {
        [fm removeItemAtPath:PXLogPathForIndex(i) error:NULL];
    }
    [fm removeItemAtPath:[PXLogDirectory() stringByAppendingPathComponent:@"crash.log"] error:NULL];
    @synchronized (gTail) { [gTail removeAllObjects]; }
    return YES;
}
