#import "PXCloneURLRouter.h"
#import "PXCloneCrane.h"
#import "PXCloneRuntime.h"
#import "PXCloneProbe.h"
#import "PXCloneURLPolicy.h"
#import "PXCloneLaunch.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Only confirmed payment requests are owned. Plain opens/notifications never
// wait for a catalog and never create a timer. All state belongs to one request.
static NSTimeInterval const PXURLRouterPollInterval = 0.2;
static NSUInteger const PXURLRouterPollLimit = 25;

@interface PXURLRoutingTransaction : NSObject {
@public
    PXURLRouteState route;
}
@property(nonatomic, copy) NSString *bundle;
@property(nonatomic, copy) NSString *container;
@property(nonatomic, copy) void (^proceed)(void);
@property(nonatomic, strong) UIAlertController *alert;
@property(nonatomic) BOOL selected;
@property(nonatomic) BOOL stopRequested;
@property(nonatomic) BOOL requiresExit;
@property(nonatomic) BOOL authenticationOutstanding;
@property(nonatomic, copy) NSArray<NSDictionary *> *containers;
@end
@implementation PXURLRoutingTransaction
@end

static PXURLRoutingTransaction *PXURLRouterActive;
static uint64_t PXURLRouterNextToken = 1;

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

@interface PXCloneURLRouter ()
+ (BOOL)beginBundle:(NSString *)bundle containers:(NSArray<NSDictionary *> *)containers
            proceed:(void (^)(void))proceed;
+ (void)presentTransaction:(PXURLRoutingTransaction *)transaction;
+ (void)stopOldProcess:(PXURLRoutingTransaction *)transaction attempt:(NSUInteger)attempt;
+ (void)switchTransaction:(PXURLRoutingTransaction *)transaction;
+ (void)verifyTransaction:(PXURLRoutingTransaction *)transaction attempt:(NSUInteger)attempt;
+ (void)endTransaction:(PXURLRoutingTransaction *)transaction cancelled:(BOOL)cancelled
                 error:(nullable NSString *)message;
+ (void)showRoutingError:(NSString *)message;
@end

static BOOL PXURLRouterCurrent(PXURLRoutingTransaction *transaction) {
    return transaction && PXURLRouterActive == transaction &&
           PXURLRouteCurrent(&transaction->route, transaction->route.token);
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

static id PXURLRouterField(id object, NSString *key) {
    if ([object isKindOfClass:NSDictionary.class]) return ((NSDictionary *)object)[key];
    return PXURLRouterValue(object, key);
}

static NSURL *PXURLRouterURLValue(id value) {
    NSURL *url = nil;
    if ([value isKindOfClass:NSURL.class]) url = value;
    else if ([value isKindOfClass:NSString.class] && [(NSString *)value length])
        url = [NSURL URLWithString:value];
    return url.scheme.length ? url : nil;
}

// Several keys may carry the same link in different encodings. Taking the
// first hit in priority order beats comparing them: a mismatch between
// __PayloadURL and a nested copy used to cancel both out.
static NSURL *PXURLRouterTargetURL(id object, NSUInteger depth) {
    if (!object || depth > 3) return nil;
    if ([object isKindOfClass:NSURL.class]) return object;
    if ([object isKindOfClass:NSString.class]) return nil;
    for (NSString *key in @[@"__PayloadURL", @"__PayloadOpenURL", @"UIApplicationLaunchOptionsURLKey",
                            @"url", @"URL", @"targetURL", @"openURL", @"webpageURL"]) {
        NSURL *url = PXURLRouterURLValue(PXURLRouterField(object, key));
        if (url) return url;
    }
    for (NSString *key in @[@"__PayloadOptions", @"__AppLink4LS", @"__UserActivity4LS",
                            @"__Payload", @"payload", @"options"]) {
        id value = PXURLRouterField(object, key);
        if (![value isKindOfClass:NSDictionary.class] && ![value isKindOfClass:NSObject.class]) continue;
        NSURL *url = PXURLRouterTargetURL(value, depth + 1);
        if (url) return url;
    }
    return nil;
}

static UIViewController *PXURLRouterPresenter(void) {
    UIApplication *application = UIApplication.sharedApplication;
    if (!application) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *window in application.windows.reverseObjectEnumerator) {
        if (window.hidden || window.alpha <= 0.1 || !window.rootViewController) continue;
        UIViewController *presenter = window.rootViewController;
        while (presenter.presentedViewController) presenter = presenter.presentedViewController;
        if ([presenter isKindOfClass:UIAlertController.class] || presenter.isBeingDismissed) continue;
        if (presenter.viewIfLoaded.window) return presenter;
    }
#pragma clang diagnostic pop
    return nil; // Never create a scene-less key window that steals PX's handle.
}

