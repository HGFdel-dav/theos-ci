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

// 注入过热区的宿主视图（弱引用）。面板改了设置后要靠这个名单回头重画，
// 否则注入视图不重新布局时颜色/尺寸就不会更新（调试橙块关不掉就是这么来的）。
static NSHashTable *TWHotHosts(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

static void (*TWOrigPresentationLayout)(id, SEL);

static void TWPresentationLayout(id self, SEL _cmd) {
    TWOrigPresentationLayout(self, _cmd);
    @try {
        [TWHotHosts() addObject:self];
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
// 除了窗口，还要把「之前注入过的宿主视图」全部重刷一遍——面板改设置
// （比如关掉调试模式）时，它们不会自己重新布局，不重刷就会留着旧颜色。
void TWSceneInjectSync(void) {
    for (UIView *host in [TWHotHosts() allObjects]) {
        if (![host isKindOfClass:UIView.class]) continue;
        @try {
            [TWArcCoordinator ensureCornerViewsInPresentationView:host];
        } @catch (__unused NSException *e) { }
    }
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        [TWArcCoordinator ensureCornerViewsInPresentationView:window];
    }
}
