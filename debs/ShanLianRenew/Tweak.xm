#import <substrate.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <stdlib.h>
#import <sys/socket.h>
#import <sys/uio.h>
#import <dlfcn.h>
#import <unistd.h>
#import <mach-o/dyld.h>
#import <string.h>
#import <Security/Security.h>
#import <CoreFoundation/CFUserNotification.h>
#import <UserNotifications/UserNotifications.h>
#import "SLRenewPaths.h"
#import "SLRenewState.h"
#import "SLHttp.h"
#import "SLSigner.h"
#import "SLCacheDB.h"
#import "SLDiag.h"
#import "SLRenewFlow.h"

static NSString *g_fakeId = nil;

#pragma mark - 抓请求体（诊断）

static __thread int g_inHook = 0;
static volatile int g_ready = 0;

static void SLDumpBuf(NSString *tag, const void *buf, size_t len) {
    if (!buf || len < 40 || !g_ready || g_inHook) return;
    g_inHook = 1;
    @try {
        size_t n = MIN(len, (size_t)4096);
        if (!memmem(buf, n, "firstDeviceLogin", 16)) return;
        NSData *d = [NSData dataWithBytes:buf length:n];
        SLLog(@"%@ firstDeviceLogin body-b64=%@", tag, [d base64EncodedStringWithOptions:0]);
    } @catch (__unused NSException *e) {
    } @finally {
        g_inHook = 0;
    }
}

static ssize_t (*g_origSend)(int, const void *, size_t, int);
static ssize_t SLHookSend(int fd, const void *buf, size_t len, int flags) {
    @try {
        if (buf && len > 40) {
            const char *p = (const char *)buf;
            size_t n = MIN(len, (size_t)4096);
            NSData *d = [NSData dataWithBytes:p length:n];
            NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
            if (s && [s containsString:@"firstDeviceLogin"]) {
                SLLog(@"SEND firstDeviceLogin body-b64=%@", [d base64EncodedStringWithOptions:0]);
            }
        }
    } @catch (__unused NSException *e) {}
    return g_origSend ? g_origSend(fd, buf, len, flags) : -1;
}

static ssize_t (*g_origWrite)(int, const void *, size_t);
static ssize_t SLHookWrite(int fd, const void *buf, size_t len) {
    SLDumpBuf(@"WRITE", buf, len);
    return g_origWrite ? g_origWrite(fd, buf, len) : -1;
}

static ssize_t (*g_origSendTo)(int, const void *, size_t, int, const struct sockaddr *, socklen_t);
static ssize_t SLHookSendTo(int fd, const void *buf, size_t len, int flags, const struct sockaddr *a, socklen_t al) {
    SLDumpBuf(@"SENDTO", buf, len);
    return g_origSendTo ? g_origSendTo(fd, buf, len, flags, a, al) : -1;
}

static ssize_t (*g_origWriteV)(int, const struct iovec *, int);
static ssize_t SLHookWriteV(int fd, const struct iovec *iov, int cnt) {
    for (int i = 0; i < cnt; i++) SLDumpBuf(@"WRITEV", iov[i].iov_base, iov[i].iov_len);
    return g_origWriteV ? g_origWriteV(fd, iov, cnt) : -1;
}

static int (*g_origSSLWrite)(void *, const void *, int);
static int SLHookSSLWrite(void *ssl, const void *buf, int num) {
    SLDumpBuf(@"SSL", buf, (size_t)num);
    return g_origSSLWrite ? g_origSSLWrite(ssl, buf, num) : -1;
}

#pragma mark - 钥匙串写入诊断