@implementation PXCloneURLRouter

+ (BOOL)isPaymentURL:(NSURL *)url {
    if (![url isKindOfClass:NSURL.class] || !url.scheme.length) return NO;
    NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!parts || parts.user.length || parts.password.length) return NO;
    NSString *scheme = parts.scheme.lowercaseString ?: @"";
    NSString *host = parts.host.lowercaseString ?: @"";
    NSString *path = parts.path.lowercaseString ?: @"";
    NSString *action = @"";
    for (NSURLQueryItem *item in parts.queryItems) {
        NSString *name = item.name.lowercaseString;
        if ([name isEqualToString:@"action"] || [name isEqualToString:@"service"] ||
            [name isEqualToString:@"method"]) {
            NSString *value = item.value.lowercaseString ?: @"";
            if (action.length && ![action isEqualToString:value]) return NO;
            action = value;
        }
    }
    return PXURLRoutePayment(scheme.UTF8String, host.UTF8String, path.UTF8String, action.UTF8String);
}

// A cross-app share arrives as a document payload, not as a payment URL. Only
// these unambiguous markers count; everything else keeps passing through.
+ (BOOL)isShareRequest:(id)request options:(id)options {
    for (id object in @[request ?: NSNull.null, options ?: NSNull.null]) {
        if ([object isKindOfClass:NSDictionary.class]) {
            NSDictionary *dictionary = object;
            for (NSString *key in @[@"__DocumentOpen4LS", @"__AppBasedViewService"]) {
                if (dictionary[key] && ![dictionary[key] isKindOfClass:NSNull.class]) return YES;
            }
        }
    }
    for (id object in @[request ?: NSNull.null, options ?: NSNull.null]) {
        NSURL *url = PXURLRouterTargetURL(object, 0);
        if ([url.scheme.lowercaseString isEqualToString:@"file"]) return YES;
    }
    return NO;
}

+ (NSURL *)paymentURLForRequest:(id)request options:(id)options {
    NSURL *direct = PXURLRouterTargetURL(options, 0);
    NSURL *nested = PXURLRouterTargetURL(request, 0);
    if (direct && nested && ![direct isEqual:nested]) return nil;
    NSURL *url = direct ?: nested;
    return [self isPaymentURL:url] ? url : nil;
}

+ (BOOL)handleOpenURL:(NSURL *)url proceed:(void (^)(void))proceed {
    // Do not resolve a target, touch Crane or create state for plain URLs.
    [PXCloneProbe log:@"PAY url=%@", url.absoluteString.length > 70 ?
        [url.absoluteString substringToIndex:70] : url.absoluteString];
    BOOL file = [url.scheme.lowercaseString isEqualToString:@"file"];
    if (!NSThread.isMainThread || !proceed || (!file && ![self isPaymentURL:url])) return NO;
    NSString *bundle = PXURLRouterBundleForURL(url);
    if (!bundle.length) return NO;
    NSArray<NSDictionary *> *containers = [PXCloneCrane containersForBundle:bundle];
    if (containers.count < 2) return NO;
    return [self beginBundle:bundle containers:containers proceed:proceed];
}

