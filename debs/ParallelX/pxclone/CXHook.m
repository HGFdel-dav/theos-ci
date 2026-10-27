// CXHook.m
//
// CloneX 主注入层（仅 SpringBoard）。
//
// 两个职责：
//   A. 把 CloneX 配置同步进 PX 的菜单模型（CXMenuInjector），让菜单里
//      出现「应用 · 分身名」条目（应用图标 + 「分」角标）。
//   B. 截住这些条目的点击：先切 Crane 容器，再让 PX 用真实 bundleID
//      走它自己的开窗流程。全部走运行时签名核验，不符只记日志。
//
// 依据（alpha377 反汇编）：
//   -[PXSceneBridge performConfiguredAction:]  B24@0:8@16   （动作执行入口）
//   -[PXSceneBridge prepareWindowForBundleID:wasFullscreen:completion:]
//                                              v36@0:8@16B24@?28（开窗准备阶段）
//   +[PXPanelEntry applicationActivated:]      v24@0:8@16   （前台激活通知）
//   +[PXPanelEntry externalOpenApplication:]   v24@0:8@16   （PX 完整原生建窗入口）
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <notify.h>
#include <string.h>
#include <stdlib.h>
#import "CXCraneBridge.h"
#import "CXPrefs.h"
#import "CXLog.h"
#import "CXMenuInjector.h"
#import "CXPXRuntime.h"

typedef void (*CXHookFn)(Class, SEL, IMP, IMP *);

static void CXSyncIfNeeded(NSString *reason);
static CXHookFn CXMSHookMessageEx(void);
static void (*CXOrigSystemRequest)(id, SEL, id, id, id);
static void CXSystemRequestHook(id self, SEL _cmd, id service, id request, id completion);
static void CXInstallSystemRequestHook(void);

#pragma mark - 防重复处理

static NSMutableDictionary<NSString *, NSDate *> *CXRecentHandles(void) {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

static BOOL CXHandledRecently(NSString *key) {
    if (!key.length) return NO;
    @synchronized (CXRecentHandles()) {
        NSDate *date = CXRecentHandles()[key];
        if (!date) return NO;
        if (-[date timeIntervalSinceNow] > 1.5) {
            [CXRecentHandles() removeObjectForKey:key];
            return NO;
        }
        return YES;
    }
}

static void CXMarkHandled(NSString *key) {
    if (!key.length) return;
    @synchronized (CXRecentHandles()) {
        CXRecentHandles()[key] = NSDate.date;
    }
}

static BOOL CXInternalOpen = NO;

// 系统 request 已经在完整入口完成账号选择后，PX 的后续 externalOpen
// 只能透传，不能再弹一次晚期 chooser。按 bundle 保留一个短时标记，
// 因为后续 PX 回调接口只携带 bundleID，不再携带原始 request。
static NSMutableDictionary<NSString *, NSDate *> *CXRequestBypassBundles(void) {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

static void CXMarkRequestBypass(NSString *bundleID) {
    if (!bundleID.length) return;
    @synchronized (CXRequestBypassBundles()) {
        // 足够覆盖 PX externalOpen -> openApplication -> prepareWindow，
        // 但不能吞掉用户数秒后发起的下一笔独立支付请求。
        CXRequestBypassBundles()[bundleID] = [NSDate dateWithTimeIntervalSinceNow:8.0];
    }
}

static BOOL CXRequestBypassActive(NSString *bundleID) {
    if (!bundleID.length) return NO;
    @synchronized (CXRequestBypassBundles()) {
        NSDate *until = CXRequestBypassBundles()[bundleID];
        if (!until) return NO;
        if ([until timeIntervalSinceNow] <= 0) {
            [CXRequestBypassBundles() removeObjectForKey:bundleID];
            return NO;
        }
        return YES;
    }
}

static NSMutableSet *CXActiveRequestRoutes(void) {
    static NSMutableSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

static BOOL CXClaimRequestRoute(id request) {
    if (!request) return NO;
    @synchronized (CXActiveRequestRoutes()) {
        if ([CXActiveRequestRoutes() containsObject:request]) return NO;
        [CXActiveRequestRoutes() addObject:request];
        return YES;
    }
}

static void CXReleaseRequestRoute(id request) {
    if (!request) return;
    @synchronized (CXActiveRequestRoutes()) {
        [CXActiveRequestRoutes() removeObject:request];
    }
}

#pragma mark - 最近一次外部 URL（重载后补投，否则只落到主界面）

static NSURL *CXLastURL;
static NSTimeInterval CXLastURLAt;
static NSString *CXConsumedURLString;
static NSTimeInterval CXConsumedURLAt;
static NSTimeInterval CXLastSharedURLScanAt;
static NSMutableDictionary<NSString *, NSDictionary *> *CXRecentContainerSelections;

static NSMutableDictionary<NSString *, NSDictionary *> *CXRecentSelections(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ CXRecentContainerSelections = [NSMutableDictionary dictionary]; });
    return CXRecentContainerSelections;
}

static void CXRememberContainerSelection(NSString *bundleID, NSString *containerID) {
    if (!bundleID.length || !containerID.length) return;
    @synchronized (CXRecentSelections()) {
        CXRecentSelections()[bundleID] = @{ @"container": containerID, @"date": NSDate.date };
    }
}

static NSString *CXRecentContainerSelection(NSString *bundleID) {
    if (!bundleID.length) return nil;
    @synchronized (CXRecentSelections()) {
        NSDictionary *entry = CXRecentSelections()[bundleID];
        NSDate *date = entry[@"date"];
        if (![date isKindOfClass:NSDate.class] || -[date timeIntervalSinceNow] > 20.0) {
            [CXRecentSelections() removeObjectForKey:bundleID];
            return nil;
        }
        return [entry[@"container"] isKindOfClass:NSString.class] ? entry[@"container"] : nil;
    }
}

static void CXForgetRecentContainerSelection(NSString *bundleID) {
    if (!bundleID.length) return;
    @synchronized (CXRecentSelections()) { [CXRecentSelections() removeObjectForKey:bundleID]; }
}

static void CXMarkCurrentURLConsumed(void) {
    if (CXLastURLAt > CXConsumedURLAt) {
        CXConsumedURLAt = CXLastURLAt;
        CXConsumedURLString = [CXLastURL.absoluteString copy];
    }
    CXLastURL = nil;
    CXLastURLAt = 0;
}


// App 注入库只能写入各自沙盒的偏好域。SpringBoard 通过 RootHide 映射后的
// Data/Application 目录读取最新一份，不依赖不存在的 AppSupport/rocketbootstrap。
static void CXImportSharedAppURL(void) {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - CXLastSharedURLScanAt < 0.25) return;
    CXLastSharedURLScanAt = now;
    NSTimeInterval bestAt = MAX(CXLastURLAt, CXConsumedURLAt);
    NSString *bestURL = nil;
    NSString *bestBundle = nil;
    NSArray<NSString *> *allowed = @[@"com.chinaunicom.mobilebusiness", @"com.alipay.iphoneclient",
                                     @"com.tencent.mqq", @"com.tencent.xin"];
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL proxySel = NSSelectorFromString(@"applicationProxyForIdentifier:");
    SEL dataSel = NSSelectorFromString(@"dataContainerURL");
    for (NSString *bundleID in allowed) {
        if (!proxyClass || ![proxyClass respondsToSelector:proxySel]) continue;
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, proxySel, bundleID);
        if (!proxy || ![proxy respondsToSelector:dataSel]) continue;
        id dataURL = ((id (*)(id, SEL))objc_msgSend)(proxy, dataSel);
        NSString *container = [dataURL isKindOfClass:NSURL.class] ? [dataURL path] : nil;
        if (!container.length) continue;
        NSString *path = [container stringByAppendingPathComponent:@"Library/Preferences/com.niubiprass.clonex.plist"];
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:path];
        NSString *value = prefs[@"CXSharedURL"];
        NSNumber *atValue = prefs[@"CXSharedURLAt"];
        NSString *sourceBundle = prefs[@"CXSharedURLBundle"];
        NSTimeInterval at = [atValue respondsToSelector:@selector(doubleValue)] ? atValue.doubleValue : 0;
        if (![value isKindOfClass:NSString.class] || !value.length || at <= bestAt || now - at > 30.0) continue;
        if (CXConsumedURLString && [value isEqualToString:CXConsumedURLString] &&
            now - CXConsumedURLAt < 30.0) continue;
        NSURL *url = [NSURL URLWithString:value];
        if (!url) continue;
        bestAt = at;
        bestURL = value;
        bestBundle = [sourceBundle isKindOfClass:NSString.class] ? sourceBundle : bundleID;
    }
    if (!bestURL) return;
    CXLastURL = [NSURL URLWithString:bestURL];
    CXLastURLAt = bestAt;
    CFStringRef domain = CFSTR("com.niubiprass.clonex");
    CFPreferencesSetAppValue(CFSTR("CXSharedURL"), (__bridge CFStringRef)bestURL, domain);
    CFPreferencesSetAppValue(CFSTR("CXSharedURLAt"), (__bridge CFPropertyListRef)@(bestAt), domain);
    CFPreferencesAppSynchronize(domain);
    CXLog(@"[url] imported app plist bundle=%@ scheme=%@ host=%@", bestBundle,
          CXLastURL.scheme ?: @"", CXLastURL.host ?: @"");
}

