#import "SLRenewPaths.h"
#import <stdio.h>
#import <stdarg.h>
#import <unistd.h>

static NSString *g_root = nil;
static BOOL g_rootDone = NO;
static NSString *g_stateDir = nil;
static NSString *g_logDir = nil;

#pragma mark - 日志

// 用真实写入判断（access 不看沙盒）
static BOOL SLDirWritable(NSString *d) {
    if (!d.length) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *probe = [d stringByAppendingPathComponent:@".slwrite"];
    BOOL ok = [fm createFileAtPath:probe contents:[NSData dataWithBytes:"x" length:1] attributes:nil];
    if (ok) [fm removeItemAtPath:probe error:NULL];
    return ok;
}

NSString *SLLogDir(void) {
    if (g_logDir) return g_logDir;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *cands = [NSMutableArray array];
    [cands addObject:SLStateDir()];
    [cands addObject:NSTemporaryDirectory()];
    for (NSString *d in cands) {
        if (!d.length) continue;
        [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:NULL];
        if (SLDirWritable(d)) { g_logDir = d; break; }
    }
    if (!g_logDir) g_logDir = NSTemporaryDirectory();
    return g_logDir;
}

void SLLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"MM-dd HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [f stringFromDate:[NSDate date]], s];

    NSLog(@"[SLRenew] %@", s);
    @try {
        NSString *file = [SLLogDir() stringByAppendingPathComponent:@"com.minis.shanlianrenew.log"];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *a = [fm attributesOfItemAtPath:file error:NULL];
        if ([a fileSize] > 256 * 1024) {
            [fm removeItemAtPath:[file stringByAppendingString:@".1"] error:NULL];
            [fm moveItemAtPath:file toPath:[file stringByAppendingString:@".1"] error:NULL];
        }
        FILE *fp = fopen(file.UTF8String, "a");
        if (fp) { fputs(line.UTF8String, fp); fclose(fp); }
    } @catch (__unused NSException *e) {}
}

#pragma mark - 隐根

// 优先系统 jbroot()，否则扫描真实位置
NSString *SLJbRoot(void) {
    if (g_rootDone) return g_root;
    g_rootDone = YES;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *cands = [NSMutableArray array];
    for (NSString *base in @[@"/var/containers/Bundle/Application",
                             @"/var/mobile/Containers/Shared/AppGroup"]) {
        for (NSString *n in [fm contentsOfDirectoryAtPath:base error:NULL]) {
            if (![n hasPrefix:@".jbroot-"]) continue;
            NSString *p = [base stringByAppendingPathComponent:n];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:[p stringByAppendingPathComponent:@"usr/lib"] isDirectory:&isDir] || !isDir) continue;
            [cands addObject:p];
        }
    }
    NSString *best = nil; int bestScore = -1; NSTimeInterval bestT = 0;
    for (NSString *p in cands) {
        int score = 1;
        if ([fm fileExistsAtPath:[p stringByAppendingPathComponent:@"Library/MobileSubstrate"]]) score += 2;
        if ([fm fileExistsAtPath:[p stringByAppendingPathComponent:
              @"Library/MobileSubstrate/DynamicLibraries/ShanLianRenew.dylib"]]) score += 3;
        NSDictionary *a = [fm attributesOfItemAtPath:p error:NULL];
        NSTimeInterval t = [a fileModificationDate].timeIntervalSince1970;
        if (score > bestScore || (score == bestScore && t > bestT)) { best = p; bestScore = score; bestT = t; }
    }
    if (!best && [fm fileExistsAtPath:@"/var/jb/usr/lib"]) best = @"/var/jb";
    g_root = best ?: @"";
    return g_root;
}

