//  TIMCleanKit.dylib — TIM (com.tencent.tim) 净化/增强插件
//  目标：TIM 4.1.0 (NT 架构)，1.0.2 隔离测试版
//  功能：防撤回标记 / 截屏状态 / UIDevice机型 / 红包过滤 / 设置面板
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

// ---------------------------------------------------------------- 配置键
//  TIMCleanKit 自有前缀，避免与其它插件冲突
static NSString *const kDomain      = @"com.tencent.tim";
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
//   验证真实方法签名，缺失或签名不匹配时跳过。
//   TIM 与 QQ 共用的消息内核类两端通用。

// C storage: original IMP lookup never calls Foundation during replacement.
typedef struct { const char *className; SEL selector; IMP original; } TKHookRecord;
static TKHookRecord gHooks[16];
static unsigned gHookCount;

static const char *TKExpectedEncoding(NSString *name, SEL selector) {
    const char *sel = sel_getName(selector);
    if ([name isEqualToString:@"OCMsgRecord"] && !strcmp(sel,"setRecallTime:")) return "v24@0:8q16";
    if ([name isEqualToString:@"NTRedPackRouterService"]) {
        if (!strcmp(sel,"handleRedPackViewClickWithRootVC:msgRecord:gesture:completion:")) return "v48@0:8@16@24@32@?40";
        if (!strcmp(sel,"checkCanOpenRedPack:resultTip:")) return "B32@0:8@16^@24";
        if (!strcmp(sel,"grabCommandRedPackIfCanWithMsgRecord:")) return "v24@0:8@16";
        if (!strcmp(sel,"shouldShowRedPackBubbleWithRootVC:msgRecord:")) return "B32@0:8@16@24";
    }
    if ([name isEqualToString:@"UIScreen"]) return "B16@0:8";
    if ([name isEqualToString:@"UIDevice"]) return "@16@0:8";
    if ([name isEqualToString:@"UIWindow"]) return "v16@0:8";
    return NULL;
}
static BOOL TKSameSignature(const char *actual, const char *expected) {
    if (!actual || !expected) return NO;
    NSMethodSignature *a = [NSMethodSignature signatureWithObjCTypes:actual];
    NSMethodSignature *b = [NSMethodSignature signatureWithObjCTypes:expected];
    if (!a || !b || a.numberOfArguments != b.numberOfArguments || strcmp(a.methodReturnType,b.methodReturnType)) return NO;
    for (NSUInteger i=0;i<a.numberOfArguments;i++) if (strcmp([a getArgumentTypeAtIndex:i],[b getArgumentTypeAtIndex:i])) return NO;
    return YES;
}
static void InstallHook(NSString *clsName, SEL sel, IMP newImp, BOOL isClassMethod) {
    Class cls = NSClassFromString(clsName);
    if (!cls || gHookCount >= 16) return;
    Class target = isClassMethod ? object_getClass(cls) : cls;
    Method m = class_getInstanceMethod(target,sel);
    if (!m || !TKSameSignature(method_getTypeEncoding(m),TKExpectedEncoding(clsName,sel))) {
        LOG(@"skip signature %@ %@",clsName,NSStringFromSelector(sel)); return;
    }
    TKHookRecord *r = &gHooks[gHookCount++];
    r->className = strdup(clsName.UTF8String);
    r->selector = sel;
    // Use substrate/ElleKit to avoid replacing an inherited superclass Method.
    MSHookMessageEx(target,sel,newImp,&r->original);
    LOG(@"hooked %@ %@ %@",isClassMethod ? @"+" : @"-",clsName,NSStringFromSelector(sel));
}
static IMP OrigIMP(NSString *clsName, SEL sel) {
    const char *name = clsName.UTF8String;
    for (unsigned i=0;i<gHookCount;i++) if (gHooks[i].selector==sel && !strcmp(gHooks[i].className,name)) return gHooks[i].original;
    return NULL;
}

// ============================================================ 1. 防撤回
// TIM 与 QQ 共用 NT 消息内核，方法名一致：
//   -[OCMsgRecord setRecallTime:]       标记撤回时间
//   -[OCIKernelMsgService recallMsg:msgIds:cb:]  触发撤回
static void AR_setRecallTime(id self, SEL _cmd, long long t) {
    if (!prefBool(kEnabled, YES) || !prefBool(kAntiRecall, YES)) {
        IMP orig = OrigIMP(@"OCMsgRecord", _cmd);
        if (orig) ((void (*)(id, SEL, long long))orig)(self, _cmd, t);
        return;
    }
    LOG(@"blocked setRecallTime: %lld", t);   // 不写入撤回时间 => 消息不会显示已撤回
}

// ============================================================ 2. 复读
// initWithCpp: and automatic duplicate forwarding intentionally unhooked.