static BOOL CXFreshURL(NSURL **out) {
    CXImportSharedAppURL();
    if (CXLastURL && [NSDate date].timeIntervalSince1970 - CXLastURLAt <= 30.0) {
        if (out) *out = CXLastURL;
        return YES;
    }
    // 其他进程（发起方应用）抓到的链接放这里，供 SpringBoard 读取。
    NSString *str = [CXPrefs.shared objectForKey:@"CXSharedURL"];
    if (![str isKindOfClass:NSString.class] || !str.length) return NO;
    double at = [CXPrefs.shared objectForKey:@"CXSharedURLAt"] ?
                [[CXPrefs.shared objectForKey:@"CXSharedURLAt"] doubleValue] : 0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - at > 30.0 || at <= CXConsumedURLAt) return NO;
    if (CXConsumedURLString && [str isEqualToString:CXConsumedURLString] &&
        now - CXConsumedURLAt < 30.0) return NO;
    NSURL *url = [NSURL URLWithString:str];
    if (!url) return NO;
    CXLastURL = url;
    CXLastURLAt = at;
    if (out) *out = url;
    return YES;
}

// 应用是否已在运行（有场景）。运行中才需要重载，未运行直接切配置即可保住 URL。
static BOOL CXAppRunning(NSString *bundle) {
    Class cls = NSClassFromString(@"PXSceneBridge");
    SEL shared = NSSelectorFromString(@"sharedBridge");
    if (!cls || ![cls respondsToSelector:shared]) return NO;
    id bridge = ((id (*)(id, SEL))objc_msgSend)(cls, shared);
    SEL sel = NSSelectorFromString(@"hasSceneForApplication:");
    if (!bridge || ![bridge respondsToSelector:sel]) return NO;
    NSMethodSignature *sig = [bridge methodSignatureForSelector:sel];
    if (!sig || sig.numberOfArguments != 3 || sig.methodReturnType[0] != 'B') return NO;
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(bridge, sel, bundle) != 0;
}

// Crane reload 完成只代表“配置已写入并发出 reload”。切换账号时只等旧
// scene 退出，然后立即让 PX 创建目标 scene；新 scene 不会在 PX 开窗前自行出现。
static void CXWaitForApplicationReady(NSString *bundleID, BOOL expectRestart,
                                      BOOL wasRunning, NSInteger phase,
                                      NSInteger tries, void (^completion)(void)) {
    if (!completion) return;
    BOOL running = CXAppRunning(bundleID);
    if (!expectRestart) {
        if (running || tries >= 16) {
            if (!running) CXLog(@"[ready] %@ 未观察到 scene，超时继续", bundleID);
            else CXLog(@"[ready] %@ scene ready", bundleID);
            completion();
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            CXWaitForApplicationReady(bundleID, expectRestart, wasRunning, phase,
                                      tries + 1, completion);
        });
        return;
    }

    if (phase == 0) { // wait only for the old scene to disappear
        // Reloading the app does not create the replacement scene by itself;
        // PX creates it when externalOpenApplication: is called. Waiting for
        // a new scene here therefore deadlocks the first open for six seconds.
        if (!running || tries >= 12) {
            if (running) CXLog(@"[ready] %@ old scene still present, open now", bundleID);
            else CXLog(@"[ready] %@ old scene gone, open now", bundleID);
            completion();
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            CXWaitForApplicationReady(bundleID, YES, wasRunning, 0,
                                      tries + 1, completion);
        });
        return;
    }
}

static void (*CXOrigOpenURL)(id, SEL, id, id, id);
static BOOL (*CXOrigOpenURLLegacy)(id, SEL, id);
static void CXCaptureExternalURL(id url) {
    if (CXInternalOpen || ![url isKindOfClass:NSURL.class]) return;
    CXLastURL = [url copy];
    CXLastURLAt = [NSDate date].timeIntervalSince1970;
    [CXPrefs.shared setObject:((NSURL *)url).absoluteString forKey:@"CXSharedURL"];
    [CXPrefs.shared setObject:@([[NSDate date] timeIntervalSince1970]) forKey:@"CXSharedURLAt"];
    CXLog(@"[url] captured scheme=%@ host=%@", CXLastURL.scheme ?: @"", CXLastURL.host ?: @"");
}
static void (*CXOrigWorkspaceOpen)(id, SEL, id, id);
static void (*CXOrigWorkspaceSensitive)(id, SEL, id, id);
static void CXWorkspaceOpenHook(id self, SEL _cmd, id url, id options) {
    CXCaptureExternalURL(url);
    if (CXOrigWorkspaceOpen) CXOrigWorkspaceOpen(self, _cmd, url, options);
}
static void CXWorkspaceSensitiveHook(id self, SEL _cmd, id url, id options) {
    CXCaptureExternalURL(url);
    if (CXOrigWorkspaceSensitive) CXOrigWorkspaceSensitive(self, _cmd, url, options);
}
static BOOL CXOpenURLLegacyHook(id self, SEL _cmd, id url) {
    CXCaptureExternalURL(url);
    return CXOrigOpenURLLegacy ? CXOrigOpenURLLegacy(self, _cmd, url) : NO;
}
static void CXOpenURLHook(id self, SEL _cmd, id url, id options, id completion) {
    CXCaptureExternalURL(url);
    if (CXOrigOpenURL) CXOrigOpenURL(self, _cmd, url, options, completion);
}

static void (*CXOrigSceneOpen)(id, SEL, id, id);
static void CXSceneOpenHook(id self, SEL _cmd, id scene, id contexts) {
    for (id ctx in contexts) {
        id url = nil;
        @try { url = [ctx valueForKey:@"URL"]; } @catch (__unused NSException *e) {}
        CXCaptureExternalURL(url);
    }
    if (CXOrigSceneOpen) CXOrigSceneOpen(self, _cmd, scene, contexts);
}

static void (*CXOrigAppOpenURL)(id, SEL, id, id, id);
static void CXAppOpenURLHook(id self, SEL _cmd, id app, id url, id options) {
    CXCaptureExternalURL(url);
    if (CXOrigAppOpenURL) CXOrigAppOpenURL(self, _cmd, app, url, options);
}

// FrontBoard 直接把 URL 塞进场景上下文，前面几种都收不到；从上下文对象初始化处抓。
static id (*CXOrigOpenURLContextInit)(id, SEL, id, id);
static id CXOpenURLContextInit(id self, SEL _cmd, id url, id options) {
    CXCaptureExternalURL(url);
    return CXOrigOpenURLContextInit ? CXOrigOpenURLContextInit(self, _cmd, url, options) : self;
}

static void CXInstallURLContextHook(void) {
    Class cls = NSClassFromString(@"UIOpenURLContext");
    if (!cls) { CXLog(@"[url] UIOpenURLContext 不存在"); return; }
    SEL sel = NSSelectorFromString(@"initWithURL:options:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { CXLog(@"[url] initWithURL:options: 不存在"); return; }
    CXOrigOpenURLContextInit = (id (*)(id, SEL, id, id))method_getImplementation(m);
    method_setImplementation(m, (IMP)CXOpenURLContextInit);
    CXLog(@"[url] UIOpenURLContext hook ok");
}

// SpringBoard 内部一定有人接收场景 URL 上下文；运行期扫描这些选择器并挂钩，无需注入应用。
static void (*CXOrigSetURLContexts)(id, SEL, id);
static void (*CXOrigSetLaunchURL)(id, SEL, id);
static void CXSetURLContextsHook(id self, SEL _cmd, id contexts) {
    @try {
        if ([contexts isKindOfClass:NSArray.class] || [contexts isKindOfClass:NSSet.class]) {
            for (id ctx in contexts) {
                id url = nil;
                @try { url = [ctx valueForKey:@"URL"]; } @catch (__unused NSException *e) {}
                CXCaptureExternalURL(url ?: ctx);
            }
        } else {
            CXCaptureExternalURL(contexts);
        }
    } @catch (__unused NSException *e) {}
    if (CXOrigSetURLContexts) CXOrigSetURLContexts(self, _cmd, contexts);
}

static void CXSetLaunchURLHook(id self, SEL _cmd, id url) {
    CXCaptureExternalURL(url);
    if (CXOrigSetLaunchURL) CXOrigSetLaunchURL(self, _cmd, url);
}

static void CXInstallURLContextScan(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    const char *names[] = {"setURLContexts:", "_setURLContexts:", "setLaunchURL:", "_setLaunchURL:"};
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return;
    objc_getClassList(classes, count);
    int n = 0;
    for (int i = 0; i < count; i++) {
        Class c = classes[i];
        const char *cname = class_getName(c);
        if (!cname || !(strncmp(cname, "SB", 2) == 0 || strncmp(cname, "FB", 2) == 0 ||
                        strncmp(cname, "_UI", 3) == 0 || strstr(cname, "Scene"))) continue;
        for (size_t k = 0; k < sizeof(names)/sizeof(names[0]); k++) {
            SEL sel = NSSelectorFromString([NSString stringWithUTF8String:names[k]]);
            Method m = class_getInstanceMethod(c, sel);
            if (!m) continue;
            const char *t = method_getTypeEncoding(m);
            if (!t || t[0] != 'v' || strchr(t, '@') == NULL) continue;
            BOOL isLaunch = strstr(names[k], "LaunchURL") != NULL;
            if (isLaunch) {
                if (CXOrigSetLaunchURL) continue;
                CXOrigSetLaunchURL = (void (*)(id, SEL, id))method_getImplementation(m);
                method_setImplementation(m, (IMP)CXSetLaunchURLHook);
            } else {
                if (CXOrigSetURLContexts) continue;
                CXOrigSetURLContexts = (void (*)(id, SEL, id))method_getImplementation(m);
                method_setImplementation(m, (IMP)CXSetURLContextsHook);
            }
            CXLog(@"[url] context hook %s %s", cname, names[k]);
            n++;
        }
    }
    free(classes);
    CXLog(@"[url] context hooks=%d", n);
}

static void CXInstallSceneURLHooks(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    SEL sceneSel = NSSelectorFromString(@"scene:openURLContexts:");
    SEL appSel = NSSelectorFromString(@"application:openURL:options:");
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return;
    objc_getClassList(classes, count);
    int n = 0;
    for (int i = 0; i < count; i++) {
        Class c = classes[i];
        Method m = class_getInstanceMethod(c, sceneSel);
        if (m) {
            CXOrigSceneOpen = (void (*)(id, SEL, id, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)CXSceneOpenHook);
            n++;
            CXLog(@"[url] scene hook %s", class_getName(c));
        }
        Method a = class_getInstanceMethod(c, appSel);
        if (a) {
            CXOrigAppOpenURL = (void (*)(id, SEL, id, id, id))method_getImplementation(a);
            method_setImplementation(a, (IMP)CXAppOpenURLHook);
            n++;
            CXLog(@"[url] appdelegate hook %s", class_getName(c));
        }
    }
    free(classes);
    CXLog(@"[url] scene hooks=%d", n);
}

static void CXInstallSystemRequestHook(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class cls = NSClassFromString(@"SBMainWorkspace");
    SEL sel = NSSelectorFromString(@"systemService:handleOpenApplicationRequest:withCompletion:");
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        CXLog(@"[route] SBMainWorkspace request selector 不存在");
        return;
    }
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    BOOL valid = sig && sig.numberOfArguments == 5 &&
                 strcmp(sig.methodReturnType, @encode(void)) == 0 &&
                 [sig getArgumentTypeAtIndex:2][0] == '@' &&
                 [sig getArgumentTypeAtIndex:3][0] == '@' &&
                 [sig getArgumentTypeAtIndex:4][0] == '@';
    if (!valid) {
        CXLog(@"[route] request selector 签名不符: %@", sig);
        return;
    }
    CXHookFn hook = CXMSHookMessageEx();
    if (!hook) return;
    hook(cls, sel, (IMP)CXSystemRequestHook, (IMP *)&CXOrigSystemRequest);
    installed = CXOrigSystemRequest != NULL;
    CXLog(@"[route] system request installed=%d", installed);
}

