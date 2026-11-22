// Apple Foundation-only test doubles. Never link CoreTelephony or touch a radio.
#import <Foundation/Foundation.h>
#import "LCSCellularService.h"
#import "LCSCellularSettings.h"
static BOOL unlocked=YES,enabled=YES,ignoreWrite=NO;
static NSUInteger writes,checks,clientInitCalls,managerFactoryCalls;
static BOOL managerAvailable=YES,failSubscriptionRead=NO;
static NSString *lastClientReason,*lastReadReason;
static NSMutableArray *contexts;
static id selected;
#define REQUIRE(x) do{if(!(x)){fprintf(stderr,"service assertion failed at %d\n",__LINE__);exit(1);}checks++;}while(0)
NSString * const LCSCellularPreferencesDidChange=@"fixture-change";
void LCSCellularStartConfiguration(void){}
BOOL LCSCellularFeatureEnabled(LCSCellularKind kind){return LCSCellularKindValid(kind)&&enabled;}
BOOL LCSCellularIsSpringBoard(void){return YES;}
BOOL LCSCellularIsUnlocked(void){return unlocked;}
BOOL LCSCellularMayMutate(LCSCellularKind kind){return LCSCellularFeatureEnabled(kind)&&unlocked;}
NSDictionary *LCSCellularReadPreferences(void){return @{@"simManager":@(enabled),@"dataSwitch":@(enabled)};}
int LCSCellularAcquireOperationLock(NSError **error){(void)error;return 7;}
void LCSCellularReleaseOperationLock(int fd){(void)fd;}
NSString *LCSCellularSIMToolPath(void){return nil;}
void LCSCellularLog(LCSCellularKind kind,NSString *event,NSString *reason,NSInteger slot){(void)kind;(void)slot;if([event isEqualToString:@"client"])lastClientReason=reason;if([event isEqualToString:@"read"])lastReadReason=reason;}
@interface FixtureContext:NSObject<NSCopying>
@property(nonatomic) long long slotID;
@property(nonatomic,strong) NSUUID *uuid;
@property(nonatomic,strong) NSNumber *userDataPreferred;
@end
@implementation FixtureContext
- (id)copyWithZone:(NSZone *)zone {FixtureContext *v=[[[self class] allocWithZone:zone] init];v.slotID=self.slotID;v.uuid=self.uuid;return v;}
@end
@interface FixtureInfo:NSObject
@property(nonatomic,copy) NSArray *subscriptions;
@end
@implementation FixtureInfo
@end
@interface CoreTelephonyClient:NSObject
- (instancetype)initWithQueue:(id)queue;
- (id)getSubscriptionInfoWithError:(NSError **)error;
- (id)getCurrentDataSubscriptionContextSync:(NSError **)error;
- (id)getSIMStatus:(id)context error:(NSError **)error;
- (id)copyLabel:(id)context error:(NSError **)error;
- (void)setActiveUserDataSelection:(id)context error:(NSError **)error;
@end
@implementation CoreTelephonyClient
- (instancetype)initWithQueue:(id)queue {(void)queue;clientInitCalls++;return [super init];}
- (id)getSubscriptionInfoWithError:(NSError **)error {if(failSubscriptionRead){if(error)*error=[NSError errorWithDomain:@"fixture.telephony" code:7 userInfo:nil];return nil;}FixtureInfo *v=[FixtureInfo new];v.subscriptions=contexts;return v;}
- (id)getCurrentDataSubscriptionContextSync:(NSError **)error {(void)error;return selected;}
- (id)getSIMStatus:(id)context error:(NSError **)error {(void)context;(void)error;return @"kCTSIMSupportSIMStatusReady";}
- (id)copyLabel:(id)context error:(NSError **)error {(void)context;(void)error;return @"测试线路";}
- (void)setActiveUserDataSelection:(id)context error:(NSError **)error {(void)error;writes++;if(!ignoreWrite)selected=context;}
@end
@interface SBTelephonyManager:NSObject
@property(nonatomic,strong) id coreTelephonyClient;
+ (id)sharedTelephonyManagerCreatingIfNecessary:(BOOL)create;
@end
@implementation SBTelephonyManager
+ (id)sharedTelephonyManagerCreatingIfNecessary:(BOOL)create {REQUIRE(create);managerFactoryCalls++;if(!managerAvailable)return nil;static CoreTelephonyClient *client;static dispatch_once_t once;dispatch_once(&once,^{client=[[CoreTelephonyClient alloc] initWithQueue:NSOperationQueue.mainQueue];});SBTelephonyManager *manager=[SBTelephonyManager new];manager.coreTelephonyClient=client;return manager;}
@end
static BOOL Wait(BOOL (^finished)(void),NSTimeInterval seconds) {
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while(!finished()&&[end timeIntervalSinceNow]>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    return finished();
}
static FixtureContext *Context(long long slot) {FixtureContext *v=[FixtureContext new];v.slotID=slot;v.uuid=NSUUID.UUID;return v;}
int main(void) {@autoreleasepool {
    // The test build substitutes only the OS-version gate, not identities, ABI or policy.
    contexts=[NSMutableArray arrayWithObjects:Context(1),Context(2),nil];selected=contexts[0];
    LCSCellularService *service=[[LCSCellularService alloc] initWithKind:LCSCellularDataSwitch];
    REQUIRE(managerFactoryCalls==1&&clientInitCalls==1);REQUIRE([lastClientReason isEqualToString:@"system-manager"]);
    __block BOOL done=NO;__block NSArray *lines=nil;__block BOOL verified=NO;
    [service readWithToken:[LCSCellularToken new] completion:^(NSArray *v,NSString *error){REQUIRE(NSThread.isMainThread);REQUIRE(!error);lines=v;done=YES;}];
    REQUIRE(Wait(^BOOL{return done;},2));REQUIRE(lines.count==2);REQUIRE([lines[0] selected]&&![lines[1] selected]);
    failSubscriptionRead=YES;done=NO;
    [service readWithToken:[LCSCellularToken new] completion:^(NSArray *v,NSString *error){(void)v;REQUIRE(error.length>0);done=YES;}];
    REQUIRE(Wait(^BOOL{return done;},2));REQUIRE([lastReadReason isEqualToString:@"subscription-error"]);failSubscriptionRead=NO;
    LCSCellularLine *oldSecond=[lines[1] copy];done=NO;
    [service selectDataLine:oldSecond token:[LCSCellularToken new] completion:^(BOOL ok,NSArray *v,NSString *error){REQUIRE(!error);verified=ok;lines=v;done=YES;}];
    REQUIRE(Wait(^BOOL{return done;},2));REQUIRE(verified&&writes==1&&[lines[1] selected]);
    contexts[1]=Context(2);done=NO;verified=YES;
    [service selectDataLine:oldSecond token:[LCSCellularToken new] completion:^(BOOL ok,NSArray *v,NSString *error){(void)v;REQUIRE(error.length>0);verified=ok;done=YES;}];
    REQUIRE(Wait(^BOOL{return done;},2));REQUIRE(!verified&&writes==1);
    managerAvailable=NO;LCSCellularService *fallback=[[LCSCellularService alloc] initWithKind:LCSCellularDataSwitch];
    REQUIRE(managerFactoryCalls==2&&clientInitCalls==2);REQUIRE([lastClientReason isEqualToString:@"direct-fallback"]);REQUIRE(fallback!=nil);managerAvailable=YES;
    LCSCellularToken *cancelled=[LCSCellularToken new];[cancelled cancel];done=NO;
    [service selectDataLine:oldSecond token:cancelled completion:^(BOOL ok,NSArray *v,NSString *error){(void)ok;(void)v;(void)error;done=YES;}];
    REQUIRE(!Wait(^BOOL{return done;},.1));REQUIRE(writes==1);
    done=NO;[service readWithToken:[LCSCellularToken new] completion:^(NSArray *v,NSString *error){(void)error;lines=v;done=YES;}];REQUIRE(Wait(^BOOL{return done;},2));
    unlocked=NO;done=NO;
    [service selectDataLine:lines[0] token:[LCSCellularToken new] completion:^(BOOL ok,NSArray *v,NSString *error){(void)v;REQUIRE(!ok&&error.length>0);done=YES;}];
    REQUIRE(Wait(^BOOL{return done;},2));REQUIRE(writes==1);unlocked=YES;
    enabled=NO;done=NO;
    [service selectDataLine:lines[0] token:[LCSCellularToken new] completion:^(BOOL ok,NSArray *v,NSString *error){(void)v;REQUIRE(!ok&&error.length>0);done=YES;}];
    REQUIRE(Wait(^BOOL{return done;},2));REQUIRE(writes==1);enabled=YES;
    // A void setter that reports no error but does nothing must not claim success.
    ignoreWrite=YES;selected=contexts[1];done=NO;LCSCellularToken *pending=[LCSCellularToken new];
    [service selectDataLine:lines[0] token:pending completion:^(BOOL ok,NSArray *v,NSString *error){(void)v;(void)error;verified=ok;done=YES;}];
    REQUIRE(!Wait(^BOOL{return done;},.6));REQUIRE(writes==2);[pending cancel];
    REQUIRE(!Wait(^BOOL{return done;},.5));
    printf("PASS Apple Foundation service: %lu assertions; mock subscriptions only, no radio.\n",(unsigned long)checks);
}return 0;}
