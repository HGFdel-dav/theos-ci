#import "PXCloneURLRouter.h"
#import "PXCloneCrane.h"
#import "PXCloneRuntime.h"
#import "PXCloneProbe.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

// SpringBoard hands an external "open this app with this URL" request to
// FBSystemService before the app is launched. When the target bundle has more
// than one Crane container we show an account chooser, make the chosen account
// the active container, and only then let the original request run - so the app
// the system launches for the URL is the account the user picked.
//
// The catalog is refreshed on demand, but a request can arrive before the
// first asynchronous refresh has completed. Never fall through to the
// current account in that window: the URL must wait for a complete catalog.
static NSTimeInterval const PXURLRouterPollInterval = 0.2;
static NSUInteger const PXURLRouterPollLimit = 25;
static NSTimeInterval const PXURLRouterCatalogWaitInterval = 0.1;
static NSUInteger const PXURLRouterCatalogWaitLimit = 50;
static NSTimeInterval const PXURLRouterRefreshThrottle = 1.0;
static UIWindow *PXURLRouterWindow = nil;
static NSTimeInterval PXURLRouterLastRefresh = 0;
static BOOL PXURLRouterCatalogLoading = NO;
static BOOL PXURLRouterCatalogReady = NO;
// Last account per bundle: repeat jumps of the same app must not ask again.
static NSMutableDictionary<NSString *, NSString *> *PXURLRouterLastChoice;
static NSMutableDictionary<NSString *, NSNumber *> *PXURLRouterLastChoiceAt;
static NSTimeInterval const PXURLRouterChoiceTTL = 600.0;

static NSString *PXURLRouterString(id object, NSArray<NSString *> *keys) {
    if (!object) return nil;
    for (NSString *key in keys) {
        SEL selector = NSSelectorFromString(key);
        if (![object respondsToSelector:selector]) continue;
        id value = nil;
        @try { value = [object valueForKey:key]; }
        @catch (NSException *exception) { (void)exception; continue; }
        if ([value isKindOfClass:NSString.class] && [(NSString *)value length]) return value;
    }
    return nil;
}

static id PXURLRouterValue(id object, NSString *key) {
    if (!object || !key.length) return nil;
    SEL selector = NSSelectorFromString(key);
    if (![object respondsToSelector:selector]) return nil;
    @try { return [object valueForKey:key]; }
    @catch (NSException *exception) { (void)exception; return nil; }
}

static NSArray<NSDictionary *> *PXURLRouterContainers(NSString *bundle) {
    for (NSDictionary *entry in PXCloneCrane.cachedCatalog) {
        if (![entry[@"bundle"] isKindOfClass:NSString.class]) continue;
        if (![(NSString *)entry[@"bundle"] isEqualToString:bundle]) continue;
        id containers = entry[@"containers"];
        return [containers isKindOfClass:NSArray.class] ? containers : @[];
    }
    return @[];
}

// A request may be observed more than once; the original call must happen
// exactly once no matter which path finishes first. Blocks are not objects
// Clang accepts in @synchronized, so a dedicated NSObject is the lock.
static void (^PXURLRouterOnce(void (^proceed)(void)))(void) {
    __block BOOL done = NO;
    NSObject *lock = [NSObject new];
    // A block RETURNED from a function is on the stack unless copied; the
    // alert keeps it past this frame (crash: objc_retain at 0x20).
    return [^{
        @synchronized (lock) {
            if (done) return;
            done = YES;
        }
        if (proceed) proceed();
    } copy];
}

@interface PXCloneURLRouter ()
+ (void)loadCatalogForRequest:(id)request proceed:(void (^)(void))proceed
                      bundle:(NSString *)bundle attempt:(NSUInteger)attempt;
+ (void)activateContainer:(NSString *)container bundle:(NSString *)bundle
                  proceed:(void (^)(void))proceed;
+ (void)waitForContainer:(NSString *)container bundle:(NSString *)bundle
                 attempt:(NSUInteger)attempt proceed:(void (^)(void))proceed;