static void CXInstallURLHook(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class cls = UIApplication.class;
    SEL sel = NSSelectorFromString(@"openURL:options:completionHandler:");
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (!sig || sig.numberOfArguments != 5 || [sig getArgumentTypeAtIndex:2][0] != '@') return;
    CXHookFn hook = CXMSHookMessageEx();
    if (!hook) return;
    hook(cls, sel, (IMP)CXOpenURLHook, (IMP *)&CXOrigOpenURL);
    installed = CXOrigOpenURL != NULL;
    SEL legacySel = NSSelectorFromString(@"openURL:");
    Method legacyMethod = class_getInstanceMethod(cls, legacySel);
    if (legacyMethod) {
        NSMethodSignature *legacySig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(legacyMethod)];
        if (legacySig && legacySig.numberOfArguments == 3 && [legacySig getArgumentTypeAtIndex:2][0] == '@') {
            hook(cls, legacySel, (IMP)CXOpenURLLegacyHook, (IMP *)&CXOrigOpenURLLegacy);
        }
    }
    CXLog(@"[hook] openURL installed=%d legacy=%d", installed, CXOrigOpenURLLegacy != NULL);
    CXInstallURLContextScan();
    CXInstallSceneURLHooks();
    CXInstallURLContextHook();

    // 支付、第三方跳转常常走 LSApplicationWorkspace，不走 UIApplication
    Class workspace = NSClassFromString(@"LSApplicationWorkspace");
    if (!workspace) { CXLog(@"[hook] 无 LSApplicationWorkspace"); return; }
    struct { const char *sel; IMP imp; IMP *orig; } whooks[] = {
        {"openURL:withOptions:", (IMP)CXWorkspaceOpenHook, (IMP *)&CXOrigWorkspaceOpen},
        {"openSensitiveURL:withOptions:", (IMP)CXWorkspaceSensitiveHook, (IMP *)&CXOrigWorkspaceSensitive},
    };
    for (size_t i = 0; i < sizeof(whooks)/sizeof(whooks[0]); i++) {
        SEL s = NSSelectorFromString([NSString stringWithUTF8String:whooks[i].sel]);
        Method m = class_getInstanceMethod(workspace, s);
        if (!m) { CXLog(@"[hook] %s 不存在", whooks[i].sel); continue; }
        NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)];
        if (!sig || sig.numberOfArguments != 4 || [sig getArgumentTypeAtIndex:2][0] != '@') {
            CXLog(@"[hook] %s 签名不符", whooks[i].sel); continue;
        }
        hook(workspace, s, whooks[i].imp, whooks[i].orig);
    }
}

#pragma mark - 打开分屏窗口（真实 bundle）

static BOOL CXShowingChooser = NO;
static __strong UIWindow *CXChooserWindow;
static __weak UIWindow *CXChooserPreviousKeyWindow;
static void CXCloseChooser(void);

static BOOL CXChooserHostWindow(UIWindow *window) {
    if (!window || window.hidden || !window.userInteractionEnabled || !window.rootViewController) return NO;
    if (!window.windowScene) return NO;
    NSString *name = NSStringFromClass(window.class);
    // These overlay windows are drawn above SpringBoard but are not reliable
    // presenters for interactive controls (the payment chooser used one).
    for (NSString *token in @[@"PX", @"Panel", @"Overlay", @"Handle", @"Pill", @"CXArc", @"Debug"]) {
        if ([name containsString:token]) return NO;
    }
    return YES;
}

static UIViewController *CXTopViewController(void) {
    UIViewController *vc = nil;
    for (UIWindow *window in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        if (!CXChooserHostWindow(window)) continue;
        vc = window.rootViewController; break;
    }
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void CXOpenInSplitImpl(NSString *bundleID);

// 菜单已指定账号，或 URL 已选择账号：内部开窗不再次弹选择。
static void CXReplayURL(NSURL *url) {
    if (!url) return;
    BOOL wasInternal = CXInternalOpen;
    CXInternalOpen = YES;
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL ok) {
        CXLog(@"[url] replay %@ ok=%d", url.scheme ?: @"", ok);
    }];
    CXInternalOpen = wasInternal;
}
static void CXOpenInSplit(NSString *bundleID) {
    BOOL wasInternal = CXInternalOpen;
    CXInternalOpen = YES;
    @try { CXOpenInSplitImpl(bundleID); }
    @finally { CXInternalOpen = wasInternal; }
}

// 外部 URL 且应用有多容器：带图标的容器选择（参照 ScreenCore 的深色选择条）
@interface CXChooserController : UIViewController
@property (nonatomic, copy) NSArray<NSDictionary *> *containers;
@property (nonatomic, copy) NSString *appName;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) void (^pick)(NSString *containerID);
@property (nonatomic, copy) void (^cancel)(void);
@property (nonatomic, assign) BOOL finishing;
@end

@implementation CXChooserController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    UIView *sheet = [[UIView alloc] init];
    sheet.backgroundColor = [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:1];
    sheet.layer.cornerRadius = 26;
    sheet.layer.cornerCurve = kCACornerCurveContinuous;
    sheet.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:sheet];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"选择打开应用";
    title.font = [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold];
    title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter;

    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.spacing = 8;
    UIImage *icon = nil;
    @try {
        SEL iconSel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
        if ([UIImage respondsToSelector:iconSel])
            icon = ((id (*)(id, SEL, id, long, double))objc_msgSend)(UIImage.class, iconSel,
                self.bundleID, 0, (double)UIScreen.mainScreen.scale);
    } @catch (NSException *e) {
        CXLog(@"[url] icon API 异常: %@", e.reason ?: @"unknown");
    }
    // 没有图标时用占位（空图片，不崩溃）
    if (!icon) icon = [[UIImage alloc] init];
    for (NSDictionary *entry in self.containers) {
        NSString *cid = entry[@"containerID"];
        BOOL isDefault = [entry[@"isDefault"] boolValue];
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.tag = [self.containers indexOfObject:entry];
        UIImageView *iv = [[UIImageView alloc] initWithImage:icon];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.layer.cornerRadius = 14;
        iv.clipsToBounds = YES;
        iv.userInteractionEnabled = NO;
        UILabel *name = [[UILabel alloc] init];
        name.text = isDefault ? self.appName : (entry[@"name"] ?: cid);
        name.font = [UIFont systemFontOfSize:13];
        name.textColor = UIColor.whiteColor;
        name.textAlignment = NSTextAlignmentCenter;
        name.userInteractionEnabled = NO;
        if (!isDefault) {
            UIView *dot = [[UIView alloc] init];
            dot.backgroundColor = [UIColor systemOrangeColor];
            dot.layer.cornerRadius = 4;
            dot.translatesAutoresizingMaskIntoConstraints = NO;
            [button addSubview:dot];
            [NSLayoutConstraint activateConstraints:@[
                [dot.widthAnchor constraintEqualToConstant:8],
                [dot.heightAnchor constraintEqualToConstant:8]]];
        }
        UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:@[iv, name]];
        col.axis = UILayoutConstraintAxisVertical; col.alignment = UIStackViewAlignmentCenter; col.spacing = 6;
        col.userInteractionEnabled = NO; col.translatesAutoresizingMaskIntoConstraints = NO;
        [button addSubview:col];
        if (!isDefault) {
            UIView *dot = button.subviews.firstObject;
            [NSLayoutConstraint activateConstraints:@[
                [dot.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:-8],
                [dot.centerYAnchor constraintEqualToAnchor:button.centerYAnchor]]];
        }
        [NSLayoutConstraint activateConstraints:@[
            [iv.widthAnchor constraintEqualToConstant:56], [iv.heightAnchor constraintEqualToConstant:56],
            [col.centerXAnchor constraintEqualToAnchor:button.centerXAnchor],
            [col.topAnchor constraintEqualToAnchor:button.topAnchor constant:4]]];
        [button addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
        [row addArrangedSubview:button];
    }
    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancel setTitle:@"取消跳转" forState:UIControlStateNormal];
    [cancel setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    cancel.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1];
    cancel.layer.cornerRadius = 14;
    [cancel addTarget:self action:@selector(cancelled) forControlEvents:UIControlEventTouchUpInside];

    for (UIView *v in @[title, row, cancel]) { v.translatesAutoresizingMaskIntoConstraints = NO; [sheet addSubview:v]; }
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [sheet.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:10],
        [sheet.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-10],
        [sheet.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-6],
        [title.topAnchor constraintEqualToAnchor:sheet.topAnchor constant:18],
        [title.leadingAnchor constraintEqualToAnchor:sheet.leadingAnchor constant:16],
        [title.trailingAnchor constraintEqualToAnchor:sheet.trailingAnchor constant:-16],
        [row.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:16],
        [row.leadingAnchor constraintEqualToAnchor:sheet.leadingAnchor constant:14],
        [row.trailingAnchor constraintEqualToAnchor:sheet.trailingAnchor constant:-14],
        [row.heightAnchor constraintEqualToConstant:84],
        [cancel.topAnchor constraintEqualToAnchor:row.bottomAnchor constant:16],
        [cancel.leadingAnchor constraintEqualToAnchor:sheet.leadingAnchor constant:14],
        [cancel.trailingAnchor constraintEqualToAnchor:sheet.trailingAnchor constant:-14],
        [cancel.heightAnchor constraintEqualToConstant:50],
        [cancel.bottomAnchor constraintEqualToAnchor:sheet.bottomAnchor constant:-14]]];
}