static OSStatus (*g_origSecItemCopyMatching)(CFDictionaryRef, CFTypeRef *);
static OSStatus SLHookSecItemCopyMatching(CFDictionaryRef q, CFTypeRef *out) {
    @try {
        NSDictionary *d = (__bridge NSDictionary *)q;
        SLLog(@"CopyMatching class=%@ acct=%@ svce=%@ agrp=%@",
              d[(__bridge id)kSecClass], d[(__bridge id)kSecAttrAccount],
              d[(__bridge id)kSecAttrService], d[(__bridge id)kSecAttrAccessGroup]);
    } @catch (__unused NSException *e) {}
    OSStatus st = g_origSecItemCopyMatching ? g_origSecItemCopyMatching(q, out) : errSecInternalError;
    @try {
        if (st == errSecSuccess && out && *out) {
            id r = (__bridge id)*out;
            if ([r isKindOfClass:[NSData class]]) {
                NSData *x = (NSData *)r;
                NSString *t = x.length ? [[NSString alloc] initWithData:
                    [x subdataWithRange:NSMakeRange(0, MIN((NSUInteger)20, x.length))] encoding:NSUTF8StringEncoding] : nil;
                SLLog(@"  -> data len=%lu head=%@", (unsigned long)x.length, t ?: @"");
            } else if ([r isKindOfClass:[NSArray class]]) {
                for (NSDictionary *it in (NSArray *)r) {
                    if (![it isKindOfClass:[NSDictionary class]]) continue;
                    id dat = it[(__bridge id)kSecValueData];
                    NSString *t = nil;
                    if ([dat isKindOfClass:[NSData class]] && [(NSData *)dat length]) {
                        t = [[NSString alloc] initWithData:[(NSData *)dat subdataWithRange:
                             NSMakeRange(0, MIN((NSUInteger)16, [(NSData *)dat length]))]
                                                  encoding:NSUTF8StringEncoding];
                    }
                    SLLog(@"  item acct=%@ len=%lu head=%@",
                          it[(__bridge id)kSecAttrAccount],
                          (unsigned long)[(NSData *)dat length], t ?: @"");
                }
            } else {
                SLLog(@"  -> %@", [r class]);
            }
        } else {
            SLLog(@"  -> st=%d", (int)st);
        }
    } @catch (__unused NSException *e) {}
    return st;
}

static OSStatus (*g_origSecItemAdd)(CFDictionaryRef, CFTypeRef *);
static OSStatus SLHookSecItemAdd(CFDictionaryRef attrs, CFTypeRef *out) {
    @try {
        NSDictionary *d = (__bridge NSDictionary *)attrs;
        NSString *cls = [d[(__bridge id)kSecClass] description];
        id data = d[(__bridge id)kSecValueData];
        NSString *head = @"";
        if ([data isKindOfClass:[NSData class]]) {
            NSData *x = (NSData *)data;
            NSString *t = [[NSString alloc] initWithData:[x subdataWithRange:
                            NSMakeRange(0, MIN((NSUInteger)24, x.length))] encoding:NSUTF8StringEncoding];
            if (t) head = t;
            SLLog(@"SecItemAdd len=%lu head=%@", (unsigned long)x.length, head);
        } else {
            SLLog(@"SecItemAdd class=%@", cls);
        }
        SLLog(@"  acct=%@ svce=%@ agrp=%@ sync=%@",
              d[(__bridge id)kSecAttrAccount], d[(__bridge id)kSecAttrService],
              d[(__bridge id)kSecAttrAccessGroup], d[(__bridge id)kSecAttrSynchronizable]);
    } @catch (__unused NSException *e) {}
    return g_origSecItemAdd ? g_origSecItemAdd(attrs, out) : errSecInternalError;
}
static const char *kSLFireName = "com.minis.shanlianrenew.fire";

#pragma mark - 通知

static void SLNotify(NSString *title, NSString *body) {
    SLLog(@"notify: %@ / %@", title, body);
    Class unc = NSClassFromString(@"UNUserNotificationCenter");
    if (unc) {
        UNMutableNotificationContent *c = [UNMutableNotificationContent new];
        c.title = title; c.body = body;
        UNNotificationRequest *r = [UNNotificationRequest requestWithIdentifier:
            [NSString stringWithFormat:@"sl.%u", arc4random()] content:c trigger:nil];
        [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:r withCompletionHandler:nil];
        return;
    }
    CFUserNotificationDisplayNotice(0, 0, NULL, NULL, NULL,
        (__bridge CFStringRef)title, (__bridge CFStringRef)body, NULL);
}

