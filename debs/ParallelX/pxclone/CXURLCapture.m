// CXURLCapture.m — 最小化应用侧 URL 捕获，仅写入共享 CX 偏好。
// 不改变应用 UI、不拦截原调用；SpringBoard 的 CloneX 负责选择账号与分屏路由。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>
#include <string.h>
#include <dlfcn.h>
#include <notify.h>
#import "CXLog.h"

typedef void (*CXURLHookFn)(Class, SEL, IMP, IMP *);

static NSString *const CXURLDomain = @"com.niubiprass.clonex";
static void (*CXURLOrigOpen)(id, SEL, id, id, id);
static BOOL (*CXURLOrigLegacy)(id, SEL, id);
static void (*CXURLOrigWorkspaceOpen)(id, SEL, id, id);
static void (*CXURLOrigWorkspaceSensitive)(id, SEL, id, id);
static id (*CXURLOrigContextInit)(id, SEL, id, id);

static void CXURLStore(id value) {
    if (![value isKindOfClass:NSURL.class]) return;
    NSURL *url = value;
    CXLog(@"[url] app-captured bundle=%@ scheme=%@ host=%@",
          NSBundle.mainBundle.bundleIdentifier ?: @"?", url.scheme ?: @"", url.host ?: @"");
    CFStringRef domain = (__bridge CFStringRef)CXURLDomain;
    CFPreferencesSetAppValue(CFSTR("CXSharedURL"), (__bridge CFStringRef)url.absoluteString, domain);
    CFPreferencesSetAppValue(CFSTR("CXSharedURLAt"),
                              (__bridge CFPropertyListRef)@([NSDate date].timeIntervalSince1970), domain);
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
    CFPreferencesSetAppValue(CFSTR("CXSharedURLBundle"), (__bridge CFStringRef)bundleID, domain);
    CFPreferencesAppSynchronize(domain);
    notify_post("com.niubiprass.clonex/url");
}

static void CXURLOpen(id self, SEL cmd, id url, id options, id completion) {
    CXURLStore(url);
    if (CXURLOrigOpen) CXURLOrigOpen(self, cmd, url, options, completion);
}
static BOOL CXURLLegacy(id self, SEL cmd, id url) {
    CXURLStore(url);
    return CXURLOrigLegacy ? CXURLOrigLegacy(self, cmd, url) : NO;
}
static void CXURLWorkspace(id self, SEL cmd, id url, id options) {
    CXURLStore(url);
    if (cmd == NSSelectorFromString(@"openSensitiveURL:withOptions:")) {
        if (CXURLOrigWorkspaceSensitive) CXURLOrigWorkspaceSensitive(self, cmd, url, options);
    } else if (CXURLOrigWorkspaceOpen) CXURLOrigWorkspaceOpen(self, cmd, url, options);
}
static id CXURLOpenURLContextInit(id self, SEL cmd, id url, id options) {
    CXURLStore(url);
    return CXURLOrigContextInit ? CXURLOrigContextInit(self, cmd, url, options) : self;
}

static BOOL CXURLObjectArg(NSMethodSignature *sig, NSUInteger index) {
    return sig && index < sig.numberOfArguments && [sig getArgumentTypeAtIndex:index][0] == '@';
}

__attribute__((constructor)) static void CXURLCaptureInit(void) {
    @autoreleasepool {
        Class app = UIApplication.class;
        SEL open = NSSelectorFromString(@"openURL:options:completionHandler:");
        Method m = class_getInstanceMethod(app, open);
        NSMethodSignature *sig = m ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)] : nil;
        void *sym = dlsym(RTLD_DEFAULT, "MSHookMessageEx");
        if (sym && sig && sig.numberOfArguments == 5 && CXURLObjectArg(sig, 2)) {
            ((void (*)(Class, SEL, IMP, IMP *))sym)(app, open, (IMP)CXURLOpen, (IMP *)&CXURLOrigOpen);
        }
        SEL legacy = NSSelectorFromString(@"openURL:");
        m = class_getInstanceMethod(app, legacy);
        sig = m ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)] : nil;
        if (sym && sig && sig.numberOfArguments == 3 && CXURLObjectArg(sig, 2))
            ((void (*)(Class, SEL, IMP, IMP *))sym)(app, legacy, (IMP)CXURLLegacy, (IMP *)&CXURLOrigLegacy);

        Class context = NSClassFromString(@"UIOpenURLContext");
        SEL contextSel = NSSelectorFromString(@"initWithURL:options:");
        m = context ? class_getInstanceMethod(context, contextSel) : NULL;
        sig = m ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)] : nil;
        if (sym && sig && sig.numberOfArguments == 4 && CXURLObjectArg(sig, 2) && CXURLObjectArg(sig, 3)) {
            CXURLOrigContextInit = (id (*)(id, SEL, id, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)CXURLOpenURLContextInit);
        }

        if (!sym) CXLog(@"[url] app hook unavailable bundle=%@", NSBundle.mainBundle.bundleIdentifier ?: @"?");
        Class workspace = NSClassFromString(@"LSApplicationWorkspace");
        if (!sym || !workspace) return;
        SEL selectors[] = { NSSelectorFromString(@"openURL:withOptions:"),
                            NSSelectorFromString(@"openSensitiveURL:withOptions:") };
        for (NSUInteger i = 0; i < 2; i++) {
            m = class_getInstanceMethod(workspace, selectors[i]);
            sig = m ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)] : nil;
            if (!sig || sig.numberOfArguments != 4 || !CXURLObjectArg(sig, 2) || !CXURLObjectArg(sig, 3)) continue;
            IMP *orig = i == 0 ? (IMP *)&CXURLOrigWorkspaceOpen : (IMP *)&CXURLOrigWorkspaceSensitive;
            ((void (*)(Class, SEL, IMP, IMP *))sym)(workspace, selectors[i], (IMP)CXURLWorkspace, orig);
        }
    }
}
