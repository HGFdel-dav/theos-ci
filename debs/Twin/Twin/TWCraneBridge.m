// TWCraneBridge.m
#import "TWCraneBridge.h"
#import "TWPrefs.h"
#import <objc/message.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

// Verified against opa334/Crane-Resources master/libCrane/libCrane.h:
// successHandler is void (^)(BOOL); only the biometric-respecting API is used.
static BOOL TWCraneSwitching = NO;   // SpringBoard 主队列专用：同一时间只允许一次容器切换
static BOOL TWSignature(id target, SEL sel, const char *result, NSArray<NSString *> *args) {
    if (!target || ![target respondsToSelector:sel]) return NO;
    Method method = class_getInstanceMethod(object_getClass(target), sel);
    const char *types = method ? method_getTypeEncoding(method) : NULL;
    if (!types) return NO;
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:types];
    if (sig.numberOfArguments != args.count+2 || strcmp(sig.methodReturnType,result)) return NO;
    for (NSUInteger i=0;i<args.count;i++) if (strcmp([sig getArgumentTypeAtIndex:i+2],args[i].UTF8String)) return NO;
    return YES;
}
static void TWCraneNotice(NSString *message) {
    NSLog(@"[Twin] %@", message);
    UIViewController *vc = nil;
    for (UIWindow *window in UIApplication.sharedApplication.windows.reverseObjectEnumerator)
        if (!window.hidden && window.rootViewController) { vc=window.rootViewController; break; }
    while (vc.presentedViewController) vc=vc.presentedViewController;
    if (!vc || [vc isKindOfClass:UIAlertController.class]) return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Twin — 启动已取消" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:alert animated:YES completion:nil];
}

@implementation TWCraneBridge

static Class CraneManagerClass(void) {
    Class cls = NSClassFromString(@"CraneManager");
    if (cls) return cls;
    NSMutableArray *paths=[NSMutableArray array];
    NSString *root=TWJBRootPath();
    if (root.length) [paths addObject:[root stringByAppendingPathComponent:@"usr/lib/libcrane.dylib"]];
    [paths addObjectsFromArray:@[@"/var/jb/usr/lib/libcrane.dylib",@"/usr/lib/libcrane.dylib"]];
    for (NSString *path in paths) {
        if ([NSFileManager.defaultManager fileExistsAtPath:path] && dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_GLOBAL)) {
            cls=NSClassFromString(@"CraneManager"); if (cls) break;
        }
    }
    return cls;
}

+ (BOOL)isCraneAvailable {
    return CraneManagerClass() != nil;
}

// Runtime-safe objc_msgSend (ARC forbids direct casts, so use a function pointer).
static id TWMsgSend(id target, SEL sel) {
    if (!target || !sel) return nil;
    id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return fn(target, sel);
}

static id TWMsgSendStr(id target, SEL sel, id arg) {
    if (!target || !sel) return nil;
    id (*fn)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
    return fn(target, sel, arg);
}

+ (id)sharedManager {
    Class cls = CraneManagerClass();
    if (!cls) return nil;
    SEL sel = NSSelectorFromString(@"sharedManager");
    if (!TWSignature(cls, sel, @encode(id), @[])) return nil;
    return TWMsgSend(cls, sel);
}

+ (BOOL)isApplicationSupportedByCrane:(NSString *)bundleID {
    id manager = [self sharedManager];
    if (!manager || !bundleID.length) return NO;
    SEL sel = NSSelectorFromString(@"isApplicationSupportedByCrane:");
    if (!TWSignature(manager, sel, @encode(BOOL), @[@"@"])) return NO;
    BOOL (*fn)(id, SEL, id) = (BOOL (*)(id, SEL, id))objc_msgSend;
    return fn(manager, sel, bundleID) != 0;
}

+ (NSString *)activeContainerForBundleID:(NSString *)bundleID {
    id manager = [self sharedManager];
    if (!manager || !bundleID.length) return @"";
    SEL sel = NSSelectorFromString(@"activeContainerIdentifierForApplicationWithIdentifier:");
    if (!TWSignature(manager, sel, @encode(id), @[@"@"])) return @"";
    id result = TWMsgSendStr(manager, sel, bundleID);
    return [result isKindOfClass:[NSString class]] ? result : @"";
}