#pragma mark - 身份

// 到期提醒：由 App 自己排一条本地通知，点它会打开 App，App 起来就自动续期
static void SLScheduleReminder(SLState *st) {
    if (!st.enabled) return;
    Class unc = NSClassFromString(@"UNUserNotificationCenter");
    if (!unc) return;
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    if (!center) return;

    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge)
                          completionHandler:^(BOOL granted, NSError *err) {
        SLLog(@"notif auth granted=%d err=%@", granted, err.localizedDescription ?: @"-");
    }];

    [center removePendingNotificationRequestsWithIdentifiers:@[@"sl.remind"]];

    double now = [NSDate date].timeIntervalSince1970;
    double fire = (st.nextFire1 > now + 5) ? st.nextFire1 : now + 30;

    NSDate *dl = [NSDate dateWithTimeIntervalSince1970:(st.deadline > 0 ? st.deadline : now)];
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"MM-dd HH:mm";

    UNMutableNotificationContent *c = [UNMutableNotificationContent new];
    c.title = @"闪连快到期了";
    c.body = [NSString stringWithFormat:@"点这条通知，自动帮你续期（到期 %@）", [df stringFromDate:dl]];
    c.sound = [UNNotificationSound defaultSound];
    c.userInfo = @{@"slrenew": @YES};

    UNTimeIntervalNotificationTrigger *tr =
        [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:(fire - now) repeats:NO];
    UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:@"sl.remind"
                                                                    content:c trigger:tr];
    [center addNotificationRequest:req withCompletionHandler:^(NSError *err) {
        SLLog(@"reminder in %.0fs err=%@", fire - now, err.localizedDescription ?: @"-");
    }];
    st.remindAt = fire;
    [st save];
}

static void (*g_origMakeKeyAndVisible_)(id, SEL) = NULL;

static NSUserDefaults *SLDefaults(void);

// 点通知的回调：记下"这次是点通知进来的"，App 启动时据此立刻续期
@interface SLNotifHandler : NSObject <UNUserNotificationCenterDelegate>
+ (instancetype)shared;
@end

@implementation SLNotifHandler
+ (instancetype)shared {
    static SLNotifHandler *g = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ g = [SLNotifHandler new]; });
    return g;
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
 didReceiveNotificationResponse:(UNNotificationResponse *)response
          withCompletionHandler:(void (^)(void))completion {
    @try {
        NSDictionary *u = response.notification.request.content.userInfo;
        if ([u[@"slrenew"] boolValue]) {
            SLLog(@"notif tapped -> mark renew");
            [SLDefaults() setBool:YES forKey:@"sl.lastNotifTap"];
            [SLDefaults() synchronize];
            SLState *st = [SLState load];
            st.phase = SLPhaseResetting;
            st.attempt = 0;
            [st save];
            SLLog(@"notif tap -> phase resetting");
        }
    } @catch (NSException *e) {
        SLLog(@"notif tap exception %@", e.reason ?: @"-");
    }
    if (completion) completion();
}
@end

static NSUUID *(*g_origIdfv)(id, SEL) = NULL;
static NSUUID *SLHookIdfv(id self, SEL _cmd) {
    if (g_fakeId.length) return [[NSUUID alloc] initWithUUIDString:g_fakeId];
    return g_origIdfv ? g_origIdfv(self, _cmd) : nil;
}

static NSUUID *(*g_origAdid)(id, SEL) = NULL;
static NSUUID *SLHookAdid(id self, SEL _cmd) {
    if (g_fakeId.length) return [[NSUUID alloc] initWithUUIDString:g_fakeId];
    return g_origAdid ? g_origAdid(self, _cmd) : nil;
}


