#import "SLDiag.h"
#import "SLRenewPaths.h"
#import "SLHttp.h"
#import "SLCacheDB.h"
#import <Security/Security.h>

static NSString *SLDiagPath(void) {
    return [SLStateDir() stringByAppendingPathComponent:@"diag.log"];
}

static NSString *SLDiagReqPath(void) {
    return [SLStateDir() stringByAppendingPathComponent:@"diag.req"];
}

void SLDiag(NSString *cat, NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"MM-dd HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n",
                      [f stringFromDate:[NSDate date]], cat ?: @"-", msg ?: @""];

    NSString *p = SLDiagPath();
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:p];
    if (!h) {
        [line writeToFile:p atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    } else {
        @try {
            [h seekToEndOfFile];
            [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [h closeFile];
        } @catch (NSException *e) {}
    }
    // 同一份也进主日志，方便连着看时序
    SLLog(@"diag[%@] %@", cat ?: @"-", msg ?: @"");
}

// 读 App 自己的偏好文件，取出关键字段（不依赖 App 运行）
static NSString *SLDiagAppFacts(void) {
    NSString *pl = SLAppPrefsPath();
    if (!pl) return @"app prefs: NOT FOUND";
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:pl];
    if (![d isKindOfClass:[NSDictionary class]]) return @"app prefs: unreadable";
    NSString *j = d[@"flutter.klocalUserInfoSaveKey"];
    if (![j isKindOfClass:[NSString class]]) return @"app prefs: no login key";

    NSMutableString *out = [NSMutableString string];
    @try {
        NSDictionary *o = [NSJSONSerialization JSONObjectWithData:
                           [j dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        NSDictionary *ui = o[@"userInfo"];
        NSString *tok = o[@"token"];
        [out appendFormat:@"userId=%@ userName=%@ deadline=%@ tokenLen=%lu\n",
            o[@"userId"] ?: @"-", ui[@"userName"] ?: @"-", ui[@"isoDeadline"] ?: @"-",
            (unsigned long)([tok isKindOfClass:[NSString class]] ? tok.length : 0)];
    } @catch (NSException *e) {
        [out appendFormat:@"login json parse failed: %@\n", e.reason];
    }
    [out appendFormat:@"agree=%@ firstLaunch=%@ alwaysOn=%@ loginTs=%@\n",
        d[@"flutter.agree"] ?: @"-", d[@"flutter.kisAppFirstLaunchedKey"] ?: @"-",
        d[@"flutter.kappleAwaysOnKey"] ?: @"-", d[@"flutter.login_ts"] ?: @"-"];
    return out;
}

static NSString *SLDiagKeychainFacts(void) {
    NSMutableString *out = [NSMutableString string];
    NSArray *items = [SLHttp keychainItems];
    [out appendFormat:@"keychain items=%lu\n", (unsigned long)items.count];
    for (NSDictionary *d in items) {
        NSString *acc = [d[(__bridge id)kSecAttrAccount] description] ?: @"";
        NSString *svc = [d[(__bridge id)kSecAttrService] description] ?: @"";
        NSData *v = d[(__bridge id)kSecValueData];
        NSUInteger n = [v isKindOfClass:[NSData class]] ? v.length : 0;
        [out appendFormat:@"  kc %@ / %@ len=%lu\n", acc, svc, (unsigned long)n];
    }
    return out;
}

static NSString *SLDiagOwnState(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:SLStatePath()] ?: @{};
    NSMutableString *out = [NSMutableString string];
    for (NSString *k in @[@"ver", @"phase", @"enabled", @"attempt", @"deadline",
                          @"nextFire1", @"nextFire2", @"lastError", @"kcBackup"]) {
        [out appendFormat:@"  %@=%@\n", k, d[k] ?: @"-"];
    }
    return out;
}

NSString *SLDiagSnapshot(NSString *why) {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"===== SNAPSHOT %@ =====\n", why ?: @""];
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    [s appendFormat:@"time: %@\n\n", [f stringFromDate:[NSDate date]]];

    [s appendString:@"-- plugin state --\n"];
    [s appendString:SLDiagOwnState()];
    [s appendString:@"\n-- app login facts --\n"];
    [s appendString:SLDiagAppFacts()];
    [s appendString:@"\n-- cache db --\n"];
    [s appendFormat:@"tokenInCache=%d peachInCache=%d\n",
        [SLCacheDB token] ? 1 : 0, [SLCacheDB peach] ? 1 : 0];
    [s appendString:@"\n-- keychain --\n"];
    [s appendString:SLDiagKeychainFacts()];
    [s appendString:@"\n-- paths --\n"];
    [s appendFormat:@"stateDir=%@\nappPrefs=%@\n", SLStateDir(), SLAppPrefsPath() ?: @"-"];

    NSString *p = [SLStateDir() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"snapshot-%.0f.txt", [NSDate date].timeIntervalSince1970]];
    [s writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    SLDiag(@"snap", @"written %@", p.lastPathComponent);
    return p;
}

void SLDiagCheckRequest(void) {
    NSString *req = SLDiagReqPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:req]) return;
    [[NSFileManager defaultManager] removeItemAtPath:req error:NULL];
    SLDiag(@"snap", @"requested");
    SLDiagSnapshot(@"on demand");
}