+ (void)prepareLaunchForBundleID:(NSString *)bundleID completion:(void (^)(BOOL))completion {
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        TWPrefs *prefs=TWPrefs.shared;
        if (![bundleID isKindOfClass:NSString.class] || !bundleID.length) { TWCraneNotice(@"应用标识无效，未启动应用。"); completion(NO); return; }
        if (![prefs boolForKey:TWKeyEnabled defaultValue:YES] || ![prefs boolForKey:TWKeyCraneEnabled defaultValue:YES]) { completion(YES); return; }
        id configured=[prefs craneApps][bundleID];
        if (!configured) { completion(YES); return; }
        if (![configured isKindOfClass:NSString.class] || ![configured length]) { TWCraneNotice(@"Crane 容器配置无效，请重新选择。"); completion(NO); return; }
        [self switchBundleID:bundleID toContainer:[configured copy] completion:completion];
    });
}

// 指定容器的版本：Arc 里每个图标就是一个 (应用, 容器) 对，直接指名道姓。
+ (void)prepareLaunchForBundleID:(NSString *)bundleID containerID:(NSString *)containerID completion:(void (^)(BOOL))completion {
    if (!completion) return;
    if (![containerID isKindOfClass:NSString.class] || !containerID.length) {
        [self prepareLaunchForBundleID:bundleID completion:completion];   // 退回按面板配置的映射
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        TWPrefs *prefs=TWPrefs.shared;
        if (![bundleID isKindOfClass:NSString.class] || !bundleID.length) { TWCraneNotice(@"应用标识无效，未启动应用。"); completion(NO); return; }
        if (![prefs boolForKey:TWKeyEnabled defaultValue:YES] || ![prefs boolForKey:TWKeyCraneEnabled defaultValue:YES]) { completion(YES); return; }
        [self switchBundleID:bundleID toContainer:containerID completion:completion];
    });
}

// 真正的切换与核验（主队列调用）。completion 保证只回调一次。
// 0.9.7：改为 Crane 官方的「不带认证」接口
//   setActiveContainerIdentifier:forApplicationWithIdentifier:reloadApplication:
// （ScreenCore / Crane 自己用的就是这一条，所以开分身不会再弹指纹）。
+ (void)switchBundleID:(NSString *)bundleID toContainer:(NSString *)container completion:(void (^)(BOOL))completion {
    if (!completion) return;
    if (![container isKindOfClass:NSString.class] || ![container length] ||
        ![bundleID isKindOfClass:NSString.class] || !bundleID.length) { completion(NO); return; }
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            id manager = [self sharedManager];
            if (!manager || ![self isApplicationSupportedByCrane:bundleID]) {
                TWCraneNotice(@"Crane 未安装或该应用不受支持，已取消启动。");
                completion(NO); return;
            }
            // 已经在目标容器上：直接放行，不做任何切换。
            @try {
                NSString *current = [self activeContainerForBundleID:bundleID];
                if ([current isEqualToString:container]) { completion(YES); return; }
            } @catch (__unused NSException *e) { /* 继续走显式切换 */ }

            // ① 首选：无认证接口（Crane 官方，ScreenCore 同款）。
            SEL plain = NSSelectorFromString(@"setActiveContainerIdentifier:forApplicationWithIdentifier:reloadApplication:");
            if ([manager respondsToSelector:plain]) {
                @try {
                    ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(manager, plain, container, bundleID, NO);
                } @catch (__unused NSException *e) {
                    TWCraneNotice(@"Crane 切换发生异常，未启动应用。");
                    completion(NO); return;
                }
                NSString *now = [self activeContainerForBundleID:bundleID];
                BOOL ok = [now isEqualToString:container];
                if (!ok) TWCraneNotice(@"Crane 未确认容器，未启动应用。");
                completion(ok); return;
            }

            // ② 兜底：旧版 Crane 只有带认证的接口。
            SEL bio = NSSelectorFromString(@"setActiveContainerIdentifier:forApplicationWithIdentifier:usingBiometricsIfNeededWithSuccessHandler:");
            SEL active = NSSelectorFromString(@"activeContainerIdentifierForApplicationWithIdentifier:");
            if (!TWSignature(manager, bio, @encode(void), @[@"@", @"@", @"@?"]) ||
                !TWSignature(manager, active, @encode(id), @[@"@"])) {
                TWCraneNotice(@"Crane 接口不兼容，为避免打开错误容器，已取消启动。");
                completion(NO); return;
            }
            TWCraneSwitching = YES;
            __block BOOL finished = NO;
            void (^finish)(BOOL, NSString *) = ^(BOOL success, NSString *reason) {
                if (finished) return; finished = YES;
                if (!success) TWCraneNotice(reason);
                completion(success);
            };
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 45 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if (!finished) finish(NO, @"Crane 45 秒内未确认容器，已取消启动。");
            });
            void (^callback)(BOOL) = ^(BOOL success) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (finished) { TWCraneSwitching = NO; return; }
                    BOOL verified = success && [[self activeContainerForBundleID:bundleID] isEqualToString:container];
                    finish(verified, @"认证取消或容器核验不符，为避免误开，未启动应用。");
                    TWCraneSwitching = NO;
                });
            };
            @try { ((void (*)(id, SEL, id, id, void (^)(BOOL)))objc_msgSend)(manager, bio, container, bundleID, callback); }
            @catch (__unused NSException *e) { finish(NO, @"Crane 切换发生异常，未启动应用。"); }
        } @catch (__unused NSException *e) {
            TWCraneNotice(@"Crane 初始化异常，未启动应用。");
            completion(NO);
        }
    });
}