static NSUserDefaults *SLDefaults(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:SL_PREF_SUITE];
    if (!d) d = [[NSUserDefaults alloc] initWithSuiteName:SL_APP_GROUP];
    if (!d) d = [NSUserDefaults standardUserDefaults];
    return d;
}


#pragma mark - 配对捕获（data + 密钥同刻取样）

// 把钥匙串全部项完整写出（含完整 base64），用于和同一时刻的 data 配对解密
static NSString *SLCaptureKeychain(void) {
    NSMutableString *out = [NSMutableString string];
    NSArray *items = [SLHttp keychainItems];
    [out appendFormat:@"# count=%lu ts=%.0f\n", (unsigned long)items.count, [NSDate date].timeIntervalSince1970];
    for (NSDictionary *d in items) {
        NSString *acc = [d[(__bridge id)kSecAttrAccount] description] ?: @"";
        NSString *svc = [d[(__bridge id)kSecAttrService] description] ?: @"";
        NSString *grp = [d[(__bridge id)kSecAttrAccessGroup] description] ?: @"";
        NSData *val = d[(__bridge id)kSecValueData];
        NSString *b64 = [val isKindOfClass:[NSData class]] ? [val base64EncodedStringWithOptions:0] : @"";
        [out appendFormat:@"%@\t%@\t%@\t%@\n", acc, svc, grp, b64];
    }
    NSString *p = [SLStateDir() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"cap-kc-%.0f.tsv", [NSDate date].timeIntervalSince1970]];
    [out writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    SLLog(@"capture: keychain -> %@ (%lu items)", p.lastPathComponent, (unsigned long)items.count);
    return p;
}

// 从 App 缓存里找 firstDeviceLogin 的请求体，原样写出
static BOOL SLCaptureLoginBody(void) {
    NSString *body = [SLCacheDB firstDeviceLoginBody];
    if (!body.length) return NO;
    NSData *d = [body dataUsingEncoding:NSUTF8StringEncoding];
    NSString *p = [SLStateDir() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"cap-body-%.0f.json", [NSDate date].timeIntervalSince1970]];
    [d writeToFile:p atomically:YES];
    SLLog(@"capture: login body -> %@ (%lu bytes)", p.lastPathComponent, (unsigned long)d.length);
    return YES;
}

static void SLCaptureRun(void) {
    SLCaptureKeychain();
    __block int tries = 0;
    void (^poll)(void);
    __block __weak void (^weakPoll)(void);
    weakPoll = poll = ^{
        if (SLCaptureLoginBody()) { SLLog(@"capture: done"); return; }
        if (++tries > 12) { SLLog(@"capture: body not found after %d tries", tries); return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), weakPoll);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), poll);
}

#pragma mark - 重置

static void SLPerformReset(SLState *st) {
    NSUserDefaults *d = SLDefaults();
    if (!d) d = [NSUserDefaults standardUserDefaults];
    NSDictionary *snap = [d dictionaryRepresentation] ?: @{};
    st.snapPrefs = snap;
    st.snapToken = [SLHttp currentToken];
    st.phase = SLPhaseNeedFill;
    st.attempt = 0;
    st.lastRun = [NSDate date].timeIntervalSince1970;

    // 偏好文件留底，万一 App 没注册出来可以还原
    NSString *appPl = SLAppPrefsPath();
    NSString *dir = SLStateDir();
    NSString *bak = [dir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"prefs-%.0f.plist", [NSDate date].timeIntervalSince1970]];
    if (appPl) {
        [[NSFileManager defaultManager] copyItemAtPath:appPl toPath:bak error:NULL];
        st.kcBackup = bak;
    }
    [d setObject:g_fakeId forKey:SL_DEVICE_KEY];
    [d synchronize];
    [SLHttp setDeviceId:g_fakeId];   // 真正生效的是钥匙串里那份
    SLLog(@"reset done id=%@ snap=%lu cleared=%d", g_fakeId, (unsigned long)snap.count, cleared);

    // 主队列正常退出；主线程若被卡住，全局队列兜底
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ exit(0); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(0, 0), ^{ exit(0); });
}

