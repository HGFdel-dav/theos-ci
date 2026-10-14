//  TIMCleanKit.dylib — TIM (com.tencent.tim) 净化/增强插件
//  目标：TIM 4.1.0 (NT 架构)，1.0.4 功能修订与诊断版
//  功能：消息监听 / 前台自动红包领取 / 内存防撤回 / 复读 / 闪照保存 / 原生设置
//  构建：Theos (Logos)，arm64 + arm64e
//
//  设计原则：所有 Hook 均通过 NSClassFromString 动态获取类，
//  目标不存在或签名不匹配时跳过。TIM 与 QQ 共用的消息内核类
//  (OCMsgRecord/OCMsgsReq/OCIKernelMsgService) 双端通用。

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <sys/sysctl.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import <unistd.h>

// ---------------------------------------------------------------- 配置键
//  TIMCleanKit 自有前缀，避免与其它插件冲突
static NSString *const kDomain      = @"com.tencent.tim";
static NSString *const kAutoRed = @"TIMCK.autoRed";
static NSString *const kRepeater = @"TIMCK.repeater";
static NSString *const kBlankTap = @"TIMCK.blankTap";
static NSString *const kEnabled     = @"TIMCK.enabled";         // 总开关
static NSString *const kAntiRecall  = @"TIMCK.antiRecall";      // 防撤回
static NSString *const kFlashPhoto  = @"TIMCK.flashPhoto";      // 闪照/截屏
static NSString *const kDeviceSpoof = @"TIMCK.deviceSpoof";     // 设备伪装
static NSString *const kSpoofModel  = @"TIMCK.spoofModel";      // 伪装机型
static NSString *const kRedPacket   = @"TIMCK.redPacket";       // 红包过滤总开关
static NSString *const kRedMinAmount= @"TIMCK.redMinAmount";    // 小额阈值(分)，0=不启用
static NSString *const kRedSkipTest = @"TIMCK.redSkipTest";     // 测试红包不抢
static NSString *const kRedSkipCmd  = @"TIMCK.redSkipCommand";  // 口令红包不抢

#define LOG(fmt, ...) do { \
    if (getenv("TIMCK_DEBUG")) NSLog(@"[TIMCleanKit] " fmt, ##__VA_ARGS__); \
} while (0)

// ---------------------------------------------------------- 配置读写
static NSUserDefaults *prefs(void) {
    return [NSUserDefaults standardUserDefaults];
}
static BOOL prefBool(NSString *key, BOOL def) {
    id v = [prefs() objectForKey:key];
    return v ? [v boolValue] : def;
}
static NSInteger prefInt(NSString *key, NSInteger def) {
    id v = [prefs() objectForKey:key];
    return v ? [v integerValue] : def;
}
static NSString *prefStr(NSString *key, NSString *def) {
    id v = [prefs() objectForKey:key];
    return ([v isKindOfClass:[NSString class]] && [v length]) ? v : def;
}

// 首次注入时写入默认值，保证面板开关立即可见
static void registerDefaultsOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *d = @{
            kEnabled:     @YES,
            kBlankTap:    @YES,
            kAutoRed:     @YES,
            kRepeater:    @YES,
            kAntiRecall:  @YES,
            kFlashPhoto:  @YES,
            kDeviceSpoof: @NO,
            kSpoofModel:  @"iPhone 15 Pro",
            kRedPacket:   @YES,
            kRedMinAmount:@(100),      // 默认 1.00 元以下不抢
            kRedSkipTest: @YES,
            kRedSkipCmd:  @NO,
        };
        [prefs() registerDefaults:d];
        [prefs() synchronize];
    });
}

static BOOL TKSameSignature(const char *actual,const char *expected);

// 从字符串中解析金额(单位:分)，找不到返回 -1
static long long amountFromString(NSString *s);
// 动态取值：避免依赖未声明的类接口
static id TK_performObject(id obj, NSString *prop) {
    if (!obj || !prop) return nil;
    SEL s = NSSelectorFromString(prop);
    if (![obj respondsToSelector:s]) return nil;
    NSMethodSignature *sig = [obj methodSignatureForSelector:s];
    if (!sig || sig.numberOfArguments != 2 || sig.methodReturnType[0] != '@' || sig.methodReturnLength != sizeof(id)) return nil;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:s];
    [inv setTarget:obj];
    [inv invoke];
    id __unsafe_unretained r = nil;
    [inv getReturnValue:&r];
    return r;
}

// ------------------------------------------------------ 红包金额/类型解析
// TIM 与 QQ 共用 OCWalletElement。属性(已从 TIM 4.1.0 二进制核对):
//   redType (int)  grabState (uint32)  grabbedAmount (uint64)
//   envelopeId (int)  billNo/authkey/name/pcBody/stringIndex ...
// 其中 sender/receiver 为 OCWalletAio(title/content/notice...)
static id findElementOfClass(NSArray *elements, NSString *clsName) {
    if (![elements isKindOfClass:[NSArray class]]) return nil;
    Class c = NSClassFromString(clsName);
    if (!c) return nil;
    for (id e in elements) {
        if ([e isKindOfClass:c]) return e;
        id wallet = TK_performObject(e, @"walletElement");
        if ([wallet isKindOfClass:c]) return wallet;
    }
    return nil;
}

static id msgRecordElement(NSArray *elements) {
    return findElementOfClass(elements, @"OCWalletElement");
}

// 从红包元素尽量取出金额(单位:分)。返回 -1 表示无法确定
static long long redPacketAmount(id element) {
    if (!element) return -1;
    // 1) 直接取 grabbedAmount (TIM 客户端已知的金额字段)
    if ([element respondsToSelector:@selector(grabbedAmount)]) {
        // 属性为 unsigned long long，用 NSInvocation 规避编译器类型
        NSMethodSignature *sig = [element methodSignatureForSelector:@selector(grabbedAmount)];
        if (sig && sig.numberOfArguments == 2 && sig.methodReturnLength == sizeof(unsigned long long) && !strcmp(sig.methodReturnType, @encode(unsigned long long))) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:@selector(grabbedAmount)];
            [inv setTarget:element];
            [inv invoke];
            unsigned long long v = 0;
            [inv getReturnValue:&v];
            if (v > 0 && v < 1000000000000LL) return (long long)v;
        }
    }
    // 2) 从 OCWalletAio 的 title/content 里正则抓 "1.23元" / "¥1.23"
    id aio = TK_performObject(element, @"sender");
    if (!aio) aio = TK_performObject(element, @"receiver");
    if (!aio) return -1;
    for (NSString *prop in @[@"title", @"content", @"notice", @"subTitle"]) {
        SEL s = NSSelectorFromString(prop);
        if ([aio respondsToSelector:s]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id v = [aio performSelector:s];
#pragma clang diagnostic pop
            if ([v isKindOfClass:[NSString class]]) {
                long long cents = amountFromString((NSString *)v);
                if (cents >= 0) return cents;
            }
        }
    }
    return -1;
}

