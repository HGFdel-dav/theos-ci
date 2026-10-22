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

typedef void (*CXHookFn)(Class, SEL, IMP, IMP *);

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

#pragma mark - 打开分屏窗口（真实 bundle）

static void CXOpenInSplit(NSString *bundleID) {
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
        CXLog(@"[hit] %@ switch=%d, opening split", bundleID, ok);
        CXOpenInSplit(bundleID);
    }];
    return YES;
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
    if (!item) { CXOrigPrepareWindow(self, _cmd, bundleID, wasFullscreen, completion); return; }
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
    if (!item) { cont(cls, _cmd, argument); return; }
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
    CXLog(@"[trace] openApplication app=%@(%@) view=%@(%@) overlay=%@(%@)",
          app, NSStringFromClass([app class]), view, NSStringFromClass([view class]),
          overlay, NSStringFromClass([overlay class]));
    if (CXOrigOpenApp) CXOrigOpenApp(self, _cmd, app, view, overlay, completion);
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

static void CXInstallAll(void) {
    CXInstallPanelEntryHooks();
    CXInstallBridgeHooks();
}

#pragma mark - 配置同步

static void CXSyncMenu(void) {
    @try { [CXMenuInjector sync]; }
    @catch (__unused NSException *e) { CXLog(@"[menu] sync 异常"); }
}

static void CXPreferencesChanged(CFNotificationCenterRef center, void *observer,
                                 CFStringRef name, const void *object,
                                 CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{ CXSyncMenu(); });
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
        CXSyncMenu();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, CXPreferencesChanged,
                                        CFSTR("com.niubiprass.clonex/changed"),
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    });
}