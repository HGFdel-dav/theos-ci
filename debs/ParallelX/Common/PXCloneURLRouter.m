#import "PXCloneURLRouter.h"
#import "PXCloneCrane.h"
#import "PXCloneRuntime.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// SpringBoard hands an external "open this app with this URL" request to
// FBSystemService before the app is launched. When the target bundle has more
// than one Crane container we show an account chooser, make the chosen account
// the active container, and only then let the original request run - so the app
// the system launches for the URL is the account the user picked.
//
// The chosen container is confirmed by reading Crane's active container back
// with a bounded wait; a switch that does not land still proceeds, so an
// incoming payment URL is never swallowed silently.

static NSTimeInterval const PXURLRouterPollInterval = 0.2;
static NSUInteger const PXURLRouterPollLimit = 25;
// The catalog is refreshed at most once per minute from this path, so a burst
// of launches cannot turn into a burst of Crane queries.
static NSTimeInterval const PXURLRouterRefreshThrottle = 60.0;
static UIWindow *PXURLRouterWindow = nil;
static NSTimeInterval PXURLRouterLastRefresh = 0;

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
    return ^{
        @synchronized (lock) {
            if (done) return;
            done = YES;
        }
        if (proceed) proceed();
    };
}

@implementation PXCloneURLRouter

+ (BOOL)handleOpenRequest:(id)request proceed:(void (^)(void))proceed {
    if (!proceed) return NO;
    NSString *bundle = PXURLRouterString(request,
        @[@"applicationIdentifier", @"bundleIdentifier", @"targetApplicationIdentifier"]);
    if (!bundle.length) return NO;

    NSArray<NSDictionary *> *containers = PXURLRouterContainers(bundle);
    if (containers.count < 2) {
        // Nothing to choose. Refresh a missing/stale catalog at most once a
        // minute so the next request already knows this bundle's containers.
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        if (now - PXURLRouterLastRefresh >= PXURLRouterRefreshThrottle) {
            PXURLRouterLastRefresh = now;
            [PXCloneCrane refreshCatalogWithCompletion:^(NSArray<NSDictionary *> *catalog,
                                                         NSError *error) {
                (void)catalog; (void)error;
            }];
        }
        return NO;
    }

    void (^once)(void) = PXURLRouterOnce(proceed);
    void (^present)(void) = ^{
        [self presentChooserForBundle:bundle containers:containers proceed:once];
    };
    if (NSThread.isMainThread) present();
    else dispatch_async(dispatch_get_main_queue(), present);
    return YES;
}

+ (void)presentChooserForBundle:(NSString *)bundle
                     containers:(NSArray<NSDictionary *> *)containers
                        proceed:(void (^)(void))proceed {
    UIApplication *application = UIApplication.sharedApplication;
    if (!application) { proceed(); return; }

    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    window.windowLevel = UIWindowLevelAlert + 1;
    UIViewController *host = [UIViewController new];
    host.view.backgroundColor = UIColor.clearColor;
    window.rootViewController = host;
    PXURLRouterWindow = window;
    [window makeKeyAndVisible];

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

    [host presentViewController:alert animated:YES completion:nil];
}

+ (void)activateContainer:(NSString *)container
                   bundle:(NSString *)bundle
                  proceed:(void (^)(void))proceed {
    NSString *active = [PXCloneCrane activeContainerForBundle:bundle];
    if (!container.length || (active.length && [container isEqualToString:active])) {
        proceed();
        return;
    }

    NSError *error = nil;
    BOOL started = [PXCloneCrane requestSwitchToContainer:container
                                                forBundle:bundle
                                                    reply:^(__unused BOOL rawAuthenticationFlag) {}
                                                    error:&error];
    if (!started) { proceed(); return; }
    [self waitForContainer:container bundle:bundle attempt:0 proceed:proceed];
}

+ (void)waitForContainer:(NSString *)container
                  bundle:(NSString *)bundle
                 attempt:(NSUInteger)attempt
                 proceed:(void (^)(void))proceed {
    NSString *active = [PXCloneCrane activeContainerForBundle:bundle];
    if ([container isEqualToString:active] || attempt >= PXURLRouterPollLimit) {
        proceed();
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(PXURLRouterPollInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self waitForContainer:container bundle:bundle attempt:attempt + 1 proceed:proceed];
    });
}

@end
