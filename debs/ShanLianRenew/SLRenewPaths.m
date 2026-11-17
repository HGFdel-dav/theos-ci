#import "SLRenewPaths.h"
#import <notify.h>
#import <stdio.h>
#import <stdarg.h>

static NSString *g_root = nil;
static NSString *g_stateDir = nil;

void SLLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"MM-dd HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [f stringFromDate:[NSDate date]], s];

    NSLog(@"[SLRenew] %@", s);

    static NSString *file = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ file = [SLStateDir() stringByAppendingPathComponent:@"com.minis.shanlianrenew.log"]; });

    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *a = [fm attributesOfItemAtPath:file error:NULL];
    if ([a fileSize] > 256 * 1024) {
        [fm removeItemAtPath:[file stringByAppendingString:@".1"] error:NULL];
        [fm moveItemAtPath:file toPath:[file stringByAppendingString:@".1"] error:NULL];
    }
    FILE *fp = fopen(file.UTF8String, "a");
    if (fp) { fputs(line.UTF8String, fp); fclose(fp); }
}

NSString *SLJbRoot(void) {
    if (g_root) return g_root;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *base = @"/var/mobile/Containers/Shared/AppGroup";
    NSMutableArray *cands = [NSMutableArray array];
    for (NSString *n in [fm contentsOfDirectoryAtPath:base error:NULL]) {
        if (![n hasPrefix:@".jbroot-"]) continue;
        NSString *p = [base stringByAppendingPathComponent:n];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:[p stringByAppendingPathComponent:@"usr/lib"] isDirectory:&isDir] || !isDir) continue;
        [cands addObject:p];
    }
    // 优先含本插件 dylib 的根，其次含 Library/MobileSubstrate，同分取最新
    NSString *best = nil; int bestScore = -1; NSTimeInterval bestT = 0;
    for (NSString *p in cands) {
        int score = 0;
        if ([fm fileExistsAtPath:[p stringByAppendingPathComponent:@"Library/MobileSubstrate"]]) score += 2;
        if ([fm fileExistsAtPath:[p stringByAppendingPathComponent:@"usr/lib/shanlianrenew.dylib"]]) score += 1;
        NSDictionary *a = [fm attributesOfItemAtPath:p error:NULL];
        NSTimeInterval t = [a fileModificationDate].timeIntervalSince1970;
        if (score > bestScore || (score == bestScore && t > bestT)) { best = p; bestScore = score; bestT = t; }
    }
    if (!best && [fm fileExistsAtPath:@"/var/jb/usr/lib"]) best = @"/var/jb";
    if (!best) best = @"";
    g_root = best;
    return g_root;
}

NSString *SLStateDir(void) {
    if (g_stateDir) return g_stateDir;
    NSString *r = SLJbRoot();
    NSString *p = r.length ? [r stringByAppendingPathComponent:@"var/mobile/Library/Preferences"]
                           : @"/var/mobile/Library/Preferences";
    [[NSFileManager defaultManager] createDirectoryAtPath:p withIntermediateDirectories:YES
                             attributes:nil error:NULL];
    g_stateDir = p;
    return g_stateDir;
}

NSString *SLStatePath(void) {
    return [SLStateDir() stringByAppendingPathComponent:SL_STATE_NAME];
}

NSString *SLAppGroupPrefsPath(void) {
    static NSString *p = nil;
    if (p) return p;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *base = @"/var/mobile/Containers/Shared/AppGroup";
    for (NSString *n in [fm contentsOfDirectoryAtPath:base error:NULL]) {
        NSString *c = [[base stringByAppendingPathComponent:n]
                       stringByAppendingPathComponent:@"Library/Preferences"];
        NSString *f = [c stringByAppendingPathComponent:
                       [SL_APP_GROUP stringByAppendingString:@".plist"]];
        if ([fm fileExistsAtPath:f]) { p = f; break; }
    }
    if (!p) p = @"";
    return p;
}
