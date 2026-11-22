#import "LCSCellularService.h"
#import "LCSCellularSettings.h"
#import "LCSCellularRuntime.h"
#import <dlfcn.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <fcntl.h>

#if LCS_CELLULAR_DATA_MODULE
#define LCSCellularTask LCSDataModuleTask
#endif
@implementation LCSCellularLine
- (id)copyWithZone:(NSZone *)zone {
    LCSCellularLine *v=[[[self class] allocWithZone:zone] init];
    v.slot=self.slot;v.identity=self.identity;v.name=self.name;v.available=self.available;
    v.stateKnown=self.stateKnown;v.enabled=self.enabled;v.selectionKnown=self.selectionKnown;v.selected=self.selected;return v;
}
@end
@interface LCSCellularToken ()
@property(atomic,readwrite,getter=isCancelled) BOOL cancelled;
@end
@implementation LCSCellularToken
- (void)cancel {self.cancelled=YES;}
@end
@interface LCSCellularTask : NSObject
@property(nonatomic,strong) LCSCellularToken *token;
@property(nonatomic,copy) LCSCellularActionCompletion completion;
@property(nonatomic) NSTimeInterval started;
@property(nonatomic) BOOL completed;
@end
@implementation LCSCellularTask
@end
static BOOL LCSServiceOSSupported(void) {
#ifdef LCS_CELLULAR_SERVICE_TEST
    return YES; // Mock-only native Foundation harness; never enabled in shipping Makefiles.
#else
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion==15;
#endif
}
static BOOL LCSServiceMayMutate(LCSCellularKind kind) {
    if(!LCSCellularMayMutate(kind))return NO;
    NSString *key=kind==LCSCellularSIMManager?@"simManager":@"dataSwitch";
    return [LCSCellularReadPreferences()[key] boolValue];
}
static BOOL LCSAlive(LCSCellularTask *task) {
    return task&&!task.token.cancelled&&!LCSCellularExpiredAt(NSProcessInfo.processInfo.systemUptime,task.started,12.0);
}
static void LCSFinish(LCSCellularTask *task,BOOL verified,NSArray *lines,NSString *message) {
    @synchronized(task){if(task.completed)return;task.completed=YES;}
    dispatch_async(dispatch_get_main_queue(),^{
        if(task.token.cancelled)return;
        LCSCellularActionCompletion completion=task.completion;task.completion=nil;
        if(completion)completion(verified,lines?:@[],message);
    });
}
static NSString *LCSUUIDString(id object) {
    if([object isKindOfClass:NSUUID.class])return [object UUIDString].lowercaseString;
    NSString *s=LCSCellularString(object);return s&&[[NSUUID alloc] initWithUUIDString:s]?s.lowercaseString:nil;
}
static NSString *LCSContextIdentity(id context) {return LCSUUIDString(LCSCellularObject(context,"uuid"));}
static id LCSCallError(id target,const char *name,id argument,BOOL withArgument,NSError **error) {
    SEL sel=sel_registerName(name);const char *args[]={"@","^@"};
    if(!LCSCellularMethod(object_getClass(target),sel,"@",withArgument?2:1,withArgument?args:args+1)) {
        if(error)*error=[NSError errorWithDomain:@"com.local.cleanstatus.cellular.abi" code:1 userInfo:nil];return nil;
    }
    return withArgument?((id(*)(id,SEL,id,NSError *__autoreleasing *))objc_msgSend)(target,sel,argument,error):
        ((id(*)(id,SEL,NSError *__autoreleasing *))objc_msgSend)(target,sel,error);
}
@interface LCSCellularService ()
@property(nonatomic) LCSCellularKind kind;
@property(nonatomic,strong) dispatch_queue_t queue;
@property(nonatomic,strong) id client;
@property(nonatomic) BOOL busy;
- (NSArray *)readNow:(NSString **)error contexts:(NSMutableDictionary *)contexts;
@end
static id LCSSystemTelephonyClient(void) {
    Class cls=NSClassFromString(@"SBTelephonyManager");
    SEL factory=sel_registerName("sharedTelephonyManagerCreatingIfNecessary:");
    const char *boolArgument[]={"B"},*charArgument[]={"c"};
    if(!LCSCellularClassMethod(cls,factory,"@",1,boolArgument)&&!LCSCellularClassMethod(cls,factory,"@",1,charArgument))return nil;
    id manager=((id(*)(id,SEL,BOOL))objc_msgSend)((id)cls,factory,YES);
    return LCSCellularObject(manager,"coreTelephonyClient");
}
static id LCSDirectTelephonyClient(void) {
    Class cls=NSClassFromString(@"CoreTelephonyClient");SEL selector=sel_registerName("initWithQueue:");const char *arguments[]={"@"};
    if(!LCSCellularMethod(cls,selector,"@",1,arguments))return nil;
    return ((id(*)(id,SEL,id))objc_msgSend)([cls alloc],selector,dispatch_get_main_queue());
}
@implementation LCSCellularService
- (instancetype)initWithKind:(LCSCellularKind)kind {
    if(!(self=[super init]))return nil;
    _kind=kind;_queue=dispatch_queue_create("com.local.cleanstatus.cellular.worker",DISPATCH_QUEUE_SERIAL);
    LCSCellularStartConfiguration();
    __block id client=nil;__block NSString *source=@"client-unavailable";
    void (^createClient)(void)=^{
        dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony",RTLD_NOW|RTLD_LOCAL);
        @try {
            id shared=LCSSystemTelephonyClient();SEL read=sel_registerName("getSubscriptionInfoWithError:");const char *args[]={"^@"};
            if(LCSCellularMethod(object_getClass(shared),read,"@",1,args)){client=shared;source=@"system-manager";}
        } @catch(__unused NSException *exception) {client=nil;}
        if(!client)@try {client=LCSDirectTelephonyClient();if(client)source=@"direct-fallback";} @catch(__unused NSException *exception) {client=nil;}
    };
    if(NSThread.isMainThread)createClient();else dispatch_sync(dispatch_get_main_queue(),createClient);
    self.client=client;LCSCellularLog(self.kind,@"client",source,0);
    return self;
}
- (id)telephony {return self.client;}
- (NSArray *)readNow:(NSString **)message contexts:(NSMutableDictionary *)contexts {
    id client=[self telephony];NSError *error=nil;
    if(!client){LCSCellularLog(self.kind,@"read",@"client-unavailable",0);if(message)*message=@"系统电话服务客户端不可用。";return @[];}
    id info=LCSCallError(client,"getSubscriptionInfoWithError:",nil,NO,&error);
    id subscriptions=LCSCellularObject(info,"subscriptions");
    NSArray *subscriptionList=[subscriptions isKindOfClass:NSArray.class]?subscriptions:nil;
    if(error||!subscriptionList) {
        NSString *reason=[error.domain isEqualToString:@"com.local.cleanstatus.cellular.abi"]?@"subscription-abi":(error?@"subscription-error":@"subscription-list-missing");
        LCSCellularLog(self.kind,@"read",reason,0);
        if(message)*message=@"无法读取蜂窝订阅，系统接口或权限尚未确认。";return @[];
    }
    LCSCellularLog(self.kind,@"read",subscriptionList.count?@"subscriptions-ready":@"subscriptions-empty",0);
    NSMutableDictionary *bySlot=[NSMutableDictionary new];NSMutableSet *ambiguous=[NSMutableSet new];
    for(id context in subscriptionList) {
        long long slot=LCSCellularSlot(context);if(slot<1||slot>2)continue;
        NSNumber *key=@(slot);if(bySlot[key])[ambiguous addObject:key];else bySlot[key]=context;
    }
    NSError *selectionError=nil;id selected=LCSCallError(client,"getCurrentDataSubscriptionContextSync:",nil,NO,&selectionError);
    NSString *selectedIdentity=LCSContextIdentity(selected);BOOL selectionKnown=!selectionError&&selectedIdentity.length;
    if(selectionError)LCSCellularLog(self.kind,@"read",@"selection-error",0);
    NSMutableArray *lines=[NSMutableArray new];
    if(self.kind==LCSCellularSIMManager&&!subscriptionList.count&&message)*message=@"未读取到可用的 SIM 线路，请重新读取。";
    for(NSInteger slot=1;slot<=2;slot++) {
        LCSCellularLine *line=[LCSCellularLine new];line.slot=slot;line.name=[NSString stringWithFormat:@"SIM %ld",(long)slot];
        id context=bySlot[@(slot)];NSString *uuid=LCSContextIdentity(context);BOOL unique=![ambiguous containsObject:@(slot)]&&uuid.length>0;
        if(context&&unique) {
            NSError *labelError=nil;NSString *label=LCSCellularString(LCSCallError(client,"copyLabel:error:",context,YES,&labelError));
            if(!labelError&&label.length)line.name=label;
        }
        if(self.kind==LCSCellularDataSwitch) {
            NSError *statusError=nil;NSString *status=context?LCSCellularString(LCSCallError(client,"getSIMStatus:error:",context,YES,&statusError)):nil;
            line.identity=uuid;line.stateKnown=unique&&!statusError&&status.length>0;
            line.enabled=line.stateKnown&&[status isEqualToString:@"kCTSIMSupportSIMStatusReady"];
            line.available=line.enabled;line.selectionKnown=unique&&selectionKnown;
            line.selected=line.selectionKnown&&[uuid isEqualToString:selectedIdentity];
            if(context&&unique)contexts[uuid]=context;
        } else {
            // List subscription state here; only the separately entitled helper
            // queries SIM plans. Plan-entitlement acceptance still needs a device test.
            NSError *statusError=nil;
            NSString *status=context?LCSCellularString(LCSCallError(client,"getSIMStatus:error:",context,YES,&statusError)):nil;
            BOOL statusKnown=context&&!statusError&&status.length>0;
            BOOL ready=statusKnown&&[status isEqualToString:@"kCTSIMSupportSIMStatusReady"];
            line.identity=uuid;line.stateKnown=unique&&statusKnown;
            line.enabled=ready;line.available=line.stateKnown;
        }
        [lines addObject:line];
    }
    return lines;
}
- (LCSCellularTask *)taskWithToken:(LCSCellularToken *)token completion:(LCSCellularActionCompletion)completion {
    LCSCellularTask *task=[LCSCellularTask new];task.token=token?:[LCSCellularToken new];task.completion=completion;
    task.started=NSProcessInfo.processInfo.systemUptime;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,12*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        LCSFinish(task,NO,@[],@"操作超时，尚未确认系统最终状态，请刷新。已发送的请求不能据此认定已撤回。");
    });return task;
}
- (void)readWithToken:(LCSCellularToken *)token completion:(LCSCellularReadCompletion)completion {
    if(!completion)return;
    LCSCellularTask *task=[self taskWithToken:token completion:^(BOOL verified,NSArray *lines,NSString *message){(void)verified;completion(lines,message);}];
    dispatch_async(self.queue,^{
        if(!LCSAlive(task))return;
        NSArray *lines=@[];NSString *message=nil;
        @try {lines=[self readNow:&message contexts:nil];}
        @catch(__unused NSException *exception){LCSCellularLog(self.kind,@"read",@"system-exception",0);message=@"系统拒绝读取蜂窝状态，未更改任何线路。";}
        if(LCSAlive(task))LCSFinish(task,NO,lines,message);
    });
}
- (LCSCellularLine *)lineWithIdentity:(NSString *)identity inLines:(NSArray *)lines {
    LCSCellularLine *result=nil;NSUInteger count=0;
    for(LCSCellularLine *line in lines)if(identity.length&&[line.identity isEqualToString:identity]){result=line;count++;}
    return count==1?result:nil;
}
- (void)endTask:(LCSCellularTask *)task descriptor:(int)fd verified:(BOOL)verified lines:(NSArray *)lines message:(NSString *)message reason:(NSString *)reason slot:(NSInteger)slot {
    self.busy=NO;LCSCellularReleaseOperationLock(fd);
    LCSCellularLog(self.kind,@"result",reason,slot);LCSFinish(task,verified,lines,message);
}
- (void)pollTask:(LCSCellularTask *)task descriptor:(int)fd identity:(NSString *)identity desired:(BOOL)desired slot:(NSInteger)slot {
    if(!LCSAlive(task)||!LCSServiceMayMutate(self.kind)) {
        [self endTask:task descriptor:fd verified:NO lines:@[] message:@"操作已取消、功能已关闭或状态确认超时；已发送的请求仍须刷新核实。" reason:@"cancelled-or-expired" slot:slot];return;
    }
    NSString *message=nil;NSArray *lines=@[];
    @try {lines=[self readNow:&message contexts:nil];}
    @catch(__unused NSException *exception){message=@"无法读回系统最终状态。";}
    LCSCellularLine *fresh=[self lineWithIdentity:identity inLines:lines];
    BOOL known=self.kind==LCSCellularSIMManager?fresh.stateKnown:fresh.selectionKnown;
    BOOL observed=self.kind==LCSCellularSIMManager?fresh.enabled:fresh.selected;
    BOOL verified=LCSCellularReadbackMatches(self.kind,fresh&&[identity isEqualToString:fresh.identity],known,observed,desired);
    if(!LCSAlive(task)||!LCSServiceMayMutate(self.kind)) {
        [self endTask:task descriptor:fd verified:NO lines:@[] message:@"状态已变化，未确认操作结果，请刷新。" reason:@"cancelled-after-read" slot:slot];return;
    }
    if(verified){[self endTask:task descriptor:fd verified:YES lines:lines message:nil reason:@"readback-verified" slot:slot];return;}
    if(lines.count&&!fresh){[self endTask:task descriptor:fd verified:NO lines:lines message:@"目标 SIM 已变化，未确认结果，请重新读取。" reason:@"identity-changed" slot:slot];return;}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,350*NSEC_PER_MSEC),self.queue,^{
        [self pollTask:task descriptor:fd identity:identity desired:desired slot:slot];
    });
}
static NSString *LCSHelperFailureReason(int code) {
    switch(code) {
        case 64:return @"helper-usage";
        case 65:return @"helper-identity";
        case 66:return @"helper-plan-api";
        case 67:return @"helper-gate";
        case 68:return @"helper-request";
        case 69:return @"helper-unusable";
        case 70:return @"helper-plan-changed";
        default:return @"helper-failed";
    }
}
- (void)waitForHelper:(pid_t)pid task:(LCSCellularTask *)task descriptor:(int)fd identity:(NSString *)identity desired:(BOOL)desired slot:(NSInteger)slot {
    int status=0;pid_t waited;do {waited=waitpid(pid,&status,WNOHANG);}while(waited<0&&errno==EINTR);
    if(waited==pid) {
        int code=WIFEXITED(status)?WEXITSTATUS(status):-1;
        if(!WIFEXITED(status)||code!=0) {
            LCSCellularLog(self.kind,@"result",LCSHelperFailureReason(code),slot);
            [self endTask:task descriptor:fd verified:NO lines:@[] message:@"线路工具未接受请求。权限、锁屏或线路信息可能不满足条件，未确认状态改变。" reason:@"helper-refused" slot:slot];return;
        }
        LCSCellularLog(self.kind,@"request",@"helper-accepted-not-verified",slot);
        [self pollTask:task descriptor:fd identity:identity desired:desired slot:slot];return;
    }
    if(waited<0){[self endTask:task descriptor:fd verified:NO lines:@[] message:@"无法确认线路工具结果，请刷新。" reason:@"helper-wait-failed" slot:slot];return;}
    if(!LCSAlive(task)||!LCSServiceMayMutate(self.kind)) {
        // Kill only this child. A radio request already sent by it cannot be rolled back.
        kill(pid,SIGKILL);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),self.queue,^{
            [self waitForHelper:pid task:task descriptor:fd identity:identity desired:desired slot:slot];
        });return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),self.queue,^{
        [self waitForHelper:pid task:task descriptor:fd identity:identity desired:desired slot:slot];
    });
}
- (void)performLine:(LCSCellularLine *)line desired:(BOOL)desired confirmed:(BOOL)confirmed token:(LCSCellularToken *)token completion:(LCSCellularActionCompletion)completion {
    LCSCellularLine *expected=[line copy];
    LCSCellularTask *task=[self taskWithToken:token completion:completion];
    dispatch_async(self.queue,^{
        if(!LCSAlive(task))return;
        if(self.busy){LCSFinish(task,NO,@[],@"已有蜂窝操作正在处理，请等待状态确认。");return;}
        NSError *lockError=nil;int fd=LCSCellularAcquireOperationLock(&lockError);
        if(fd<0){LCSFinish(task,NO,@[],@"另一项蜂窝操作正在处理，或当前隐根不可用。");return;}
        self.busy=YES;NSString *message=nil;NSArray *lines=@[];
        @try {
            NSMutableDictionary *contexts=[NSMutableDictionary new];lines=[self readNow:&message contexts:contexts];
            LCSCellularLine *fresh=[self lineWithIdentity:expected.identity inLines:lines];
            BOOL known=self.kind==LCSCellularSIMManager?fresh.stateKnown:fresh.selectionKnown;
            BOOL allowed=LCSCellularCanWrite(self.kind,LCSCellularFeatureEnabled(self.kind),LCSCellularIsUnlocked(),LCSAlive(task),
                fresh.available,known,expected.identity.length>0,fresh&&[fresh.identity isEqualToString:expected.identity],NO,!desired,confirmed);
            if(!LCSCellularIsSpringBoard()||!LCSServiceOSSupported()||!allowed) {
                [self endTask:task descriptor:fd verified:NO lines:lines message:message?:@"目标线路信息已变化或当前条件不安全，未发送请求。" reason:@"write-gate-refused" slot:expected.slot];return;
            }
            BOOL observed=self.kind==LCSCellularSIMManager?fresh.enabled:fresh.selected;
            if(observed==desired){[self endTask:task descriptor:fd verified:YES lines:lines message:nil reason:@"already-verified" slot:fresh.slot];return;}
            if(self.kind==LCSCellularDataSwitch) {
                id client=[self telephony],context=contexts[expected.identity];SEL prefer=sel_registerName("setUserDataPreferred:"),select=sel_registerName("setActiveUserDataSelection:error:");
                const char *preferArgs[]={"@"},*selectArgs[]={"@","^@"};
                if(!LCSCellularMethod(object_getClass(context),prefer,"v",1,preferArgs)||
                   !LCSCellularMethod(object_getClass(client),select,"v",2,selectArgs)||![context conformsToProtocol:@protocol(NSCopying)]) {
                    [self endTask:task descriptor:fd verified:NO lines:lines message:@"系统数据切换接口签名不匹配，未操作。" reason:@"data-abi-unavailable" slot:fresh.slot];return;
                }
                id target=[context copy];
                if(![LCSContextIdentity(target) isEqualToString:expected.identity]||LCSCellularSlot(target)!=fresh.slot) {
                    [self endTask:task descriptor:fd verified:NO lines:lines message:@"无法确认复制后的目标线路，未操作。" reason:@"copied-identity-changed" slot:fresh.slot];return;
                }
                ((void(*)(id,SEL,id))objc_msgSend)(target,prefer,@YES);
                if(!LCSAlive(task)||!LCSServiceMayMutate(self.kind)) {
                    [self endTask:task descriptor:fd verified:NO lines:lines message:@"已取消，未发送数据切换请求。" reason:@"cancelled-before-write" slot:fresh.slot];return;
                }
                NSError *writeError=nil;
                // This is a void setter. No error means accepted, NEVER verified success.
                ((void(*)(id,SEL,id,NSError *__autoreleasing *))objc_msgSend)(client,select,target,&writeError);
                if(writeError){[self endTask:task descriptor:fd verified:NO lines:lines message:@"系统拒绝数据切换请求，请检查线路与权限。" reason:@"data-request-refused" slot:fresh.slot];return;}
                LCSCellularLog(self.kind,@"request",@"data-accepted-not-verified",fresh.slot);
                [self pollTask:task descriptor:fd identity:expected.identity desired:YES slot:fresh.slot];return;
            }
            NSString *tool=LCSCellularSIMToolPath();
            if(!tool.length){[self endTask:task descriptor:fd verified:NO lines:lines message:@"SIM 启停工具尚不可用，未操作。" reason:@"helper-unavailable" slot:fresh.slot];return;}
            if(!LCSAlive(task)||!LCSServiceMayMutate(self.kind)) {
                [self endTask:task descriptor:fd verified:NO lines:lines message:@"已取消，未启动 SIM 工具。" reason:@"cancelled-before-helper" slot:fresh.slot];return;
            }
            NSString *target=desired?@"1":@"0";
            if(!LCSCellularHelperArgumentValid(expected.identity.UTF8String,target.UTF8String)) {
                [self endTask:task descriptor:fd verified:NO lines:lines message:@"线路身份参数无效，未启动工具。" reason:@"invalid-helper-argument" slot:fresh.slot];return;
            }
            char *args[]={(char *)tool.fileSystemRepresentation,(char *)expected.identity.UTF8String,(char *)target.UTF8String,NULL};
            char *environment[]={"PATH=/usr/bin:/bin",NULL};
            posix_spawn_file_actions_t actions;int setup=posix_spawn_file_actions_init(&actions);
            if(!setup) {
                setup=posix_spawn_file_actions_addopen(&actions,STDIN_FILENO,"/dev/null",O_RDONLY,0);
                if(!setup)setup=posix_spawn_file_actions_addopen(&actions,STDOUT_FILENO,"/dev/null",O_WRONLY,0);
                if(!setup)setup=posix_spawn_file_actions_addopen(&actions,STDERR_FILENO,"/dev/null",O_WRONLY,0);
                if(setup){posix_spawn_file_actions_destroy(&actions);}
            }
            if(setup){[self endTask:task descriptor:fd verified:NO lines:lines message:@"未能建立安全的工具运行环境。" reason:@"helper-setup-failed" slot:fresh.slot];return;}
            pid_t pid=0;int result=posix_spawn(&pid,tool.fileSystemRepresentation,&actions,NULL,args,environment);
            posix_spawn_file_actions_destroy(&actions);
            if(result||pid<=0){[self endTask:task descriptor:fd verified:NO lines:lines message:@"无法启动 SIM 工具，权限或签名尚未验证。" reason:@"helper-spawn-failed" slot:fresh.slot];return;}
            [self waitForHelper:pid task:task descriptor:fd identity:expected.identity desired:desired slot:fresh.slot];
        } @catch(__unused NSException *exception) {
            [self endTask:task descriptor:fd verified:NO lines:lines message:@"系统接口调用未完成，未确认最终状态，请刷新。" reason:@"system-exception" slot:expected.slot];
        }
    });
}
- (void)selectDataLine:(LCSCellularLine *)line token:(LCSCellularToken *)token completion:(LCSCellularActionCompletion)completion {
    if(self.kind!=LCSCellularDataSwitch){dispatch_async(dispatch_get_main_queue(),^{if(completion)completion(NO,@[],@"入口类型不匹配，未操作。");});return;}
    [self performLine:line desired:YES confirmed:YES token:token completion:completion];
}
- (void)setSIMLine:(LCSCellularLine *)line enabled:(BOOL)enabled confirmed:(BOOL)confirmed token:(LCSCellularToken *)token completion:(LCSCellularActionCompletion)completion {
    if(self.kind!=LCSCellularSIMManager){dispatch_async(dispatch_get_main_queue(),^{if(completion)completion(NO,@[],@"入口类型不匹配，未操作。");});return;}
    [self performLine:line desired:enabled confirmed:confirmed token:token completion:completion];
}
@end
