#import "SLRenewFlow.h"
#import "SLRenewPaths.h"
#import "SLRenewState.h"
#import "SLHttp.h"
#import "SLDiag.h"
#import <objc/message.h>
#import <notify.h>
#import <UserNotifications/UserNotifications.h>

static NSString *const kFL = @"/var/mobile/Containers/Shared/AppGroup/FE3195E7-59B2-4284-BCCD-C16BE374F8BF/Library/Preferences/renew-flow.log";

static void FL(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%.0f %@\n", [NSDate date].timeIntervalSince1970, s];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kFL];
    if (!fh) [line writeToFile:kFL atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    else { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
}

static BOOL g_running = NO;
static id g_center = nil;

@implementation SLRenewFlow

+ (BOOL)isRunning { return g_running; }

#pragma mark - 通知

+ (void)notifyTitle:(NSString *)t body:(NSString *)b {
    Class unc = NSClassFromString(@"UNUserNotificationCenter");
    if (!unc) return;
    UNUserNotificationCenter *c = [UNUserNotificationCenter currentNotificationCenter];
    UNMutableNotificationContent *ct = [UNMutableNotificationContent new];
    ct.title = t; ct.body = b; ct.sound = [UNNotificationSound defaultSound];
    UNNotificationRequest *r = [UNNotificationRequest requestWithIdentifier:
        [NSString stringWithFormat:@"slf.%u", arc4random()] content:ct trigger:nil];
    [c addNotificationRequest:r withCompletionHandler:^(NSError *e) {
        FL(@"notify err=%@", e.localizedDescription ?: @"-");
    }];
}

#pragma mark - Crane 重置

+ (BOOL)craneWipe {
    Class mgr = NSClassFromString(@"CraneManager");
    if (!mgr) { FL(@"crane: no class"); return NO; }
    id inst = ((id (*)(id, SEL))objc_msgSend)(mgr, sel_registerName("sharedManager"));
    if (!inst) { FL(@"crane: no manager"); return NO; }
    SEL w = sel_registerName("wipeContainerWithIdentifier:forApplicationWithIdentifier:shouldRepopulate:");
    if (![inst respondsToSelector:w]) { FL(@"crane: no wipe sel"); return NO; }
    FL(@"crane: wipe start");
    ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(inst, w, @"DEFAULT", @"com.shanlian.pro", YES);
    FL(@"crane: wipe issued");
    return YES;
}

#pragma mark - 起 App

+ (void)launchApp {
    Class c = NSClassFromString(@"LSApplicationWorkspace");
    id ws = c ? ((id (*)(id, SEL))objc_msgSend)(c, sel_registerName("defaultWorkspace")) : nil;
    if (!ws) { FL(@"launch: no workspace"); return; }
    ((void (*)(id, SEL, id))objc_msgSend)(ws, sel_registerName("openApplicationWithBundleID:"), @"com.shanlian.pro");
    FL(@"launch: issued");
}

#pragma mark - 主流程

+ (void)startWithReason:(NSString *)reason {
    if (g_running) { FL(@"start ignored: already running"); return; }
    g_running = YES;
    FL(@"=== flow start: %@ ===", reason);

    // 1. 重置
    if (![self craneWipe]) { FL(@"abort: wipe failed"); g_running = NO; return; }

    // 2. 重置会把状态目录一起清掉，这里先重建状态：交给 App 里的流程继续
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SLState *st = [SLState load];
        st.enabled = YES;
        st.phase = SLPhaseNeedFill;     // App 起来后据此执行"等新号→填码→验证→通知"
        st.attempt = 0;
        st.lastError = @"";
        st.testSecs = 0;
        st.deadline = 0;
        [st save];
        FL(@"state written phase=NeedFill path=%@", SLStatePath());

        // 3. 起 App（会闪一下），剩下的在 App 里完成
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self launchApp]; });
    });
}

+ (void)waitNewAccount:(int)tries {
    if (tries > 40) {
        FL(@"abort: no new account in time"); g_running = NO;
        [self notifyTitle:@"闪连没续上" body:@"自动续期失败，需要你手动看一下"];
        return;
    }
    NSString *t = [SLHttp currentToken];
    if (t.length > 40) {
        FL(@"got token len=%lu try=%d", (unsigned long)t.length, tries);
        [self fillCode:t tries:0];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self waitNewAccount:tries + 1]; });
}

+ (void)fillCode:(NSString *)token tries:(int)tries {
    if (tries > 5) { FL(@"abort: fill failed"); g_running = NO; return; }
    [SLHttp send:@"POST" path:@"/app/customer/slfillInviteCodefe"
           body:@{@"inviteCode": @"88888888"}
     completion:^(NSInteger st, NSDictionary *resp, NSError *err) {
        long code = [resp[@"code"] integerValue];
        FL(@"fill try=%d http=%ld api=%ld msg=%@", tries, (long)st, code, resp[@"msg"] ?: @"-");
        if (code == 200) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self verify:0]; }); return; }
        // 已存在也当作成功，去验证日期
        if ([resp[@"msg"] rangeOfString:@"already exists"].location != NSNotFound ||
            [resp[@"msg"] rangeOfString:@"已存在"].location != NSNotFound) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self verify:0]; });
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self fillCode:token tries:tries + 1]; });
    }];
}

+ (void)verify:(int)tries {
    if (tries > 8) { FL(@"abort: verify timeout"); g_running = NO; return; }
    [SLHttp send:@"GET" path:@"/app/customer/slgetUserInfogo" body:nil
     completion:^(NSInteger st, NSDictionary *resp, NSError *err) {
        NSDictionary *d = resp[@"data"];
        NSString *dl = d[@"deadline"];
        BOOL expired = [d[@"expired"] boolValue];
        FL(@"verify try=%d user=%@ deadline=%@ expired=%d", tries, d[@"userName"] ?: @"-", dl ?: @"-", expired);
        if (dl.length && !expired) {
            g_running = NO;
            FL(@"=== flow done: user=%@ deadline=%@ (静默，不通知) ===", d[@"userName"] ?: @"-", dl);
            // 做完让 App 自己退回后台，不留界面
            notify_post("com.minis.shanlianrenew.done");
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self verify:tries + 1]; });
    }];
}

@end
