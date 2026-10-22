// CXRemember.m
//
// 分屏窗口大小记忆：按「应用 + 容器」各记各的。
//   · 调整窗口结束后记录 panelWindow 的宽高
//   · 下次从菜单打开同一账号时，等窗口出来后恢复上次宽高
// 不写任何设置界面，纯自动。
#import "CXRemember.h"
#import "CXPrefs.h"
#import "CXCraneBridge.h"
#import "CXLog.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <math.h>
#include <string.h>
#include <stdlib.h>

static NSString *const CXRememberKey = @"CXRememberSizes";   // { "bundle#container": {w,h,updated} }
static NSString *const CXLastOpenKey  = @"CXLastOpen";       // { bundle, container, at }

#pragma mark - 当前打开上下文

static NSDictionary *CXLastOpen(void) {
    id v = [CXPrefs.shared objectForKey:CXLastOpenKey];
    return [v isKindOfClass:NSDictionary.class] ? v : nil;
}

void CXRememberNoteLaunch(NSString *bundleID, NSString *containerID) {
    if (!bundleID.length || !containerID.length) return;
    [CXPrefs.shared setObject:@{@"bundle": bundleID, @"container": containerID,
                                @"at": @([[NSDate date] timeIntervalSince1970])}
                       forKey:CXLastOpenKey];
}

static NSString *CXKey(NSString *bundle, NSString *container) {
    if (!bundle.length) return nil;
    return [NSString stringWithFormat:@"%@#%@", bundle, container.length ? container : @"DEFAULT"];
}

#pragma mark - 读写记忆

static NSMutableDictionary *CXAllSizes(void) {
    id v = [CXPrefs.shared objectForKey:CXRememberKey];
    return [v isKindOfClass:NSDictionary.class] ? [v mutableCopy] : [NSMutableDictionary dictionary];
}

static NSDictionary *CXSizeFor(NSString *bundle, NSString *container) {
    NSString *key = CXKey(bundle, container);
    if (!key) return nil;
    id v = CXAllSizes()[key];
    return [v isKindOfClass:NSDictionary.class] ? v : nil;
}

static void CXStoreSize(NSString *bundle, NSString *container, CGSize size) {
    NSString *key = CXKey(bundle, container);
    if (!key || size.width < 40 || size.height < 40) return;
    if (size.width > 5000 || size.height > 5000) return;
    NSMutableDictionary *all = CXAllSizes();
    NSDictionary *old = all[key];
    if ([old isKindOfClass:NSDictionary.class]) {
        double ow = [old[@"w"] doubleValue], oh = [old[@"h"] doubleValue];
        if (fabs(ow - size.width) < 0.5 && fabs(oh - size.height) < 0.5) return;   // 没变不写
    }
    all[key] = @{@"w": @(size.width), @"h": @(size.height),
                 @"updated": @([[NSDate date] timeIntervalSince1970])};
    [CXPrefs.shared setObject:all forKey:CXRememberKey];
    CXLog(@"[remember] store %@ %.0fx%.0f", key, size.width, size.height);
}

#pragma mark - PXPanelEntry 辅助

static id CXEntryIvarObject(id obj, const char *name) {
    if (!obj) return nil;
    Ivar ivar = class_getInstanceVariable([obj class], name);
    if (!ivar) {
        unsigned int count = 0;
        Ivar *list = class_copyIvarList([obj class], &count);
        for (unsigned int i = 0; i < count && !ivar; i++)
            if (strcmp(ivar_getName(list[i]), name) == 0) ivar = list[i];
        free(list);
    }
    if (!ivar) return nil;
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || type[0] != '@') return nil;
    return object_getIvar(obj, ivar);
}

static NSString *CXEntryBundle(id entry) {
    id v = CXEntryIvarObject(entry, "hostedBundleID");
    if ([v isKindOfClass:NSString.class] && [v length]) return v;
    id b = CXEntryIvarObject(entry, "bundleID");
    return [b isKindOfClass:NSString.class] ? b : nil;
}

static UIWindow *CXEntryPanelWindow(id entry) {
    id w = CXEntryIvarObject(entry, "panelWindow");
    return [w isKindOfClass:UIWindow.class] ? w : nil;
}

static NSString *CXEntryContainer(id entry) {
    NSString *bundle = CXEntryBundle(entry);
    if (!bundle.length) return @"DEFAULT";
    // 以 Crane 当前活动容器为准：所有窗口（普通应用或分身）都按实际账号记
    NSString *active = [CXCraneBridge activeContainerForBundleID:bundle];
    if (active.length) return active;
    NSDictionary *last = CXLastOpen();
    if ([last[@"bundle"] isEqual:bundle]) {
        id c = last[@"container"];
        if ([c isKindOfClass:NSString.class] && [c length]) return c;
    }
    return @"DEFAULT";
}

