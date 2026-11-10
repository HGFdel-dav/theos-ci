// macOS: clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra -Werror
// -framework Foundation tests/router_host.mm -o /tmp/rd-router-host
// Host contract only: UIApplication is simulated; Foundation/dispatch are real.
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <initializer_list>

static unsigned checks;
#define CHECK(x) do { ++checks; if (!(x)) { \
    fprintf(stderr, "FAIL %d: %s\n", __LINE__, #x); abort(); } } while (0)

static BOOL enabled = YES, handoff = YES;
static NSString *const kEnabledKey = @"enabled", *const kHandoffKey = @"handoff";
static BOOL RDReadBoolPref(NSString *key, BOOL fallback) {
    if ([key isEqualToString:kEnabledKey]) return enabled;
    if ([key isEqualToString:kHandoffKey]) return handoff;
    return fallback;
}
static void RDLog(NSString *format, ...) { (void)format; }
@protocol RDEventCallback <NSObject>
- (void)sendSuccess:(id)value;
- (void)sendError:(id)value;
@end

typedef NS_ENUM(NSInteger, UIApplicationState) {
    UIApplicationStateActive, UIApplicationStateInactive, UIApplicationStateBackground
};
static NSString *const UIApplicationOpenURLOptionUniversalLinksOnly = @"universalLinksOnly";
@interface UIApplication : NSObject
@property(nonatomic) UIApplicationState applicationState;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *opens;
@property(nonatomic, copy) void (^pending)(BOOL);
+ (instancetype)sharedApplication;
- (void)openURL:(NSURL *)url options:(NSDictionary *)options
    completionHandler:(void (^)(BOOL))completion;
@end
@implementation UIApplication
+ (instancetype)sharedApplication {
    static UIApplication *app;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ app = [UIApplication new]; app.opens = [NSMutableArray new]; });
    return app;
}
- (void)openURL:(NSURL *)url options:(NSDictionary *)options
    completionHandler:(void (^)(BOOL))completion {
    CHECK([NSThread isMainThread]);
    CHECK(self.pending == nil && completion != nil);
    [self.opens addObject:@{@"url":url, @"options":[options copy]}];
    self.pending = completion; // Held until the test supplies an OS result.
}
@end

// Do not declare/reimplement RDClickEventAllowed or any router function here.
#import "../Common/RDClickRouter.h"

@interface HostCallback : NSObject <RDEventCallback>
@property(nonatomic) NSUInteger count;
@property(nonatomic) BOOL value;
@end
@implementation HostCallback
- (void)sendSuccess:(id)value {
    CHECK([NSThread isMainThread]);
    CHECK(self.count == 0 && [value isKindOfClass:[NSNumber class]]);
    ++self.count;
    self.value = [value boolValue];
}
- (void)sendError:(id)value { (void)value; CHECK(NO); }
@end

// Pump the real main run loop so main-queue completions/timeouts can execute.
static void HostWait(BOOL (^ready)(void), NSTimeInterval seconds) {
    CHECK([NSThread isMainThread]);
    NSTimeInterval end = [NSProcessInfo processInfo].systemUptime + seconds;
    while (!ready() && [NSProcessInfo processInfo].systemUptime < end) {
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    CHECK(ready());
}
static void HostWorker(void (^work)(void)) {
    __block BOOL done = NO;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool { work(); }
        // This fence is queued after all main-queue deliveries from work().
        dispatch_async(dispatch_get_main_queue(), ^{ done = YES; });
    });
    HostWait(^BOOL { return done; }, 5.0);
}
static void HostReset(void) {
    UIApplication *app = [UIApplication sharedApplication];
    CHECK(app.pending == nil);
    [app.opens removeAllObjects];
    app.applicationState = UIApplicationStateActive;
    enabled = handoff = YES;
}
static void HostComplete(BOOL accepted) {
    UIApplication *app = [UIApplication sharedApplication];
    void (^completion)(BOOL) = app.pending;
    CHECK(completion != nil);
    app.pending = nil;
    HostWorker(^{ completion(accepted); completion(!accepted); });
}
static NSDictionary *HostPayload(NSString *uri, BOOL gesture, BOOL top, uint32_t flags) {
    return @{@"uri":uri, @"hasUserGesture":@(gesture), @"isTopLevel":@(top), @"flags":@(flags)};
}
static NSString *const pre = @"GeckoView:OnPreNavigation";
static NSString *const load = @"GeckoView:OnLoadRequest";
static NSString *const web = @"https://shop.example/item?sku=a%2Fb&foo=1#reviews";