static long long amountFromString(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || !s.length) return -1;
    // 形如 1.23 / 12.34，支持中文"元"
    NSString *pat = @"([0-9]+(?:\\.[0-9]+)?)\\s*(?:元|块|\\$)";
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (!m) return -1;
    NSString *num = [s substringWithRange:[m rangeAtIndex:1]];
    NSDecimalNumber *d = [NSDecimalNumber decimalNumberWithString:num];
    if ([d isEqualToNumber:[NSDecimalNumber notANumber]]) return -1;
    return (long long)([d doubleValue] * 100.0);
}

// 判断是否"测试红包"
static BOOL isTestRedPacket(id element) {
    if (!element) return NO;
    NSMutableArray *texts = [NSMutableArray array];
    id aio = TK_performObject(element, @"sender");
    if (!aio) aio = TK_performObject(element, @"receiver");
    if (aio) {
        for (NSString *prop in @[@"title", @"content", @"notice", @"subTitle"]) {
            SEL s = NSSelectorFromString(prop);
            if ([aio respondsToSelector:s]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id v = [aio performSelector:s];
#pragma clang diagnostic pop
                if ([v isKindOfClass:[NSString class]]) [texts addObject:v];
            }
        }
    }
    for (NSString *prop in @[@"name", @"billNo"]) {
        id v = TK_performObject(element, prop);
        if ([v isKindOfClass:[NSString class]]) [texts addObject:v];
    }
    for (NSString *t in texts) {
        NSRange r = [t rangeOfString:@"测试" options:NSCaseInsensitiveSearch];
        if (r.location != NSNotFound) return YES;
        NSRange r2 = [t rangeOfString:@"体验" options:NSCaseInsensitiveSearch];
        if (r2.location != NSNotFound) return YES;
    }
    return NO;
}

// 从消息记录里取出红包元素
static id redElementFromRecord(id record) {
    if (!record) return nil;
    Class recordClass=NSClassFromString(@"OCMsgRecord");
    if(!recordClass || ![record isKindOfClass:recordClass])return nil;
    id els=TK_performObject(record,@"elements");
    return msgRecordElement((NSArray *)els);
}

// 核心：这条消息是否应该被"不抢"
static BOOL shouldSkipRedPacket(id record) {
    if (!prefBool(kRedPacket, YES)) return NO;
    if (!prefBool(kEnabled, YES))  return NO;
    Class recordClass=NSClassFromString(@"OCMsgRecord");
    if(!recordClass || ![record isKindOfClass:recordClass])return NO;
    id element = redElementFromRecord(record);

    // 口令红包
    if (prefBool(kRedSkipCmd, NO)) {
        Class router = NSClassFromString(@"NTRedPackRouterService");
        if (router) {
            SEL s = @selector(isCommandRedPack:);
            if ([router respondsToSelector:s] && TKSameSignature(method_getTypeEncoding(class_getClassMethod(router,s)), "B24@0:8@16")) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                BOOL isCmd = ((BOOL (*)(id, SEL, id))objc_msgSend)(router, s, record);
#pragma clang diagnostic pop
                if (isCmd) { LOG(@"skip command red packet"); return YES; }
            }
        }
    }
    if (!element) return NO;

    // 测试红包
    if (prefBool(kRedSkipTest, YES) && isTestRedPacket(element)) {
        LOG(@"skip test red packet"); return YES;
    }
    // 小额
    NSInteger min = prefInt(kRedMinAmount, 100);
    if (min > 0) {
        long long amount = redPacketAmount(element);
        if (amount >= 0 && amount < (long long)min) {
            LOG(@"skip small red packet: %lld < %ld", amount, (long)min);
            return YES;
        }
    }
    return NO;
}


// ================================================================ Hook 框架
// 全部采用「NSClassFromString + MSHookMessageEx」动态注册：
//   验证真实方法签名，缺失或签名不匹配时跳过。
//   TIM 与 QQ 共用的消息内核类两端通用。