+ (void)waitForTermination:(NSString *)bundle attempt:(NSUInteger)attempt
                  proceed:(void (^)(void))proceed container:(NSString *)container;
+ (void)showRoutingError:(NSString *)message;
@end

static void PXURLRouterRefreshCatalog(void) {
    if (PXURLRouterCatalogLoading) return;
    PXURLRouterCatalogLoading = YES;
    PXURLRouterLastRefresh = NSDate.date.timeIntervalSince1970;
    [PXCloneCrane refreshCatalogWithCompletion:^(NSArray<NSDictionary *> *catalog, NSError *error) {
        PXURLRouterCatalogLoading = NO;
        PXURLRouterCatalogReady = (catalog != nil && error == nil);
    }];
}

static NSString *PXURLRouterBundleFromRequest(id request) {
    // SBWorkspace hands the bundle identifier itself, as a plain string.
    if ([request isKindOfClass:NSString.class] && [(NSString *)request length]) return request;
    NSString *bundle = PXURLRouterString(request,
        @[@"applicationIdentifier", @"bundleIdentifier", @"targetApplicationIdentifier"]);
    if (bundle.length) return bundle;

    id target = nil;
    for (NSString *key in @[@"target", @"application", @"applicationProxy"]) {
        target = PXURLRouterValue(request, key);
        if (target) break;
    }
    if (!target) return nil;
    return PXURLRouterString(target, @[@"bundleIdentifier", @"bundleID", @"applicationIdentifier"]);
}
// An app-originated open (the normal payment flow) already picked an account
// and forwarded; SpringBoard will see the same URL a moment later and must not
// prompt a second time.
static NSTimeInterval PXURLRouterLastAppHandoff = 0;
static NSTimeInterval const PXURLRouterHandoffWindow = 8.0;

static id PXURLRouterWorkspace(void) {
    Class workspace = NSClassFromString(@"LSApplicationWorkspace");
    SEL shared = NSSelectorFromString(@"defaultWorkspace");
    if (!PXCloneClassMethodMatches(workspace, shared, @encode(id), @[], NULL)) return nil;
    return ((id (*)(id, SEL))objc_msgSend)((id)workspace, shared);
}

static NSString *PXURLRouterProxyBundle(id proxy) {
    if (!proxy) return nil;
    for (NSString *key in @[@"bundleIdentifier", @"bundleID", @"applicationIdentifier"]) {
        SEL selector = NSSelectorFromString(key);
        if (![proxy respondsToSelector:selector]) continue;
        id value = nil;
        @try { value = [proxy valueForKey:key]; }
        @catch (NSException *exception) { (void)exception; continue; }
        if ([value isKindOfClass:NSString.class] && [(NSString *)value length]) return value;
    }
    return nil;
}

// Ask LaunchServices which app a scheme belongs to. Both selectors exist on
// different iOS builds; either answer is enough, no scheme table is hardcoded.
static NSString *PXURLRouterBundleForURL(NSURL *url) {
    if (!url) return nil;
    id workspace = PXURLRouterWorkspace();
    if (!workspace) return nil;
    SEL single = NSSelectorFromString(@"applicationForURL:");
    if (PXCloneInstanceMethodMatches(workspace, single, @encode(id), @[@"@"])) {
        id proxy = nil;
        @try { proxy = ((id (*)(id, SEL, id))objc_msgSend)(workspace, single, url); }
        @catch (__unused NSException *exception) { proxy = nil; }
        NSString *bundle = PXURLRouterProxyBundle(proxy);
        if (bundle.length) return bundle;
    }
    SEL many = NSSelectorFromString(@"applicationsForOpeningURL:");
    if (PXCloneInstanceMethodMatches(workspace, many, @encode(id), @[@"@"])) {
        id list = nil;
        @try { list = ((id (*)(id, SEL, id))objc_msgSend)(workspace, many, url); }
        @catch (__unused NSException *exception) { list = nil; }
        if ([list isKindOfClass:NSArray.class] && [list count]) {
            NSString *bundle = PXURLRouterProxyBundle(((NSArray *)list).firstObject);
            if (bundle.length) return bundle;
        }
    }
    return nil;
}