static UIWindow *CXFindPanelWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            NSString *name = NSStringFromClass(w.class);
            if ([name.lowercaseString containsString:@"panelwindow"]) return w;
        }
    }
    return nil;
}

// PXPanelEntry 单例：init 钩子没赶上时，从 handle 窗口的响应链里找
static id CXFindPanelEntry(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            NSString *name = NSStringFromClass(w.class);
            if (![name containsString:@"PXHandleWindow"]) continue;
            UIResponder *r = w.nextResponder;
            for (int i = 0; i < 10 && r; i++, r = r.nextResponder) {
                if ([NSStringFromClass(r.class) isEqualToString:@"PXPanelEntry"]) return (id)r;
            }
        }
    }
    return nil;
}

#pragma mark - 捕获（缩放结束 / 关闭）

static id CXRememberEntry = nil;

static void (*CXOrigApplyResizePreview)(id, SEL);
static void (*CXOrigCloseTapped)(id, SEL);

static void CXCapture(id entry) {
    if (!entry) return;
    NSString *bundle = CXEntryBundle(entry);
    if (!bundle.length) return;
    UIWindow *window = CXEntryPanelWindow(entry) ?: CXFindPanelWindow();
    if (!window) return;
    id fullscreen = CXEntryIvarObject(entry, "fullscreenToWindowInProgress");
    if ([fullscreen respondsToSelector:@selector(boolValue)] && [fullscreen boolValue]) return;
    CGRect f = window.frame;
    CXStoreSize(bundle, CXEntryContainer(entry), f.size);
}

static void CXApplyResizePreview(id self, SEL _cmd) {
    if (CXOrigApplyResizePreview) CXOrigApplyResizePreview(self, _cmd);
    CXCapture(self);
}

static void CXCloseTapped(id self, SEL _cmd) {
    CXCapture(self);
    if (CXOrigCloseTapped) CXOrigCloseTapped(self, _cmd);
}

#pragma mark - 恢复

static void CXApplySize(id entry, NSString *bundle, NSString *container) {
    NSDictionary *saved = CXSizeFor(bundle, container);
    if (!saved) return;
    CGFloat w = [saved[@"w"] doubleValue], h = [saved[@"h"] doubleValue];
    if (w < 40 || h < 40) return;
    UIWindow *window = CXEntryPanelWindow(entry) ?: CXFindPanelWindow();
    if (!window) return;
    CGRect f = window.frame;
    CGRect screen = UIScreen.mainScreen.bounds;
    CGFloat cx = CGRectGetMidX(f), cy = CGRectGetMidY(f);
    CGRect target = CGRectMake(cx - w / 2.0, cy - h / 2.0, w, h);
    if (CGRectGetMaxX(f) > screen.size.width - 2) target.origin.x = screen.size.width - w;
    if (target.origin.x < 0) target.origin.x = 0;
    if (target.origin.y < 0) target.origin.y = 0;
    if (CGRectGetMaxY(target) > screen.size.height) target.origin.y = screen.size.height - h;
    window.frame = target;
    CXLog(@"[remember] apply %@#%@ %.0fx%.0f", bundle, container, w, h);
}

void CXRememberApplySoon(NSString *bundleID, NSString *containerID) {
    if (!bundleID.length || !containerID.length) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id entry = CXRememberEntry ?: CXFindPanelEntry();
        if (!entry) { CXLog(@"[remember] 找不到 PXPanelEntry，跳过恢复"); return; }
        CXApplySize(entry, bundleID, containerID);
    });
}

#pragma mark - 安装

static void CXInstallRememberHooks(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class cls = NSClassFromString(@"PXPanelEntry");
    if (!cls) return;

    SEL initSel = NSSelectorFromString(@"init");
    Method initMethod = class_getInstanceMethod(cls, initSel);
    if (initMethod) {
        typedef id (*InitFn)(id, SEL);
        static InitFn origInit;
        IMP newInit = imp_implementationWithBlock(^id(id self) {
            id result = origInit ? origInit(self, initSel) : self;
            CXRememberEntry = result;
            return result;
        });
        origInit = (InitFn)method_setImplementation(initMethod, newInit);
    }

    struct { const char *name; IMP imp; IMP *orig; } hooks[] = {
        {"applyResizePreview", (IMP)CXApplyResizePreview, (IMP *)&CXOrigApplyResizePreview},
        {"closeTapped", (IMP)CXCloseTapped, (IMP *)&CXOrigCloseTapped},
    };
    for (size_t i = 0; i < sizeof(hooks)/sizeof(hooks[0]); i++) {
        SEL sel = NSSelectorFromString([NSString stringWithUTF8String:hooks[i].name]);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) continue;
        NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)];
        if (!sig || sig.numberOfArguments != 2) continue;
        *hooks[i].orig = (IMP)method_setImplementation(m, hooks[i].imp);
        CXLog(@"[remember] hook %s ok", hooks[i].name);
    }
    installed = YES;
}

void CXRememberStart(void) {
    CXInstallRememberHooks();
}