#pragma mark - 填码

static void SLFailOrRetry(SLState *st, NSString *reason);
static void SLGoBackground(void);
static BOOL g_filling = NO;

static NSDate *SLParseDeadline(NSDictionary *data) {
    NSString *iso = data[@"isoDeadline"];
    if ([iso isKindOfClass:[NSString class]]) {
        NSISO8601DateFormatter *f = [NSISO8601DateFormatter new];
        f.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        NSDate *d = [f dateFromString:iso];
        if (d) return d;
    }
    NSString *plain = data[@"deadline"];
    if ([plain isKindOfClass:[NSString class]]) {
        NSDateFormatter *f = [NSDateFormatter new];
        f.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        return [f dateFromString:plain];
    }
    return nil;
}

static void SLFill(SLState *st, NSString *token) {
    (void)token;
    SLLog(@"filling");
    [SLHttp send:@"POST" path:@"/app/customer/slfillInviteCodefe"
           body:@{@"inviteCode": st.code ?: @"88888888"}
     completion:^(NSInteger status, NSDictionary *resp, NSError *err) {
        NSString *rj = resp ? [[NSString alloc] initWithData:
            [NSJSONSerialization dataWithJSONObject:resp options:0 error:NULL]
            encoding:NSUTF8StringEncoding] : (err.localizedDescription ?: @"");
        SLLog(@"fill resp http=%ld api=%ld body=%@", (long)status,
              (long)[resp[@"code"] integerValue],
              [rj substringToIndex:MIN((NSUInteger)220, rj.length)]);
        if ([resp[@"code"] integerValue] != 200) {
            g_filling = NO;
            SLFailOrRetry(st, [NSString stringWithFormat:@"fill %ld/%ld",
                               (long)status, (long)[resp[@"code"] integerValue]]);
            return;
        }
        [SLHttp send:@"GET" path:@"/app/customer/slgetUserInfogo" body:nil
         completion:^(NSInteger s2, NSDictionary *r2, NSError *e2) {
            NSDictionary *data = r2[@"data"];
            NSDate *nd = SLParseDeadline(data);
            double ndv = nd ? nd.timeIntervalSince1970 : 0;
            SLLog(@"verify old=%.0f new=%.0f", st.deadline, ndv);
            if (ndv > st.deadline + 86400) {
                g_filling = NO;
                [st armFromDeadline:ndv];
                st.attempt = 0;
                st.lastError = @"";
                st.dueNotified = NO;
                [st save];
                SLScheduleReminder(st);
                SLLog(@"renew ok -> %.0f", ndv);
                SLNotify(@"闪连已续上",
                         [NSString stringWithFormat:@"新账号 %@，到期 %@",
                          data[@"userName"] ?: @"", data[@"deadline"] ?: @""]);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ SLGoBackground(); });
            } else {
                g_filling = NO;
                SLFailOrRetry(st, @"deadline not extended");
            }
        }];
    }];
}

static void SLFailOrRetry(SLState *st, NSString *reason) {
    st.lastError = reason ?: @"";
    st.attempt++;
    [st save];
    SLLog(@"fail: %@ (%d)", reason, st.attempt);
    if (st.attempt < st.maxAttempts) return;
    // 把备份的偏好文件整份还原回去（kcBackup 现在存的是偏好备份路径）
    NSString *appPl = SLAppPrefsPath();
    if (st.kcBackup.length && appPl &&
        [[NSFileManager defaultManager] fileExistsAtPath:st.kcBackup]) {
        NSData *bak = [NSData dataWithContentsOfFile:st.kcBackup];
        if (bak.length) {
            [bak writeToFile:appPl atomically:YES];
            SLLog(@"rollback: prefs restored from %@", st.kcBackup.lastPathComponent);
        }
    }
    st.phase = SLPhaseFailed;
    [st save];
    SLLog(@"rolled back, phase=failed");
    SLNotify(@"闪连没续上", [NSString stringWithFormat:@"需要你看一眼（%@）", reason ?: @"未知"]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ SLGoBackground(); });
}