static void HostPass(NSString *event, NSDictionary *payload) {
    UIApplication *app = [UIApplication sharedApplication];
    NSUInteger opens = app.opens.count;
    HostCallback *callback = [HostCallback new];
    // NO leaves this callback untouched for the hook's original Gecko path.
    CHECK(!RDHandleClickNavigation([NSObject new], event, payload, callback));
    HostWorker(^{});
    CHECK(app.opens.count == opens && app.pending == nil && callback.count == 0);
}
static void HostRoundTrip(NSString *uri, BOOL accepted, uint32_t flags) {
    HostReset();
    UIApplication *app = [UIApplication sharedApplication];
    NSObject *dispatcher = [NSObject new];
    NSDictionary *payload = HostPayload(uri, YES, YES, flags);
    NSMutableArray<HostCallback *> *callbacks = [NSMutableArray new];
    // Pre/Pre/Load/Load overlap while the OS completion is pending.
    for (NSString *event in @[pre, pre, load, load]) {
        HostCallback *callback = [HostCallback new];
        [callbacks addObject:callback];
        CHECK(RDHandleClickNavigation(dispatcher, event, payload, callback));
        CHECK(app.opens.count == 1 && callback.count == 0);
    }
    NSDictionary *record = app.opens.lastObject;
    CHECK([[record[@"url"] absoluteString] isEqualToString:uri]);
    NSDictionary *options = record[@"options"];
    CHECK(options.count == 1 && [options[UIApplicationOpenURLOptionUniversalLinksOnly] isEqual:@YES]);
    HostComplete(accepted); // Two contradictory OS replies must finish only once.
    for (HostCallback *callback in callbacks) CHECK(callback.count == 1 && callback.value == accepted);
    // Completed Pre deduplication has a production 350ms window. Load reuses
    // the result independently of that window; test its repeated phase too.
    for (NSString *event in @[pre, load, load]) {
        HostCallback *callback = [HostCallback new];
        CHECK(RDHandleClickNavigation(dispatcher, event, payload, callback));
        CHECK(callback.count == 1 && callback.value == accepted);
    }
    CHECK(app.opens.count == 1 && app.pending == nil);
}
static void HostTimeout(void) {
    HostReset();
    UIApplication *app = [UIApplication sharedApplication];
    HostCallback *callback = [HostCallback new];
    NSObject *dispatcher = [NSObject new];
    CHECK(RDHandleClickNavigation(dispatcher, pre, HostPayload(web, YES, YES, 0), callback));
    CHECK(callback.count == 0 && app.opens.count == 1);
    HostWait(^BOOL { return callback.count == 1; }, 6.0); // Real production 3s timeout.
    CHECK(!callback.value);
    HostComplete(YES); // A late success and then failure cannot finish again.
    CHECK(callback.count == 1 && !callback.value && app.opens.count == 1);
}

int main(void) {
    @autoreleasepool {
        for (uint32_t flags : {0u, 0x800000u}) {
            HostRoundTrip(web, YES, flags);
            HostRoundTrip(@"http://news.example/plain?x=%2F#text", NO, flags);
        }
        HostReset();
        UIApplication *app = [UIApplication sharedApplication];
        HostPass(pre, HostPayload(web, NO, YES, 0x800000));
        HostPass(pre, HostPayload(web, YES, NO, 0x800000));
        for (UIApplicationState state : {UIApplicationStateBackground, UIApplicationStateInactive}) {
            app.applicationState = state;
            HostPass(pre, HostPayload(web, YES, YES, 0x800000));
        }
        app.applicationState = UIApplicationStateActive;
        enabled = NO; HostPass(pre, HostPayload(web, YES, YES, 0)); enabled = YES;
        handoff = NO; HostPass(pre, HostPayload(web, YES, YES, 0)); handoff = YES;
        HostPass(load, HostPayload(web, YES, YES, 0)); // Orphan Load stays with Gecko.
        for (NSString *uri in @[@"tg://resolve?domain=moonup_chat&start=a%2Bb#c",
                @"tg:resolve?domain=moonup_chat", @"mailto:a@example.com?subject=x%26y",
                @"tel:+861234", @"demo://item/42?a=%2F&b=%23"]) {
            NSObject *dispatcher = [NSObject new];
            for (NSString *event in @[pre, pre, load, load]) {
                HostCallback *callback = [HostCallback new];
                CHECK(!RDHandleClickNavigation(dispatcher, event, HostPayload(uri, YES, YES, 0x800000), callback));
                CHECK(callback.count == 0 && app.opens.count == 0 && app.pending == nil);
            }
        }
        HostCallback *callback = [HostCallback new];
        RDRouteReply *reply = [RDRouteReply new];
        reply.callback = callback;
        HostWorker(^{ [reply finish:YES]; [reply finish:NO]; });
        [reply finish:NO];
        CHECK(callback.count == 1 && callback.value && reply.callback == nil);
        HostTimeout();
        printf("ROUTER_HOST_PASS checks=%u\n", checks);
    }
    return 0;
}