+ (BOOL)handleOpenRequest:(id)request options:(id)options proceed:(void (^)(void))proceed {
    if (!NSThread.isMainThread || !proceed) return NO;
    NSURL *url = [self paymentURLForRequest:request options:options];
    NSString *raw = url.absoluteString.length > 70 ?
        [url.absoluteString substringToIndex:70] : url.absoluteString;
    // bundle-only requests carry no URL at all. 0.33 answered them by bundle
    // and that is the only shape that worked on device; only a URL that is
    // present and clearly not a payment is skipped here.
    BOOL payment = url && [self isPaymentURL:url];
    BOOL share = [self isShareRequest:request options:options];
    if (!payment && !share) return NO;
    NSString *bundle = PXURLRouterBundleFromRequest(request);
    [PXCloneProbe log:@"%@ open url=%@ bundle=%@", payment ? @"PAY" : @"SHARE",
        raw ?: @"(none)", bundle ?: @"(nil)"];
    if (!bundle.length) return NO;
    NSArray<NSDictionary *> *containers = [PXCloneCrane containersForBundle:bundle];
    [PXCloneProbe log:@"%@ gate bundle=%@ n=%lu", payment ? @"PAY" : @"SHARE",
        bundle, (unsigned long)containers.count];
    if (containers.count >= 2) return [self beginBundle:bundle containers:containers proceed:proceed];
    // Catalog still cold: hold the request (falling through launches the
    // current account before the chooser can appear) and poll briefly.
    PXURLRoutingTransaction *transaction = [PXURLRoutingTransaction new];
    transaction->route = (PXURLRouteState){ PXURLRouterNextToken++, PXURLRouteNew };
    transaction.bundle = bundle;
    transaction.proceed = [proceed copy];
    transaction.containers = @[];
    PXURLRouterActive = transaction;
    [PXCloneCrane refreshCatalogWithCompletion:^(NSArray<NSDictionary *> *catalog, NSError *error) {
        (void)catalog; (void)error;
    }];
    [self awaitContainers:transaction attempt:0];
    return YES;
}

+ (void)awaitContainers:(PXURLRoutingTransaction *)transaction attempt:(NSUInteger)attempt {
    if (PXURLRouterActive != transaction) return;
    NSArray<NSDictionary *> *containers = [PXCloneCrane containersForBundle:transaction.bundle];
    void (^forward)(void) = [transaction.proceed copy];
    if (containers.count >= 2) {
        transaction.proceed = nil;
        transaction.containers = containers;
        PXURLRouterActive = nil;
        if (![self beginBundle:transaction.bundle containers:containers proceed:forward ?: ^{}])
            if (forward) forward();
        return;
    }
    if (attempt >= 15) { // ~1.5s
        PXURLRouterActive = nil;
        transaction.proceed = nil;
        [PXCloneProbe log:@"PAY wait timeout"];
        if (forward) forward();
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{ [self awaitContainers:transaction attempt:attempt + 1]; });
}

+ (BOOL)hasActivePayment {
    return PXURLRouterActive != nil;
}

+ (BOOL)beginBundle:(NSString *)bundle containers:(NSArray<NSDictionary *> *)containers
            proceed:(void (^)(void))proceed {
    if (!NSThread.isMainThread || !bundle.length || !proceed || containers.count < 2) return NO;
    if (PXURLRouterActive || PXCloneLaunchController.shared.busy) {
        [self showRoutingError:@"正在切换账号，请完成当前操作后再打开付款链接"];
        return YES; // Never launch a concurrent payment into whichever account wins.
    }
    PXURLRoutingTransaction *transaction = [PXURLRoutingTransaction new];
    transaction->route = (PXURLRouteState){ PXURLRouterNextToken++, PXURLRouteNew };
    if (!transaction->route.token) transaction->route.token = PXURLRouterNextToken++;
    transaction.bundle = bundle;
    transaction.proceed = [proceed copy];
    transaction.containers = [containers copy];
    if (!PXURLRouteAdvance(&transaction->route, transaction->route.token,
                            PXURLRouteNew, PXURLRouteChoosing)) return YES;
    PXURLRouterActive = transaction;
    [PXCloneProbe log:@"payment.choose.begin"];
    [self presentTransaction:transaction];
    __weak PXURLRoutingTransaction *weakTransaction = transaction;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 45 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        PXURLRoutingTransaction *current = weakTransaction;
        if (PXURLRouterCurrent(current) && current->route.phase == PXURLRouteChoosing)
            [self endTransaction:current cancelled:NO error:@"账号选择已超时，付款链接未打开"];
    });
    return YES;
}