#pragma mark - 流程（App 端）

static void SLRefreshDeadline(void) {
    if (![SLHttp currentToken]) {
        [SLHttp mintTokenCompletion:^(NSString *t, NSString *raw) {
            if (t.length) { SLLog(@"mint ok token len=%lu", (unsigned long)t.length); SLRefreshDeadline(); }
            else { SLLog(@"mint failed"); }
        }];
        return;
    }
    SLState *st0 = [SLState load];
    if (st0.phase == SLPhaseNeedFill || st0.phase == SLPhaseResetting) return;
    [SLHttp send:@"GET" path:@"/app/customer/slgetUserInfogo" body:nil
     completion:^(NSInteger s, NSDictionary *r, NSError *e) {
        NSDate *nd = SLParseDeadline(r[@"data"]);
        if (!nd) return;
        SLState *st = [SLState load];
        if (st.phase == SLPhaseNeedFill || st.phase == SLPhaseResetting) return;
        [st armFromDeadline:nd.timeIntervalSince1970];
        st.attempt = 0;
        [st save];
        SLLog(@"deadline=%.0f next=%.0f", st.deadline, st.nextFire1);
        SLScheduleReminder(st);
    }];
}

static __attribute__((unused)) void SLRunFillPhase(SLState *st) {
    if (g_filling) return;
    g_filling = YES;

    st.signerIdx = 0;   // 使用固定签名，不需要校准
    NSString *old = st.snapToken ?: @"";
    __block int waited = 0;
    __block __weak void (^weakPoll)(void);
    void (^poll)(void);
    weakPoll = poll = ^{
        NSString *t = [SLHttp newTokenDifferentFrom:old];
        if (t) {
            SLDiag(@"fill", @"new token after %ds len=%lu", waited, (unsigned long)t.length);
            SLFill(st, t); return;
        }
        if (waited % 15 == 0) { SLDiag(@"fill", @"waiting token %ds", waited); SLDiagSnapshot(@"waiting-token"); }
        if (++waited > 90) { g_filling = NO; SLFailOrRetry(st, @"no new token"); return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), weakPoll);
    };
    poll();
}

static void SLOnLaunch(void) {
    SLState *st = [SLState load];
    if (st.phase == SLPhaseResetting) {
        // 只有锁屏时才真正换号（会退出 App），避免打断用户
        if (!SLScreenLocked()) { SLLog(@"reset: not locked, defer"); return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SLState *s2 = [SLState load];
            if (s2.phase == SLPhaseResetting) SLPerformReset(s2);
        });
        return;
    }
    if (st.phase == SLPhaseNeedFill) { SLRunFillPhase(st); return; }
    [SLHttp warmup];
    [SLHttp probeNet];
    [SLHttp probeHeaders];
    SLRefreshDeadline();
}

#pragma mark - 计时（桌面端）

static __attribute__((unused)) BOOL SLScreenLocked(void) {
    Class c = NSClassFromString(@"SBLockScreenManager");
    if (!c) return NO;
    id sh = ((id (*)(id, SEL))objc_msgSend)(c, sel_registerName("sharedInstance"));
    if (!sh) return NO;
    SEL s = sel_registerName("isUILocked");
    if ([sh respondsToSelector:s]) return ((BOOL (*)(id, SEL))objc_msgSend)(sh, s);
    return NO;
}

static void SLOpenApp(void);

