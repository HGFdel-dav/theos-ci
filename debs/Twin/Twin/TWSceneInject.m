// TWSceneInject.m
// 把"四角热区视图"注入到 App 的 scene 呈现层里。
//
// 为什么必须这么做：
// SpringBoard 自己的窗口和前台 App 的窗口属于不同 scene。App 在前台时，
// App 的 scene 盖在 SpringBoard 的 scene 之上，SpringBoard 窗口根本收不到触摸
// —— 表现就是"桌面能划出来，进了 App 就划不出来"。
// ScreenCore（原版，本机可用）也是往 _UIScenePresentationView 里插视图，
// 这里照它的结构做：hook 该视图的 layoutSubviews，在四个角落各放一个
// 66×66 的小视图，只覆盖角落，不遮挡 App 主体内容，也不吃中间区域的触摸。
#import "TWSceneInject.h"
#import "TWArcCoordinator.h"
#import "TWPrefs.h"
#import "TWPath.h"
#import "TWRuntimeLog.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>

static const void *TWHotViewKey = "TWSceneHotViews";

static void (*TWOrigPresentationLayout)(id, SEL);

static void TWPresentationLayout(id self, SEL _cmd) {
    TWOrigPresentationLayout(self, _cmd);
    @try {
        [TWArcCoordinator ensureCornerViewsInPresentationView:(UIView *)self];
    } @catch (__unused NSException *e) { }
}

void TWSceneInjectStart(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class cls = NSClassFromString(@"_UIScenePresentationView");
    if (!cls) {
        TWRuntimeLog(@"[inject] _UIScenePresentationView 不存在，跳过 App 内注入");
        return;
    }
    SEL sel = sel_registerName("layoutSubviews");
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    typedef void (*Hook)(Class, SEL, IMP, IMP *);
    Hook hook = (Hook)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (!hook) return;
    hook(cls, sel, (IMP)TWPresentationLayout, (IMP *)&TWOrigPresentationLayout);
    installed = TWOrigPresentationLayout != NULL;
    TWRuntimeLog(@"[inject] _UIScenePresentationView 注入%@", installed ? @"成功" : @"失败");
}

// 由协调器调用：按当前的唤醒方式/角落设置，维护 presentation view 上的热区。
void TWSceneInjectSync(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        [TWArcCoordinator ensureCornerViewsInPresentationView:window];
    }
}