typedef struct { const char *className; SEL selector; IMP original; IMP replacement; const char *encoding; unsigned state; unsigned long long hits; } TKHookRecord;
static TKHookRecord gHooks[32];
static unsigned gHookCount;
static unsigned gRegistrationRounds;
static const char *TKExpectedEncoding(NSString *name, SEL selector) {
    const char *sel=sel_getName(selector);
    if ([name isEqualToString:@"OCMsgRecord"]) {
        if(!strcmp(sel,"setRecallTime:"))return "v24@0:8q16";
        if(!strcmp(sel,"recallTime"))return "q16@0:8";
        if(!strcmp(sel,"elements"))return "@16@0:8";
        if(!strcmp(sel,"setElements:"))return "v24@0:8@16";
        if(!strcmp(sel,"msgType"))return "i16@0:8";
        if(!strcmp(sel,"setMsgType:"))return "v20@0:8i16";
    }
    if ([name isEqualToString:@"OCMsgsReq"]) {
        if(!strcmp(sel,"includeDeleteMsg"))return "B16@0:8";
        if(!strcmp(sel,"setIncludeDeleteMsg:"))return "v20@0:8B16";
    }
    if ([name isEqualToString:@"OCIKernelMsgService"]) {
        if(!strcmp(sel,"getMsgsBySeqAndCount:msgSeq:cnt:queryOrder:incloudeDeleteMsg:cb:"))return "v52@0:8@16q24i32B36B40@44";
        if(!strcmp(sel,"getMsgsWithMsgTimeAndClientSeqForC2C:msgTime:clientSeq:cnt:needIncludeSelf:queryOrder:incloudeDeleteMsg:cb:"))return "v64@0:8@16q24q32i40B44B48B52@56";
    }
    if ([name isEqualToString:@"NTRedPackRouterService"]) {
        if(!strcmp(sel,"handleRedPackViewClickWithRootVC:msgRecord:gesture:completion:"))return "v48@0:8@16@24@32@?40";
        if(!strcmp(sel,"checkCanOpenRedPack:resultTip:"))return "B32@0:8@16^@24";
        if(!strcmp(sel,"grabCommandRedPackIfCanWithMsgRecord:"))return "v24@0:8@16";
        if(!strcmp(sel,"shouldShowRedPackBubbleWithRootVC:msgRecord:"))return "B32@0:8@16@24";
    }
    if([name isEqualToString:@"PhotoBrowserFlashPictureService"])return "@24@0:8@16";
    if([name isEqualToString:@"QQWalletPreGrapHBResultViewController"])return "v16@0:8";
    if([name isEqualToString:@"_TtC15AIOPhotoBrowser43NTAIOFlashPicturePhotoBrowserViewController"])return "v24@0:8@16";
    if([name isEqualToString:@"UIDevice"])return "@16@0:8";
    return NULL;
}
static BOOL TKTypesEqual(const char *a,const char *b) {
    while(*a && strchr("rnNoORV",*a))a++;
    while(*b && strchr("rnNoORV",*b))b++;
    if(a[0]=='@'&&b[0]=='@')return (a[1]=='?')==(b[1]=='?');
    return !strcmp(a,b);
}
static BOOL TKSameSignature(const char *actual,const char *expected) {
    if(!actual||!expected)return NO;
    NSMethodSignature *a=[NSMethodSignature signatureWithObjCTypes:actual],*b=[NSMethodSignature signatureWithObjCTypes:expected];
    if(!a||!b||a.numberOfArguments!=b.numberOfArguments||!TKTypesEqual(a.methodReturnType,b.methodReturnType))return NO;
    for(NSUInteger i=0;i<a.numberOfArguments;i++)if(!TKTypesEqual([a getArgumentTypeAtIndex:i],[b getArgumentTypeAtIndex:i]))return NO;
    return YES;
}
static TKHookRecord *TKRecord(NSString *name,SEL sel) {
    unsigned count=__atomic_load_n(&gHookCount,__ATOMIC_ACQUIRE);
    const char *text=name.UTF8String;
    for(unsigned i=0;i<count;i++)if(gHooks[i].selector==sel&&!strcmp(gHooks[i].className,text))return &gHooks[i];
    return NULL;
}
static void InstallHook(NSString *name,SEL sel,IMP replacement,BOOL isClassMethod) {
    TKHookRecord *r=TKRecord(name,sel);
    if(!r){
        unsigned count=gHookCount;if(count>=32)return;
        r=&gHooks[count];r->className=strdup(name.UTF8String);r->selector=sel;r->replacement=replacement;
        __atomic_store_n(&gHookCount,count+1,__ATOMIC_RELEASE);
    }
    unsigned state=__atomic_load_n(&r->state,__ATOMIC_ACQUIRE);
    if(state==3||state==4)return;
    Class cls=NSClassFromString(name);
    if(!cls){__atomic_store_n(&r->state,0,__ATOMIC_RELEASE);return;}
    Class target=isClassMethod?object_getClass(cls):cls;
    Method method=class_getInstanceMethod(target,sel);
    if(!method){__atomic_store_n(&r->state,1,__ATOMIC_RELEASE);return;}
    r->encoding=method_getTypeEncoding(method);
    if(!TKSameSignature(r->encoding,TKExpectedEncoding(name,sel))){__atomic_store_n(&r->state,2,__ATOMIC_RELEASE);return;}
    // Preseed fallback before publishing replacement; installation is serialized on main.
    r->original=method_getImplementation(method);
    MSHookMessageEx(target,sel,replacement,&r->original);
    IMP installed=class_getMethodImplementation(target,sel);
    __atomic_store_n(&r->state,(installed==replacement)?3:4,__ATOMIC_RELEASE);
}
static IMP OrigIMP(NSString *name,SEL sel) {
    TKHookRecord *r=TKRecord(name,sel);
    if(r)__atomic_fetch_add(&r->hits,1,__ATOMIC_RELAXED);
    return r?r->original:NULL;
}
// ============================================================ 1. 防撤回
// TIM 与 QQ 共用 NT 消息内核，方法名一致：
//   -[OCMsgRecord setRecallTime:]       标记撤回时间
//   -[OCIKernelMsgService recallMsg:msgIds:cb:]  触发撤回
static char kTKRecallFlag;
static BOOL TKAntiRecallEnabled(void) {return prefBool(kEnabled,YES)&&prefBool(kAntiRecall,YES);}
static void AR_setRecallTime(id self,SEL cmd,long long value) {
    IMP orig=OrigIMP(@"OCMsgRecord",cmd);
    if(TKAntiRecallEnabled()) {
        if(value>0)objc_setAssociatedObject(self,&kTKRecallFlag,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if(orig)((void(*)(id,SEL,long long))orig)(self,cmd,value);
}
static long long AR_recallTime(id self,SEL cmd) {
    IMP orig=OrigIMP(@"OCMsgRecord",cmd);
    long long value=orig?((long long(*)(id,SEL))orig)(self,cmd):0;
    return TKAntiRecallEnabled()?0:value;
}
static BOOL AR_includeDelete(id self,SEL cmd) {
    IMP orig=OrigIMP(@"OCMsgsReq",cmd);
    return TKAntiRecallEnabled()?YES:(orig?((BOOL(*)(id,SEL))orig)(self,cmd):NO);
}
static void AR_setIncludeDelete(id self,SEL cmd,BOOL value) {
    IMP orig=OrigIMP(@"OCMsgsReq",cmd);
    if(orig)((void(*)(id,SEL,BOOL))orig)(self,cmd,TKAntiRecallEnabled()?YES:value);
}
static void AR_querySeq(id self,SEL cmd,id peer,long long seq,int count,BOOL order,BOOL includeDeleted,id callback) {
    IMP orig=OrigIMP(@"OCIKernelMsgService",cmd);
    if(orig)((void(*)(id,SEL,id,long long,int,BOOL,BOOL,id))orig)(self,cmd,peer,seq,count,order,TKAntiRecallEnabled()?YES:includeDeleted,callback);
}
static void AR_queryTime(id self,SEL cmd,id peer,long long time,long long clientSeq,int count,BOOL includeSelf,BOOL order,BOOL includeDeleted,id callback) {
    IMP orig=OrigIMP(@"OCIKernelMsgService",cmd);
    if(orig)((void(*)(id,SEL,id,long long,long long,int,BOOL,BOOL,BOOL,id))orig)(self,cmd,peer,time,clientSeq,count,includeSelf,order,TKAntiRecallEnabled()?YES:includeDeleted,callback);
}


// ============================================================ 2. 复读
// initWithCpp: and automatic duplicate forwarding intentionally unhooked.

// ============================================================ 3. 闪照/截屏
// TIM 使用 UIScreen.isCaptured（已确认 TIM 二进制引用该 selector）
// ============================================================ 4. 设备伪装
static NSString *SP_model(id self, SEL _cmd) {
    IMP orig = OrigIMP(@"UIDevice", _cmd);
    if (prefBool(kEnabled, YES) && prefBool(kDeviceSpoof, NO)) {
        return prefStr(kSpoofModel, @"iPhone 15 Pro");
    }
    return orig ? ((NSString *(*)(id, SEL))orig)(self, _cmd) : @"iPhone";
}
static NSString *SP_localizedModel(id self, SEL _cmd) {
    IMP orig = OrigIMP(@"UIDevice", _cmd);
    if (prefBool(kEnabled, YES) && prefBool(kDeviceSpoof, NO)) {
        return prefStr(kSpoofModel, @"iPhone 15 Pro");
    }
    return orig ? ((NSString *(*)(id, SEL))orig)(self, _cmd) : @"iPhone";
}
// sysctl/sysctlbyname unhooked: no Foundation calls in low-level system functions.

// ============================================================ 5. 红包过滤
// TIM 4.1.0 红包核心：NTRedPackRouterService（类方法，已从二进制核对 26 个方法）
//   + handleRedPackViewClickWithRootVC:msgRecord:gesture:completion:
//   + checkCanOpenRedPack:resultTip:
//   + grabCommandRedPackIfCanWithMsgRecord:
//   + shouldShowRedPackBubbleWithRootVC:msgRecord:
//   + canGrabCommandRedPack:  + isCommandRedPack:
static void RPkt_handleClick(id self, SEL _cmd, id vc, id record, id gesture, id completion) {
    if (shouldSkipRedPacket(record)) {
        (void)OrigIMP(@"NTRedPackRouterService",_cmd);
        LOG(@"red packet click blocked");
        return;
    }
    IMP orig = OrigIMP(@"NTRedPackRouterService", _cmd);
    if (orig) ((void (*)(id, SEL, id, id, id, id))orig)(self, _cmd, vc, record, gesture, completion);
}
static BOOL RPkt_checkCanOpen(id self, SEL _cmd, id pack, NSString **tip) {
    if (shouldSkipRedPacket(pack)) {
        (void)OrigIMP(@"NTRedPackRouterService",_cmd);
        if (tip) *tip = @"TIMCleanKit 已拦截";
        return NO;
    }
    IMP orig = OrigIMP(@"NTRedPackRouterService", _cmd);
    return orig ? ((BOOL (*)(id, SEL, id, NSString **))orig)(self, _cmd, pack, tip) : NO;
}
static void RPkt_grabCommand(id self, SEL _cmd, id record) {
    if (shouldSkipRedPacket(record)) { (void)OrigIMP(@"NTRedPackRouterService",_cmd); LOG(@"command red packet blocked"); return; }
    IMP orig = OrigIMP(@"NTRedPackRouterService", _cmd);
    if (orig) ((void (*)(id, SEL, id))orig)(self, _cmd, record);
}
static BOOL RPkt_shouldShowBubble(id self, SEL _cmd, id vc, id record) {
    if (shouldSkipRedPacket(record)) { (void)OrigIMP(@"NTRedPackRouterService",_cmd); return NO; }
    IMP orig = OrigIMP(@"NTRedPackRouterService", _cmd);
    return orig ? ((BOOL (*)(id, SEL, id, id))orig)(self, _cmd, vc, record) : NO;
}


// Message objects remain in memory only. Diagnostics contain counters, never message content.
static id gTKListener,gTKMessageService;
static unsigned long long gTKListenerToken;
static NSMutableDictionary *gTKMessageCache;
static NSMutableArray *gTKRecentMessages;
static NSMutableSet *gTKSeenRedPackets;
static NSString *gTKCurrentClaimIdentity;
static unsigned long long gTKReceived,gTKAutoAttempts,gTKAutoCompleted,gTKAutoErrors,gTKFlashSaved,gTKRepeats;
static NSString *gTKEngineStatus=@"等待登录会话";
static BOOL gTKAutoBusy;
static unsigned long long gTKAutoGeneration;
static BOOL gTKListenerRegistered;
static NSMutableArray *gTKRedQueue;
static id TKObjectCall(id obj,NSString *method){return TK_performObject(obj,method);}
static long long TKScalar(id obj,NSString *method,const char *encoding) {
    SEL sel=NSSelectorFromString(method);NSMethodSignature *sig=[obj methodSignatureForSelector:sel];
    if(!sig||sig.numberOfArguments!=2||strcmp(sig.methodReturnType,encoding))return 0;
    NSInvocation *inv=[NSInvocation invocationWithMethodSignature:sig];inv.target=obj;inv.selector=sel;[inv invoke];
    if(!strcmp(encoding,"i")){int v=0;[inv getReturnValue:&v];return v;}
    if(!strcmp(encoding,"q")){long long v=0;[inv getReturnValue:&v];return v;}
    return 0;
}
static BOOL TKMethodABI(id target,SEL sel,const char *encoding) {
    if(!target||![target respondsToSelector:sel])return NO;
    Method m=class_getInstanceMethod(object_getClass(target),sel);
    return m&&TKSameSignature(method_getTypeEncoding(m),encoding);
}
static NSString *TKMessageIdentity(id record) {
    NSString *peer=TKObjectCall(record,@"peerUid");long long mid=TKScalar(record,@"msgId","q");
    int chat=(int)TKScalar(record,@"chatType","i");
    return [peer isKindOfClass:NSString.class]&&mid?[NSString stringWithFormat:@"%d:%@:%lld",chat,peer,mid]:nil;
}
static void TKRememberMessage(id record) {
    if(!gTKMessageCache)gTKMessageCache=[NSMutableDictionary new];
    if(!gTKRecentMessages)gTKRecentMessages=[NSMutableArray new];
    NSString *identity=TKMessageIdentity(record);if(!identity)return;
    NSArray *elements=TKObjectCall(record,@"elements");
    if(![elements isKindOfClass:NSArray.class]||!elements.count)return;
    if(!gTKMessageCache[identity]) {
        gTKMessageCache[identity]=@{@"record":record,@"elements":[elements copy],@"msgType":@(TKScalar(record,@"msgType","i"))};
        [gTKRecentMessages addObject:identity];
        if(gTKRecentMessages.count>200){NSString *old=gTKRecentMessages.firstObject;[gTKRecentMessages removeObjectAtIndex:0];[gTKMessageCache removeObjectForKey:old];}
    }
}
static NSArray *TKCachedElements(id record) {
    if(![NSThread isMainThread])return nil;
    NSString *identity=TKMessageIdentity(record);return identity?gTKMessageCache[identity][@"elements"]:nil;
}
static void AR_setElements(id self,SEL cmd,id elements) {
    IMP orig=OrigIMP(@"OCMsgRecord",cmd);
    if(TKAntiRecallEnabled()&&[objc_getAssociatedObject(self,&kTKRecallFlag) boolValue]) {
        NSArray *saved=TKCachedElements(self);if(saved.count)elements=saved;
    }
    if(orig)((void(*)(id,SEL,id))orig)(self,cmd,elements);
}
static id AR_elements(id self,SEL cmd) {
    IMP orig=OrigIMP(@"OCMsgRecord",cmd);id actual=orig?((id(*)(id,SEL))orig)(self,cmd):nil;
    if(TKAntiRecallEnabled()&&[objc_getAssociatedObject(self,&kTKRecallFlag) boolValue]) {
        NSArray *saved=TKCachedElements(self);if(saved.count)return saved;
    }
    return actual;
}
static int AR_msgType(id self,SEL cmd) {
    IMP orig=OrigIMP(@"OCMsgRecord",cmd);int value=orig?((int(*)(id,SEL))orig)(self,cmd):0;
    if([NSThread isMainThread]&&TKAntiRecallEnabled()&&[objc_getAssociatedObject(self,&kTKRecallFlag) boolValue]) {
        NSString *identity=TKMessageIdentity(self);NSNumber *saved=identity?gTKMessageCache[identity][@"msgType"]:nil;if(saved)return saved.intValue;
    }
    return value;
}
static void AR_setMsgType(id self,SEL cmd,int value) {
    IMP orig=OrigIMP(@"OCMsgRecord",cmd);
    if([NSThread isMainThread]&&TKAntiRecallEnabled()&&[objc_getAssociatedObject(self,&kTKRecallFlag) boolValue]) {
        NSString *identity=TKMessageIdentity(self);NSNumber *saved=identity?gTKMessageCache[identity][@"msgType"]:nil;if(saved)value=saved.intValue;
    }
    if(orig)((void(*)(id,SEL,int))orig)(self,cmd,value);
}
static void TKDrainRedQueue(void);
static void TKQueueRedPacket(id record) {
    if(!prefBool(kEnabled,YES)||!prefBool(kRedPacket,YES)||!prefBool(kAutoRed,YES))return;
    if(UIApplication.sharedApplication.applicationState!=UIApplicationStateActive){gTKEngineStatus=@"应用未在前台，未请求领取";return;}
    id wallet=redElementFromRecord(record);if(!wallet||shouldSkipRedPacket(record))return;
    long long time=TKScalar(record,@"msgTime","q");NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    if(time>100000000000LL)time/=1000;
    if(time<=0||now-time>120||time>now+30)return; // Never claim old synchronized history.
    NSString *identity=TKMessageIdentity(record);if(!identity)return;
    NSString *bill=TKObjectCall(wallet,@"billNo");NSString *key=[bill isKindOfClass:NSString.class]&&bill.length?bill:identity;
    if(!gTKSeenRedPackets)gTKSeenRedPackets=[NSMutableSet new];
    if([gTKSeenRedPackets containsObject:key])return;
    if(gTKSeenRedPackets.count>=500){gTKEngineStatus=@"本次会话已达去重上限，请关闭再开启自动领取";return;}
    [gTKSeenRedPackets addObject:key];
    if(!gTKRedQueue)gTKRedQueue=[NSMutableArray new];
    if(gTKRedQueue.count<20)[gTKRedQueue addObject:record];
    TKDrainRedQueue();
}
static void TKDrainRedQueue(void) {
    if(gTKAutoBusy||!gTKRedQueue.count)return;
    if(!prefBool(kEnabled,YES)||!prefBool(kAutoRed,YES)||!prefBool(kRedPacket,YES)){[gTKRedQueue removeAllObjects];return;}
    if(UIApplication.sharedApplication.applicationState!=UIApplicationStateActive)return;
    Class service=NSClassFromString(@"QQWalletRedPacketMsgService");
    SEL claim=NSSelectorFromString(@"grabRedPackWithMsgRecord:rootVC:completion:");
    if(!TKMethodABI(service,claim,"v40@0:8@16@24@?32")){gTKEngineStatus=@"领取服务尚未加载或签名不匹配";return;}
    id record=gTKRedQueue.firstObject;[gTKRedQueue removeObjectAtIndex:0];
    if(shouldSkipRedPacket(record)){TKDrainRedQueue();return;}
    UIWindow *window=UIApplication.sharedApplication.keyWindow;
    UIViewController *root=window.rootViewController;if(!root){gTKEngineStatus=@"没有可用前台窗口";return;}
    id selectedWallet=redElementFromRecord(record);
    id bill=TKObjectCall(selectedWallet,@"billNo");
    gTKCurrentClaimIdentity=[bill isKindOfClass:NSString.class]?[bill copy]:nil;
    gTKAutoBusy=YES;unsigned long long generation=++gTKAutoGeneration;gTKAutoAttempts++;gTKEngineStatus=@"已调用原生领取，等待完成回调";
    void (^completion)(id,id)=^(id result,id error){dispatch_async(dispatch_get_main_queue(),^{
        if(!gTKAutoBusy || generation!=gTKAutoGeneration)return;gTKAutoBusy=NO;
        if(error){gTKAutoErrors++;gTKEngineStatus=@"原生领取返回失败，未自动重试";}
        else {gTKAutoCompleted++;gTKEngineStatus=@"原生领取完成回调已返回，请核对红包结果";}
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{TKDrainRedQueue();});
    });};
    ((void(*)(id,SEL,id,id,id))objc_msgSend)(service,claim,record,root,completion);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if(gTKAutoBusy && generation==gTKAutoGeneration){gTKAutoBusy=NO;gTKAutoErrors++;gTKEngineStatus=@"领取超时：未收到完成回调";TKDrainRedQueue();}
    });
}
static void TKReceiveMessages(id payload) {
    if(![payload isKindOfClass:NSArray.class])return;
    NSArray *records=[payload copy];
    dispatch_async(dispatch_get_main_queue(),^{
        Class recordClass=NSClassFromString(@"OCMsgRecord");
        for(id record in records)if([record isKindOfClass:recordClass]){gTKReceived++;TKRememberMessage(record);TKQueueRedPacket(record);}
    });
}
static void TKAttachListener(void) {
    Class wrapper=NSClassFromString(@"QZNTKernelServiceWrapper");
    id session=TKObjectCall(wrapper,@"currentActiveWrapperSession");id service=TKObjectCall(session,@"getMsgService");
    if(!service){gTKEngineStatus=@"等待当前登录会话的消息服务";return;}
    if(service==gTKMessageService&&gTKListenerRegistered)return;
    SEL remove=NSSelectorFromString(@"removeKernelMsgListener:");
    if(gTKMessageService&&gTKListenerRegistered&&TKMethodABI(gTKMessageService,remove,"v24@0:8Q16"))((void(*)(id,SEL,unsigned long long))objc_msgSend)(gTKMessageService,remove,gTKListenerToken);
    gTKListenerToken=0;gTKListenerRegistered=NO;gTKListener=nil;gTKMessageService=service;
    [gTKMessageCache removeAllObjects];[gTKRecentMessages removeAllObjects];[gTKSeenRedPackets removeAllObjects];[gTKRedQueue removeAllObjects];
    gTKAutoBusy=NO;++gTKAutoGeneration;
    Class listener=NSClassFromString(@"GuildNTKernel.SWIKernelMsgListener");if(!listener)listener=NSClassFromString(@"_TtC13GuildNTKernel20SWIKernelMsgListener");
    id object=[[listener alloc] init];
    SEL set=NSSelectorFromString(@"setOnRecvMsg:"),add=NSSelectorFromString(@"addKernelMsgListener:");
    if(!TKMethodABI(object,set,"@24@0:8@?16")||!TKMethodABI(service,add,"Q24@0:8@16")){gTKEngineStatus=@"消息监听接口缺失或签名不匹配";return;}
    void (^receive)(id)=^(id records){TKReceiveMessages(records);};
    ((id(*)(id,SEL,id))objc_msgSend)(object,set,receive);
    gTKListener=object;gTKListenerToken=((unsigned long long(*)(id,SEL,id))objc_msgSend)(service,add,object);
    gTKListenerRegistered=YES;gTKEngineStatus=@"消息监听已注册，等待新消息";
}
static BOOL TKRepeatRecord(id record) {
    if(!prefBool(kEnabled,YES)||!prefBool(kRepeater,YES)||!gTKMessageService)return NO;
    NSString *peer=TKObjectCall(record,@"peerUid"),*guild=TKObjectCall(record,@"guildId");
    long long mid=TKScalar(record,@"msgId","q");int chat=(int)TKScalar(record,@"chatType","i");
    Class contactClass=NSClassFromString(@"OCContact");SEL factory=NSSelectorFromString(@"ContactWithChatType:peerUid:guildId:");
    if(!mid||![peer isKindOfClass:NSString.class]||!TKMethodABI(contactClass,factory,"@36@0:8i16@20@28"))return NO;
    id contact=((id(*)(id,SEL,int,id,id))objc_msgSend)(contactClass,factory,chat,peer,guild);
    SEL forward=NSSelectorFromString(@"forwardMsg:srcContact:dstContacts:msgAttributeInfos:cb:");
    if(!contact||!TKMethodABI(gTKMessageService,forward,"v56@0:8@16@24@32@40@48"))return NO;
    ((void(*)(id,SEL,id,id,id,id,id))objc_msgSend)(gTKMessageService,forward,@[@(mid)],contact,@[contact],nil,nil);
    gTKRepeats++;return YES;
}
static id FS_decryptImage(id self,SEL cmd,id path) {
    IMP orig=OrigIMP(@"PhotoBrowserFlashPictureService",cmd);id image=orig?((id(*)(id,SEL,id))orig)(self,cmd,path):nil;
    if(prefBool(kEnabled,YES)&&prefBool(kFlashPhoto,YES)&&[image isKindOfClass:UIImage.class]) {
        UIImage *copy=image;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool {
            NSData *data=UIImagePNGRepresentation(copy);NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
            NSString *folder=[documents stringByAppendingPathComponent:@"TIMCleanKit/FlashPhotos"];
            if(data&&folder){[NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
                NSString *file=[folder stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"png"]];
                if([data writeToFile:file atomically:YES])__atomic_fetch_add(&gTKFlashSaved,1,__ATOMIC_RELAXED);
            }
        }});
    }
    return image;
}
static void FS_screenshotNotify(id self,SEL cmd,id notify) {
    NSString *name=@"_TtC15AIOPhotoBrowser43NTAIOFlashPicturePhotoBrowserViewController";
    IMP orig=OrigIMP(name,cmd);
    if(prefBool(kEnabled,YES)&&prefBool(kFlashPhoto,YES))return;
    if(orig)((void(*)(id,SEL,id))orig)(self,cmd,notify);
}
static void TKAutoOpenPreView(id self,SEL cmd) {
    IMP orig=OrigIMP(@"QQWalletPreGrapHBResultViewController",cmd);
    if(orig)((void(*)(id,SEL))orig)(self,cmd);
    if(!gTKAutoBusy)return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,350*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        if(!gTKAutoBusy||!prefBool(kAutoRed,YES))return;
        UIView *root=(UIView *)TKObjectCall(self,@"view");
        NSMutableArray *views=[NSMutableArray array];if(root)[views addObject:root];
        for(NSUInteger i=0;i<views.count&&i<1000;i++){
            UIView *view=views[i];
            if([view isKindOfClass:NSClassFromString(@"QQWalletPreOpenHBView")]) {
                SEL dataSel=NSSelectorFromString(@"grapHBData");id data=TKObjectCall(view,@"grapHBData");
                id aio=TKObjectCall(data,@"aioData");id list=TKObjectCall(aio,@"listId");
                BOOL identityOK=!gTKCurrentClaimIdentity||!list||[list isEqual:gTKCurrentClaimIdentity];
                if(identityOK){SEL open=NSSelectorFromString(@"openButtonClick");if([view respondsToSelector:open])((void(*)(id,SEL))objc_msgSend)(view,open);}
                return;
            }
            if([view isKindOfClass:UIView.class])[views addObjectsFromArray:view.subviews];
        }
    });
}