static BOOL SLAppRunning(void) {
    Class c = NSClassFromString(@"LSApplicationWorkspace");
    if (!c) return NO;
    id ws = ((id (*)(id, SEL))objc_msgSend)(c, sel_registerName("defaultWorkspace"));
    if (!ws) return NO;
    SEL sel = sel_registerName("runningApplications");
    if (![ws respondsToSelector:sel]) return NO;
    id apps = ((id (*)(id, SEL))objc_msgSend)(ws, sel);
    if (![apps isKindOfClass:[NSArray class]]) return NO;
    for (id a in (NSArray *)apps) {
        SEL bs = sel_registerName("bundleIdentifier");
        if (![a respondsToSelector:bs]) continue;
        id bid = ((id (*)(id, SEL))objc_msgSend)(a, bs);
        if ([bid isKindOfClass:[NSString class]] && [(NSString *)bid isEqualToString:SL_APP_ID]) return YES;
    }
    return NO;
}

// 最近一次拉起的时间，避免每 15 秒强行前台化
static NSTimeInterval g_lastOpen = 0;
static void SLOpenAppThrottled(void) {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - g_lastOpen < 90) return;          // 90 秒内不重复拉起
    g_lastOpen = now;
    SLLog(@"open app (throttled)");
    SLOpenApp();
}

static void SLOpenApp(void) {
    Class c = NSClassFromString(@"LSApplicationWorkspace");
    if (c) {
        id ws = ((id (*)(id, SEL))objc_msgSend)(c, sel_registerName("defaultWorkspace"));
        if (ws) {
            ((void (*)(id, SEL, id))objc_msgSend)(ws,
                sel_registerName("openApplicationWithBundleID:"), SL_APP_ID);
            return;
        }
    }
}

static void SLTick(void) {
    SLDiagCheckRequest();
    // 观察版：桌面端不做任何动作（不拉起 App、不重置、不填码）
    SLState *st = [SLState load];
    double now = [NSDate date].timeIntervalSince1970;

    // 换号/填码阶段同样只在锁屏时动作，避免打扰用户
    if (st.phase == SLPhaseResetting || st.phase == SLPhaseNeedFill) {
        if (!SLScreenLocked()) {
            if ((int)now % 300 == 0) SLLog(@"phase=%d waiting for lock", (int)st.phase);
            return;
        }
        if (!SLAppRunning()) SLOpenAppThrottled();
        if (st.phase == SLPhaseNeedFill) notify_post(kSLFireName);
        return;
    }
    if (st.phase != SLPhaseArmed) return;

    BOOL due = (st.nextFire1 > 0 && now >= st.nextFire1) || (st.nextFire2 > 0 && now >= st.nextFire2);
    if (!due) return;
    SLLog(@"due reached dl_in=%.0f (等待用户点通知)", st.deadline - now);
}


#pragma mark - 注入

static void SLInitBody(void);
__attribute__((constructor)) static void SLInit(void) {
    @try { SLInitBody(); }
    @catch (NSException *e) { SLLog(@"ctor exception %@: %@", e.name, e.reason); }
}

