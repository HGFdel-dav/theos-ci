//  TIMCleanKit.dylib — TIM (com.tencent.tim) 净化/增强插件
//  目标：TIM 4.1.0 (NT 架构) + 兼容 QQ
//  功能：防撤回 / 复读 / 闪照 / 设备伪装 / 红包过滤(小额不抢、测试不抢) / 设置面板
//  构建：Theos (Logos)，arm64 + arm64e
//
//  设计原则：所有 Hook 均通过 NSClassFromString 动态获取类，
//  类不存在时自动跳过，绝不崩溃。TIM 与 QQ 共用的消息内核类
//  (OCMsgRecord/OCMsgsReq/OCIKernelMsgService) 双端通用。

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <sys/sysctl.h>

// ---------------------------------------------------------------- 配置键
//  TIMCleanKit 自有前缀，避免与其它插件冲突
static NSString *const kDomain      = @"com.tencent.tim";
static NSString *const kEnabled     = @"TIMCK.enabled";         // 总开关
static NSString *const kAntiRecall  = @"TIMCK.antiRecall";      // 防撤回
static NSString *const kRepeater    = @"TIMCK.repeater";        // 复读
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
            kAntiRecall:  @YES,
            kRepeater:    @YES,
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

// 从字符串中解析金额(单位:分)，找不到返回 -1
static long long amountFromString(NSString *s);

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
        if (sig) {
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
    id aio = nil;
    if ([element respondsToSelector:@selector(sender)]) aio = [element sender];
    if (!aio && [element respondsToSelector:@selector(receiver)]) aio = [element receiver];
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
    if ([d isEqualTo:[NSDecimalNumber notANumber]]) return -1;
    return (long long)([d doubleValue] * 100.0);
}

// 判断是否"测试红包"
static BOOL isTestRedPacket(id element) {
    if (!element) return NO;
    NSMutableArray *texts = [NSMutableArray array];
    id aio = nil;
    if ([element respondsToSelector:@selector(sender)]) aio = [element sender];
    if (!aio && [element respondsToSelector:@selector(receiver)]) aio = [element receiver];
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
        SEL s = NSSelectorFromString(prop);
        if ([element respondsToSelector:s]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id v = [element performSelector:s];
#pragma clang diagnostic pop
            if ([v isKindOfClass:[NSString class]]) [texts addObject:v];
        }
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
    SEL sel = @selector(elements);
    if (![record respondsToSelector:sel]) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id els = [record performSelector:sel];
#pragma clang diagnostic pop
    return msgRecordElement((NSArray *)els);
}