// ============================================================ 3. 闪照/截屏
// TIM 使用 UIScreen.isCaptured（已确认 TIM 二进制引用该 selector）
static BOOL FS_isCaptured(id self, SEL _cmd) {
    if (prefBool(kEnabled, YES) && prefBool(kFlashPhoto, YES)) {
        LOG(@"spoof isCaptured -> NO");
        return NO;
    }
    IMP orig = OrigIMP(@"UIScreen", _cmd);
    return orig ? ((BOOL (*)(id, SEL))orig)(self, _cmd) : NO;
}

// ============================================================ 4. 设备伪装
static NSString *SP_model(id self, SEL _cmd) {
    if (prefBool(kEnabled, YES) && prefBool(kDeviceSpoof, NO)) {
        return prefStr(kSpoofModel, @"iPhone 15 Pro");
    }
    IMP orig = OrigIMP(@"UIDevice", _cmd);
    return orig ? ((NSString *(*)(id, SEL))orig)(self, _cmd) : @"iPhone";
}
static NSString *SP_localizedModel(id self, SEL _cmd) {
    if (prefBool(kEnabled, YES) && prefBool(kDeviceSpoof, NO)) {
        return prefStr(kSpoofModel, @"iPhone 15 Pro");
    }
    IMP orig = OrigIMP(@"UIDevice", _cmd);
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
        LOG(@"red packet click blocked");
        return;
    }
    IMP orig = OrigIMP(@"NTRedPackRouterService", _cmd);
    if (orig) ((void (*)(id, SEL, id, id, id, id))orig)(self, _cmd, vc, record, gesture, completion);
}
static BOOL RPkt_checkCanOpen(id self, SEL _cmd, id pack, NSString **tip) {
    if (shouldSkipRedPacket(pack)) {
        if (tip) *tip = @"TIMCleanKit 已拦截";
        return NO;
    }
    IMP orig = OrigIMP(@"NTRedPackRouterService", _cmd);
    return orig ? ((BOOL (*)(id, SEL, id, NSString **))orig)(self, _cmd, pack, tip) : NO;
}
static void RPkt_grabCommand(id self, SEL _cmd, id record) {
    if (shouldSkipRedPacket(record)) { LOG(@"command red packet blocked"); return; }
    IMP orig = OrigIMP(@"NTRedPackRouterService", _cmd);
    if (orig) ((void (*)(id, SEL, id))orig)(self, _cmd, record);
}
static BOOL RPkt_shouldShowBubble(id self, SEL _cmd, id vc, id record) {
    if (shouldSkipRedPacket(record)) return NO;
    IMP orig = OrigIMP(@"NTRedPackRouterService", _cmd);
    return orig ? ((BOOL (*)(id, SEL, id, id))orig)(self, _cmd, vc, record) : NO;
}


// ==================================================== 6. 设置面板（双指长按 0.8s）
static char kGestureAddedKey;
static const NSTimeInterval kLongPress = 0.8;

static void ShowPanel(UIWindow *w);

@interface TIMCKGestureTarget : NSObject
@end
@implementation TIMCKGestureTarget
+ (instancetype)shared {
    static TIMCKGestureTarget *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [self new]; });
    return s;
}
- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (!prefBool(kEnabled, YES)) return;
    if (![g.view isKindOfClass:[UIWindow class]]) return;
    ShowPanel((UIWindow *)g.view);
}
@end

static void InstallGesture(UIWindow *w) {
    if (!w || ![NSThread isMainThread] || !prefBool(kEnabled, YES)) return;
    if (objc_getAssociatedObject(w, &kGestureAddedKey)) return;
    UILongPressGestureRecognizer *g =
        [[UILongPressGestureRecognizer alloc] initWithTarget:[TIMCKGestureTarget shared]
                                                   action:@selector(onLongPress:)];
    g.numberOfTouchesRequired = 2;
    g.minimumPressDuration = kLongPress;
    g.cancelsTouchesInView = NO;
    [w addGestureRecognizer:g];
    objc_setAssociatedObject(w, &kGestureAddedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ObserveWindows(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([note.object isKindOfClass:[UIWindow class]]) InstallGesture(note.object);
    }];
    for (UIWindow *window in UIApplication.sharedApplication.windows) InstallGesture(window);
}

// ------------------------------------------------------------ 面板内容
typedef struct { NSString *title; NSString *key; BOOL def; } PanelItem;

