// TWPXPrefs.m — 见 TWPXPrefs.h。ParallelX 偏好的轻量读写 / 通知桥。
#import "TWPXPrefs.h"
#import "TWPath.h"
#import <UIKit/UIKit.h>
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>
#import <CoreFoundation/CoreFoundation.h>

// ParallelX 运行时的刷新通知（与 ParallelX Root.plist 的 PostNotification 同名）。
static NSString *const PXPXRefreshNotification = @"com.moxuan.parallelx.capture-updated";

// 在全部 .jbroot-* 里找 com.moxuan.parallelx.plist。
static NSString *PXFindParallelXPrefs(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *best = nil;
    NSTimeInterval bestTime = -1;
    for (NSString *root in TWJBRootCandidates()) {
        NSString *path = [root stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.moxuan.parallelx.plist"];
        NSString *resolved = path.stringByResolvingSymlinksInPath;
        if (![fm fileExistsAtPath:resolved]) continue;
        NSTimeInterval stamp = [[[fm attributesOfItemAtPath:resolved error:nil] fileModificationDate] timeIntervalSince1970];
        if (stamp >= bestTime) { best = resolved; bestTime = stamp; } // >= 让后扫的有同时间戳时覆盖（最新根优先）
    }
    return best ?: @"";
}

// 0.9.0：plist 还不存在时的落点。
// 原逻辑：找不到 com.moxuan.parallelx.plist 就 available=NO，面板四页直接变空页
// ——用户从没打开过原版面板（或原版包已被替换）时就是这个状态，看起来就是
// “所有功能都不显示”。改成：找不到现成文件就用当前 jbroot 下的标准路径，
// 读走默认值、写时新建文件，面板始终可操作。
static NSString *PXCanonicalPrefsPath(void) {
    NSString *root = TWJBRootPath();
    if (!root.length) return @"";
    NSString *p = [root stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.moxuan.parallelx.plist"];
    return p.stringByResolvingSymlinksInPath ?: p;
}

static int PXLock(NSString *path) {    if (!path.length) return -1;
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    int fd = open([[path stringByAppendingString:@".lock"] fileSystemRepresentation], O_CREAT|O_RDWR|O_NOFOLLOW, 0600);
    if (fd >= 0 && flock(fd, LOCK_EX|LOCK_NB) != 0) { close(fd); return -1; }
    return fd;
}

@implementation TWPXPrefs

- (NSString *)parallelXFilePath {
    // 每次现扫（jbroot 可轮转），保证指向当前真实存在的文件；
    // 不存在时给标准落点，让读写都还能进行（写会新建文件）。
    NSString *found = PXFindParallelXPrefs();
    return found.length ? found : PXCanonicalPrefsPath();
}

- (BOOL)available {
    return YES;   // cfprefsd 始终可读写，不再依赖某个具体文件是否存在
}

static NSString *const PXDomain = @"com.moxuan.parallelx";
static CFStringRef PXDomainRef(void) { return (__bridge CFStringRef)PXDomain; }

// 0.9.9：改成 CFPreferences。ParallelX 本体就是用 cfprefsd 读写这个域的，
// 之前的"直接写 plist 文件"会被 SpringBoard/设置进程各看一份，改了不生效。
- (NSDictionary *)__pxDiskCopy {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    CFPreferencesAppSynchronize(PXDomainRef());
    CFArrayRef keys = CFPreferencesCopyKeyList(PXDomainRef(), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keys) {
        for (id key in (__bridge_transfer NSArray *)keys) {
            if (![key isKindOfClass:NSString.class]) continue;
            CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, PXDomainRef());
            if (v) out[key] = (__bridge_transfer id)v;
        }
    }
    return out;
}

- (id)objectForKey:(NSString *)key defaultValue:(id)fallback {
    if (!key.length) return fallback;
    id v = [self __pxDiskCopy][key];
    return v ?: fallback;
}

- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)def {
    id v = [self objectForKey:key defaultValue:nil];
    if (!v) return def;
    return ([v respondsToSelector:@selector(boolValue)]) ? [v boolValue] : def;
}

- (NSInteger)integerForKey:(NSString *)key defaultValue:(NSInteger)def {
    id v = [self objectForKey:key defaultValue:nil];
    if (!v) return def;
    return ([v respondsToSelector:@selector(integerValue)]) ? [v integerValue] : def;
}

- (CGFloat)floatForKey:(NSString *)key defaultValue:(CGFloat)def {
    id v = [self objectForKey:key defaultValue:nil];
    if (!v) return def;
    return ([v respondsToSelector:@selector(floatValue)]) ? [v floatValue] : def;
}

- (BOOL)setObject:(id)value forKey:(NSString *)key {
    if (!key.length || ![key isKindOfClass:NSString.class]) return NO;
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             value ? (__bridge CFPropertyListRef)value : NULL,
                             PXDomainRef());
    BOOL ok = CFPreferencesAppSynchronize(PXDomainRef());
    [self postRefresh];
    return ok;
}

- (NSDictionary *)allValues {
    NSDictionary *disk = [self __pxDiskCopy];
    return [disk isKindOfClass:NSDictionary.class] ? disk : @{};
}

- (void)removeAll {
    @synchronized (self) {
        NSString *path = [self parallelXFilePath];
        if (!path.length) return;
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
    [self postRefresh];
}

- (void)synchronize {
    // 无内存缓存：每次 setObject: 已经原子落盘，这里只是接口对齐。
}

- (void)postRefresh {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)PXPXRefreshNotification,
                                         NULL, NULL, YES);
}

@end