// 核心：这条消息是否应该被"不抢"
static BOOL shouldSkipRedPacket(id record) {
    if (!prefBool(kRedPacket, YES)) return NO;
    if (!prefBool(kEnabled, YES))  return NO;
    id element = redElementFromRecord(record);

    // 口令红包
    if (prefBool(kRedSkipCmd, NO)) {
        Class router = NSClassFromString(@"NTRedPackRouterService");
        if (router) {
            SEL s = @selector(isCommandRedPack:);
            if ([router respondsToSelector:s]) {
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
//   类/方法不存在时静默跳过，目标 App 不崩溃。
//   TIM 与 QQ 共用的消息内核类两端通用。

static NSMutableDictionary *gOrigMap = nil;

static void InstallHook(NSString *clsName, SEL sel, IMP newImp, BOOL isClassMethod) {
    Class cls = NSClassFromString(clsName);
    if (!cls)            { LOG(@"skip: class %@ absent", clsName); return; }
    if (isClassMethod) cls = object_getClass(cls);
    Method m = isClassMethod ? class_getClassMethod(cls, sel)
                             : class_getInstanceMethod(cls, sel);
    if (!m) { LOG(@"skip: -[%@ %@] absent", clsName, NSStringFromSelector(sel)); return; }
    IMP old = method_getImplementation(m);
    method_setImplementation(m, newImp);
    NSString *key = [NSString stringWithFormat:@"%@::%@", clsName, NSStringFromSelector(sel)];
    gOrigMap[key] = [NSValue valueWithPointer:old];
    LOG(@"hooked %@[%@ %@]%s", isClassMethod ? "+" : "-", clsName, NSStringFromSelector(sel), "");
}
static IMP OrigIMP(NSString *clsName, SEL sel) {
    return [gOrigMap[[NSString stringWithFormat:@"%@::%@", clsName, NSStringFromSelector(sel)]] pointerValue];
}

// ============================================================ 1. 防撤回
// TIM 与 QQ 共用 NT 消息内核，方法名一致：
//   -[OCMsgRecord setRecallTime:]       标记撤回时间
//   -[OCIKernelMsgService recallMsg:msgIds:cb:]  触发撤回
static void AR_setRecallTime(id self, SEL _cmd, long long t) {
    if (!prefBool(kEnabled, YES) || !prefBool(kAntiRecall, YES)) {
        ((void (*)(id, SEL, long long))OrigIMP(@"OCMsgRecord", _cmd))(self, _cmd, t);
        return;
    }
    LOG(@"blocked setRecallTime: %lld", t);   // 不写入撤回时间 => 消息不会显示已撤回
}
static void AR_recallMsg(id self, SEL _cmd, id a1, id a2, id a3) {
    if (!prefBool(kEnabled, YES) || !prefBool(kAntiRecall, YES)) {
        ((void (*)(id, SEL, id, id, id))OrigIMP(@"OCIKernelMsgService", _cmd))(self, _cmd, a1, a2, a3);
        return;
    }
    LOG(@"blocked recallMsg:msgIds:cb:");     // 不转发撤回请求 => 服务端撤回被吞掉
}

// ============================================================ 2. 复读
static id RP_initWithCpp(id self, SEL _cmd, const void *cpp) {
    return ((id (*)(id, SEL, const void *))OrigIMP(@"OCIKernelMsgService", _cmd))(self, _cmd, cpp);
}
static void RP_forwardMsg(id self, SEL _cmd, id msg, id src, id dsts, id attrs, id cb) {
    BOOL on = prefBool(kEnabled, YES) && prefBool(kRepeater, YES);
    typedef void (*Fn)(id, SEL, id, id, id, id, id);
    Fn orig = (Fn)OrigIMP(@"OCIKernelMsgService", _cmd);
    if (!orig) return;
    if (!on) { orig(self, _cmd, msg, src, dsts, attrs, cb); return; }
    // 复读：同一条消息再次转发一次（模拟重复发送）
    orig(self, _cmd, msg, src, dsts, attrs, cb);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        orig(self, _cmd, msg, src, dsts, attrs, cb);
    });
}

// ============================================================ 3. 闪照/截屏
// TIM 使用 UIScreen.isCaptured（已确认 TIM 二进制引用该 selector）
static BOOL FS_isCaptured(id self, SEL _cmd) {
    if (prefBool(kEnabled, YES) && prefBool(kFlashPhoto, YES)) {
        LOG(@"spoof isCaptured -> NO");
        return NO;
    }
    return ((BOOL (*)(id, SEL))OrigIMP(@"UIScreen", _cmd))(self, _cmd);
}

// ============================================================ 4. 设备伪装
static NSString *SP_model(id self, SEL _cmd) {
    if (prefBool(kEnabled, YES) && prefBool(kDeviceSpoof, NO)) {
        return prefStr(kSpoofModel, @"iPhone 15 Pro");
    }
    return ((NSString *(*)(id, SEL))OrigIMP(@"UIDevice", _cmd))(self, _cmd);
}
static NSString *SP_localizedModel(id self, SEL _cmd) {
    if (prefBool(kEnabled, YES) && prefBool(kDeviceSpoof, NO)) {
        return prefStr(kSpoofModel, @"iPhone 15 Pro");
    }
    return ((NSString *(*)(id, SEL))OrigIMP(@"UIDevice", _cmd))(self, _cmd);
}
// sysctl 层：hw.machine / hw.model（C 函数 Hook）
static int (*gOrigSysctl)(int *, u_int, void *, size_t *, void *, size_t);
static int HK_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (prefBool(kEnabled, YES) && prefBool(kDeviceSpoof, NO) && name && namelen >= 2
        && name[0] == CTL_HW && (name[1] == HW_MACHINE || name[1] == HW_MODEL)) {
        const char *fake = [prefStr(kSpoofModel, @"iPhone 15 Pro") UTF8String];
        if (oldp && oldlenp && *oldlenp >= strlen(fake) + 1) {
            strlcpy((char *)oldp, fake, *oldlenp);
            *oldlenp = strlen(fake) + 1;
            return 0;
        }
    }
    return gOrigSysctl(name, namelen, oldp, oldlenp, newp, newlen);
}
static int (*gOrigSysctlbyname)(const char *, void *, size_t *, void *, size_t);
static int HK_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (name && (strcmp(name, "hw.machine") == 0 || strcmp(name, "hw.model") == 0)
        && prefBool(kEnabled, YES) && prefBool(kDeviceSpoof, NO)) {
        const char *fake = [prefStr(kSpoofModel, @"iPhone 15 Pro") UTF8String];
        if (oldp && oldlenp && *oldlenp >= strlen(fake) + 1) {
            strlcpy((char *)oldp, fake, *oldlenp);
            *oldlenp = strlen(fake) + 1;
            return 0;
        }
    }
    return gOrigSysctlbyname(name, oldp, oldlenp, newp, newlen);
}