- (void)tapped:(UIButton *)sender {
    if (self.finishing || sender.tag < 0 || sender.tag >= (NSInteger)self.containers.count) return;
    self.finishing = YES;
    NSDictionary *entry = self.containers[sender.tag];
    NSString *containerID = entry[@"containerID"];
    CXLog(@"[url] chooser tapped index=%ld container=%@", (long)sender.tag, containerID ?: @"?");
    CXCloseChooser();
    if (self.pick) self.pick(containerID);
}
- (void)cancelled {
    if (self.finishing) return;
    self.finishing = YES;
    CXCloseChooser();
    if (self.cancel) self.cancel();
}
@end

static void CXCloseChooser(void) {
    UIWindow *window = CXChooserWindow;
    CXChooserWindow = nil;
    CXShowingChooser = NO;
    if (window) {
        window.hidden = YES;
        window.rootViewController = nil;
    }
    UIWindow *previous = CXChooserPreviousKeyWindow;
    CXChooserPreviousKeyWindow = nil;
    if (previous && !previous.hidden) [previous makeKeyWindow];
}

static BOOL CXPresentChooserInOwnWindow(CXChooserController *chooser, UIWindow *hostWindow) {
    UIWindowScene *scene = hostWindow.windowScene;
    if (!scene || !chooser) return NO;
    CXChooserPreviousKeyWindow = UIApplication.sharedApplication.keyWindow ?: hostWindow;
    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.frame = scene.coordinateSpace.bounds;
    window.windowLevel = UIWindowLevelAlert + 1;
    window.backgroundColor = UIColor.clearColor;
    window.userInteractionEnabled = YES;
    window.rootViewController = chooser;
    CXChooserWindow = window;
    [window makeKeyAndVisible];
    CXLog(@"[url] chooser own-window shown scene=%@ level=%.0f interactive=%d",
          scene.session.persistentIdentifier ?: @"?", window.windowLevel, window.userInteractionEnabled);
    return YES;
}

#pragma mark - 系统打开请求 continuation

static id CXRequestObjectValue(id object, NSString *key) {
    if (!object || !key.length) return nil;
    if ([object isKindOfClass:NSDictionary.class]) return ((NSDictionary *)object)[key];
    SEL sel = NSSelectorFromString(key);
    if (![object respondsToSelector:sel]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, sel);
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static NSDictionary *CXRequestDictionary(id object) {
    if ([object isKindOfClass:NSDictionary.class]) return object;
    id dictionary = CXRequestObjectValue(object, @"dictionary");
    return [dictionary isKindOfClass:NSDictionary.class] ? dictionary : nil;
}

static NSString *CXBundleIdentifierFromRequestValue(id value, NSUInteger depth) {
    if (!value || value == NSNull.null || depth > 4) return nil;
    if ([value isKindOfClass:NSString.class])
        return [value length] ? value : nil;

    NSArray<NSString *> *directKeys = @[
        @"targetBundleIdentifier", @"applicationBundleIdentifier",
        @"applicationIdentifier", @"bundleIdentifier"
    ];
    for (NSString *key in directKeys) {
        id candidate = CXRequestObjectValue(value, key);
        if ([candidate isKindOfClass:NSString.class] && [candidate length]) return candidate;
    }

    // iOS 15 的 FBS request 有的把标识藏在 targetApplication/target；
    // ParallelX alpha377 原生解析器也枚举了这两个字段。
    for (NSString *key in @[@"targetApplication", @"target", @"application"]) {
        NSString *candidate = CXBundleIdentifierFromRequestValue(CXRequestObjectValue(value, key), depth + 1);
        if (candidate.length) return candidate;
    }
    NSDictionary *dictionary = CXRequestDictionary(value);
    if (dictionary && dictionary != value) {
        NSString *candidate = CXBundleIdentifierFromRequestValue(dictionary, depth + 1);
        if (candidate.length) return candidate;
    }
    return nil;
}

static NSString *CXRequestTargetBundle(id request) {
    NSString *bundleID = CXBundleIdentifierFromRequestValue(request, 0);
    if (bundleID.length) return bundleID;
    return CXBundleIdentifierFromRequestValue(CXRequestObjectValue(request, @"options"), 0);
}

static BOOL CXPayloadContainsURL(id value, NSUInteger depth) {
    if (!value || value == NSNull.null || depth > 5) return NO;
    if ([value isKindOfClass:NSURL.class]) return YES;

    NSString *className = NSStringFromClass([value class]);
    if ([className containsString:@"AppLink"] ||
        [className containsString:@"OpenApplicationPayloadURL"] ||
        [className containsString:@"OpenApplicationPayloadOpenURL"]) return YES;

    if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = value;
        id openURL = dictionary[@"__PayloadOpenURL"];
        if ([openURL respondsToSelector:@selector(boolValue)] && [openURL boolValue]) return YES;
        for (id rawKey in dictionary) {
            NSString *key = [rawKey isKindOfClass:NSString.class] ? rawKey : @"";
            NSString *lower = key.lowercaseString;
            id child = dictionary[rawKey];
            BOOL relevant = [lower containsString:@"url"] || [lower containsString:@"link"] ||
                            [lower containsString:@"payload"] || [lower containsString:@"options"];
            if (!relevant) continue;
            if ([child isKindOfClass:NSString.class]) {
                NSURL *url = [NSURL URLWithString:child];
                if (url.scheme.length) return YES;
            }
            if (CXPayloadContainsURL(child, depth + 1)) return YES;
        }
        return NO;
    }
    if ([value isKindOfClass:NSArray.class] || [value isKindOfClass:NSSet.class]) {
        for (id child in value)
            if (CXPayloadContainsURL(child, depth + 1)) return YES;
        return NO;
    }

    NSDictionary *dictionary = CXRequestDictionary(value);
    if (dictionary && dictionary != value && CXPayloadContainsURL(dictionary, depth + 1)) return YES;
    for (NSString *key in @[@"URL", @"url", @"payloadURL", @"appLink", @"targetURL"]) {
        id child = CXRequestObjectValue(value, key);
        if (child && CXPayloadContainsURL(child, depth + 1)) return YES;
    }
    return NO;
}

static BOOL CXRequestHasURLPayload(id request) {
    id optionsObject = CXRequestObjectValue(request, @"options");
    if (CXPayloadContainsURL(optionsObject, 0)) return YES;
    // 少数调用把 payload 直接挂在 request，而不是 options。
    return CXPayloadContainsURL(CXRequestObjectValue(request, @"payload"), 0) ||
           CXPayloadContainsURL(CXRequestObjectValue(request, @"URL"), 0);
}

static void CXPresentSystemRequestChooser(NSString *bundleID,
                                           NSArray<NSDictionary *> *containers,
                                           void (^pick)(NSString *containerID),
                                           void (^cancel)(void)) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            CXPresentSystemRequestChooser(bundleID, containers, pick, cancel);
        });
        return;
    }
    if (CXShowingChooser) {
        if (cancel) cancel();
        return;
    }
    UIViewController *host = CXTopViewController();
    if (!host || (!host.viewIfLoaded.window && !host.view.window)) {
        if (cancel) cancel();
        return;
    }

    NSString *appName = bundleID;
    Class proxyCls = NSClassFromString(@"LSApplicationProxy");
    if (proxyCls) {
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyCls,
            NSSelectorFromString(@"applicationProxyForIdentifier:"), bundleID);
        id name = proxy ? CXRequestObjectValue(proxy, @"localizedName") : nil;
        if ([name isKindOfClass:NSString.class] && [name length]) appName = name;
    }

    CXShowingChooser = YES;
    CXChooserController *chooser = [[CXChooserController alloc] init];
    chooser.containers = containers;
    chooser.appName = appName;
    chooser.bundleID = bundleID;
    chooser.modalPresentationStyle = UIModalPresentationOverFullScreen;
    chooser.cancel = ^{
        CXShowingChooser = NO;
        if (cancel) cancel();
    };
    chooser.pick = ^(NSString *containerID) {
        CXShowingChooser = NO;
        if (pick) pick(containerID);
    };
    @try {
        UIWindow *hostWindow = host.viewIfLoaded.window ?: host.view.window;
        if (!CXPresentChooserInOwnWindow(chooser, hostWindow)) {
            CXShowingChooser = NO;
            CXLog(@"[route] chooser own-window unavailable");
            if (cancel) cancel();
        }
    } @catch (NSException *e) {
        CXCloseChooser();
        CXLog(@"[route] present chooser 异常: %@", e.reason ?: @"unknown");
        if (cancel) cancel();
    }
}

