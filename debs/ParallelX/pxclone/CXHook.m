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
// 依据（alpha342 反汇编）：
//   -[PXSceneBridge performConfiguredAction:]  B24@0:8@16   （动作执行入口）
//   -[PXSceneBridge prepareWindowForBundleID:wasFullscreen:completion:]
//                                              v36@0:8@16B24@?28（开窗准备）
//   +[PXPanelEntry applicationActivated:]      v24@0:8@16   （分屏打开）
//   +[PXPanelEntry externalOpenApplication:]   v24@0:8@16   （全屏打开）
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
#import "CXArcWake.h"
#import "CXWindowLevel.h"  // ← 新增：窗口层级

typedef void (*CXHookFn)(Class, SEL, IMP, IMP *);

static void CXSyncIfNeeded(NSString *reason);
static CXHookFn CXMSHookMessageEx(void);

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

#pragma mark - 最近一次外部 URL（重载后补投，否则只落到主界面）

static NSURL *CXLastURL;
static NSTimeInterval CXLastURLAt;

static BOOL CXFreshURL(NSURL **out) {
    if (CXLastURL && [NSDate date].timeIntervalSince1970 - CXLastURLAt <= 6.0) {
        if (out) *out = CXLastURL;
        return YES;
    }
    // 其他进程（发起方应用）抓到的链接放这里，供 SpringBoard 读取。
    NSString *str = [CXPrefs.shared objectForKey:@"CXSharedURL"];
    if (![str isKindOfClass:NSString.class] || !str.length) return NO;
    double at = [CXPrefs.shared objectForKey:@"CXSharedURLAt"] ?
                [[CXPrefs.shared objectForKey:@"CXSharedURLAt"] doubleValue] : 0;
    if ([NSDate date].timeIntervalSince1970 - at > 8.0) return NO;
    NSURL *url = [NSURL URLWithString:str];
    if (!url) return NO;
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

static void CXReplayURL(NSURL *url) {
    if (!url) return;
    BOOL wasInternal = CXInternalOpen;
    CXInternalOpen = YES; // 补投引起的激活不再弹选择
    CXLog(@"[url] replay %@", url.scheme);
    @try {
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(UIApplication.sharedApplication,
            NSSelectorFromString(@"openURL:options:completionHandler:"), url, @{}, nil);
    } @catch (__unused NSException *e) { CXLog(@"[url] replay 异常"); }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CXInternalOpen = wasInternal;
    });
}

static void (*CXOrigOpenURL)(id, SEL, id, id, id);
static BOOL (*CXOrigOpenURLLegacy)(id, SEL, id);
static void CXCaptureExternalURL(id url) {
    if (![url isKindOfClass:NSURL.class]) return;
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

static UIViewController *CXTopViewController(void) {
    UIViewController *vc = nil;
    for (UIWindow *window in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        if (window.hidden || !window.rootViewController) continue;
        vc = window.rootViewController; break;
    }
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void CXOpenInSplitImpl(NSString *bundleID);

// 菜单已指定账号，或 URL 已选择账号：内部开窗不再次弹选择。
static void CXReplayRecentURL(void) {
    NSURL *url = nil;
    if (!CXFreshURL(&url)) return;
    CXLastURL = nil;
    CXLastURLAt = 0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        BOOL wasInternal = CXInternalOpen;
        CXInternalOpen = YES;
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL ok) {
            CXLog(@"[url] replay %@ ok=%d", url.scheme ?: @"", ok);
        }];
        CXInternalOpen = wasInternal;
    });
}

static void CXOpenInSplit(NSString *bundleID) {
    BOOL wasInternal = CXInternalOpen;
    CXInternalOpen = YES;
    @try {
        CXOpenInSplitImpl(bundleID);
        CXReplayRecentURL();
    } @finally {
        CXInternalOpen = wasInternal;
    }
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
    [self dismissViewControllerAnimated:YES completion:^{ if (self.pick) self.pick(entry[@"containerID"]); }];
}
- (void)cancelled {
    if (self.finishing) return;
    self.finishing = YES;
    [self dismissViewControllerAnimated:YES completion:^{ if (self.cancel) self.cancel(); }];
}
@end

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