// ============================================================ 5. 红包过滤
// TIM 4.1.0 红包核心：NTRedPackRouterService（类方法，已从二进制核对 26 个方法）
//   + handleRedPackViewClickWithRootVC:msgRecord:gesture:completion:
//   + checkCanOpenRedPack:resultTip:
//   + grabCommandRedPackIfCanWithMsgRecord:
//   + shouldShowRedPackBubbleWithRootVC:msgRecord:
//   + canGrabCommandRedPack:  + isCommandRedPack:
static void RPkt_handleClick(id self, SEL _cmd, id vc, id record, id gesture, id completion) {
    if (shouldSkipRedPacket(record)) {
        LOG(@"red packet click blocked");
        return;
    }
    ((void (*)(id, SEL, id, id, id, id))OrigIMP(@"NTRedPackRouterService", _cmd))(self, _cmd, vc, record, gesture, completion);
}
static BOOL RPkt_checkCanOpen(id self, SEL _cmd, id pack, NSString **tip) {
    if (shouldSkipRedPacket(pack)) {
        if (tip) *tip = @"TIMCleanKit 已拦截";
        return NO;
    }
    return ((BOOL (*)(id, SEL, id, NSString **))OrigIMP(@"NTRedPackRouterService", _cmd))(self, _cmd, pack, tip);
}
static void RPkt_grabCommand(id self, SEL _cmd, id record) {
    if (shouldSkipRedPacket(record)) { LOG(@"command red packet blocked"); return; }
    ((void (*)(id, SEL, id))OrigIMP(@"NTRedPackRouterService", _cmd))(self, _cmd, record);
}
static BOOL RPkt_shouldShowBubble(id self, SEL _cmd, id vc, id record) {
    if (shouldSkipRedPacket(record)) return NO;
    return ((BOOL (*)(id, SEL, id, id))OrigIMP(@"NTRedPackRouterService", _cmd))(self, _cmd, vc, record);
}


// ============================================================ 6. 设置面板（已移除 — 导致闪退）
// 如需调试：在 ~/.launchd.conf 或启动脚本设置环境变量 TIMCK_DEBUG=1
// 日志前缀 [TIMCleanKit]，查看每个 Hook 是否注册成功
// 若确认无闪退，可逐步加回面板（去掉本注释并启用 InstallHook UIWindow）


// ==================================================== 构造函数：注册全部 Hook
__attribute__((constructor)) static void TIMCKInit(void) {
    gOrigMap = [[NSMutableDictionary alloc] init];
    registerDefaultsOnce();

    // --- 防撤回（TIM/QQ 共用消息内核）---
    InstallHook(@"OCMsgRecord",        @selector(setRecallTime:),       (IMP)AR_setRecallTime,  NO);
    InstallHook(@"OCIKernelMsgService",@selector(recallMsg:msgIds:cb:), (IMP)AR_recallMsg,      NO);
    InstallHook(@"OCIKernelMsgService",@selector(initWithCpp:),         (IMP)RP_initWithCpp,    NO);
    InstallHook(@"OCIKernelMsgService",@selector(forwardMsg:srcContact:dstContacts:msgAttributeInfos:cb:),
                                                                        (IMP)RP_forwardMsg,      NO);

    // --- 闪照/截屏 ---
    InstallHook(@"UIScreen", @selector(isCaptured), (IMP)FS_isCaptured, NO);

    // --- 设备伪装 ---
    InstallHook(@"UIDevice", @selector(model),           (IMP)SP_model,           NO);
    InstallHook(@"UIDevice", @selector(localizedModel),  (IMP)SP_localizedModel,  NO);
    if (!gOrigSysctl)        MSHookFunction((void *)sysctl,        (void *)HK_sysctl,        (void **)&gOrigSysctl);
    if (!gOrigSysctlbyname)  MSHookFunction((void *)sysctlbyname,  (void *)HK_sysctlbyname,  (void **)&gOrigSysctlbyname);

    // --- 红包过滤（TIM 4.1.0：NTRedPackRouterService）---
    InstallHook(@"NTRedPackRouterService", @selector(handleRedPackViewClickWithRootVC:msgRecord:gesture:completion:),
                                                                    (IMP)RPkt_handleClick,    YES);
    InstallHook(@"NTRedPackRouterService", @selector(checkCanOpenRedPack:resultTip:),
                                                                    (IMP)RPkt_checkCanOpen,   YES);
    InstallHook(@"NTRedPackRouterService", @selector(grabCommandRedPackIfCanWithMsgRecord:),
                                                                    (IMP)RPkt_grabCommand,    YES);
    InstallHook(@"NTRedPackRouterService", @selector(shouldShowRedPackBubbleWithRootVC:msgRecord:),
                                                                    (IMP)RPkt_shouldShowBubble,YES);

    // --- 面板入口（已移除）---
    // InstallHook(@"UIWindow", @selector(becomeKeyWindow), (IMP)SW_becomeKeyWindow, NO);

    LOG(@"loaded");
}
