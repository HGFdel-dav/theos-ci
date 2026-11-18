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

static void (*g_origViewDidAppear)(id, SEL, BOOL) = NULL;
static void SLHookViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (g_origViewDidAppear) g_origViewDidAppear(self, _cmd, animated);
    // 界面出现后立刻把窗口藏起来
    @try {
        id v = ((id (*)(id, SEL))objc_msgSend)(self, sel_registerName("view"));
        id w = v ? ((id (*)(id, SEL))objc_msgSend)(v, sel_registerName("window")) : nil;
        if (w) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(w, sel_registerName("setHidden:"), YES);
        }
    } @catch (NSException *e) {}
}



#pragma mark - 重置

static NSUserDefaults *SLDefaults(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:SL_PREF_SUITE];
    if (!d) d = [[NSUserDefaults alloc] initWithSuiteName:SL_APP_GROUP];
    if (!d) d = [NSUserDefaults standardUserDefaults];
    return d;
}

static void SLPerformReset(SLState *st) {
    NSUserDefaults *d = SLDefaults();
    if (!d) d = [NSUserDefaults standardUserDefaults];
    NSDictionary *snap = [d dictionaryRepresentation] ?: @{};
    st.snapPrefs = snap;
    st.snapToken = [SLHttp currentToken];
    st.phase = SLPhaseNeedFill;
    st.lastRun = [NSDate date].timeIntervalSince1970;
    [st save];

    // 先把偏好文件整份留底，失败能回滚
    NSString *appPl = SLAppPrefsPath();
    NSString *dir = SLStateDir();
    NSString *bak = [dir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"prefs-%.0f.plist", [NSDate date].timeIntervalSince1970]];
    if (appPl) {
        [[NSFileManager defaultManager] copyItemAtPath:appPl toPath:bak error:NULL];
        st.kcBackup = bak;   // 复用这个字段存偏好备份路径
        [st save];
    }
    SLLog(@"reset: prefs backup=%@", bak.lastPathComponent);

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
    if (st.kcBackup.length) [SLHttp restoreKeychain:st.kcBackup];
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

    st.signerIdx = 0;   // 使用固定签名，不需要校准
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


// App 是否在前台（避免在用户正看着时退出它）
static BOOL SLAppForeground(void) {
    Class app = NSClassFromString(@"UIApplication");
    if (!app) return NO;
    id a = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("sharedApplication"));
    if (!a) return NO;
    SEL s = sel_registerName("applicationState");
    if (![a respondsToSelector:s]) return NO;
    return ((NSInteger (*)(id, SEL))objc_msgSend)(a, s) == 0;  // 0 = active
}


// 让 App 立刻退回后台（用户几乎看不到）
static void SLGoBackground(void) {
    Class app = NSClassFromString(@"UIApplication");
    if (!app) return;
    id a = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("sharedApplication"));
    if (!a) return;
    SEL s = sel_registerName("suspend");
    if ([a respondsToSelector:s]) {
        ((void (*)(id, SEL))objc_msgSend)(a, s);
        SLLog(@"app suspended");
        return;
    }
    SEL s2 = sel_registerName("_suspend");
    if ([a respondsToSelector:s2]) {
        ((void (*)(id, SEL))objc_msgSend)(a, s2);
        SLLog(@"app _suspended");
    }
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

    if (isApp) g_fakeId = [SLDefaults() stringForKey:SL_DEVICE_KEY];

    Class ud = NSClassFromString(@"UIDevice");
    if (ud) MSHookMessageEx(ud, @selector(identifierForVendor), (IMP)SLHookIdfv, (IMP *)&g_origIdfv);
    MSHookFunction((void *)SecItemAdd, (void *)SLHookSecItemAdd, (void **)&g_origSecItemAdd);
    Class am = NSClassFromString(@"ASIdentifierManager");
    if (am) MSHookMessageEx(am, @selector(advertisingIdentifier), (IMP)SLHookAdid, (IMP *)&g_origAdid);

    if (isSB) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSTimer scheduledTimerWithTimeInterval:15 repeats:YES block:^(NSTimer *t) { SLTick(); }];
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