// Only payment handoffs should ask. Everything else (plain links, app-to-app
// browsing) keeps the current account silently.
static BOOL PXURLRouterLooksLikePayment(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString;
    for (NSString *pay in @[@"weixin", @"wechat", @"wxpay", @"tenpay",
                            @"alipay", @"alipays", @"alipayqr", @"alipayobject",
                            @"mqqapi", @"mqqwallet", @"upwallet", @"uppay",
                            @"unionpay", @"wallet", @"bank"]) {
        if ([scheme isEqualToString:pay]) return YES;
    }
    NSString *text = url.absoluteString.lowercaseString;
    for (NSString *hint in @[@"pay", @"cashier", @"trade", @"wxpay", @"tenpay",
                             @"alipay", @"alipays", @"unionpay", @"uppay",
                             @"收银台", @"支付", @"付款", @"收款", @"转账", @"prepay"]) {
        if ([text containsString:hint]) return YES;
    }
    return NO;
}

static BOOL PXURLRouterSchemeIsWeb(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString;
    if (!scheme.length) return YES;
    for (NSString *web in @[@"http", @"https", @"about", @"file", @"data", @"javascript"]) {
        if ([scheme isEqualToString:web]) return YES;
    }
    return NO;
}

@implementation PXCloneURLRouter

+ (NSString *)rememberedChoiceForBundle:(NSString *)bundle {
    if (!bundle.length) return nil;
    NSNumber *when = PXURLRouterLastChoiceAt[bundle];
    if (!when || NSDate.date.timeIntervalSince1970 - when.doubleValue > PXURLRouterChoiceTTL) return nil;
    return PXURLRouterLastChoice[bundle];
}

+ (void)rememberChoice:(NSString *)container forBundle:(NSString *)bundle {
    if (!bundle.length || !container.length) return;
    if (!PXURLRouterLastChoice) PXURLRouterLastChoice = [NSMutableDictionary dictionary];
    if (!PXURLRouterLastChoiceAt) PXURLRouterLastChoiceAt = [NSMutableDictionary dictionary];
    PXURLRouterLastChoice[bundle] = container;
    PXURLRouterLastChoiceAt[bundle] = @(NSDate.date.timeIntervalSince1970);
}

+ (BOOL)recentAppHandoff {
    return PXURLRouterLastAppHandoff > 0 &&
           NSDate.date.timeIntervalSince1970 - PXURLRouterLastAppHandoff < PXURLRouterHandoffWindow;
}

+ (void)noteAppHandoff {
    PXURLRouterLastAppHandoff = NSDate.date.timeIntervalSince1970;
}