// 任何开窗入口（URL/快捷/激活）通用：有分身且有新鲜 URL 就弹；proceed 由调用方继续原流程
static BOOL CXPromptForURL(NSString *bundleID, BOOL requireURL, void (^proceed)(void)) {
    if (CXInternalOpen || CXShowingChooser || !bundleID.length) return NO;
    NSArray<NSDictionary *> *containers = [CXCraneBridge containersForBundleID:bundleID];
    if (containers.count < 2) return NO;
    NSURL *incoming = nil;
    BOOL fresh = CXFreshURL(&incoming);
    if (requireURL && !fresh) return NO;
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
        CXLog(@"[url] %@ selected=%@ same=%d running=%d", bundleID, cid, same, running);
        BOOL wasInternal = CXInternalOpen;
        CXInternalOpen = YES;
        [CXCraneBridge switchBundleID:bundleID toContainer:cid reload:!same completion:^(BOOL ok) {
            if (!ok) { CXInternalOpen = wasInternal; CXLog(@"[url] %@ switch failed", bundleID); return; }
            // 重载后进程要重新起来，立刻开窗会开到旧账号的进程上，所以先等一拍。
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((same ? 0.05 : (running ? 1.0 : 0.2)) * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (proceed) proceed();
                if (!incoming) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                        CXInternalOpen = wasInternal; });
                    return;
                }
                // 重启后进程要几秒才可收链接；多补几次，避免第一次打开丢链接。
                NSArray *delays = same ? @[@0.3, @1.0] : @[@1.5, @2.5, @3.5, @4.5];
                BOOL wasInt = CXInternalOpen;
                for (NSNumber *d in delays) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{ CXReplayURL(incoming); });
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((same ? 1.5 : 5.0) * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ CXInternalOpen = wasInt; });
            });
        }];
    };
    @try {
        if (!host.viewIfLoaded.window && host.view.window == nil) {
            CXShowingChooser = NO;
            CXLog(@"[url] chooser host 无有效窗口");
            return NO;
        }
        [host presentViewController:chooser animated:YES completion:nil];
    } @catch (NSException *e) {
        CXShowingChooser = NO;
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

static void CXOpenInSplitImpl(NSString *bundleID) {
    // ① 首选：+[PXPanelEntry externalOpenApplication:] —— PX 自己会创建桥与容器视图，
    //    日志证实它随后调用 openApplication，视图为 312x675（分屏尺寸）。
    Class entryCls = NSClassFromString(@"PXPanelEntry");
    SEL extSel = NSSelectorFromString(@"externalOpenApplication:");
    if (entryCls && [entryCls respondsToSelector:extSel]) {
        NSMethodSignature *extSig = [entryCls methodSignatureForSelector:extSel];
        if (extSig && extSig.numberOfArguments == 3 &&
            strcmp(extSig.methodReturnType, @encode(void)) == 0 &&
            [extSig getArgumentTypeAtIndex:2][0] == '@') {
            @try {
                ((void (*)(id, SEL, id))objc_msgSend)(entryCls, extSel, bundleID);
                CXLog(@"[open] %@ via externalOpenApplication", bundleID);
                return;
            } @catch (__unused NSException *e) {
                CXLog(@"[open] externalOpenApplication 异常，回退 %@", bundleID);
            }
        }
    }
    // ② 照抄普通应用的路径 openApplication:inView:keyboardOverlay:completion:
    Class bridgeCls = NSClassFromString(@"PXSceneBridge");
    id bridge = nil;
    if (bridgeCls && [bridgeCls respondsToSelector:NSSelectorFromString(@"sharedBridge")])
        bridge = ((id (*)(id, SEL))objc_msgSend)(bridgeCls, NSSelectorFromString(@"sharedBridge"));
    if (bridge) {
        SEL openSel = NSSelectorFromString(@"openApplication:inView:keyboardOverlay:completion:");
        NSMethodSignature *sig = [bridge methodSignatureForSelector:openSel];
        if (sig && sig.numberOfArguments == 6 &&
            strcmp(sig.methodReturnType, @encode(void)) == 0 &&
            [sig getArgumentTypeAtIndex:2][0] == '@' &&
            [sig getArgumentTypeAtIndex:3][0] == '@' &&
            [sig getArgumentTypeAtIndex:4][0] == '@' &&
            [sig getArgumentTypeAtIndex:5][0] == '@') {
            id view = nil, overlay = nil;
            SEL hostSel = NSSelectorFromString(@"hostView");
            SEL overlaySel = NSSelectorFromString(@"keyboardOverlay");
            if ([bridge respondsToSelector:hostSel])
                view = ((id (*)(id, SEL))objc_msgSend)(bridge, hostSel);
            if ([bridge respondsToSelector:overlaySel])
                overlay = ((id (*)(id, SEL))objc_msgSend)(bridge, overlaySel);
            if (view) {
                CXLog(@"[open] %@ via sharedBridge.openApplication view=%@ overlay=%@",
                      bundleID, NSStringFromClass([view class]), NSStringFromClass([overlay class]));
                void (^done)(BOOL) = ^(BOOL ok) { CXLog(@"[open] openApplication %@ done=%d", bundleID, ok); };
                @try {
                    ((void (*)(id, SEL, id, id, id, id))objc_msgSend)(bridge, openSel, bundleID, view, overlay, done);
                    return;
                } @catch (__unused NSException *e) {
                    CXLog(@"[open] openApplication 异常，回退 prepareWindow %@", bundleID);
                }
            } else {
                CXLog(@"[open] sharedBridge.hostView 为空，回退 prepareWindow");
            }
        }
        SEL prep = NSSelectorFromString(@"prepareWindowForBundleID:wasFullscreen:completion:");
        NSMethodSignature *prepSig = [bridge methodSignatureForSelector:prep];
        if (prepSig && prepSig.numberOfArguments == 5 &&
            strcmp(prepSig.methodReturnType, @encode(void)) == 0 &&
            [prepSig getArgumentTypeAtIndex:2][0] == '@' &&
            [prepSig getArgumentTypeAtIndex:3][0] == 'B' &&
            [prepSig getArgumentTypeAtIndex:4][0] == '@') {
            @try {
                void (^done)(BOOL) = ^(BOOL ok) { CXLog(@"[open] prepareWindow %@ done=%d", bundleID, ok); };
                ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(bridge, prep, bundleID, NO, done);
                CXLog(@"[open] %@ via sharedBridge.prepareWindow", bundleID);
                return;
            } @catch (__unused NSException *e) {
                CXLog(@"[open] sharedBridge.prepareWindow 异常，回退 %@", bundleID);
            }
        } else {
            CXLog(@"[open] sharedBridge 存在但签名不符，回退");
        }
    } else {
        CXLog(@"[open] sharedBridge 不存在，回退 applicationActivated:");
    }
    // ② 兜底：类方法 applicationActivated:
    Class entry = NSClassFromString(@"PXPanelEntry");
    SEL sel = NSSelectorFromString(@"applicationActivated:");
    if (!entry) return;
    NSMethodSignature *entrySig = [entry methodSignatureForSelector:sel];
    if (!entrySig || entrySig.numberOfArguments != 3 ||
        strcmp(entrySig.methodReturnType, @encode(void)) != 0 ||
        [entrySig getArgumentTypeAtIndex:2][0] != '@') return;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(entry, sel, bundleID);
    } @catch (__unused NSException *e) {
        CXLog(@"[open] %@ 打开异常", bundleID);
    }
}