+ (void)presentTransaction:(PXURLRoutingTransaction *)transaction {
    if (!PXURLRouterCurrent(transaction)) return;
    UIViewController *presenter = PXURLRouterPresenter();
    if (!presenter) {
        [self endTransaction:transaction cancelled:NO error:@"当前无法显示账号选择，付款链接未打开"];
        return;
    }
    NSString *active = [PXCloneCrane activeContainerForBundle:transaction.bundle];
    if (!active.length) {
        [self endTransaction:transaction cancelled:NO error:@"无法读取当前账号，付款链接未打开"];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"选择付款账号"
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    transaction.alert = alert;
    __weak PXURLRoutingTransaction *weakTransaction = transaction;
    for (NSDictionary *entry in transaction.containers) {
        NSString *container = entry[@"container"];
        if (![container isKindOfClass:NSString.class] || !container.length) continue;
        NSString *title = [entry[@"name"] isKindOfClass:NSString.class] ? entry[@"name"] : container;
        if ([container isEqualToString:active]) title = [title stringByAppendingString:@" ✓"];
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                PXURLRoutingTransaction *current = weakTransaction;
                if (!PXURLRouterCurrent(current) || current->route.phase != PXURLRouteChoosing) return;
                current.container = container;
                current.selected = YES;
                NSString *now = [PXCloneCrane activeContainerForBundle:current.bundle];
                if (!now.length) {
                    [self endTransaction:current cancelled:NO error:@"无法读取当前账号，付款链接未打开"];
                    return;
                }
                current.requiresExit = ![container isEqualToString:now];
                if (!PXURLRouteAdvance(&current->route, current->route.token,
                        PXURLRouteChoosing, PXURLRouteStopping)) return;
                [self stopOldProcess:current attempt:0];
            }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
        handler:^(__unused UIAlertAction *action) {
            PXURLRoutingTransaction *current = weakTransaction;
            if (PXURLRouterCurrent(current)) [self endTransaction:current cancelled:YES error:nil];
        }]];
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = presenter.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(presenter.view.bounds),
            CGRectGetMidY(presenter.view.bounds), 1, 1);
        alert.popoverPresentationController.permittedArrowDirections = 0;
    }
    @try {
        [presenter presentViewController:alert animated:YES completion:^{
            PXURLRoutingTransaction *current = weakTransaction;
            if (PXURLRouterCurrent(current) && current->route.phase == PXURLRouteChoosing &&
                !current.alert.presentingViewController)
                [self endTransaction:current cancelled:NO error:@"账号选择未显示，付款链接未打开"];
        }];
    } @catch (__unused NSException *exception) {
        [self endTransaction:transaction cancelled:NO error:@"账号选择未显示，付款链接未打开"];
    }
}

+ (void)stopOldProcess:(PXURLRoutingTransaction *)transaction attempt:(NSUInteger)attempt {
    if (!PXURLRouterCurrent(transaction) || transaction->route.phase != PXURLRouteStopping) return;
    BOOL running = NO;
    NSError *error = nil;
    if (![PXCloneCrane queryApplicationRunning:transaction.bundle running:&running error:&error]) {
        [self endTransaction:transaction cancelled:NO error:@"无法确认旧账号进程状态，付款链接未打开"];
        return;
    }
    if (!transaction.requiresExit || !running) {
        if (PXURLRouteAdvance(&transaction->route, transaction->route.token,
                PXURLRouteStopping, PXURLRouteSwitching)) [self switchTransaction:transaction];
        return;
    }
    if (!transaction.stopRequested) {
        transaction.stopRequested = YES;
        if (![PXCloneCrane terminateApplication:transaction.bundle]) {
            [self endTransaction:transaction cancelled:NO error:@"无法请求旧账号退出，付款链接未打开"];
            return;
        }
    }
    if (attempt >= 30) {
        [self endTransaction:transaction cancelled:NO error:@"旧账号进程未退出，未切换或打开其他账号"];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(PXURLRouterPollInterval * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{ [self stopOldProcess:transaction attempt:attempt + 1]; });
}

+ (void)switchTransaction:(PXURLRoutingTransaction *)transaction {
    if (!PXURLRouterCurrent(transaction) || transaction->route.phase != PXURLRouteSwitching) return;
    NSString *active = [PXCloneCrane activeContainerForBundle:transaction.bundle];
    if ([active isEqualToString:transaction.container]) {
        if (PXURLRouteAdvance(&transaction->route, transaction->route.token,
                PXURLRouteSwitching, PXURLRouteVerifying)) [self verifyTransaction:transaction attempt:0];
        return;
    }
    transaction.authenticationOutstanding = YES;
    NSError *error = nil;
    BOOL started = [PXCloneCrane requestSwitchToContainer:transaction.container
        forBundle:transaction.bundle reply:^(BOOL rawAuthenticationFlag) {
            (void)rawAuthenticationFlag; // Crane NO/YES is not the switch result.
            if (PXURLRouterActive != transaction || !transaction.authenticationOutstanding) return;
            transaction.authenticationOutstanding = NO;
            if (PXURLRouteTerminal(transaction->route.phase)) {
                [self endTransaction:transaction cancelled:NO error:nil];
                return;
            }
            if (PXURLRouteAdvance(&transaction->route, transaction->route.token,
                    PXURLRouteSwitching, PXURLRouteVerifying))
                [self verifyTransaction:transaction attempt:0];
        } error:&error];
    if (!started) {
        transaction.authenticationOutstanding = NO;
        [self endTransaction:transaction cancelled:NO error:error.localizedDescription ?: @"账号切换未启动"];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 45 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (PXURLRouterCurrent(transaction) && transaction.authenticationOutstanding)
            [self endTransaction:transaction cancelled:NO error:@"Crane 验证超时，付款未打开；等待原验证返回"];
    });
}

