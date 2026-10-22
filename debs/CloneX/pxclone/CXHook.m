// CXHook.m
//
// CloneX 主注入层（仅 SpringBoard）。
//
// 目标：ParallelX 的「菜单 → 打开应用图标 → 分屏窗口」链路在开窗前先把
// Crane 容器切到用户给该应用选的分身。PX 是闭源 Swift，方案是钩它的
// ObjC 可见漏斗，而不是改它：
//
//   ① -[PXSceneBridge prepareWindowForBundleID:wasFullscreen:completion:]
//      真正"为某应用准备分屏窗口"的入口（反汇编 0x39574 处 objc_msgSend，
//      selref 槽 0x87560）。菜单点图标最终走这里，所以以它为主钩子。
//   ② +[PXPanelEntry applicationActivated:] / +externalOpenApplication:
//      外部唤起入口（v24@0:8@16，Twin 0.1.0 起验证过）。兜底覆盖。
//
// 所有 hook 安装前都做运行时签名核验：签名不符就跳过并写日志，绝不硬上。
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import "CXCraneBridge.h"
#import "CXPrefs.h"
#import "CXLog.h"
#include <string.h>
#include <stdlib.h>

typedef void (*CXHookFn)(Class, SEL, IMP, IMP *);

#pragma mark - 防重复处理

// 同一次菜单点击可能先后经过多个入口；记录最近处理过的 bundleID，
// 1.5 秒内不再重复切容器。
static NSMutableDictionary<NSString *, NSDate *> *CXRecentHandles(void) {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

static BOOL CXHandledRecently(NSString *bundleID) {
    if (!bundleID.length) return NO;
    @synchronized (CXRecentHandles()) {
        NSDate *date = CXRecentHandles()[bundleID];
        if (!date) return NO;
        if (-[date timeIntervalSinceNow] > 1.5) {
            [CXRecentHandles() removeObjectForKey:bundleID];
            return NO;
        }
        return YES;
    }
}

static void CXMarkHandled(NSString *bundleID) {
    if (!bundleID.length) return;
    @synchronized (CXRecentHandles()) {
        CXRecentHandles()[bundleID] = NSDate.date;
    }
}

#pragma mark - 通用：按配置准备容器

// 返回 YES 表示已接管（稍后会带 orig 继续）；NO 表示应立即原样放行。
static BOOL CXShouldDefer(NSString *bundleID) {
    if (![bundleID isKindOfClass:NSString.class] || !bundleID.length) return NO;
    NSString *container = [CXPrefs.shared containerForBundleID:bundleID];
    if (!container.length || [container isEqualToString:@"DEFAULT"]) return NO;
    if (CXHandledRecently(bundleID)) return NO;
    return YES;
}

#pragma mark - ① PXSceneBridge prepareWindowForBundleID:wasFullscreen:completion:

static void (*CXOrigPrepareWindow)(id, SEL, id, BOOL, id);

static void CXPrepareWindow(id self, SEL _cmd, id bundleID, BOOL wasFullscreen, id completion) {
    if (!CXOrigPrepareWindow) return;
    if (!CXShouldDefer(bundleID)) { CXOrigPrepareWindow(self, _cmd, bundleID, wasFullscreen, completion); return; }
    NSString *container = [CXPrefs.shared containerForBundleID:bundleID];
    CXMarkHandled(bundleID);
    CXLog(@"[hook] prepareWindow %@ -> container %@", bundleID, container);
    [CXCraneBridge prepareLaunchForBundleID:bundleID containerID:container completion:^(BOOL ok) {
        // 失败（用户取消认证 / 容器核验不符）也继续原流程：
        // PX 的 completion 必须被调用，否则窗口准备会卡在中间态。
        CXLog(@"[hook] prepareWindow %@ switch=%d continue=%d", bundleID, ok, 1);
        CXOrigPrepareWindow(self, _cmd, bundleID, wasFullscreen, completion);
    }];
}

#pragma mark - ② PXPanelEntry 类方法（外部唤起兜底）

static void (*CXOrigActivated)(Class, SEL, id);
static void (*CXOrigExternalOpen)(Class, SEL, id);

static void CXHandlePanelEntry(Class cls, SEL _cmd, id bundleID, void (*cont)(Class, SEL, id)) {
    if (!CXShouldDefer(bundleID)) { cont(cls, _cmd, bundleID); return; }
    NSString *container = [CXPrefs.shared containerForBundleID:bundleID];
    CXMarkHandled(bundleID);
    CXLog(@"[hook] %@ %@ -> container %@", NSStringFromSelector(_cmd), bundleID, container);
    [CXCraneBridge prepareLaunchForBundleID:bundleID containerID:container completion:^(BOOL ok) {
        CXLog(@"[hook] %@ %@ switch=%d continue=1", NSStringFromSelector(_cmd), bundleID, ok);
        cont(cls, _cmd, bundleID);
    }];
}

static void CXActivated(Class cls, SEL _cmd, id bundleID) {
    if (!CXOrigActivated) return;
    CXHandlePanelEntry(cls, _cmd, bundleID, CXOrigActivated);
}

static void CXExternalOpen(Class cls, SEL _cmd, id bundleID) {
    if (!CXOrigExternalOpen) return;
    CXHandlePanelEntry(cls, _cmd, bundleID, CXOrigExternalOpen);
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

// 类方法签名核验：返回 meta 上的 Method（不存在或不符返回 NULL）
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

static void CXInstallBridgeHook(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class cls = NSClassFromString(@"PXSceneBridge");
    if (!cls) return;
    CXHookFn hook = CXMSHookMessageEx();
    if (!hook) return;
    SEL sel = NSSelectorFromString(@"prepareWindowForBundleID:wasFullscreen:completion:");
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) { CXLog(@"[hook] PXSceneBridge prepareWindow 不存在（PX 版本差异），仅用入口钩子"); return; }
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    BOOL ok = sig && sig.numberOfArguments == 5 &&
              strcmp(sig.methodReturnType, @encode(void)) == 0 &&
              CXTypecodeEqual([sig getArgumentTypeAtIndex:2], @encode(id)) &&
              CXTypecodeEqual([sig getArgumentTypeAtIndex:3], @encode(BOOL)) &&
              [sig getArgumentTypeAtIndex:4][0] == '@';
    if (!ok) {
        CXLog(@"[hook] prepareWindow 签名 %s 核验未通过，跳过",
             sig ? method_getTypeEncoding(method) : "?");
        return;
    }
    hook(cls, sel, (IMP)CXPrepareWindow, (IMP *)&CXOrigPrepareWindow);
    installed = CXOrigPrepareWindow != NULL;
    CXLog(@"[hook] PXSceneBridge prepareWindow installed=%d", installed);
}

static void CXInstallAll(void) {
    CXInstallPanelEntryHooks();
    CXInstallBridgeHook();
}

#pragma mark - 载入时机

static void CXImageAdded(const struct mach_header *header, intptr_t slide) {
    Dl_info info = {0};
    if (!dladdr(header, &info) || !info.dli_fname) return;
    NSString *path = [NSString stringWithUTF8String:info.dli_fname];
    if (![path.lastPathComponent isEqualToString:@"ParallelX.dylib"]) return;
    // dyld 回调里不能解析 ObjC 类；抛回主队列
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
        CXInstallAll();   // PX 可能早已加载（构造函数晚于 dyld 通知）
    });
}