static void ShowPanel(UIWindow *w) {
    UIViewController *vc = w.rootViewController;
    if (!vc) vc = UIApplication.sharedApplication.keyWindow.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if (!vc || [vc isKindOfClass:[UIAlertController class]]) return;

    static PanelItem items[] = {
        {@"防撤回",   kAntiRecall,  YES},
        {@"闪照/截屏", kFlashPhoto,  YES},
        {@"设备伪装", kDeviceSpoof, NO},
    };
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"TIMCleanKit"
                                                                   message:@"1.0.2 启动隔离测试版：复读与底层机型伪装暂不启用"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (int i = 0; i < (int)(sizeof(items)/sizeof(items[0])); i++) {
        BOOL on = prefBool(items[i].key, items[i].def);
        NSString *t = [NSString stringWithFormat:@"%@ %@", on ? @"✅" : @"⬜️", items[i].title];
        UIAlertAction *a = [UIAlertAction actionWithTitle:t
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *_) {
            [prefs() setBool:!on forKey:items[i].key];
            [prefs() synchronize];
            dispatch_async(dispatch_get_main_queue(), ^{ ShowPanel(w); });
        }];
        [alert addAction:a];
    }
    // 小额红包阈值
    NSInteger min = prefInt(kRedMinAmount, 100);
    NSString *minTitle = [NSString stringWithFormat:@"小额阈值：%@",
        min == 0 ? @"关闭" : [NSString stringWithFormat:@"%.2f 元", min / 100.0]];
    [alert addAction:[UIAlertAction actionWithTitle:minTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        UIAlertController *sub = [UIAlertController alertControllerWithTitle:@"小额红包阈值"
                                                                    message:nil preferredStyle:UIAlertControllerStyleAlert];
        NSArray *presets = @[@0, @1, @5, @10, @20, @100];
        for (NSNumber *n in presets) {
            NSString *label = [n integerValue] == 0 ? @"关闭" :
                [NSString stringWithFormat:@"%.2f 元", [n integerValue] / 100.0];
            [sub addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
                [prefs() setInteger:[n integerValue] forKey:kRedMinAmount];
                [prefs() synchronize];
            }]];
        }
        [sub addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [vc presentViewController:sub animated:YES completion:nil];
    }]];
    // 测试/口令红包
    BOOL skipTest = prefBool(kRedSkipTest, YES);
    [alert addAction:[UIAlertAction actionWithTitle:
        [NSString stringWithFormat:@"%@ 测试红包不抢", skipTest ? @"✅" : @"⬜️"]
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            [prefs() setBool:!skipTest forKey:kRedSkipTest];
            [prefs() synchronize];
            dispatch_async(dispatch_get_main_queue(), ^{ ShowPanel(w); });
    }]];
    BOOL skipCmd = prefBool(kRedSkipCmd, NO);
    [alert addAction:[UIAlertAction actionWithTitle:
        [NSString stringWithFormat:@"%@ 口令红包不抢", skipCmd ? @"✅" : @"⬜️"]
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            [prefs() setBool:!skipCmd forKey:kRedSkipCmd];
            [prefs() synchronize];
            dispatch_async(dispatch_get_main_queue(), ^{ ShowPanel(w); });
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = w;
        alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(w.bounds), CGRectGetMidY(w.bounds), 1, 1);
        alert.popoverPresentationController.permittedArrowDirections = 0;
    }
    [vc presentViewController:alert animated:YES completion:nil];
}

// ==================================================== 构造函数：注册全部 Hook
__attribute__((constructor)) static void TIMCKInit(void) {
    @autoreleasepool {
    if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:kDomain]) return;
    registerDefaultsOnce();

    // --- 防撤回（TIM/QQ 共用消息内核）---
    InstallHook(@"OCMsgRecord",        @selector(setRecallTime:),       (IMP)AR_setRecallTime,  NO);
    // --- 闪照/截屏 ---
    InstallHook(@"UIScreen", @selector(isCaptured), (IMP)FS_isCaptured, NO);

    // --- 设备伪装 ---
    InstallHook(@"UIDevice", @selector(model),           (IMP)SP_model,           NO);
    InstallHook(@"UIDevice", @selector(localizedModel),  (IMP)SP_localizedModel,  NO);
    // --- 红包过滤（TIM 4.1.0：NTRedPackRouterService）---
    InstallHook(@"NTRedPackRouterService", @selector(handleRedPackViewClickWithRootVC:msgRecord:gesture:completion:),
                                                                    (IMP)RPkt_handleClick,    YES);
    InstallHook(@"NTRedPackRouterService", @selector(checkCanOpenRedPack:resultTip:),
                                                                    (IMP)RPkt_checkCanOpen,   YES);
    InstallHook(@"NTRedPackRouterService", @selector(grabCommandRedPackIfCanWithMsgRecord:),
                                                                    (IMP)RPkt_grabCommand,    YES);
    InstallHook(@"NTRedPackRouterService", @selector(shouldShowRedPackBubbleWithRootVC:msgRecord:),
                                                                    (IMP)RPkt_shouldShowBubble,YES);

    // Observe existing windows and future key-window notifications on the main queue.
    dispatch_async(dispatch_get_main_queue(), ^{ ObserveWindows(); });

    LOG(@"loaded 1.0.2");
    }
}
