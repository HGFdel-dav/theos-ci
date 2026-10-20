// TWSystemGesture.m
// App 内角落唤醒的系统手势注册。全部运行时解析，任何一步缺失都只是
// 「App 内唤醒不可用」并写日志，绝不影响桌面、绝不崩溃。
#import "TWSystemGesture.h"
#import "TWArcCoordinator.h"
#import "TWPrefs.h"
#import "TWPath.h"
#import "TWRuntimeLog.h"
#import <objc/runtime.h>
#import <objc/message.h>

static id gTWGestureManager;            // _UISystemGestureManager sharedInstance
static id gTWDisplayIdentity;           // 主显示器的 displayIdentity
static UIPanGestureRecognizer *gTWSystemPan;
static BOOL gTWSystemRegistered;

static id TWSGCallNoArg(id obj, NSString *selName) {
    SEL sel = NSSelectorFromString(selName);
    if (!obj || ![obj respondsToSelector:sel]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
    } @catch (NSException *e) {
        TWRuntimeLog(@"[sysgest] %@ 抛异常: %@", selName, e.name ?: @"?");
        return nil;
    }
}

// 原版：addGestureRecognizer:toDisplayWithIdentity: 的第二个参数是主显示器的
// displayIdentity。它是从某个系统类的实例上取 displayIdentity 得到的；
// 反汇编里拿不到确切的类名（chained fixups），这里按候选逐个试，
// 全部带 respondsToSelector 守卫——取不到就传 nil 试一把，失败只记日志。
static id TWSystemDisplayIdentity(void) {
    UIScreen *screen = UIScreen.mainScreen;
    id ident = TWSGCallNoArg(screen, @"displayIdentity");
    if (ident) { TWRuntimeLog(@"[sysgest] identity ← UIScreen.displayIdentity"); return ident; }
    NSArray<NSString *> *classNames = @[@"FBDisplayManager", @"SBDisplayManager",
                                        @"CADisplayManager", @"FBDisplay"];
    for (NSString *clsName in classNames) {
        Class cls = NSClassFromString(clsName);
        if (!cls) continue;
        for (NSString *selName in @[@"mainDisplay", @"sharedInstance", @"mainDisplayManager"]) {
            id obj = TWSGCallNoArg((id)cls, selName);
            if (!obj) continue;
            id got = TWSGCallNoArg(obj, @"displayIdentity");
            if (got) {
                TWRuntimeLog(@"[sysgest] identity ← +[%@ %@].displayIdentity", clsName, selName);
                return got;
            }
        }
    }
    TWRuntimeLog(@"[sysgest] 没取到 displayIdentity（稍后传 nil 试）");
    return nil;
}

void TWSystemGestureSync(void) {
    [[TWPrefs shared] reload];
    BOOL want = [[TWPrefs shared] integerForKey:TWKeyWakeMode defaultValue:TWWakeModeCorner] == TWWakeModeCorner &&
                [[TWPrefs shared] boolForKey:TWKeyEnabled defaultValue:YES] &&
                [[TWPrefs shared] boolForKey:TWKeyArcEnabled defaultValue:YES];
    if (!want) {
        if (gTWSystemRegistered && gTWGestureManager && gTWSystemPan) {
            SEL rmSel = NSSelectorFromString(@"removeGestureRecognizer:fromDisplayWithIdentity:");
            if ([gTWGestureManager respondsToSelector:rmSel]) {
                @try {
                    ((void (*)(id, SEL, id, id))objc_msgSend)(gTWGestureManager, rmSel,
                                                              gTWSystemPan, gTWDisplayIdentity);
                } @catch (__unused NSException *e) { }
            }
            TWRuntimeLog(@"[sysgest] 已反注册（唤醒方式/总开关关闭）");
        }
        gTWSystemRegistered = NO;
        return;
    }
    if (gTWSystemRegistered) return;

    Class mgrCls = NSClassFromString(@"_UISystemGestureManager");
    id manager = TWSGCallNoArg((id)mgrCls, @"sharedInstance");
    if (!manager) {
        TWRuntimeLog(@"[sysgest] _UISystemGestureManager 不可用：App 内唤醒不可用（桌面不受影响）");
        return;
    }
    SEL addSel = NSSelectorFromString(@"addGestureRecognizer:toDisplayWithIdentity:");
    if (![manager respondsToSelector:addSel]) {
        TWRuntimeLog(@"[sysgest] 管理器没有 add recognizer 入口：App 内唤醒不可用");
        return;
    }
    id identity = TWSystemDisplayIdentity();

    if (!gTWSystemPan) {
        TWArcCoordinator *coordinator = [TWArcCoordinator sharedInstance];
        gTWSystemPan = [[UIPanGestureRecognizer alloc] initWithTarget:coordinator
                                                               action:@selector(twSystemGestureChanged:)];
        gTWSystemPan.maximumNumberOfTouches = 1;
        gTWSystemPan.minimumNumberOfTouches = 1;
        // 识别成功才吞掉底层触摸；没识别（非角落/未拖动）时 App 照常收到触摸。
        gTWSystemPan.cancelsTouchesInView = YES;
        gTWSystemPan.delegate = coordinator;
        objc_setAssociatedObject(coordinator, "TWArcSysPan", gTWSystemPan,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(manager, addSel, gTWSystemPan, identity);
        gTWGestureManager = manager;
        gTWDisplayIdentity = identity;
        gTWSystemRegistered = YES;
        TWRuntimeLog(@"[sysgest] App 内角落手势注册成功 identity=%@", identity ?: @"(nil)");
    } @catch (NSException *e) {
        TWRuntimeLog(@"[sysgest] 注册抛异常：%@", e);
    }
}

void TWSystemGestureStart(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        TWSystemGestureSync();
    });
}
