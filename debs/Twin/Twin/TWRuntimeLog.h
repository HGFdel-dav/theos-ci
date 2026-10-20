// TWRuntimeLog.h — 真机运行诊断（SpringBoard 的 dylib 与设置面板的 bundle 共用一份）
//
// 为什么要它：这台机器上"面板改了没反应"曾经完全靠猜。现在引擎和面板都把
// 关键动作写进同一份日志，出问题直接读文件就能定位（路径 + 值 + 结果）。
// 位置：/var/mobile/Library/Application Support/Twin/runtime.log
#import <Foundation/Foundation.h>
#import <stdarg.h>
#import <CoreFoundation/CoreFoundation.h>

static inline NSString *TWRuntimeLogPath(void) {
    return @"/var/mobile/Library/Application Support/Twin/runtime.log";
}

static inline void TWRuntimeLog(NSString *format, ...) {
    if (![format isKindOfClass:NSString.class] || !format.length) return;
    @try {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *path = TWRuntimeLogPath();
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        if ([[attrs objectForKey:NSFileSize] unsignedLongLongValue] > 262144) { [fm removeItemAtPath:path error:nil]; attrs = nil; }
        if (!attrs) {
            [fm createDirectoryAtPath:[path stringByDeletingLastPathComponent]
          withIntermediateDirectories:YES attributes:nil error:nil];
        }
        va_list args;
        va_start(args, format);
        NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);
        NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n",
                          [NSDate date], NSProcessInfo.processInfo.processName, body ?: @"(null)"];
        NSLog(@"[Twin] %@", body);
        // 0.9.10：同时写进偏好域的一个环形缓冲。SpringBoard 直接写文件在这台机器上
        // 看不到（0.9.9 实测 runtime.log 根本不出现），但 cfprefsd 是通的 ——
        // 这样我在电脑上读 com.niubiprass.twin.plist 就能看到引擎跑到哪一步。
        @try {
            CFStringRef domain = CFSTR("com.niubiprass.twin.log");
            NSMutableArray *lines = nil;
            CFPropertyListRef existing = CFPreferencesCopyAppValue(CFSTR("TWRuntimeLog"), domain);
            if (existing && CFGetTypeID(existing) == CFArrayGetTypeID()) {
                lines = [(__bridge_transfer NSArray *)existing mutableCopy];
            } else if (existing) {
                CFRelease(existing);
            }
            if (!lines) lines = [NSMutableArray array];
            [lines addObject:line];
            while (lines.count > 80) [lines removeObjectAtIndex:0];
            CFPreferencesSetAppValue(CFSTR("TWRuntimeLog"),
                                     (__bridge CFPropertyListRef)[lines copy],
                                     domain);
            CFPreferencesAppSynchronize(domain);
        } @catch (__unused NSException *exception) { }
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle) {
            @try { [handle seekToEndOfFile]; [handle writeData:data]; }
            @finally { [handle closeFile]; }
        } else {
            [data writeToFile:path atomically:YES];
        }
    } @catch (__unused NSException *exception) { /* 诊断永不打扰主流程 */ }
}