static void CXForwardSystemRequest(id self, SEL _cmd, id service, id request, id completion) {
    CXReleaseRequestRoute(request);
    if (CXOrigSystemRequest) CXOrigSystemRequest(self, _cmd, service, request, completion);
}

static void CXSystemRequestHook(id self, SEL _cmd, id service, id request, id completion) {
    if (!CXOrigSystemRequest) return;
    NSString *bundleID = CXRequestTargetBundle(request);
    BOOL hasPayload = CXRequestHasURLPayload(request);
    NSArray<NSDictionary *> *containers = bundleID.length ? [CXCraneBridge containersForBundleID:bundleID] : @[];
    if (bundleID.length || hasPayload) {
        CXLog(@"[route] request class=%@ target=%@ payload=%d containers=%lu main=%d",
              NSStringFromClass([request class]), bundleID ?: @"?", hasPayload,
              (unsigned long)containers.count, [NSThread isMainThread]);
    }
    if (CXInternalOpen || CXShowingChooser || !bundleID.length ||
        !hasPayload || containers.count < 2) {
        CXOrigSystemRequest(self, _cmd, service, request, completion);
        return;
    }
    // PX 的该系统服务入口在 SpringBoard 主队列处理；若系统版本改变了
    // 调用队列，保持原调用不搬线程，避免 completion 超时。
    if (![NSThread isMainThread]) {
        CXLog(@"[route] %@ request 非主队列，透传", bundleID);
        CXOrigSystemRequest(self, _cmd, service, request, completion);
        return;
    }
    if (!CXClaimRequestRoute(request)) {
        CXOrigSystemRequest(self, _cmd, service, request, completion);
        return;
    }

    NSObject *gate = [NSObject new];
    __block BOOL forwarded = NO;
    void (^forward)(void) = ^{
        @synchronized (gate) {
            if (forwarded) return;
            forwarded = YES;
        }
        // 把同一个 request + completion 原样续传给 PX；禁止降级成仅 bundleID 开窗。
        CXMarkRequestBypass(bundleID);
        CXLog(@"[route] %@ forward original request", bundleID);
        CXForwardSystemRequest(self, _cmd, service, request, completion);
    };

    void (^present)(void) = ^{
        CXPresentSystemRequestChooser(bundleID, containers, ^(NSString *containerID) {
            NSString *active = [CXCraneBridge activeContainerForBundleID:bundleID] ?: @"DEFAULT";
            BOOL same = [active isEqualToString:containerID];
            BOOL running = CXAppRunning(bundleID);
            CXRememberContainerSelection(bundleID, containerID);
            CXLog(@"[route] %@ selected=%@ same=%d running=%d", bundleID, containerID, same, running);
            [CXCraneBridge switchBundleID:bundleID toContainer:containerID reload:!same completion:^(BOOL ok) {
                if (!ok) {
                    CXLog(@"[route] %@ switch failed, forward unchanged", bundleID);
                    forward();
                    return;
                }
                // reload completion 只表示已发出重载。必须先等旧 scene 消失，
                // 再续传完整支付 request，避免它落入即将退出的旧账号进程。
                CXWaitForApplicationReady(bundleID, !same, running, 0, 0, forward);
            }];
        }, ^{
            CXLog(@"[route] %@ cancelled, forward unchanged", bundleID);
            forward();
        });
    };

    present();
}

// 主队列定时任务持有每次重试参数，不使用自引用 block。
static void CXPollReloadedURL(NSString *bundleID, NSURL *incoming, BOOL wasInternal, NSInteger tries) {
    if (tries >= 15) { CXInternalOpen = wasInternal; return; }
    if (CXAppRunning(bundleID)) {
        if (incoming) CXReplayURL(incoming);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            CXInternalOpen = wasInternal;
        });
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        CXPollReloadedURL(bundleID, incoming, wasInternal, tries + 1);
    });
}

// 付款 URL 有时在来源 App 写入沙盒后才到达 SpringBoard；如果用户刚刚
// 选过账号，就把迟到的 URL 投进已打开的目标分屏，不再重新弹选择。
static BOOL CXRouteRecentSelectedURL(NSString *bundleID, NSURL *incoming) {
    if (!bundleID.length || !incoming) return NO;
    NSString *containerID = CXRecentContainerSelection(bundleID);
    if (!containerID.length) return NO;
    NSString *active = [CXCraneBridge activeContainerForBundleID:bundleID] ?: @"DEFAULT";
    if (![active isEqualToString:containerID]) {
        CXForgetRecentContainerSelection(bundleID);
        return NO;
    }
    BOOL running = CXAppRunning(bundleID);
    CXLog(@"[url] %@ late URL -> recent container %@ running=%d", bundleID, containerID, running);
    CXMarkCurrentURLConsumed();
    CXInternalOpen = YES;
    if (!running) CXOpenInSplit(bundleID);
    NSTimeInterval delay = running ? 0.35 : 1.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ CXReplayURL(incoming); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CXInternalOpen = NO;
        CXForgetRecentContainerSelection(bundleID);
    });
    return YES;
}

// 任何开窗入口（URL/快捷/激活）通用：有分身且有新鲜 URL 就弹；proceed 由调用方继续原流程
static void CXReplayLateURLForSelection(NSString *bundleID, NSString *containerID,
                                        NSTimeInterval promptAt, NSInteger attempt);

static BOOL CXPromptForURL(NSString *bundleID, BOOL requireURL, void (^proceed)(void)) {
    if (CXInternalOpen || CXShowingChooser || !bundleID.length) return NO;
    if (CXRequestBypassActive(bundleID)) {
        CXLog(@"[route] %@ 已由系统 request 入口处理，跳过晚期 chooser", bundleID);
        return NO;
    }
    NSArray<NSDictionary *> *containers = [CXCraneBridge containersForBundleID:bundleID];
    if (containers.count < 2) return NO;
    NSTimeInterval promptAt = [NSDate date].timeIntervalSince1970;
    NSURL *incoming = nil;
    BOOL fresh = CXFreshURL(&incoming);
    if (requireURL && !fresh) return NO;
    if (fresh && CXRouteRecentSelectedURL(bundleID, incoming)) return YES;
    UIViewController *host = CXTopViewController();
    if (!host) return NO;
    CXShowingChooser = YES;
    CXLog(@"[url] %@ 容器=%lu url=%d", bundleID, (unsigned long)containers.count, fresh);
    NSString *appName = bundleID;
    Class proxyCls = NSClassFromString(@"LSApplicationProxy");
    if (proxyCls) {
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyCls, NSSelectorFromString(@"applicationProxyForIdentifier:"), bundleID);
        if (proxy) {
            id n = ((id (*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(@"localizedName"));
            if ([n isKindOfClass:NSString.class] && [n length]) appName = n;
        }
    }
    CXChooserController *chooser = [[CXChooserController alloc] init];
    chooser.containers = containers;
    chooser.appName = appName;
    chooser.bundleID = bundleID;
    chooser.modalPresentationStyle = UIModalPresentationOverFullScreen;
    chooser.cancel = ^{ CXShowingChooser = NO; if (proceed) proceed(); };
    chooser.pick = ^(NSString *cid) {
        CXShowingChooser = NO;
        BOOL running = CXAppRunning(bundleID);
        NSString *active = [CXCraneBridge activeContainerForBundleID:bundleID] ?: @"DEFAULT";
        BOOL same = [active isEqualToString:cid];
        CXRememberContainerSelection(bundleID, cid);
        CXLog(@"[url] %@ selected=%@ same=%d running=%d", bundleID, cid, same, running);
        BOOL wasInternal = CXInternalOpen;
        if (incoming) CXMarkCurrentURLConsumed();
        CXInternalOpen = YES;
        [CXCraneBridge switchBundleID:bundleID toContainer:cid reload:!same completion:^(BOOL ok) {
            if (!ok) { CXInternalOpen = wasInternal; CXLog(@"[url] %@ switch failed", bundleID); return; }
            // Crane completion 只代表配置写入；等待 PX 目标 scene
            // 真正消失/重建并稳定后，再继续原开窗链和 URL 补投。
            CXWaitForApplicationReady(bundleID, !same, running, 0, 0, ^{
                if (proceed) proceed();
                if (!incoming) {
                    // 支付来源 App 可能稍后才把 URL 写入共享记录；轮询 5 秒。
                    CXReplayLateURLForSelection(bundleID, cid, promptAt, 0);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.8 * NSEC_PER_SEC),
                                   dispatch_get_main_queue(), ^{ CXInternalOpen = wasInternal; });
                    return;
                }
                // 只在目标 scene 已经出现后补投，避免第一次打开落到空 scene。
                NSArray *delays = same ? @[@0.3, @1.0] : @[@0.8, @1.8, @3.0];
                for (NSNumber *d in delays) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{ CXReplayURL(incoming); });
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((same ? 1.5 : 4.0) * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ CXInternalOpen = wasInternal; });
            });
        }];
    };
    @try {
        UIWindow *hostWindow = host.viewIfLoaded.window ?: host.view.window;
        if (!CXPresentChooserInOwnWindow(chooser, hostWindow)) {
            CXShowingChooser = NO;
            CXLog(@"[url] chooser own-window unavailable");
            return NO;
        }
    } @catch (NSException *e) {
        CXCloseChooser();
        CXLog(@"[url] present chooser 异常: %@", e.reason ?: @"unknown");
        return NO;
    }
    return YES;
}

