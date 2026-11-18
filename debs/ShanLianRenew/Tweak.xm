#import <substrate.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <stdlib.h>
#import <Security/Security.h>
#import <CoreFoundation/CFUserNotification.h>
#import <UserNotifications/UserNotifications.h>
#import "SLRenewPaths.h"
#import "SLRenewState.h"
#import "SLHttp.h"
#import "SLSigner.h"

static NSString *g_fakeId = nil;

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

static NSString *SLNewUUID(void) { return [[NSUUID UUID].UUIDString uppercaseString]; }

static NSUserDefaults *SLDefaults(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:SL_PREF_SUITE];
    if (!d) d = [[NSUserDefaults alloc] initWithSuiteName:SL_APP_GROUP];
    if (!d) d = [NSUserDefaults standardUserDefaults];
    return d;
}

static BOOL SLLooksLikeToken(id v) {
    return [v isKindOfClass:[NSString class]] && [(NSString *)v hasPrefix:@"eyJ"];
}

static BOOL SLAccountKey(NSString *k, id v) {
    NSString *l = k.lowercaseString;
    if (SLLooksLikeToken(v)) return YES;
    if ([l isEqualToString:SL_DEVICE_KEY.lowercaseString]) return NO;
    for (NSString *p in @[@"token", @"userinfo", @"user_info", @"vip", @"dead", @"expire",
                          @"member", @"login", @"uid", @"iso", @"level"]) {
        if ([l containsString:p]) return YES;
    }
    return NO;
}

#pragma mark - 重置

static void SLPerformReset(SLState *st) {
    NSUserDefaults *d = SLDefaults();
    if (!d) d = [NSUserDefaults standardUserDefaults];
    NSDictionary *snap = [d dictionaryRepresentation] ?: @{};
    st.snapPrefs = snap;
    st.snapToken = [SLHttp currentToken];
    st.phase = SLPhaseNeedFill;
    st.lastRun = [NSDate date].timeIntervalSince1970;
    [st save];

    g_fakeId = SLNewUUID();
    int cleared = 0;
    for (NSString *k in snap.allKeys) {
        if ([k isEqualToString:SL_DEVICE_KEY]) continue;
        if (SLAccountKey(k, snap[k])) { [d removeObjectForKey:k]; cleared++; }
    }
    [d setObject:g_fakeId forKey:SL_DEVICE_KEY];
    [d synchronize];
    SLLog(@"reset done id=%@ snap=%lu cleared=%d", g_fakeId, (unsigned long)snap.count, cleared);

    // 主队列正常退出；主线程若被卡住，全局队列兜底
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ exit(0); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(0, 0), ^{ exit(0); });
}

#pragma mark - 填码

static void SLFailOrRetry(SLState *st, NSString *reason);
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
        SLLog(@"fill resp http=%ld api=%ld", (long)status, (long)[resp[@"code"] integerValue]);
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
                [st save];
                SLLog(@"renew ok -> %.0f", ndv);
                SLNotify(@"闪连已续上", [NSString stringWithFormat:@"到期 %@", data[@"deadline"] ?: @""]);
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
    if (st.snapPrefs) {
        NSUserDefaults *d = SLDefaults();
        for (NSString *k in st.snapPrefs.allKeys) [d setObject:st.snapPrefs[k] forKey:k];
        [d synchronize];
    }
    st.phase = SLPhaseFailed;
    [st save];
    SLLog(@"rolled back, phase=failed");
    SLNotify(@"闪连没续上", [NSString stringWithFormat:@"已退回旧号，需要你看一眼（%@）", reason ?: @"未知"]);
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
    }];
}

static void SLRunFillPhase(SLState *st) {
    if (g_filling) return;
    g_filling = YES;

    if (st.signerIdx < 0) {
        [SLHttp calibrateSignerCompletion:^(NSInteger i) {
            SLState *s2 = [SLState load]; s2.signerIdx = (int)i; [s2 save];
            SLLog(@"signer=%ld", (long)i);
            g_filling = NO;
            SLRunFillPhase(s2);
        }];
        return;
    }

    NSString *old = st.snapToken ?: @"";
    __block int waited = 0;
    __block __weak void (^weakPoll)(void);
    void (^poll)(void);
    weakPoll = poll = ^{
        NSString *t = [SLHttp newTokenDifferentFrom:old];
        if (t) { SLLog(@"new token after %ds", waited); SLFill(st, t); return; }
        if (waited % 15 == 0) SLLog(@"waiting token %ds", waited);
        if (++waited > 90) { g_filling = NO; SLFailOrRetry(st, @"no new token"); return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), weakPoll);
    };
    poll();
}

