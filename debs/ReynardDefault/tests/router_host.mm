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
static void HostClickCustom(void) {
    HostReset();
    UIApplication *app=[UIApplication sharedApplication];
    NSObject *dispatcher=[NSObject new];
    HostCallback *callback=[HostCallback new];
    NSDictionary *payload=HostPayload(@"tg:resolve?domain=moonup_chat",YES,YES,0);
    CHECK(RDHandleClickNavigation(dispatcher,@"GeckoView:OnNewSession",payload,callback));
    CHECK(app.opens.count==1 && app.pending!=nil && callback.count==0);
    CHECK([app.opens.lastObject[@"url"] isEqual:@"tg://resolve?domain=moonup_chat"]);
    CHECK([app.opens.lastObject[@"options"] count]==0);
    HostComplete(YES);
    CHECK(callback.count==1 && callback.value);
}
static void HostNoHandoff(NSString *event, NSString *uri) {
    HostPass(event,HostPayload(uri,YES,YES,0));
}
int main(void) {
    @autoreleasepool {
        HostNoHandoff(pre,web);
        HostNoHandoff(load,web);
        HostNoHandoff(pre,@"http://news.example/plain?x=%2F#text");
        HostNoHandoff(pre,@"https://github.com/someone");
        HostNoHandoff(pre,@"tg://resolve?domain=moonup_chat");
        HostNoHandoff(load,@"tg://resolve?domain=moonup_chat");
        HostNoHandoff(pre,@"mailto:a@example.com?subject=x%26y");
        HostNoHandoff(pre,@"tel:+861234");
        HostPass(pre,HostPayload(web,NO,YES,0));
        HostPass(pre,HostPayload(web,YES,NO,0));
        UIApplication *app=[UIApplication sharedApplication];
        for (UIApplicationState state in {UIApplicationStateBackground,UIApplicationStateInactive}) {
            app.applicationState=state; HostPass(pre,HostPayload(@"tg://resolve?domain=x",YES,YES,0));
        }
        app.applicationState=UIApplicationStateActive;
        enabled=NO; HostPass(pre,HostPayload(@"tg://resolve?domain=x",YES,YES,0)); enabled=YES;
        handoff=NO; HostPass(pre,HostPayload(@"tg://resolve?domain=x",YES,YES,0)); handoff=YES;
        HostClickCustom();
        HostCallback *callback=[HostCallback new];
        RDRouteReply *reply=[RDRouteReply new];
        reply.callback=callback;
        HostWorker(^{ [reply finish:YES]; [reply finish:NO]; });
        [reply finish:NO];
        CHECK(callback.count==1 && callback.value && reply.callback==nil);
        printf("ROUTER_HOST_PASS checks=%u\n",checks);
    }
    return 0;
}