+ (void)verifyTransaction:(PXURLRoutingTransaction *)transaction attempt:(NSUInteger)attempt {
    if (!PXURLRouterCurrent(transaction) || transaction->route.phase != PXURLRouteVerifying) return;
    BOOL running = NO;
    NSError *error = nil;
    BOOL processKnown = [PXCloneCrane queryApplicationRunning:transaction.bundle running:&running error:&error];
    NSString *active = [PXCloneCrane activeContainerForBundle:transaction.bundle];
    BOOL matches = [active isEqualToString:transaction.container];
    BOOL exited = !transaction.requiresExit || !running;
    if (!processKnown || !exited) {
        [self endTransaction:transaction cancelled:NO error:@"无法确认目标账号进程，付款链接未打开"];
        return;
    }
    if (PXURLRouteMayForward(&transaction->route, transaction->route.token,
            transaction.selected, matches, processKnown, exited)) {
        void (^forward)(void) = [transaction.proceed copy];
        transaction.proceed = nil;
        NSString *bundle = transaction.bundle;
        [self endTransaction:transaction cancelled:NO error:nil];
        [PXCloneProbe log:@"payment.forward.verified"];
        if (!forward) return;
        // A hosted split-screen canvas keeps pointing at the killed process, so
        // the relaunch paints black. Let the panel drop that context first and
        // give it one turn of the run loop before the request goes out.
        Class panel = NSClassFromString(@"ParallelX.PXPanelEntry");
        SEL drop = NSSelectorFromString(@"switcherRemovedApplication:");
        if (panel && [panel respondsToSelector:drop]) {
            @try { ((void (*)(id, SEL, id))objc_msgSend)((id)panel, drop, bundle); }
            @catch (__unused NSException *exception) { }
            [PXCloneProbe log:@"payment.forward.teardown"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(200 * NSEC_PER_MSEC)),
                dispatch_get_main_queue(), forward);
            return;
        }
        forward();
        return;
    }
    if (attempt >= PXURLRouterPollLimit) {
        [self endTransaction:transaction cancelled:NO error:@"账号未切换完成，付款链接未打开"];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(PXURLRouterPollInterval * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{ [self verifyTransaction:transaction attempt:attempt + 1]; });
}

+ (void)endTransaction:(PXURLRoutingTransaction *)transaction cancelled:(BOOL)cancelled
                 error:(NSString *)message {
    if (!transaction || PXURLRouterActive != transaction) return;
    if (!PXURLRouteTerminal(transaction->route.phase))
        PXURLRouteAbort(&transaction->route, transaction->route.token, cancelled);
    transaction.proceed = nil;
    UIAlertController *alert = transaction.alert;
    transaction.alert = nil;
    transaction.containers = nil;
    if (alert.presentingViewController) [alert dismissViewControllerAnimated:YES completion:nil];
    // A late real authentication callback may still switch Crane. Keep a
    // quarantined slot, without the opener, until that callback actually ends.
    if (!transaction.authenticationOutstanding) PXURLRouterActive = nil;
    [PXCloneProbe log:cancelled ? @"payment.cancelled" : @"payment.finished"];
    if (message.length) [self showRoutingError:message];
}

+ (void)showRoutingError:(NSString *)message {
    UIViewController *presenter = PXURLRouterPresenter();
    if (!NSThread.isMainThread || !presenter.view.window || !message.length) return;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.94];
    label.textColor = UIColor.whiteColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    label.numberOfLines = 3;
    label.layer.cornerRadius = 14;
    label.clipsToBounds = YES;
    label.text = [@"分身：" stringByAppendingString:message];
    UIView *host = presenter.view.window;
    label.frame = CGRectMake(20, 90, MAX(1, host.bounds.size.width - 40), 84);
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [host addSubview:label];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{ [label removeFromSuperview]; });
}
@end