static void SLInitBody(void) {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier;
    BOOL isApp = [bid isEqualToString:SL_APP_ID];
    BOOL isSB  = [bid isEqualToString:SL_SB_ID];
    BOOL isExt = [bid isEqualToString:@"com.shanlian.pro.iosTunnel"];
    if (!isApp && !isSB && !isExt) return;
    if (isExt) {
        SLLog(@"init tunnel ext v%@", SL_VER);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NSArray *items = [SLHttp keychainItems];
            SLLog(@"ext items=%lu", (unsigned long)items.count);
            for (NSDictionary *it in items) {
                NSString *acc = [it[(__bridge id)kSecAttrAccount] description] ?: @"";
                NSData *d = it[(__bridge id)kSecValueData];
                NSString *b64 = [d isKindOfClass:[NSData class]]
                    ? [[d base64EncodedStringWithOptions:0] substringToIndex:
                       MIN((NSUInteger)44, [d base64EncodedStringWithOptions:0].length)] : @"";
                SLLog(@"ext item %@ len=%lu %@", acc,
                      (unsigned long)([d isKindOfClass:[NSData class]] ? d.length : 0), b64);
            }
        });
        return;
    }
    SLLog(@"init %@ v%@ ver-state=%@ phase=%d", bid, SL_VER,
          [[NSDictionary dictionaryWithContentsOfFile:SLStatePath()] objectForKey:@"ver"] ?: @"-", 0);

    if (isApp) {
        // 自动续期流程里：先把"已同意隐私协议"写进 App 自己的偏好，避免停在协议页
        @try {
            SLState *st0 = [SLState load];
            if (st0.phase == SLPhaseNeedFill || st0.phase == SLPhaseResetting) {
                NSUserDefaults *sd = [NSUserDefaults standardUserDefaults];
                [sd setBool:YES forKey:@"flutter.agree"];
                [sd setBool:NO forKey:@"flutter.kisAppFirstLaunchedKey"];
                [sd synchronize];
                SLLog(@"app-side agree seeded");
            }
        } @catch (NSException *e) {}
        g_fakeId = [SLDefaults() stringForKey:SL_DEVICE_KEY];
        @try {
            [UNUserNotificationCenter currentNotificationCenter].delegate = [SLNotifHandler shared];
            SLLog(@"notif delegate set");
            [[NSNotificationCenter defaultCenter]
                addObserverForName:UIApplicationDidBecomeActiveNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *n) {
                SLState *cur = [SLState load];
                if (!cur.enabled) return;
                SLLog(@"became active -> check renew");
                if (SLRenewIfDue()) return;
                SLScheduleReminder(cur);
            }];
        } @catch (NSException *e) { SLLog(@"delegate fail %@", e.reason ?: @"-"); }
    }


    Class ud = NSClassFromString(@"UIDevice");
    if (ud) MSHookMessageEx(ud, @selector(identifierForVendor), (IMP)SLHookIdfv, (IMP *)&g_origIdfv);
    MSHookFunction((void *)send, (void *)SLHookSend, (void **)&g_origSend);
    MSHookFunction((void *)write, (void *)SLHookWrite, (void **)&g_origWrite);
    MSHookFunction((void *)sendto, (void *)SLHookSendTo, (void **)&g_origSendTo);
    MSHookFunction((void *)writev, (void *)SLHookWriteV, (void **)&g_origWriteV);
    g_ready = 1;
    void *sslw = dlsym(RTLD_DEFAULT, "SSL_write");
    if (sslw) MSHookFunction(sslw, (void *)SLHookSSLWrite, (void **)&g_origSSLWrite);
    MSHookFunction((void *)SecItemAdd, (void *)SLHookSecItemAdd, (void **)&g_origSecItemAdd);
    MSHookFunction((void *)SecItemCopyMatching, (void *)SLHookSecItemCopyMatching, (void **)&g_origSecItemCopyMatching);
    Class am = NSClassFromString(@"ASIdentifierManager");
    if (am) MSHookMessageEx(am, @selector(advertisingIdentifier), (IMP)SLHookAdid, (IMP *)&g_origAdid);

    if (isSB) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSTimer scheduledTimerWithTimeInterval:3 repeats:YES block:^(NSTimer *t) { SLTick(); }];
            SLTick();
            [SLHttp probeNet];
            [SLHttp probeHeaders];
        });
        return;
    }

    int tok = 0;
    notify_register_dispatch(kSLFireName, &tok, dispatch_get_main_queue(), ^(int t) { SLOnLaunch(); });

    SLState *st = [SLState load];
    BOOL fresh = ![SL_VER isEqualToString:(st.ver ?: @"")];
    if (fresh) {
        st.ver = SL_VER;
        st.phase = SLPhaseIdle;
        st.attempt = 0;
        st.lastError = @"";
        [st save];
        SLLog(@"fresh %@ state=%@ logdir=%@", SL_VER, SLStatePath(), SLLogDir());
    }

    SLOnLaunch();
}