// 旧调用点：选完由本函数自己开窗
static void CXPromptContainerThenOpen(NSString *bundleID, void (^cancel)(void)) {
    if (CXPromptForURL(bundleID, NO, ^{ CXOpenInSplit(bundleID); })) return;
    if (cancel) cancel();
}

// 只拿到 bundleID 的晚期入口无法保留系统 request；支付来源 App 可能稍后才
// 把 URL 写入共享记录。分身窗口创建后短时轮询一次，捕获后自动投递，避免用户
// 第一次切账号只进主页、第二次点击才进入付款页。
static void CXReplayLateURLForSelection(NSString *bundleID, NSString *containerID,
                                        NSTimeInterval promptAt, NSInteger attempt) {
    if (attempt >= 20) {
        CXLog(@"[url] %@ late URL timeout after selection %@", bundleID, containerID);
        CXForgetRecentContainerSelection(bundleID);
        return;
    }
    NSString *recent = CXRecentContainerSelection(bundleID);
    NSString *active = [CXCraneBridge activeContainerForBundleID:bundleID] ?: @"DEFAULT";
    if (![recent isEqualToString:containerID] || ![active isEqualToString:containerID]) return;

    NSURL *incoming = nil;
    if (CXFreshURL(&incoming) && CXLastURLAt >= promptAt - 1.0) {
        CXLog(@"[url] %@ late URL captured attempt=%ld scheme=%@", bundleID,
              (long)attempt, incoming.scheme ?: @"");
        CXMarkCurrentURLConsumed();
        BOOL wasInternal = CXInternalOpen;
        CXInternalOpen = YES;
        CXPollReloadedURL(bundleID, incoming, wasInternal, 0);
        CXForgetRecentContainerSelection(bundleID);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CXReplayLateURLForSelection(bundleID, containerID, promptAt, attempt + 1);
    });
}

static BOOL CXHandleVirtualItemThen(NSDictionary *item, void (^open)(void));
static BOOL CXHandleVirtualItem(NSDictionary *item);

// alpha377 的完整建窗入口。由 PX 自己创建 hostCard/canvas/keyboardOverlay、
// 设置活动 bridge，并把自己的非空 continuation 传给开窗准备阶段。
// applicationActivated: 是前台激活通知，不能拿来请求建窗；
// prepareWindow(..., nil) 在原生 0x5c43c 直接返回，也不是建窗接口。
static void CXOpenInSplitImpl(NSString *bundleID) {
    Class entry = NSClassFromString(@"PXPanelEntry");
    SEL sel = NSSelectorFromString(@"externalOpenApplication:");
    NSMethodSignature *sig = [entry methodSignatureForSelector:sel];
    if (!entry || ![entry respondsToSelector:sel] || !sig || sig.numberOfArguments != 3 ||
        strcmp(sig.methodReturnType, @encode(void)) != 0 ||
        [sig getArgumentTypeAtIndex:2][0] != '@' ||
        [sig getArgumentTypeAtIndex:2][1] == '?') {
        CXLog(@"[open] %@ native window entry unavailable; not calling notification/prepare fallback", bundleID);
        return;
    }
    // 账号已由菜单/chooser 选定。PX 的异步 prepare/激活回调不应再次弹选择。
    CXMarkRequestBypass(bundleID);
    CXLog(@"[open] %@ native-window request (PX owns canvas and completion)", bundleID);
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(entry, sel, bundleID);
    } @catch (NSException *e) {
        CXLog(@"[open] %@ native-window exception: %@", bundleID, e.reason ?: @"unknown");
    }
}

// 截获一个虚拟条目：切容器 → 打开真实应用
static BOOL CXHandleVirtualItemThen(NSDictionary *item, void (^open)(void)) {
    NSString *bundleID = item[@"bundleID"];
    NSString *containerID = item[@"containerID"];
    if (!bundleID.length || !containerID.length) return NO;
    NSString *key = [NSString stringWithFormat:@"%@#%@", bundleID, containerID];
    if (CXHandledRecently(key)) return YES;
    CXMarkHandled(key);
    CXLog(@"[hit] %@ -> container %@", bundleID, containerID);
    // 必须重启应用：Crane 只改"下次启动"的容器，运行中的进程不会换数据
    NSString *activeNow = [CXCraneBridge activeContainerForBundleID:bundleID] ?: @"DEFAULT";
    BOOL sameNow = [activeNow isEqualToString:containerID];
    BOOL running = CXAppRunning(bundleID);
    [CXCraneBridge switchBundleID:bundleID toContainer:containerID reload:!sameNow completion:^(BOOL ok) {
        CXLog(@"[hit] %@ switch=%d same=%d running=%d", bundleID, ok, sameNow, running);
        if (!ok) { CXLog(@"[hit] switch failed, skip opening wrong account"); return; }
        // 场景等待在这台机器上不回调，改固定延时；再开窗和补投 URL
        (void)running;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (open) open(); else CXOpenInSplit(bundleID);
            NSURL *incoming = nil;
            if (!CXFreshURL(&incoming)) return;
            NSArray *delays = sameNow ? @[@0.3, @1.0] : @[@0.8, @1.8, @3.0];
            for (NSNumber *d in delays) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ CXReplayURL(incoming); });
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                CXInternalOpen = NO;
            });
        });
    }];
    return YES;
}

// 扇形菜单选中条目：分身走切容器，普通应用直接开分屏
void CXOpenMenuItem(NSString *identifier) {
    if (!identifier.length) return;
    NSDictionary *item = CXVirtualItemForID(identifier);
    if (item) { CXHandleVirtualItem(item); return; }
    if ([identifier hasPrefix:@"px."]) return; // 其他快捷操作暂不接
    CXLog(@"[arc] open %@", identifier);
    if ([CXCraneBridge containersForBundleID:identifier].count >= 2) {
        CXPromptContainerThenOpen(identifier, nil);
        return;
    }
    CXOpenInSplit(identifier);
}

static BOOL CXHandleVirtualItem(NSDictionary *item) {
    return CXHandleVirtualItemThen(item, nil);
}

static NSDictionary *CXVirtualItemFromArgument(id argument) {
    if ([argument isKindOfClass:NSString.class]) return CXVirtualItemForID(argument);
    if ([argument isKindOfClass:NSDictionary.class]) {
        id itemID = argument[@"id"];
        if ([itemID isKindOfClass:NSString.class]) return CXVirtualItemForID(itemID);
    }
    return nil;
}

#pragma mark - ① performConfiguredAction:（菜单点击动作 / 自定义条目）

static BOOL (*CXOrigPerformAction)(id, SEL, id);

static BOOL CXPerformAction(id self, SEL _cmd, id argument) {
    NSDictionary *item = CXVirtualItemFromArgument(argument);
    if (item && CXHandleVirtualItem(item)) return YES;
    return CXOrigPerformAction ? CXOrigPerformAction(self, _cmd, argument) : NO;
}

#pragma mark - ② prepareWindowForBundleID（条目被当作应用打开时）

static void (*CXOrigPrepareWindow)(id, SEL, id, BOOL, id);

static void CXPrepareWindow(id self, SEL _cmd, id bundleID, BOOL wasFullscreen, id completion) {
    if (!CXOrigPrepareWindow) return;
    CXLog(@"[trace] prepareWindow %@ fullscreen=%d", bundleID, wasFullscreen);
    NSDictionary *item = CXVirtualItemFromArgument(bundleID);
    if (!item) {
        NSString *real = [bundleID isKindOfClass:NSString.class] ? bundleID : nil;
        if (CXPromptForURL(real, YES, ^{ CXOrigPrepareWindow(self, _cmd, bundleID, wasFullscreen, completion); })) return;
        CXOrigPrepareWindow(self, _cmd, bundleID, wasFullscreen, completion);
        return;
    }
    NSString *realBundle = item[@"bundleID"];
    NSString *containerID = item[@"containerID"];
    NSString *key = [NSString stringWithFormat:@"%@#%@", realBundle, containerID];
    if (CXHandledRecently(key)) { CXOrigPrepareWindow(self, _cmd, realBundle, wasFullscreen, completion); return; }
    CXMarkHandled(key);
    CXLog(@"[hook] prepareWindow virtual %@ -> %@ / %@", bundleID, realBundle, containerID);
    [CXCraneBridge prepareLaunchForBundleID:realBundle containerID:containerID completion:^(BOOL ok) {
        CXLog(@"[hook] prepareWindow %@ switch=%d, continue", realBundle, ok);
        CXOrigPrepareWindow(self, _cmd, realBundle, wasFullscreen, completion);
    }];
}

#pragma mark - ③ PXPanelEntry 类方法（兜底）

static void (*CXOrigActivated)(Class, SEL, id);
static void (*CXOrigExternalOpen)(Class, SEL, id);

static void CXHandlePanelEntry(Class cls, SEL _cmd, id argument, void (*cont)(Class, SEL, id)) {
    CXLog(@"[trace] %@ %@", NSStringFromSelector(_cmd), argument);
    NSDictionary *item = CXVirtualItemFromArgument(argument);
    if (!item) {
        NSString *real = [argument isKindOfClass:NSString.class] ? argument : nil;
        if (CXPromptForURL(real, YES, ^{ cont(cls, _cmd, argument); })) return;
        cont(cls, _cmd, argument);
        return;
    }
    NSString *realBundle = item[@"bundleID"];
    NSString *containerID = item[@"containerID"];
    NSString *key = [NSString stringWithFormat:@"%@#%@", realBundle, containerID];
    if (CXHandledRecently(key)) { cont(cls, _cmd, realBundle); return; }
    CXMarkHandled(key);
    CXLog(@"[hook] %@ virtual %@ -> %@ / %@", NSStringFromSelector(_cmd), argument, realBundle, containerID);
    [CXCraneBridge prepareLaunchForBundleID:realBundle containerID:containerID completion:^(BOOL ok) {
        CXLog(@"[hook] %@ %@ switch=%d, continue", NSStringFromSelector(_cmd), realBundle, ok);
        cont(cls, _cmd, realBundle);
    }];
}