NSString *SLStateDir(void) {
    if (g_stateDir) return g_stateDir;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *cands = [NSMutableArray array];

    NSURL *gu = [[NSFileManager defaultManager]
                 containerURLForSecurityApplicationGroupIdentifier:SL_APP_GROUP];
    if (gu.path.length) [cands addObject:[gu.path stringByAppendingPathComponent:@"Library/Preferences"]];
    // 次选：App 自己容器
    NSString *home = NSHomeDirectory();
    if (home.length) [cands addObject:[home stringByAppendingPathComponent:@"Library/Preferences"]];
    // 末选：隐根偏好、真实偏好、临时目录
    [cands addObject:NSTemporaryDirectory()];

    for (NSString *d in cands) {
        if (!d.length) continue;
        [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:NULL];
        if (SLDirWritable(d)) { g_stateDir = d; break; }
    }
    if (!g_stateDir) g_stateDir = NSTemporaryDirectory();
    return g_stateDir;
}

NSString *SLStatePath(void) {
    return [SLStateDir() stringByAppendingPathComponent:SL_STATE_NAME];
}

#pragma mark - 应用组

NSString *SLAppGroup(void) { return SL_APP_GROUP; }

// 按容器元数据找应用组容器目录
NSString *SLGroupContainer(void) {
    static NSString *g = nil;
    static BOOL done = NO;
    if (done) return g;
    done = YES;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *bases = [NSMutableArray array];
    NSString *r = SLJbRoot();
    if (r.length) [bases addObject:[r stringByAppendingPathComponent:@"var/mobile/Containers/Shared/AppGroup"]];
    [bases addObject:@"/var/mobile/Containers/Shared/AppGroup"];
    for (NSString *base in bases) {
        for (NSString *n in [fm contentsOfDirectoryAtPath:base error:NULL]) {
            NSString *dir = [base stringByAppendingPathComponent:n];
            NSString *meta = [dir stringByAppendingPathComponent:
                              @".com.apple.mobile_container_manager.metadata.plist"];
            NSDictionary *m = [NSDictionary dictionaryWithContentsOfFile:meta];
            NSString *ident = m[@"MCMMetadataIdentifier"];
            if ([ident isEqualToString:SL_APP_GROUP] ||
                [ident isEqualToString:SL_APP_GROUP_OLD]) { g = dir; return g; }
        }
    }
    // 元数据读不到就按偏好文件名反查
    for (NSString *base in bases) {
        for (NSString *n in [fm contentsOfDirectoryAtPath:base error:NULL]) {
            NSString *dir = [base stringByAppendingPathComponent:n];
            for (NSString *gname in @[SL_APP_GROUP, SL_APP_GROUP_OLD]) {
                NSString *f = [[[dir stringByAppendingPathComponent:@"Library/Preferences"]
                                stringByAppendingPathComponent:gname]
                               stringByAppendingPathExtension:@"plist"];
                if ([fm fileExistsAtPath:f]) { g = dir; return g; }
            }
        }
    }
    g = @"";
    return g;
}

NSString *SLAppGroupPrefsPath(void) {
    static NSString *p = nil;
    if (p) return p;
    NSString *g = SLGroupContainer();
    p = g.length
      ? [[[g stringByAppendingPathComponent:@"Library/Preferences"]
          stringByAppendingPathComponent:SL_APP_GROUP] stringByAppendingPathExtension:@"plist"]
      : @"";
    return p;
}

// 找到闪连 App 数据容器里的偏好文件路径
NSString *SLAppPrefsPath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *apps = [fm contentsOfDirectoryAtPath:@"/var/mobile/Containers/Data/Application" error:NULL];
    for (NSString *a in apps) {
        NSString *p = [NSString stringWithFormat:
            @"/var/mobile/Containers/Data/Application/%@/Library/Preferences/com.shanlian.pro.plist", a];
        if ([fm fileExistsAtPath:p]) return p;
    }
    return nil;
}

// 取闪连 App 数据容器里的任意相对路径（如 Documents/KKQQ.plist）
NSString *SLAppFilePath(NSString *rel) {
    if (!rel.length) return nil;
    NSString *pl = SLAppPrefsPath();               // .../Library/Preferences/com.shanlian.pro.plist
    if (!pl) return nil;
    NSString *lib = [pl stringByDeletingLastPathComponent];      // .../Library/Preferences
    NSString *container = [[lib stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    return [container stringByAppendingPathComponent:rel];
}
