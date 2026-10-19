// TWPXPrefs.m — 见 TWPXPrefs.h。ParallelX 偏好的轻量读写 / 通知桥。
#import "TWPXPrefs.h"
#import "TWPath.h"
#import <UIKit/UIKit.h>
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>

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
    return self.parallelXFilePath.length > 0;
}

// 带锁读最新磁盘内容，避免与 ParallelX 自身写入冲突。
- (NSDictionary *)__pxDiskCopy {
    NSString *path = self.parallelXFilePath;
    if (!path.length) return nil;
    int fd = PXLock(path);
    if (fd < 0) return nil;
    NSDictionary *disk = [NSDictionary dictionaryWithContentsOfFile:path];
    flock(fd, LOCK_UN); close(fd);
    return disk;
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
    if (!key.length) return NO;
    NSDictionary *disk = [self __pxDiskCopy];

    NSString *path = self.parallelXFilePath;
    if (!path.length) return NO;         // 找不到 plist → 不写（子页先提示打开面板）
    int fd = PXLock(path);
    if (fd < 0) return NO;
    // 读改写防丢失：拿锁后再读一次做增量。
    NSMutableDictionary *disk2 = [[NSDictionary dictionaryWithContentsOfFile:path] ?: @{} mutableCopy];
    if (value) disk2[key] = value; else [disk2 removeObjectForKey:key];
    // 注意：绝不用 CFPreferences 写——Preferences 进程里它会把改动落到真实的
    // /var/mobile/Library/Preferences，违反 RootHide 痕迹清理铁律。
    // 这里只直写 jbroot 下的同一份文件；ParallelX 收到 capture-updated 通知后
    // 自己 reload 就能读到新值。
    BOOL ok = [disk2 writeToFile:path atomically:YES];
    flock(fd, LOCK_UN); close(fd);

    if (ok) [self postRefresh];
    return ok;
}

- (void)postRefresh {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)PXPXRefreshNotification,
                                         NULL, NULL, YES);
}

@end