// Called from every app process for -[UIApplication openURL:options:...].
// Returns YES when the router owns the request and will run `proceed` later.
+ (BOOL)handleOpenURL:(NSURL *)url proceed:(void (^)(void))proceed {
    if (!proceed || !url.absoluteString.length) return NO;

    // Web URLs matter too: a WeChat/Alipay payment handoff is an https
    // universal link, not a scheme. Resolve the owner; only a bundle with
    // several containers is intercepted, everything else keeps normal handling.
    if (PXURLRouterSchemeIsWeb(url) && ![url.scheme.lowercaseString isEqualToString:@"https"]
        && ![url.scheme.lowercaseString isEqualToString:@"http"]) return NO;
    NSString *bundle = PXURLRouterBundleForURL(url);
    [PXCloneProbe log:@"APP-OPEN url=%@ bundle=%@", url.absoluteString, bundle ?: @"(nil)"];
    if (!bundle.length) return NO;
    [PXCloneProbe log:@"APP-OPEN url=%@ bundle=%@", url.absoluteString, bundle ?: @"(nil)"];
    // WebContent and other helpers have their own bundle; only skip when the
    // open would target this very app AND the scheme is ours.
    NSString *own = NSBundle.mainBundle.bundleIdentifier;
    if ([bundle isEqualToString:own] && ![[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/.px-allow-self"]) return NO;

    NSArray<NSDictionary *> *containers = [PXCloneCrane containersForBundle:bundle];
    [PXCloneProbe log:@"APP-CONTAINERS bundle=%@ n=%lu", bundle, (unsigned long)containers.count];
    if (containers.count < 2) return NO;

    if (!PXURLRouterLooksLikePayment(url)) return NO;

    NSString *remembered = [self rememberedChoiceForBundle:bundle];
    if (remembered.length) {
        [PXCloneProbe log:@"REMEMBERED %@ -> %@", bundle, remembered];
        [self activateContainer:remembered bundle:bundle proceed:proceed];
        return YES;
    }

    void (^once)(void) = PXURLRouterOnce(proceed);
    void (^owned)(void) = ^{
        [self noteAppHandoff];
        once();
    };
    void (^present)(void) = ^{
        [self presentChooserForBundle:bundle containers:containers proceed:owned];
    };
    if (NSThread.isMainThread) present();
    else dispatch_async(dispatch_get_main_queue(), present);
    return YES;
}

+ (BOOL)handleOpenRequest:(id)request proceed:(void (^)(void))proceed {
    if (!proceed) return NO;
    if ([self recentAppHandoff]) {
        [PXCloneProbe log:@"SB-SKIP (app already handled)"];
        return NO;
    }
    NSString *bundle = PXURLRouterBundleFromRequest(request);
    [PXCloneProbe log:@"ROUTE bundle=%@ catalog=%lu ready=%d loading=%d", bundle ?: @"(nil)",
        (unsigned long)PXCloneCrane.cachedCatalog.count, (int)PXURLRouterCatalogReady,
        (int)PXURLRouterCatalogLoading];
    if (!bundle.length) return NO;

    void (^once)(void) = PXURLRouterOnce(proceed);
    NSArray<NSDictionary *> *containers = PXURLRouterContainers(bundle);
    if (containers.count >= 2) {
        void (^present)(void) = ^{
            [self presentChooserForBundle:bundle containers:containers proceed:once];
        };
        if (NSThread.isMainThread) present();
        else dispatch_async(dispatch_get_main_queue(), present);
        return YES;
    }

    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (!PXURLRouterCatalogReady || now - PXURLRouterLastRefresh >= PXURLRouterRefreshThrottle)
        PXURLRouterRefreshCatalog();

    // This is an external request, so owning it while the catalog is loading
    // is essential. Falling through here launches the current account before
    // the chooser has a chance to appear.
    [self loadCatalogForRequest:request proceed:once bundle:bundle attempt:0];
    return YES;
}

+ (void)loadCatalogForRequest:(id)request proceed:(void (^)(void))proceed
                      bundle:(NSString *)bundle attempt:(NSUInteger)attempt {
    NSArray<NSDictionary *> *containers = PXURLRouterContainers(bundle);
    if (containers.count >= 2) {
        void (^present)(void) = ^{
            [self presentChooserForBundle:bundle containers:containers proceed:proceed];
        };
        if (NSThread.isMainThread) present();
        else dispatch_async(dispatch_get_main_queue(), present);
        return;
    }
    if (PXURLRouterCatalogReady && !PXURLRouterCatalogLoading) {
        // A completed catalog with one container is a real negative result.
        [PXCloneProbe log:@"PASS-1CONTAINER bundle=%@ n=%lu", bundle, (unsigned long)containers.count];
        proceed();
        return;
    }
    if (attempt >= PXURLRouterCatalogWaitLimit) {
        [PXCloneProbe log:@"WAIT-TIMEOUT bundle=%@", bundle];
        [self showRoutingError:@"账号目录尚未就绪，付款链接未打开，请重试"];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(PXURLRouterCatalogWaitInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self loadCatalogForRequest:request proceed:proceed bundle:bundle attempt:attempt + 1];
    });
}

+ (void)presentChooserForBundle:(NSString *)bundle
                     containers:(NSArray<NSDictionary *> *)containers
                        proceed:(void (^)(void))proceed {
    UIApplication *application = UIApplication.sharedApplication;
    if (!application) { proceed(); return; }

    // Attach to whatever is on screen when possible; a bare key window can be
    // swallowed by the app that is mid-transition.
    // Twin (own repo) does exactly this: walk the existing windows backwards
    // and present on the top controller. A fresh scene-less window stays
    // invisible in SpringBoard and looks like a freeze.
    UIViewController *presenter = nil;
    UIViewController *host = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *candidate in application.windows.reverseObjectEnumerator) {
        if (candidate.hidden || !candidate.rootViewController) continue;
        presenter = candidate.rootViewController;
        while (presenter.presentedViewController) presenter = presenter.presentedViewController;
        break;
    }
#pragma clang diagnostic pop
    if (presenter && [presenter isKindOfClass:UIAlertController.class]) { presenter = nil; }

    UIWindow *window = nil;
    if (!presenter) {
        window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        window.windowLevel = UIWindowLevelAlert + 1;
        host = [UIViewController new];
        host.view.backgroundColor = UIColor.clearColor;
        window.rootViewController = host;
        PXURLRouterWindow = window;
        [window makeKeyAndVisible];
        presenter = host;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSUInteger windowCount = application.windows.count;
#pragma clang diagnostic pop
    [PXCloneProbe log:@"PRESENT via=%@ windows=%lu", window ? @"window" : @"vc",
        (unsigned long)windowCount];

    NSString *active = [PXCloneCrane activeContainerForBundle:bundle];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"选择打开的账号"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    void (^finish)(NSString *, NSString *) = ^(NSString *container, NSString *title) {
        (void)title;
        [alert dismissViewControllerAnimated:YES completion:^{
            window.hidden = YES;
            if (PXURLRouterWindow == window) PXURLRouterWindow = nil;
        }];
        [self activateContainer:container bundle:bundle proceed:proceed];
    };

    for (NSDictionary *entry in containers) {
        NSString *container = entry[@"container"];
        if (![container isKindOfClass:NSString.class] || !container.length) continue;
        NSString *name = [entry[@"name"] isKindOfClass:NSString.class] ? entry[@"name"] : container;
        BOOL isDefault = [entry[@"isDefault"] isKindOfClass:NSNumber.class] && [entry[@"isDefault"] boolValue];
        NSString *title = isDefault ? [NSString stringWithFormat:@"%@（默认）", name] : name;
        if ([container isEqualToString:active]) title = [title stringByAppendingString:@" ✓"];
        UIAlertAction *action = [UIAlertAction actionWithTitle:title
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *selected) {
            [self rememberChoice:container forBundle:bundle];
            finish(container, title);
        }];
        [alert addAction:action];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
                                           handler:^(__unused UIAlertAction *selected) {
        // Cancelling means "do not open it at all"; the original request is
        // intentionally not forwarded.
        [alert dismissViewControllerAnimated:YES completion:^{
            window.hidden = YES;
            if (PXURLRouterWindow == window) PXURLRouterWindow = nil;
        }];
    }]];

    // An action sheet needs an anchor in SpringBoard.
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = presenter.view;
        alert.popoverPresentationController.sourceRect =
            CGRectMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 1, 1);
        alert.popoverPresentationController.permittedArrowDirections = 0;
    }
    [presenter presentViewController:alert animated:YES completion:^{
        if (alert.presentingViewController == nil) {
            [host presentViewController:alert animated:YES completion:nil];
        }
    }];

    // Never hold the original request forever.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [PXCloneProbe log:@"WATCHDOG release"];
        proceed();
    });
}

