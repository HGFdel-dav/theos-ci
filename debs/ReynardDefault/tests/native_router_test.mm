// macOS host test of production Objective-C++ routing, with only UIApplication
// replaced. Uses real Foundation URL parsing, ARC, blocks, dispatch and maps.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#include <cassert>
#include <unistd.h>
static BOOL enabled=YES;
static NSString *const kEnabledKey=@"enabled", *const kHandoffKey=@"handoff";
static BOOL RDReadBoolPref(NSString *key, BOOL fallback) {(void)key;(void)fallback;return enabled;}
static void RDLog(NSString *format,...) {(void)format;}
static char kRDBackendKey;
@protocol RDEventCallback <NSObject>
- (void)sendSuccess:(id)value;
@end
@protocol RDGeckoDispatch <NSObject>
- (void)dispatchToGecko:(NSString *)type message:(id)message callback:(id)callback;
@end
static NSString *const UIApplicationOpenURLOptionUniversalLinksOnly=@"universal";
typedef NS_ENUM(NSInteger,UIApplicationState){UIApplicationStateActive,UIApplicationStateInactive,UIApplicationStateBackground};
@interface UIApplication : NSObject
@property(nonatomic) UIApplicationState applicationState;
@property(nonatomic) BOOL answer;
@property(nonatomic,strong) NSMutableArray *opens;
+ (UIApplication *)sharedApplication;
- (void)openURL:(NSURL *)url options:(NSDictionary *)options completionHandler:(void (^)(BOOL))callback;
@end
@implementation UIApplication
+ (UIApplication *)sharedApplication {static UIApplication *a;static dispatch_once_t once;dispatch_once(&once,^{a=[UIApplication new];a.opens=[NSMutableArray array];});return a;}
- (void)openURL:(NSURL *)url options:(NSDictionary *)options completionHandler:(void (^)(BOOL))callback {
 [self.opens addObject:@{@"url":url.absoluteString,@"options":options}];
 BOOL answer=self.answer;dispatch_async(dispatch_get_main_queue(),^{callback(answer);});
}
@end
#import "../Common/RDClickRouter.h"
@interface TestCallback : NSObject<RDEventCallback>
@property(nonatomic) NSUInteger count;
@property(nonatomic) BOOL value;
@end
@implementation TestCallback
- (void)sendSuccess:(id)v {self.count++;self.value=[v boolValue];}
@end
@interface TestBackend : NSObject<RDGeckoDispatch>
@property(nonatomic,strong) NSMutableArray *messages;
@end
@implementation TestBackend
- (instancetype)init {if((self=[super init]))_messages=[NSMutableArray array];return self;}
- (void)dispatchToGecko:(NSString *)type message:(id)message callback:(id)callback {(void)callback;[self.messages addObject:@{@"type":type,@"payload":message}];}
@end
static void drain(void) {NSDate *until=[NSDate dateWithTimeIntervalSinceNow:0.035];while([until timeIntervalSinceNow]>0)[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];}
static unsigned checks;
#define CHECK(x) do { checks++; if(!(x)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x);abort();} }while(0)
static NSDictionary *message(NSString *uri,BOOL gesture){return @{@"uri":uri,@"hasUserGesture":@(gesture),@"isTopLevel":@YES,@"flags":@0};}
static NSString *bridge(NSString *app) {
 NSCharacterSet *safe=[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
 return [NSString stringWithFormat:@"https://reynarddefault.invalid/.well-known/handoff/v2#v=2&id=0123456789abcdef0123456789abcdef&ts=%llu&a=%@&h=",(unsigned long long)([NSDate date].timeIntervalSince1970*1000),[app stringByAddingPercentEncodingWithAllowedCharacters:safe]];
}
int main(void) {@autoreleasepool {
 UIApplication *a=[UIApplication sharedApplication];a.answer=YES;a.applicationState=UIApplicationStateActive;
 for(NSString *event in @[@"GeckoView:OnVisited",@"GeckoView:OnLoadError",@"GeckoView:WebExtension:PortMessage"]) {
  TestCallback *c=[TestCallback new];CHECK(!RDHandleClickNavigation([NSObject new],event,message(@"tg://resolve?domain=moonup_chat",YES),c));CHECK(a.opens.count==0);CHECK(c.count==0);
 }
 TestCallback *c=[TestCallback new];id d=[NSObject new];
 CHECK(!RDHandleClickNavigation(d,@"GeckoView:OnPreNavigation",message(@"https://shop.example/a",NO),c));CHECK(a.opens.count==0);
 NSString *web=@"https://shop.example/item?sku=a%2Fb&foo=1#reviews";
 CHECK(RDHandleClickNavigation(d,@"GeckoView:OnPreNavigation",message(web,YES),c));drain();CHECK(c.count==1&&c.value);CHECK([a.opens.lastObject[@"url"] isEqual:web]);CHECK([a.opens.lastObject[@"options"][@"universal"] boolValue]);
 TestCallback *phase=[TestCallback new];CHECK(RDHandleClickNavigation(d,@"GeckoView:OnLoadRequest",message(web,YES),phase));drain();CHECK(phase.count==1&&phase.value);CHECK(a.opens.count==1);
 a.answer=NO; c=[TestCallback new];d=[NSObject new];
 CHECK(RDHandleClickNavigation(d,@"GeckoView:OnPreNavigation",message(@"https://news.example/plain",YES),c));drain();CHECK(c.count==1&&!c.value);CHECK(a.opens.count==2);
 a.answer=YES;c=[TestCallback new];d=[NSObject new];NSString *b=bridge(@"tg:resolve?domain=moonup_chat&post=12&start=a%2Bb#c");
 CHECK(RDHandleClickNavigation(d,@"GeckoView:OnPreNavigation",message(b,YES),c));drain();CHECK(c.count==1&&c.value);
 CHECK([a.opens.lastObject[@"url"] isEqual:@"tg://resolve?domain=moonup_chat&post=12&start=a%2Bb#c"]);
 NSUInteger count=a.opens.count;c=[TestCallback new];CHECK(RDHandleClickNavigation(d,@"GeckoView:OnLoadRequest",message(b,YES),c));drain();CHECK(c.count==1&&c.value);CHECK(a.opens.count==count);
 for(NSString *url in @[@"mailto:a@example.com?subject=x%26y",@"tel:+861234",@"demo://item/42?a=%2F&b=%23"]) {
  c=[TestCallback new];CHECK(RDHandleClickNavigation([NSObject new],@"GeckoView:OnPreNavigation",message(bridge(url),YES),c));drain();CHECK([a.opens.lastObject[@"url"] isEqual:url]);CHECK(c.count==1);
 }
 count=a.opens.count;c=[TestCallback new];CHECK(RDHandleClickNavigation([NSObject new],@"GeckoView:OnPreNavigation",message(b,NO),c));drain();CHECK(c.count==1&&a.opens.count==count);
 for(NSString *uri in @[@"https://reynarddefault.invalid/.well-known/handoff/v2#v=2&a=x",@"https://reynarddefault.open/#a=tg%3Aresolve",@"https://reynarddefault.invalid:443/.well-known/handoff/v2#v=2"]) {
  c=[TestCallback new];CHECK(RDHandleClickNavigation([NSObject new],@"GeckoView:OnPreNavigation",message(uri,YES),c));drain();CHECK(c.count==1&&a.opens.count==count);
 }
 enabled=NO;d=[NSObject new];TestBackend *backend=[TestBackend new];objc_setAssociatedObject(d,&kRDBackendKey,backend,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
 c=[TestCallback new];CHECK(RDHandleClickNavigation(d,@"GeckoView:OnPreNavigation",message(b,YES),c));drain();CHECK(a.opens.count==count);CHECK(backend.messages.count==1);CHECK([backend.messages[0][@"payload"][@"uri"] isEqual:@"tg:resolve?domain=moonup_chat&post=12&start=a%2Bb#c"]);
 enabled=YES;a.applicationState=UIApplicationStateBackground;c=[TestCallback new];CHECK(!RDHandleClickNavigation([NSObject new],@"GeckoView:OnPreNavigation",message(web,YES),c));CHECK(a.opens.count==count);
 printf("NATIVE_ROUTER_CHECKS=%u\n",checks);return 0;
}}