static void SLOnLaunch(void) {
    SLState *st = [SLState load];
    if (st.phase == SLPhaseResetting) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SLState *s2 = [SLState load];
            if (s2.phase == SLPhaseResetting) SLPerformReset(s2);
        });
        return;
    }
    if (st.phase == SLPhaseNeedFill) { SLRunFillPhase(st); return; }
    [SLHttp probeNet];
    [SLHttp probeHeaders];
    SLRefreshDeadline();
}

#pragma mark - 计时（桌面端）

static BOOL SLScreenLocked(void) {
    Class c = NSClassFromString(@"SBLockScreenManager");
    if (!c) return NO;
    id sh = ((id (*)(id, SEL))objc_msgSend)(c, sel_registerName("sharedInstance"));
    if (!sh) return NO;
    SEL s = sel_registerName("isUILocked");
    if ([sh respondsToSelector:s]) return ((BOOL (*)(id, SEL))objc_msgSend)(sh, s);
    return NO;
}

static BOOL SLAppRunning(void) { return NO; }   // 一律直接调起，重复调用无害

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
    SLState *st = [SLState load];
    if (!st.enabled) return;
    double now = [NSDate date].timeIntervalSince1970;

    if (st.phase == SLPhaseResetting) { if (!SLAppRunning()) { SLLog(@"relaunch(reset)"); SLOpenApp(); } return; }
    if (st.phase == SLPhaseNeedFill) { if (!SLAppRunning()) SLOpenApp(); notify_post(kSLFireName); return; }
    if (st.phase != SLPhaseArmed) return;

    BOOL due = (st.nextFire1 > 0 && now >= st.nextFire1) || (st.nextFire2 > 0 && now >= st.nextFire2);
    if (!due) return;

    BOOL locked = SLScreenLocked();
    BOOL late = (st.deadline > 0 && now >= st.deadline - 60);
    if (!locked && !late) { if ((int)now % 60 == 0) SLLog(@"due but unlocked, wait (dl=%.0f)", st.deadline - now); return; }
    SLLog(@"fire locked=%d late=%d dl_in=%.0f", locked, late, st.deadline - now);

    st.phase = SLPhaseResetting;
    st.attempt = 0;
    [st save];
    SLLog(@"fire");
    SLOpenApp();
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
    if (!isApp && !isSB) return;
    SLLog(@"init %@ v%@ ver-state=%@ phase=%d", bid, SL_VER,
          [[NSDictionary dictionaryWithContentsOfFile:SLStatePath()] objectForKey:@"ver"] ?: @"-", 0);

    if (isApp) g_fakeId = [SLDefaults() stringForKey:SL_DEVICE_KEY];

    Class ud = NSClassFromString(@"UIDevice");
    if (ud) MSHookMessageEx(ud, @selector(identifierForVendor), (IMP)SLHookIdfv, (IMP *)&g_origIdfv);
    MSHookFunction((void *)SecItemAdd, (void *)SLHookSecItemAdd, (void **)&g_origSecItemAdd);
    MSHookFunction((void *)SecItemCopyMatching, (void *)SLHookSecItemCopyMatching, (void **)&g_origSecItemCopyMatching);
    Class am = NSClassFromString(@"ASIdentifierManager");
    if (am) MSHookMessageEx(am, @selector(advertisingIdentifier), (IMP)SLHookAdid, (IMP *)&g_origAdid);

    if (isSB) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSTimer scheduledTimerWithTimeInterval:15 repeats:YES block:^(NSTimer *t) { SLTick(); }];
            SLTick();
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

    BOOL busy = (st.phase == SLPhaseNeedFill || st.phase == SLPhaseResetting);
    if (st.signerIdx < 0 && !busy) {
        [SLHttp calibrateSignerCompletion:^(NSInteger i) {
            SLState *s2 = [SLState load]; s2.signerIdx = (int)i; [s2 save];
            SLLog(@"signer=%ld", (long)i);
            SLOnLaunch();
        }];
    } else {
        SLOnLaunch();
    }
}