static void CXActivated(Class cls, SEL _cmd, id argument) {
    if (!CXOrigActivated) return;
    CXHandlePanelEntry(cls, _cmd, argument, CXOrigActivated);
}

static void CXExternalOpen(Class cls, SEL _cmd, id argument) {
    if (!CXOrigExternalOpen) return;
    // 我们自己发起的打开：直接放行
    if (CXInternalOpen || CXShowingChooser) { CXOrigExternalOpen(cls, _cmd, argument); return; }
    if ([argument isKindOfClass:NSString.class]) {
        NSString *bundle = argument;
        NSDictionary *virtualItem = CXVirtualItemFromArgument(argument);
        if (!virtualItem && CXRequestBypassActive(bundle)) {
            CXLog(@"[route] %@ 已完成账号选择，改走分屏入口", bundle);
            CXOpenInSplit(bundle);
            return;
        }
        if (!virtualItem && [CXCraneBridge containersForBundleID:bundle].count >= 2) {
            CXLog(@"[url] %@ 有多账号，弹选择", bundle);
            CXPromptContainerThenOpen(bundle, ^{ CXOrigExternalOpen(cls, _cmd, argument); });
            return;
        }
    }
    CXHandlePanelEntry(cls, _cmd, argument, CXOrigExternalOpen);
}

#pragma mark - 安装

static CXHookFn CXMSHookMessageEx(void) {
    return (CXHookFn)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
}

static BOOL CXTypecodeEqual(const char *actual, const char *expected) {
    if (!actual || !expected) return NO;
    if (expected[0] == '@' && expected[1] == '\0') return actual[0] == '@' && actual[1] != '?';
    return strcmp(actual, expected) == 0;
}

static Method CXClassMethodIf(Class cls, NSString *selectorName, NSUInteger argCount, const char *arg2) {
    if (!cls || !selectorName.length) return NULL;
    Class meta = object_getClass(cls);
    SEL sel = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod(meta, sel);
    if (!method) return NULL;
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (!sig) return NULL;
    if (sig.numberOfArguments != argCount + 2) return NULL;
    if (strcmp(sig.methodReturnType, @encode(void)) != 0) return NULL;
    if (arg2 && !CXTypecodeEqual([sig getArgumentTypeAtIndex:2], arg2)) return NULL;
    return method;
}

static void CXInstallPanelEntryHooks(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class cls = NSClassFromString(@"PXPanelEntry");
    if (!cls) return;
    CXHookFn hook = CXMSHookMessageEx();
    if (!hook) { CXLog(@"[hook] MSHookMessageEx 不可用"); return; }
    Class meta = object_getClass(cls);

    Method activated = CXClassMethodIf(cls, @"applicationActivated:", 1, @encode(id));
    if (activated) {
        hook(meta, NSSelectorFromString(@"applicationActivated:"), (IMP)CXActivated, (IMP *)&CXOrigActivated);
        CXLog(@"[hook] applicationActivated: installed=%d", CXOrigActivated != NULL);
    } else {
        CXLog(@"[hook] applicationActivated: 签名核验未通过，跳过");
    }

    Method external = CXClassMethodIf(cls, @"externalOpenApplication:", 1, @encode(id));
    if (external) {
        hook(meta, NSSelectorFromString(@"externalOpenApplication:"), (IMP)CXExternalOpen, (IMP *)&CXOrigExternalOpen);
        CXLog(@"[hook] externalOpenApplication: installed=%d", CXOrigExternalOpen != NULL);
    } else {
        CXLog(@"[hook] externalOpenApplication: 签名核验未通过，跳过");
    }
    installed = (CXOrigActivated != NULL || CXOrigExternalOpen != NULL);
}

static void (*CXOrigOpenApp)(id, SEL, id, id, id, id);

static void CXOpenAppHook(id self, SEL _cmd, id app, id view, id overlay, id completion) {
    CXLog(@"[trace] openApplication app=%@(%@) view=%@(%@)", app,
          NSStringFromClass([app class]), NSStringFromClass([view class]),
          NSStringFromClass([overlay class]));
    if (!CXOrigOpenApp) return;

    // Normally virtual entries are consumed by performConfiguredAction:.
    // Keep this guard for PX versions that forward the virtual record further.
    NSDictionary *item = CXVirtualItemFromArgument(app);
    if (item) {
        NSString *realBundle = item[@"bundleID"];
        NSString *containerID = item[@"containerID"];
        NSString *key = [NSString stringWithFormat:@"%@#%@", realBundle, containerID];
        if (realBundle.length && containerID.length && !CXHandledRecently(key)) {
            CXMarkHandled(key);
            NSString *activeNow = [CXCraneBridge activeContainerForBundleID:realBundle] ?: @"DEFAULT";
            BOOL sameNow = [activeNow isEqualToString:containerID];
            CXLog(@"[hit] %@ -> container %@ (openApplication)", realBundle, containerID);
            [CXCraneBridge switchBundleID:realBundle toContainer:containerID reload:!sameNow completion:^(BOOL ok) {
                CXLog(@"[hit] %@ switch=%d, hand back", realBundle, ok);
                if (!ok) return;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    CXOrigOpenApp(self, _cmd, realBundle, view, overlay, completion);
                });
            }];
            return;
        }
        if (realBundle.length) {
            CXOrigOpenApp(self, _cmd, realBundle, view, overlay, completion);
            return;
        }
    }
    CXOrigOpenApp(self, _cmd, app, view, overlay, completion);
}

static void CXInstallBridgeHooks(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class cls = NSClassFromString(@"PXSceneBridge");
    if (!cls) return;
    CXHookFn hook = CXMSHookMessageEx();
    if (!hook) return;

    // ① performConfiguredAction:（B24@0:8@16）——自定义条目点击
    SEL actionSel = NSSelectorFromString(@"performConfiguredAction:");
    Method actionMethod = class_getInstanceMethod(cls, actionSel);
    if (actionMethod) {
        NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(actionMethod)];
        BOOL ok = sig && sig.numberOfArguments == 3 &&
                  strcmp(sig.methodReturnType, @encode(BOOL)) == 0 &&
                  CXTypecodeEqual([sig getArgumentTypeAtIndex:2], @encode(id));
        if (ok) {
            hook(cls, actionSel, (IMP)CXPerformAction, (IMP *)&CXOrigPerformAction);
            CXLog(@"[hook] performConfiguredAction: installed=%d", CXOrigPerformAction != NULL);
        } else {
            CXLog(@"[hook] performConfiguredAction: 签名不符，跳过");
        }
    } else {
        CXLog(@"[hook] performConfiguredAction: 不存在，跳过");
    }

    // ② prepareWindowForBundleID:wasFullscreen:completion:
    SEL prepareSel = NSSelectorFromString(@"prepareWindowForBundleID:wasFullscreen:completion:");
    Method prepareMethod = class_getInstanceMethod(cls, prepareSel);
    if (prepareMethod) {
        NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(prepareMethod)];
        BOOL ok = sig && sig.numberOfArguments == 5 &&
                  strcmp(sig.methodReturnType, @encode(void)) == 0 &&
                  CXTypecodeEqual([sig getArgumentTypeAtIndex:2], @encode(id)) &&
                  CXTypecodeEqual([sig getArgumentTypeAtIndex:3], @encode(BOOL)) &&
                  [sig getArgumentTypeAtIndex:4][0] == '@';
        if (ok) {
            hook(cls, prepareSel, (IMP)CXPrepareWindow, (IMP *)&CXOrigPrepareWindow);
            CXLog(@"[hook] prepareWindow installed=%d", CXOrigPrepareWindow != NULL);
        } else {
            CXLog(@"[hook] prepareWindow 签名不符，跳过");
        }
    }

    // ③ openApplication:inView:keyboardOverlay:completion: —— 只记录，不改行为
    SEL openSel = NSSelectorFromString(@"openApplication:inView:keyboardOverlay:completion:");
    Method openMethod = class_getInstanceMethod(cls, openSel);
    if (openMethod) {
        NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(openMethod)];
        BOOL ok = sig && sig.numberOfArguments == 6 &&
                  strcmp(sig.methodReturnType, @encode(void)) == 0 &&
                  [sig getArgumentTypeAtIndex:2][0] == '@' &&
                  [sig getArgumentTypeAtIndex:3][0] == '@' &&
                  [sig getArgumentTypeAtIndex:4][0] == '@' &&
                  [sig getArgumentTypeAtIndex:5][0] == '@';
        if (ok) {
            hook(cls, openSel, (IMP)CXOpenAppHook, (IMP *)&CXOrigOpenApp);
            CXLog(@"[hook] openApplication installed=%d", CXOrigOpenApp != NULL);
        } else {
            CXLog(@"[hook] openApplication 签名不符，跳过");
        }
    }

    installed = (CXOrigPerformAction != NULL || CXOrigPrepareWindow != NULL);
}

static void (*CXOrigDragHandle)(id, SEL, id);

static void CXDragHandleHook(id self, SEL _cmd, id gesture) {
    CXSyncIfNeeded(@"dragHandle");
    if (CXOrigDragHandle) CXOrigDragHandle(self, _cmd, gesture);
}