// ── 容器枚举（"一容器一图标"的数据源）────────────────────────────────
+ (NSArray<NSDictionary *> *)containersForBundleID:(NSString *)bundleID {
    id manager = [self sharedManager];
    if (!manager || ![bundleID isKindOfClass:NSString.class] || !bundleID.length) return @[];
    SEL sel = NSSelectorFromString(@"containerIdentifiersOfApplicationWithIdentifier:");
    if (!TWSignature(manager, sel, @encode(id), @[@"@"])) return @[];
    id list = TWMsgSendStr(manager, sel, bundleID);
    if (![list isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSString *active = [self activeContainerForBundleID:bundleID];
    for (id identifier in list) {
        if (![identifier isKindOfClass:NSString.class] || ![identifier length]) continue;
        if ([seen containsObject:identifier]) continue;
        [seen addObject:identifier];
        NSString *name = [self displayNameForContainer:identifier bundleID:bundleID];
        // Crane 没记活动容器时，视该容器为默认容器。
        BOOL isDefault = !active.length || [active isEqualToString:identifier];
        [result addObject:@{@"containerID": identifier, @"name": name ?: @"", @"isDefault": @(isDefault)}];
    }
    return result;
}

+ (NSArray<NSString *> *)applicationsWithNonDefaultContainers {
    id manager = [self sharedManager];
    if (!manager) return @[];
    SEL sel = NSSelectorFromString(@"identfiersOfApplicationsThatHaveNonDefaultContainers");
    if (!TWSignature(manager, sel, @encode(id), @[])) return @[];
    id list = TWMsgSend(manager, sel);
    if (![list isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (id item in list) if ([item isKindOfClass:NSString.class] && [item length]) [out addObject:item];
    return out;
}

+ (NSString *)displayNameForContainer:(NSString *)containerID bundleID:(NSString *)bundleID {
    id manager = [self sharedManager];
    if (!manager || ![containerID isKindOfClass:NSString.class] || !containerID.length ||
        ![bundleID isKindOfClass:NSString.class] || !bundleID.length) return @"";
    SEL sel = NSSelectorFromString(@"displayNameForContainerWithIdentifier:ofApplicationWithIdentifier:shouldUseShortVersion:");
    if (TWSignature(manager, sel, @encode(id), @[@"@", @"@", [NSString stringWithUTF8String:@encode(BOOL)]])) {
        id (*fn)(id, SEL, id, id, BOOL) = (id (*)(id, SEL, id, id, BOOL))objc_msgSend;
        id name = fn(manager, sel, containerID, bundleID, NO);
        if ([name isKindOfClass:NSString.class] && [name length]) return name;
    }
    SEL shortSel = NSSelectorFromString(@"displayNameForContainerWithIdentifier:ofApplicationWithIdentifier:");
    if (TWSignature(manager, shortSel, @encode(id), @[@"@", @"@"])) {
        id (*fn)(id, SEL, id, id) = (id (*)(id, SEL, id, id))objc_msgSend;
        id name = fn(manager, shortSel, containerID, bundleID);
        if ([name isKindOfClass:NSString.class]) return name ?: @"";
    }
    return @"";
}

// Legacy BOOL calls cannot represent async success; never switch or claim success.
+ (BOOL)setContainer:(NSString *)containerID forBundleID:(NSString *)bundleID { return NO; }
+ (BOOL)applyContainerIfConfiguredForBundleID:(NSString *)bundleID { return NO; }

@end