+ (void)activateContainer:(NSString *)container
                   bundle:(NSString *)bundle
                  proceed:(void (^)(void))proceed {
    if (!container.length) { [self showRoutingError:@"未取得目标账号，付款链接未打开"]; return; }

    NSString *active = [PXCloneCrane activeContainerForBundle:bundle];
    if (!active.length) {
        // An empty read-back means we cannot prove which account is live.
        // Before this change it was treated as "unknown, just open", which
        // launched the CURRENT account even though the user picked another.
        [self showRoutingError:@"无法读取当前账号，付款链接未打开，请重试"];
        return;
    }
    if ([container isEqualToString:active]) {
        [PXCloneProbe log:@"PASS-SAME active=%@", active];
        proceed();
        return;
    }

    NSError *error = nil;
    // Do not reload here: the app must stay stopped so the original handoff
    // launches it WITH the payment URL. Reloading first opened an empty app
    // and the URL was lost ("未完成支付").
    BOOL started = [PXCloneCrane switchToContainer:container forBundle:bundle reload:NO error:&error];
    if (!started) {
        NSString *reason = error.localizedDescription.length ? error.localizedDescription : @"账号切换未启动";
        [self showRoutingError:reason];
        return;
    }
    [PXCloneProbe log:@"SWITCH-STARTED target=%@ active=%@", container, active];

    if ([PXCloneCrane isApplicationRunning:bundle] && [PXCloneCrane terminateApplication:bundle]) {
        [PXCloneProbe log:@"TERMINATE sent"];
        [self waitForTermination:bundle attempt:0 proceed:proceed container:container];
        return;
    }
    [self waitForContainer:container bundle:bundle attempt:0 proceed:proceed];
}