static void CXInstallDragHandleHook(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class cls = NSClassFromString(@"PXPanelEntry");
    if (!cls) return;
    SEL sel = NSSelectorFromString(@"dragHandle:");
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    CXHookFn hook = CXMSHookMessageEx();
    if (!hook) return;
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (!sig || sig.numberOfArguments != 3 || [sig getArgumentTypeAtIndex:2][0] != '@') return;
    hook(cls, sel, (IMP)CXDragHandleHook, (IMP *)&CXOrigDragHandle);
    installed = CXOrigDragHandle != NULL;
    CXLog(@"[hook] dragHandle installed=%d", installed);
}


#pragma mark - 探针：图标类方法枚举


static void CXProbeGesturesRecursive(UIView *view, int depth) {
    if (!view || depth > 12) return;
    for (UIGestureRecognizer *g in view.gestureRecognizers) {
        NSMutableString *tg = [NSMutableString string];
        @try {
            NSArray *targets = [g valueForKey:@"_targets"];
            for (id t in targets) {
                id target = [t valueForKey:@"target"];
                NSString *action = [t valueForKey:@"_action"] ?: [t valueForKey:@"action"];
                [tg appendFormat:@" %@->%@", NSStringFromClass([target class]), action];
            }
        } @catch (__unused NSException *e) { [tg appendString:@" ?"]; }
        CXLog(@"[probe] gesture %@ on %@ (depth %d) targets:%@ desc=%@",
              NSStringFromClass([g class]), NSStringFromClass([view class]), depth, tg, g);
    }
    for (UIView *sub in view.subviews) CXProbeGesturesRecursive(sub, depth + 1);
}


static void CXProbeTree(UIView *v, int d) {
    if (!v || d > 18) return;
    CXLog(@"[probe] %*s%@ frame=%@ gr=%lu", d * 2, "", NSStringFromClass(v.class),
          NSStringFromCGRect(v.frame), (unsigned long)v.gestureRecognizers.count);
    for (UIView *sub in v.subviews) CXProbeTree(sub, d + 1);
}

static void CXProbePanelDeep(void) {
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (![NSStringFromClass(w.class) containsString:@"Panel"]) continue;
        if (w.subviews.count < 1) continue;   // 面板没展开就不打
        if ([w respondsToSelector:NSSelectorFromString(@"recursiveDescription")]) {
            NSString *desc = ((id (*)(id, SEL))objc_msgSend)(w, NSSelectorFromString(@"recursiveDescription"));
            for (NSString *line in [desc componentsSeparatedByString:@"\n"])
                if (line.length) CXLog(@"[tree] %@", line);
        }
        Class c = w.class; int n = 0;
        while (c && n++ < 8) { CXLog(@"[probe] chain %@", NSStringFromClass(c)); c = class_getSuperclass(c); }
        id r = w.nextResponder; n = 0;
        while (r && n++ < 8) { CXLog(@"[probe] responder %@", NSStringFromClass([r class])); r = [r nextResponder]; }
        CXProbeTree(w, 0);
        // 图标父视图的方法表
        for (UIView *v in w.subviews) {
            for (UIView *g in v.subviews) {
                NSString *cn = NSStringFromClass(g.class);
                if (![cn containsString:@"Icon"]) continue;
                UIView *host = g.superview;
                CXLog(@"[probe] iconHost %@", NSStringFromClass(host.class));
                unsigned int mc = 0;
                Method *ms = class_copyMethodList(host.class, &mc);
                for (unsigned int i = 0; i < mc && i < 60; i++)
                    CXLog(@"[probe]   -%s %s", sel_getName(method_getName(ms[i])), method_getTypeEncoding(ms[i]));
                free(ms);
            }
        }
    }
}

static void CXProbeGestures(void) {
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        NSString *cn = NSStringFromClass(w.class);
        if (!([cn hasPrefix:@"PX"] || [cn containsString:@"Panel"])) continue;
        CXLog(@"[probe] window %@ level=%.0f", cn, w.windowLevel);
        CXProbeGesturesRecursive(w, 0);
    }
}

static void CXProbeIconClasses(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return;
    objc_getClassList(classes, count);
    for (int i = 0; i < count; i++) {
        const char *name = class_getName(classes[i]);
        if (!name) continue;
        if (!strstr(name, "PXPanelIcon") && !strstr(name, "PXPanelButton") &&
            !strstr(name, "PXIconView") && !strstr(name, "PXLauncherIcon")) continue;
        CXLog(@"[probe] class %s super=%s", name, class_getName(class_getSuperclass(classes[i])));
        unsigned int mc = 0;
        Method *methods = class_copyMethodList(classes[i], &mc);
        for (unsigned int m = 0; m < mc && m < 40; m++)
            CXLog(@"[probe]   -%s  %s", sel_getName(method_getName(methods[m])),
                  method_getTypeEncoding(methods[m]));
        free(methods);
        // 类方法
        Class meta = object_getClass(classes[i]);
        methods = class_copyMethodList(meta, &mc);
        for (unsigned int m = 0; m < mc && m < 20; m++)
            CXLog(@"[probe]   +%s  %s", sel_getName(method_getName(methods[m])),
                  method_getTypeEncoding(methods[m]));
        free(methods);
    }
    free(classes);
}

static void CXInstallAll(void) {
    CXInstallURLHook();
    CXInstallPanelEntryHooks();
    CXInstallBridgeHooks();
    CXInstallDragHandleHook();
}

#pragma mark - 配置同步

static NSString *CXContainerSignature(void) {
    NSArray<NSString *> *apps = [CXCraneBridge applicationsWithNonDefaultContainers];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *bundle in [apps sortedArrayUsingSelector:@selector(compare:)]) {
        NSMutableArray<NSString *> *ids = [NSMutableArray array];
        for (NSDictionary *entry in [CXCraneBridge containersForBundleID:bundle])
            if ([entry[@"containerID"] isKindOfClass:NSString.class]) [ids addObject:entry[@"containerID"]];
        [parts addObject:[NSString stringWithFormat:@"%@=%@", bundle,
                          [[ids sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","]]];
    }
    return [parts componentsJoinedByString:@"|"];
}

static NSString *CXLastSignature;

static void CXSyncMenu(void) {
    @try { [CXMenuInjector sync]; }
    @catch (__unused NSException *e) { CXLog(@"[menu] sync 异常"); }
}

// Crane 里新增/删除容器后自动重扫（默认 5s 一次，签名不变不写盘）
static void CXSyncIfNeeded(NSString *reason) {
    NSString *sig = CXContainerSignature();
    if (CXLastSignature && [sig isEqualToString:CXLastSignature]) return;
    CXLog(@"[menu] container change (%@), resync", reason);
    CXLastSignature = sig;
    CXSyncMenu();
}

static void CXSharedURLChanged(CFNotificationCenterRef center, void *observer,
                                CFStringRef name, const void *object,
                                CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{ CXImportSharedAppURL(); });
}

static void CXPreferencesChanged(CFNotificationCenterRef center, void *observer,
                                 CFStringRef name, const void *object,
                                 CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        CXSyncMenu();
    });
}

#pragma mark - 载入时机

static void CXImageAdded(const struct mach_header *header, intptr_t slide) {
    Dl_info info = {0};
    if (!dladdr(header, &info) || !info.dli_fname) return;
    NSString *path = [NSString stringWithUTF8String:info.dli_fname];
    if (![path.lastPathComponent isEqualToString:@"ParallelX.dylib"]) return;
    dispatch_async(dispatch_get_main_queue(), ^{ CXInstallAll(); });
}

__attribute__((constructor)) static void CXInitialize(void) {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    BOOL isSB = [bid isEqualToString:@"com.apple.springboard"];
    if (!isSB) {
        // 普通应用：只挂 URL 抓取，本进程内不做任何分身/菜单工作。
        dispatch_async(dispatch_get_main_queue(), ^{
            @try { CXInstallURLHook(); } @catch (__unused NSException *e) {}
            CXLog(@"[init] app-side URL capture in %@", bid);
        });
        return;
    }
    _dyld_register_func_for_add_image(CXImageAdded);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CXLog(@"[init] CloneX loaded, crane=%d, pxEntry=%d, pxBridge=%d",
              [CXCraneBridge isCraneAvailable],
              NSClassFromString(@"PXPanelEntry") != nil,
              NSClassFromString(@"PXSceneBridge") != nil);
        BOOL craneOK = [CXCraneBridge isCraneAvailable];
        [CXPrefs.shared setBool:craneOK forKey:CXKeyDiagCraneOK];
        if (!craneOK) CXLog(@"[diag] %@", [[CXCraneBridge diagnosticLines] componentsJoinedByString:@" | "]);
        CXInstallAll();
        // PX 自己可能在加载后重挂 SBMainWorkspace 同一 selector；
        // 等 PX 的类/入口稳定后再安装 request Hook，避免被覆盖。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            CXInstallSystemRequestHook();
        });
        CXLastSignature = CXContainerSignature();
        CXSyncMenu();
        [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *timer) {
            CXSyncIfNeeded(@"timer");
        }];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, CXPreferencesChanged,
                                        CFSTR("com.niubiprass.clonex/changed"),
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, CXSharedURLChanged,
                                        CFSTR("com.niubiprass.clonex/url"),
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CXImportSharedAppURL();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
        CXProbeIconClasses();
        __block __weak void (^weakTick)(int);
        __block void (^tick)(int);
        tick = ^(int n) {
            if (n > 45) return;
            CXProbeGestures();
            CXProbePanelDeep();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ if (weakTick) weakTick(n + 1); });
        };
        weakTick = tick;
        tick(0);
    });
    });
}