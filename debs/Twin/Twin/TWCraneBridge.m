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
        if (![prefs boolForKey:TWKeyEnabled defaultValue:NO] || ![prefs boolForKey:TWKeyCraneEnabled defaultValue:NO]) { completion(YES); return; }
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
        if (![prefs boolForKey:TWKeyEnabled defaultValue:NO] || ![prefs boolForKey:TWKeyCraneEnabled defaultValue:NO]) { completion(YES); return; }
        [self switchBundleID:bundleID toContainer:containerID completion:completion];
    });
}

// 真正的切换与核验（主队列调用）。completion 保证只回调一次。
+ (void)switchBundleID:(NSString *)bundleID toContainer:(NSString *)container completion:(void (^)(BOOL))completion {
        TWPrefs *prefs=TWPrefs.shared;
        if (!completion) return;
        if (TWCraneSwitching) { TWCraneNotice(@"Crane 操作尚未结束；为避免容器竞态，暂不启动应用。请完成或取消认证后重试。"); completion(NO); return; }
        if (![container isKindOfClass:NSString.class] || ![container length] || ![bundleID isKindOfClass:NSString.class] || !bundleID.length) { completion(NO); return; }
        @try {
            id manager=[self sharedManager];
            SEL sel=NSSelectorFromString(@"setActiveContainerIdentifier:forApplicationWithIdentifier:usingBiometricsIfNeededWithSuccessHandler:");
            SEL active=NSSelectorFromString(@"activeContainerIdentifierForApplicationWithIdentifier:");
            if (!TWSignature(manager,sel,@encode(void),@[@"@",@"@",@"@?"]) || !TWSignature(manager,active,@encode(id),@[@"@"]) || ![self isApplicationSupportedByCrane:bundleID]) {
                TWCraneNotice(@"Crane 未安装、应用不受支持或 API 不兼容；为避免打开错误容器，已取消启动。"); completion(NO); return;
            }
            // Short-circuit: already on the target container -> nothing to switch,
            // no biometrics prompt (prevents double-gating when ParallelX's own
            // hooked entry point re-enters after the arc path set the container).
            @try {
                NSString *current = [self activeContainerForBundleID:bundleID];
                if ([current isEqualToString:container]) { completion(YES); return; }
            } @catch (__unused NSException *e) { /* fall through to explicit switch */ }
            TWCraneSwitching=YES; __block BOOL finished=NO; __block BOOL callbackReceived=NO;
            void (^finish)(BOOL,NSString *)=^(BOOL success,NSString *reason) {
                if (finished) return; finished=YES;
                if (!success) TWCraneNotice(reason);
                completion(success);
            };
            // Bounded failure only: no force-switch, biometric bypass or timeout launch.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,45*NSEC_PER_SEC),dispatch_get_main_queue(),^{
                if (!finished) finish(NO,@"Crane 45 秒内未确认容器，已取消启动。请完成或取消认证后重试。");
            });
            void (^callback)(BOOL)=^(BOOL success) {
                dispatch_async(dispatch_get_main_queue(),^{
                    if (callbackReceived) return; callbackReceived=YES;
                    // Keep the gate locked through completion to reject reentrant switches.
                    if (!finished) {
                        @try {
                            // 只在"面板里配了映射"时才要求映射未被改动；Arc 的显式容器路径没有映射。
                            id mapped=[prefs craneApps][bundleID];
                            BOOL unchanged=[prefs boolForKey:TWKeyEnabled defaultValue:NO] && [prefs boolForKey:TWKeyCraneEnabled defaultValue:NO];
                            if ([mapped isKindOfClass:NSString.class] && [mapped length]) unchanged = unchanged && [mapped isEqual:container];
                            BOOL verified=success && unchanged && [[self activeContainerForBundleID:bundleID] isEqualToString:container];
                            finish(verified,@"认证取消、切换失败、配置改变或容器核验不符；为避免误开，未启动应用。");
                        } @catch (__unused NSException *e) { finish(NO,@"Crane 容器核验异常，未启动应用。"); }
                    }
                    TWCraneSwitching=NO;
                });
            };
            @try { ((void (*)(id,SEL,id,id,void (^)(BOOL)))objc_msgSend)(manager,sel,container,bundleID,callback); }
            @catch (__unused NSException *e) {
                // No cancellation API: remain locked until callback or process restart.
                finish(NO,@"Crane 切换发生异常，未启动应用；请重启 SpringBoard 后再试。");
            }
        } @catch (__unused NSException *e) { TWCraneNotice(@"Crane 初始化异常，未启动应用。"); completion(NO); }
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
    if (TWSignature(manager, sel, @encode(id), @[@"@", @"@", @encode(BOOL)])) {
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