static NSDictionary *TKRuntimeSnapshot(void) {
    NSMutableArray *rows=[NSMutableArray array];
    unsigned count=__atomic_load_n(&gHookCount,__ATOMIC_ACQUIRE);
    NSArray *states=@[@"等待业务类加载",@"方法不存在",@"签名不匹配，已跳过",@"方法替换已核对",@"已请求注册，等待调用验证"];
    for(unsigned i=0;i<count;i++){
        TKHookRecord *r=&gHooks[i];unsigned state=__atomic_load_n(&r->state,__ATOMIC_ACQUIRE);
        unsigned long long hits=__atomic_load_n(&r->hits,__ATOMIC_RELAXED);
        [rows addObject:@{@"name":[NSString stringWithFormat:@"%s\n%s",r->className,sel_getName(r->selector)],@"state":hits?@"已实际调用":states[MIN(state,4)],@"hits":@(hits),@"lastHit":@""}];
    }
    return @{@"engine":@{@"status":gTKEngineStatus?:@"未知",@"listenerRegistered":@(gTKListenerRegistered),@"received":@(gTKReceived),@"claimRequests":@(gTKAutoAttempts),@"claimCallbacks":@(gTKAutoCompleted),@"claimFailures":@(gTKAutoErrors),@"savedPhotos":@(__atomic_load_n(&gTKFlashSaved,__ATOMIC_RELAXED)),@"repeatRequests":@(gTKRepeats)},@"version":@"1.0.4",@"process":[NSString stringWithFormat:@"TIM %@ · PID %d · 注册检查 %u 轮\nUIDevice.model = %@",[NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"],getpid(),gRegistrationRounds,UIDevice.currentDevice.model],@"hookRows":rows,@"warnings":@[@"调用次数只能证明该入口被调用，不能证明防撤回或过滤效果。",@"自动领取：只处理前台两分钟内新收到的红包，不保证后台唤醒；完成回调不等于到账，请核对结果。",@"防撤回：缓存仅在内存保留最近200条收到的消息；启动前丢失内容无法恢复。"]};
}



#include "TKSettingsUI.h"
static char kGestureAddedKey;
@interface TIMCKGestureTarget : NSObject <UIGestureRecognizerDelegate>
@end
@implementation TIMCKGestureTarget
+ (instancetype)shared {static TIMCKGestureTarget *t;static dispatch_once_t once;dispatch_once(&once,^{t=[self new];});return t;}
- (BOOL)isSettingsWindow:(UIWindow *)window {
    UIViewController *vc=window.rootViewController;
    while(vc.presentedViewController)vc=vc.presentedViewController;
    if([vc isKindOfClass:[UINavigationController class]]){
        for(UIViewController *page in ((UINavigationController *)vc).viewControllers)
            if([page isKindOfClass:[TKSettingsController class]]) return YES;
    }
    return NO;
}
- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if(g.state==UIGestureRecognizerStateBegan && [g.view isKindOfClass:[UIWindow class]] && ![self isSettingsWindow:(UIWindow *)g.view]) TKPresentSettings((UIWindow *)g.view);
}
- (id)recordAtView:(UIView *)view {
    Class recordClass=NSClassFromString(@"OCMsgRecord");
    for(UIView *v=view;v&&! [v isKindOfClass:[UIWindow class]];v=v.superview){
        if([v isKindOfClass:[UIControl class]]||[v isKindOfClass:[UITextView class]])return nil;
        for(NSString *selector in @[@"msgRecord",@"record",@"ocMsgRecord"]){
            id record=TKObjectCall(v,selector);if([record isKindOfClass:recordClass])return record;
        }
        id model=TKObjectCall(v,@"viewModel");
        for(NSString *selector in @[@"msgRecord",@"record",@"ocMsgRecord"]){
            id record=TKObjectCall(model,selector);if([record isKindOfClass:recordClass])return record;
        }
    }
    return nil;
}
- (void)onMessageDoubleTap:(UITapGestureRecognizer *)g {
    if(!prefBool(kEnabled,YES)||!prefBool(kRepeater,YES)||[self isSettingsWindow:(UIWindow *)g.view])return;
    UIView *hit=[g.view hitTest:[g locationInView:g.view] withEvent:nil];id record=[self recordAtView:hit];
    if(!record)return;
    UIViewController *vc=((UIWindow *)g.view).rootViewController;
    while(vc.presentedViewController)vc=vc.presentedViewController;
    if(!vc||[vc isKindOfClass:[UIAlertController class]])return;
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"复读这条消息？" message:@"确认后转发到原会话一次。" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"发送一次" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){TKRepeatRecord(record);}]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
}
- (void)onBlankTap:(UITapGestureRecognizer *)g {
    if(g.state==UIGestureRecognizerStateRecognized && [g.view isKindOfClass:[UIWindow class]]) TKPresentSettings((UIWindow *)g.view);
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
    if(![g isKindOfClass:[UITapGestureRecognizer class]])return YES;
    if([self isSettingsWindow:(UIWindow *)g.view])return NO;
    if(((UITapGestureRecognizer *)g).numberOfTapsRequired==2) return prefBool(kEnabled,YES)&&prefBool(kRepeater,YES)&&[self recordAtView:touch.view]!=nil;
    if(!prefBool(kBlankTap,YES))return NO;
    UIView *hit=touch.view;
    // Fail closed on cells, controls and custom interactive content. Do not steal app taps.
    for(UIView *v=hit;v && v!=g.view;v=v.superview) {
        if([v isKindOfClass:[UIControl class]] || [v isKindOfClass:[UITextView class]] ||
           [v isKindOfClass:[UITableViewCell class]] || [v isKindOfClass:[UICollectionViewCell class]] ||
           [v isKindOfClass:[UILabel class]] || [v isKindOfClass:[UIImageView class]] ||
           [v isKindOfClass:[UINavigationBar class]] || [v isKindOfClass:[UITabBar class]])return NO;
        NSString *name=NSStringFromClass(v.class).lowercaseString;
        if([name containsString:@"keyboard"] || [name containsString:@"input"] ||
           [name containsString:@"bubble"] || [name containsString:@"messagecell"] ||
           [name containsString:@"chatcell"])return NO;
        for(UIGestureRecognizer *other in v.gestureRecognizers) {
            if(other!=g && other.enabled && ![other isKindOfClass:[UIPanGestureRecognizer class]])return NO;
        }
        if([v isKindOfClass:[UIScrollView class]] && (((UIScrollView *)v).dragging || ((UIScrollView *)v).decelerating))return NO;
    }
    return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    return ![b isKindOfClass:[UIPanGestureRecognizer class]];
}
@end
static void InstallGesture(UIWindow *w) {
    if(!w || ![NSThread isMainThread] || objc_getAssociatedObject(w,&kGestureAddedKey))return;
    TIMCKGestureTarget *target=[TIMCKGestureTarget shared];
    UILongPressGestureRecognizer *longPress=[[UILongPressGestureRecognizer alloc] initWithTarget:target action:@selector(onLongPress:)];
    longPress.numberOfTouchesRequired=2;longPress.minimumPressDuration=0.8;longPress.cancelsTouchesInView=NO;
    longPress.delaysTouchesBegan=NO;longPress.delaysTouchesEnded=NO;longPress.delegate=target;
    UITapGestureRecognizer *tap=[[UITapGestureRecognizer alloc] initWithTarget:target action:@selector(onBlankTap:)];
    tap.numberOfTapsRequired=1;tap.numberOfTouchesRequired=1;tap.cancelsTouchesInView=NO;
    tap.delaysTouchesBegan=NO;tap.delaysTouchesEnded=NO;tap.delegate=target;
    UITapGestureRecognizer *repeat=[[UITapGestureRecognizer alloc] initWithTarget:target action:@selector(onMessageDoubleTap:)];
    repeat.numberOfTapsRequired=2;repeat.cancelsTouchesInView=NO;repeat.delaysTouchesBegan=NO;repeat.delaysTouchesEnded=NO;repeat.delegate=target;
    [w addGestureRecognizer:repeat];[w addGestureRecognizer:longPress];[w addGestureRecognizer:tap];
    objc_setAssociatedObject(w,&kGestureAddedKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void TKWriteStatus(void) {
    NSDictionary *snapshot=TKRuntimeSnapshot();
    NSString *cache=NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES).firstObject;
    if(!cache)return;
    NSData *data=[NSJSONSerialization dataWithJSONObject:snapshot options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:[cache stringByAppendingPathComponent:@"TIMCleanKit-runtime.json"] atomically:YES];
}
static void RegisterBusinessHooks(void) {
    gRegistrationRounds++;
    InstallHook(@"OCMsgRecord",@selector(setRecallTime:),(IMP)AR_setRecallTime,NO);
    InstallHook(@"OCMsgRecord",@selector(recallTime),(IMP)AR_recallTime,NO);
    InstallHook(@"OCMsgsReq",@selector(includeDeleteMsg),(IMP)AR_includeDelete,NO);
    InstallHook(@"OCMsgsReq",@selector(setIncludeDeleteMsg:),(IMP)AR_setIncludeDelete,NO);
    InstallHook(@"OCIKernelMsgService",@selector(getMsgsBySeqAndCount:msgSeq:cnt:queryOrder:incloudeDeleteMsg:cb:),(IMP)AR_querySeq,NO);
    InstallHook(@"OCIKernelMsgService",@selector(getMsgsWithMsgTimeAndClientSeqForC2C:msgTime:clientSeq:cnt:needIncludeSelf:queryOrder:incloudeDeleteMsg:cb:),(IMP)AR_queryTime,NO);
    InstallHook(@"UIDevice",@selector(model),(IMP)SP_model,NO);
    InstallHook(@"UIDevice",@selector(localizedModel),(IMP)SP_localizedModel,NO);
    InstallHook(@"NTRedPackRouterService",@selector(handleRedPackViewClickWithRootVC:msgRecord:gesture:completion:),(IMP)RPkt_handleClick,YES);
    InstallHook(@"NTRedPackRouterService",@selector(checkCanOpenRedPack:resultTip:),(IMP)RPkt_checkCanOpen,YES);
    InstallHook(@"NTRedPackRouterService",@selector(grabCommandRedPackIfCanWithMsgRecord:),(IMP)RPkt_grabCommand,YES);
    InstallHook(@"NTRedPackRouterService",@selector(shouldShowRedPackBubbleWithRootVC:msgRecord:),(IMP)RPkt_shouldShowBubble,YES);
    InstallHook(@"OCMsgRecord",@selector(elements),(IMP)AR_elements,NO);
    InstallHook(@"OCMsgRecord",@selector(setElements:),(IMP)AR_setElements,NO);
    InstallHook(@"OCMsgRecord",@selector(msgType),(IMP)AR_msgType,NO);
    InstallHook(@"OCMsgRecord",@selector(setMsgType:),(IMP)AR_setMsgType,NO);
    InstallHook(@"PhotoBrowserFlashPictureService",@selector(decryptImageWithImagePath:),(IMP)FS_decryptImage,YES);
    InstallHook(@"_TtC15AIOPhotoBrowser43NTAIOFlashPicturePhotoBrowserViewController",@selector(handleDidTakeScreenshotWithNotify:),(IMP)FS_screenshotNotify,NO);
    InstallHook(@"QQWalletPreGrapHBResultViewController",@selector(viewDidLoad),(IMP)TKAutoOpenPreView,NO);
    TKAttachListener();TKDrainRedQueue();
    for(UIWindow *w in UIApplication.sharedApplication.windows)InstallGesture(w);
    TKWriteStatus();
}
__attribute__((constructor)) static void TIMCKInit(void) {
    @autoreleasepool {
        if(![[NSBundle mainBundle].bundleIdentifier isEqualToString:kDomain])return;
        dispatch_async(dispatch_get_main_queue(),^{
            registerDefaultsOnce();RegisterBusinessHooks();
            NSNotificationCenter *nc=NSNotificationCenter.defaultCenter;
            [nc addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){RegisterBusinessHooks();}];
            [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){RegisterBusinessHooks();}];
            [nc addObserverForName:UIWindowDidBecomeKeyNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){if([n.object isKindOfClass:[UIWindow class]])InstallGesture(n.object);}];
            for(NSNumber *delay in @[@1,@3,@10,@30])dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay.doubleValue*NSEC_PER_SEC)),dispatch_get_main_queue(),^{RegisterBusinessHooks();});
            [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *timer){if(UIApplication.sharedApplication.applicationState==UIApplicationStateActive){RegisterBusinessHooks();}}];
        });
    }
}
