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
#import "CXRemember.h"
#import "CXArcWake.h"

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
    if (!CXLastURL || [NSDate date].timeIntervalSince1970 - CXLastURLAt > 6.0) return NO;
    if (out) *out = CXLastURL;
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
static void CXOpenURLHook(id self, SEL _cmd, id url, id options, id completion) {
    if ([url isKindOfClass:NSURL.class]) {
        CXLastURL = [url copy];
        CXLastURLAt = [NSDate date].timeIntervalSince1970;
    }
    if (CXOrigOpenURL) CXOrigOpenURL(self, _cmd, url, options, completion);
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
    CXLog(@"[hook] openURL installed=%d", installed);
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
static void CXOpenInSplit(NSString *bundleID) {
    BOOL wasInternal = CXInternalOpen;
    CXInternalOpen = YES;
    @try {
        CXOpenInSplitImpl(bundleID);
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
    SEL iconSel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if ([UIImage respondsToSelector:iconSel])
        icon = ((id (*)(id, SEL, id, long, double))objc_msgSend)(UIImage.class, iconSel,
            self.bundleID, 0, (double)UIScreen.mainScreen.scale);
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
                [dot.widthAnchor constraintEqualToConstant:8], [dot.heightAnchor constraintEqualToConstant:8],
                [dot.trailingAnchor constraintEqualToAnchor:name.trailingAnchor constant:6],
                [dot.centerYAnchor constraintEqualToAnchor:name.centerYAnchor]]];
        }
        UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:@[iv, name]];
        col.axis = UILayoutConstraintAxisVertical; col.alignment = UIStackViewAlignmentCenter; col.spacing = 6;
        col.userInteractionEnabled = NO; col.translatesAutoresizingMaskIntoConstraints = NO;
        [button addSubview:col];
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
    NSDictionary *entry = self.containers[sender.tag];
    [self dismissViewControllerAnimated:YES completion:^{ if (self.pick) self.pick(entry[@"containerID"]); }];
}
- (void)cancelled {
    [self dismissViewControllerAnimated:YES completion:^{ if (self.cancel) self.cancel(); }];
}
@end

// 任何开窗入口（URL/快捷/激活）通用：有分身且有新鲜 URL 就弹；proceed 由调用方继续原流程
static BOOL CXPromptForURL(NSString *bundleID, void (^proceed)(void)) {
    if (CXInternalOpen || CXShowingChooser || !bundleID.length) return NO;
    NSArray<NSDictionary *> *containers = [CXCraneBridge containersForBundleID:bundleID];
    if (containers.count < 2) return NO;
    NSURL *incoming = nil;
    if (!CXFreshURL(&incoming)) return NO;
    UIViewController *host = CXTopViewController();
    if (!host) return NO;
    CXShowingChooser = YES;
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
        CXLog(@"[url] %@ selected=%@ reload=%d", bundleID, cid, running);
        BOOL wasInternal = CXInternalOpen;
        CXInternalOpen = YES;
        [CXCraneBridge switchBundleID:bundleID toContainer:cid reload:running completion:^(BOOL ok) {
            if (!ok) { CXInternalOpen = wasInternal; CXLog(@"[url] %@ switch failed", bundleID); return; }
            CXRememberNoteLaunch(bundleID, cid);
            if (proceed) proceed();
            if (!running) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    CXInternalOpen = wasInternal; });
                return;
            }
            // 重载过的进程要等它真正起来再补投，否则又只落主界面
            __block NSInteger tries = 0;
            __block void (^poll)(void);
            poll = ^{
                if (++tries > 12) { CXInternalOpen = wasInternal; return; }
                if (CXAppRunning(bundleID)) {
                    CXReplayURL(incoming);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                        CXInternalOpen = wasInternal; });
                } else {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.25 * NSEC_PER_SEC), dispatch_get_main_queue(), poll);
                }
            };
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.4 * NSEC_PER_SEC), dispatch_get_main_queue(), poll);
        }];
    };
    [host presentViewController:chooser animated:YES completion:nil];
    return YES;
}

// 旧调用点：选完由本函数自己开窗
static void CXPromptContainerThenOpen(NSString *bundleID, void (^cancel)(void)) {
    if (CXPromptForURL(bundleID, ^{ CXOpenInSplit(bundleID); })) return;
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
    [CXCraneBridge switchBundleID:bundleID toContainer:containerID reload:YES completion:^(BOOL ok) {
    CXLog(@"[hit] %@ switch=%d", bundleID, ok);
    if (!ok) { CXLog(@"[hit] switch failed, skip opening wrong account"); return; }
    CXRememberNoteLaunch(bundleID, containerID);
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
    CXRememberNoteLaunch(identifier, @"DEFAULT");
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
        if (CXPromptForURL(real, ^{ CXOrigPrepareWindow(self, _cmd, bundleID, wasFullscreen, completion); })) return;
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
        if (CXPromptForURL(real, ^{ cont(cls, _cmd, argument); })) return;
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
    if (bundle.length && [view isKindOfClass:UIView.class])
        CXRememberBindOpen(self, view, bundle, container);
    if (CXOrigOpenApp) CXOrigOpenApp(self, _cmd, app, view, overlay, completion);
    // 原 completion 原样传回，不猜 block 内部签名；只在原开窗之后有限重试。
    if (bundle.length) CXRememberApplySoon(bundle, container);
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
    CXRememberStart();
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
    });
}