+ (void)waitForTermination:(NSString *)bundle attempt:(NSUInteger)attempt
                  proceed:(void (^)(void))proceed container:(NSString *)container {
    BOOL running = [PXCloneCrane isApplicationRunning:bundle];
    if (!running || attempt >= 15) {
        [PXCloneProbe log:@"TERMINATE running=%d attempts=%lu", (int)running, (unsigned long)attempt];
        [self waitForContainer:container bundle:bundle attempt:0 proceed:proceed];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self waitForTermination:bundle attempt:attempt + 1 proceed:proceed container:container];
    });
}

+ (void)waitForContainer:(NSString *)container
                  bundle:(NSString *)bundle
                 attempt:(NSUInteger)attempt
                 proceed:(void (^)(void))proceed {
    NSString *active = [PXCloneCrane activeContainerForBundle:bundle];
    if ([container isEqualToString:active]) {
        [PXCloneProbe log:@"SWITCH-VERIFIED target=%@ attempts=%lu", container, (unsigned long)attempt];
        proceed();
        return;
    }
    if (attempt >= PXURLRouterPollLimit) {
        [PXCloneProbe log:@"SWITCH-TIMEOUT target=%@ active=%@", container, active];
        // Fail closed: forwarding a payment URL onto the wrong account is
        // worse than asking the user to tap again.
        [self showRoutingError:@"账号未切换完成，付款链接未打开，请重试"];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(PXURLRouterPollInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self waitForContainer:container bundle:bundle attempt:attempt + 1 proceed:proceed];
    });
}

+ (void)showRoutingError:(NSString *)message {
    void (^present)(void) = ^{
        UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        window.windowLevel = UIWindowLevelAlert + 1;
        window.userInteractionEnabled = NO;
        window.backgroundColor = UIColor.clearColor;
        UIViewController *controller = [UIViewController new];
        window.rootViewController = controller;
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(20, 90, window.bounds.size.width - 40, 72)];
        label.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.94];
        label.textColor = UIColor.whiteColor;
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        label.numberOfLines = 2;
        label.layer.cornerRadius = 14;
        label.clipsToBounds = YES;
        label.text = [@"分身：" stringByAppendingString:message];
        [controller.view addSubview:label];
        window.hidden = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            window.hidden = YES;
            window.rootViewController = nil;
        });
    };
    if (NSThread.isMainThread) present();
    else dispatch_async(dispatch_get_main_queue(), present);
}

@end