// 截获一个虚拟条目：切容器 → 打开真实应用
static BOOL CXHandleVirtualItem(NSDictionary *item) {
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
    [CXCraneBridge switchBundleID:bundleID toContainer:containerID reload:!sameNow completion:^(BOOL ok) {
    CXLog(@"[hit] %@ switch=%d", bundleID, ok);
    if (!ok) { CXLog(@"[hit] switch failed, skip opening wrong account"); return; }
        CXOpenInSplit(bundleID);
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
    NSString *bundle = [app isKindOfClass:NSString.class] ? app : nil;
    NSString *active = bundle.length ? [CXCraneBridge activeContainerForBundleID:bundle] : nil;
    NSString *container = active.length ? active : @"DEFAULT"; // 普通应用也要记忆
    CXLog(@"[trace] openApplication app=%@(%@)", app, NSStringFromClass([app class]));
    if (CXOrigOpenApp) CXOrigOpenApp(self, _cmd, app, view, overlay, completion);
    // 原 completion 原样传回，不猜 block 内部签名；只在原开窗之后有限重试。
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
    CXArcWakeCaptureEntry(self); // 捕获原版真正运行的实例，不再猜响应链
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

static void CXPreferencesChanged(CFNotificationCenterRef center, void *observer,
                                 CFStringRef name, const void *object,
                                 CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        CXSyncMenu();
        CXArcWakeSync(); // 与旧版一样：设置变更即时刷新手势与调试热区
        
        // ========== 窗口层级配置变化处理 ==========
        CXLog(@"[CXWindowLevel] 配置已变化，更新所有 PX 窗口层级");
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            NSString *className = NSStringFromClass(window.class);
            if ([className hasPrefix:@"PX"] || [className containsString:@"Handle"] || 
                [className containsString:@"Panel"] || [className containsString:@"Overlay"]) {
                CXApplyWindowLevel(window);
            }
        }
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
        CXArcWakeInstall();
        CXLastSignature = CXContainerSignature();
        CXSyncMenu();
        [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *timer) {
            CXSyncIfNeeded(@"timer");
        }];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, CXPreferencesChanged,
                                        CFSTR("com.niubiprass.clonex/changed"),
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        
        // ========== 窗口层级功能初始化 ==========
        // 延迟3秒应用层级，确保 PX 窗口已创建
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            CXLog(@"[CXWindowLevel] 开始应用窗口层级");
            for (UIWindow *window in UIApplication.sharedApplication.windows) {
                NSString *className = NSStringFromClass(window.class);
                if ([className hasPrefix:@"PX"] || [className containsString:@"Handle"] || 
                    [className containsString:@"Panel"] || [className containsString:@"Overlay"]) {
                    CXApplyWindowLevel(window);
                    CXLog(@"[CXWindowLevel] 已应用到 %@: level=%.0f", className, window.windowLevel);
                }
            }
        });
    });
}