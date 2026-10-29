//
//  POCraneBridge.m
//  SplitX
//
//  ABI 依据 ScreenCore 2.0.5 反汇编：
//  setActiveContainerIdentifier:forApplicationWithIdentifier:usingBiometricsIfNeededWithSuccessHandler:
//  三参数，success handler 为 void (^)(BOOL)（descriptor v12@?0B8）。
//  “usingBiometricsIfNeededWithSuccessHandler:” 是整段 selector，不是额外 BOOL。
//  FBSystemService 终止 completion 无参数（v8@?0），ACK 不等于进程已退出。
//

#import "POSplitXLog.h"
#import "POSplitXSettings.h"
#import "POCraneBridge.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <signal.h>
#include <errno.h>
#include <string.h>

NSString *const POCraneErrorDomain = @"POCraneErrorDomain";

static NSString *const POCraneBioSelector =
    @"setActiveContainerIdentifier:forApplicationWithIdentifier:usingBiometricsIfNeededWithSuccessHandler:";
static NSString *const POCraneTerminateSelector =
    @"terminateApplication:forReason:andReport:withDescription:completion:";

static NSError *POCraneError(POCraneErrorCode code, NSString *text) {
    return [NSError errorWithDomain:POCraneErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: text}];
}

static BOOL POCraneString(id value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0;
}

static BOOL POCraneType(const char *actual, const char *expected) {
    if (!actual || !expected) return NO;
    if (strcmp(expected, "@") == 0) {
        if (strcmp(actual, "@") == 0) return YES;
        size_t n = strlen(actual);
        return n >= 4 && actual[0] == '@' && actual[1] == '"' && actual[n - 1] == '"';
    }
    return strcmp(actual, expected) == 0;
}

static BOOL POCraneSignature(id target, NSString *name, const char *result, NSArray<NSString *> *args) {
    SEL sel = NSSelectorFromString(name);
    if (!target || ![target respondsToSelector:sel]) return NO;
    Method method = class_getInstanceMethod(object_getClass(target), sel);
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!encoding) return NO;
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:encoding];
    if (!sig || sig.numberOfArguments != args.count + 2) return NO;
    if (!POCraneType(sig.methodReturnType, result) || strcmp([sig getArgumentTypeAtIndex:1], ":") != 0) return NO;
    for (NSUInteger i = 0; i < args.count; i++) {
        if (!POCraneType([sig getArgumentTypeAtIndex:i + 2], args[i].UTF8String)) return NO;
    }
    return YES;
}

static NSArray<NSString *> *POCraneCandidatePaths(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    void (^addRoot)(NSString *) = ^(NSString *root) {
        if (!root.length) return;
        NSString *p = [root stringByAppendingPathComponent:@"usr/lib/libcrane.dylib"];
        if (![paths containsObject:p]) [paths addObject:p];
    };
    const char *env = getenv("JBROOT");
    if (env) addRoot([NSString stringWithUTF8String:env]);
    addRoot(@"/");
    addRoot(@"/var/jb");
    // RootHide：真实根是 .jbroot-<UUID>，/var/jb 往往只是符号链接。
    NSArray<NSString *> *bases = @[
        @"/var/containers/Bundle/Application",
        @"/var/mobile/Containers/Shared/AppGroup",
        @"/var/mobile/Containers/Bundle/Application",
    ];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *base in bases) {
        for (NSString *name in [fm contentsOfDirectoryAtPath:base error:NULL]) {
            if (![name hasPrefix:@".jbroot"]) continue;
            addRoot([base stringByAppendingPathComponent:name]);
        }
    }
    return paths;
}

static id POCraneManager(void) {
    static BOOL logged = NO;
    Class cls = NSClassFromString(@"CraneManager");
    if (!cls) {
        for (NSString *path in POCraneCandidatePaths()) {
            if (![NSFileManager.defaultManager fileExistsAtPath:path]) continue;
            void *h = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
            cls = NSClassFromString(@"CraneManager");
            if (!logged) {
                logged = YES;
                PXLog(@"clone", @"dlopen %@ -> %p class=%d", path, h, cls != nil);
            }
            if (cls) break;
        }
    }
    if (!cls) {
        if (!logged) {
            logged = YES;
            PXLogW(@"clone", @"找不到 CraneManager，候选=%@", POCraneCandidatePaths());
        }
        return nil;
    }
    SEL shared = NSSelectorFromString(@"sharedManager");
    if (!POCraneSignature(cls, @"sharedManager", "@", @[])) {
        PXLogW(@"clone", @"CraneManager 有类但 sharedManager 签名不符");
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(cls, shared);
}

static NSString *POCraneActive(id manager, NSString *bundle) {
    SEL sel = NSSelectorFromString(@"activeContainerIdentifierForApplicationWithIdentifier:");
    if (!manager || !POCraneSignature(manager, @"activeContainerIdentifierForApplicationWithIdentifier:", "@", @[@"@"])) return nil;
    id value = ((id (*)(id, SEL, id))objc_msgSend)(manager, sel, bundle);
    return POCraneString(value) ? value : nil;
}

/// 只读 processState；缺 selector 视为未知，不当作“已退出”。
static BOOL POCraneProcess(NSString *bundle, pid_t *pid, BOOL *running) {
    Class controllerClass = NSClassFromString(@"SBApplicationController");
    if (!controllerClass) { PXLogW(@"clone", @"process: 没有 SBApplicationController"); return NO; }
    SEL lookup = NSSelectorFromString(@"applicationWithBundleIdentifier:");
    if (!POCraneSignature(controllerClass, @"sharedInstance", "@", @[]) ||
        !POCraneSignature(controllerClass, @"applicationWithBundleIdentifier:", "@", @[@"@"])) {
        PXLogW(@"clone", @"process: controller ABI 不符 shared=%d lookup=%d",
               POCraneSignature(controllerClass, @"sharedInstance", "@", @[]),
               POCraneSignature(controllerClass, @"applicationWithBundleIdentifier:", "@", @[@"@"]));
        return NO;
    }
    id controller = ((id (*)(id, SEL))objc_msgSend)(controllerClass, NSSelectorFromString(@"sharedInstance"));
    id app = ((id (*)(id, SEL, id))objc_msgSend)(controller, lookup, bundle);
    if (!app) { PXLogW(@"clone", @"process: %@ 没有 SBApplication", bundle); return NO; }
    if (!POCraneSignature(app, @"processState", "@", @[])) {
        PXLogW(@"clone", @"process: %@ processState ABI 不符 (class=%@)", bundle, NSStringFromClass([app class]));
        return NO;
    }
    id state = ((id (*)(id, SEL))objc_msgSend)(app, NSSelectorFromString(@"processState"));
    if (!state) { PXLogW(@"clone", @"process: %@ processState=nil", bundle); return NO; }
    BOOL pidInt = POCraneSignature(state, @"pid", @encode(int), @[]);
    BOOL pidLong = POCraneSignature(state, @"pid", @encode(long long), @[]);
    if (!pidInt && !pidLong) {
        PXLogW(@"clone", @"process: %@ pid ABI 不符 (state=%@)", bundle, NSStringFromClass([state class]));
        return NO;
    }
    *pid = (pid_t)((int (*)(id, SEL))objc_msgSend)(state, NSSelectorFromString(@"pid"));
    *running = NO;
    if (POCraneSignature(state, @"isRunning", @encode(BOOL), @[])) {
        *running = ((BOOL (*)(id, SEL))objc_msgSend)(state, NSSelectorFromString(@"isRunning")) != 0;
    }
    PXLog(@"clone", @"process: %@ pid=%d running=%d", bundle, *pid, *running);
    return YES;
}

static BOOL POCranePidExited(pid_t pid) {
    if (pid <= 0) return YES;
    errno = 0;
    return kill(pid, 0) == -1 && errno == ESRCH;
}

/// settings 可能是字典，也可能是应用设置对象；两种都取 containers。
static id POCRaneContainersFromSettings(id settings) {
    if (!settings) return nil;
    if ([settings isKindOfClass:NSDictionary.class]) {
        NSDictionary *dict = settings;
        return dict[@"Containers"] ?: dict[@"containers"];
    }
    for (NSString *key in @[@"containers", @"Containers"]) {
        SEL sel = NSSelectorFromString(key);
        if ([settings respondsToSelector:sel]) {
            return ((id (*)(id, SEL))objc_msgSend)(settings, sel);
        }
        if ([settings respondsToSelector:@selector(valueForKey:)]) {
            id value = ((id (*)(id, SEL, id))objc_msgSend)(settings, @selector(valueForKey:), key);
            if (value) return value;
        }
    }
    return nil;
}

/// 行可能是字典或对象。
static NSString *POCRaneRowString(id row, NSString *key) {
    if (!row) return nil;
    if ([row isKindOfClass:NSDictionary.class]) {
        id value = ((NSDictionary *)row)[key];
        return [value isKindOfClass:NSString.class] ? value : nil;
    }
    SEL sel = NSSelectorFromString(key);
    if ([row respondsToSelector:sel]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(row, sel);
        return [value isKindOfClass:NSString.class] ? value : nil;
    }
    if ([row respondsToSelector:@selector(valueForKey:)]) {
        id value = ((id (*)(id, SEL, id))objc_msgSend)(row, @selector(valueForKey:), key);
        return [value isKindOfClass:NSString.class] ? value : nil;
    }
    return nil;
}

@implementation POCraneBridge

+ (BOOL)isAvailable {
    return POCraneManager() != nil;
}

+ (BOOL)isBundleSupported:(NSString *)bundleIdentifier {
    if (!POCraneString(bundleIdentifier)) return NO;
    id manager = POCraneManager();
    if (!manager || !POCraneSignature(manager, @"isApplicationSupportedByCrane:", @encode(BOOL), @[@"@"])) return NO;
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(manager, NSSelectorFromString(@"isApplicationSupportedByCrane:"),
                                                 bundleIdentifier) != 0;
}

+ (NSString *)displayNameForContainer:(NSString *)containerID bundle:(NSString *)bundleID {
    id manager = POCraneManager();
    if (!manager || !containerID.length || !bundleID.length) return @"";
    SEL se = NSSelectorFromString(@"displayNameForContainerWithIdentifier:ofApplicationWithIdentifier:shouldUseShortVersion:");
    if (POCraneSignature(manager, NSStringFromSelector(se), "@", @[@"@", @"@", [NSString stringWithUTF8String:@encode(BOOL)]])) {
        id name = ((id (*)(id, SEL, id, id, BOOL))objc_msgSend)(manager, se, containerID, bundleID, NO);
        if ([name isKindOfClass:NSString.class] && [name length]) return name;
    }
    SEL shortSel = NSSelectorFromString(@"displayNameForContainerWithIdentifier:ofApplicationWithIdentifier:");
    if (POCraneSignature(manager, NSStringFromSelector(shortSel), "@", @[@"@", @"@"])) {
        id name = ((id (*)(id, SEL, id, id))objc_msgSend)(manager, shortSel, containerID, bundleID);
        if ([name isKindOfClass:NSString.class] && [name length]) return name;
    }
    return @"";
}

+ (NSArray<POSplitTarget *> *)targetsForBundleIdentifier:(NSString *)bundleIdentifier {
    NSMutableArray<POSplitTarget *> *targets = [NSMutableArray array];
    if (!POCraneString(bundleIdentifier)) return targets;

    id manager = POCraneManager();
    SEL listSel = NSSelectorFromString(@"containerIdentifiersOfApplicationWithIdentifier:");
    BOOL sigOK = manager && POCraneSignature(manager, NSStringFromSelector(listSel), "@", @[@"@"]);
    if (!sigOK) {
        PXLogW(@"clone", @"%@ 枚举失败 manager=%@ 有容器枚举=%@ 有settings=%@", bundleIdentifier,
               manager ? NSStringFromClass([manager class]) : @"nil",
               manager && [manager respondsToSelector:@selector(containerIdentifiersOfApplicationWithIdentifier:)] ? @"yes" : @"no",
               manager && [manager respondsToSelector:@selector(applicationSettingsForApplicationWithIdentifier:)] ? @"yes" : @"no");
        [targets addObject:[POSplitTarget targetWithBundleIdentifier:bundleIdentifier]];
        return targets;
    }
    id list = ((id (*)(id, SEL, id))objc_msgSend)(manager, listSel, bundleIdentifier);
    if (![list isKindOfClass:NSArray.class]) {
        PXLogW(@"clone", @"%@ 容器列表不是数组: %@", bundleIdentifier,
               list ? NSStringFromClass([list class]) : @"nil");
        [targets addObject:[POSplitTarget targetWithBundleIdentifier:bundleIdentifier]];
        return targets;
    }
    PXLog(@"clone", @"%@ 原始容器列表=%@", bundleIdentifier, [(NSArray *)list componentsJoinedByString:@","]);

    // DEFAULT 排最前，其余按系统给的顺序；去重。
    NSMutableOrderedSet<NSString *> *ids = [NSMutableOrderedSet orderedSetWithObject:POSplitDefaultContainerIdentifier];
    for (id item in (NSArray *)list) {
        if (POCraneString(item)) [ids addObject:item];
    }
    BOOL multiple = ids.count > 1;
    for (NSString *identifier in ids) {
        BOOL isDefault = [identifier isEqualToString:POSplitDefaultContainerIdentifier];
        if (isDefault && multiple && ![POSplitXSettings shared].cloneShowDefault) continue;
        NSString *name = isDefault ? @"默认" : [self displayNameForContainer:identifier bundle:bundleIdentifier];
        [targets addObject:[POSplitTarget targetWithBundleIdentifier:bundleIdentifier
                                                           container:identifier
                                                         displayName:name.length ? name : identifier]];
    }
    PXLog(@"clone", @"%@ 容器 %lu 个", bundleIdentifier, (unsigned long)targets.count);
    return targets;
}

+ (NSString *)activeContainerForBundleIdentifier:(NSString *)bundleIdentifier {
    return POCraneActive(POCraneManager(), bundleIdentifier);
}

+ (void)activateTarget:(POSplitTarget *)target
            completion:(void (^)(BOOL, NSError *))completion {
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!target.bundleIdentifier.length) {
            completion(NO, POCraneError(POCraneInvalidData, @"缺少应用标识"));
            return;
        }
        PXLog(@"clone", @"target %@/%@ available=%d supported=%d active=%@", target.bundleIdentifier,
              target.containerIdentifier, [self isAvailable], [self isBundleSupported:target.bundleIdentifier],
              POCraneActive(POCraneManager(), target.bundleIdentifier) ?: @"nil");
        if (![self isAvailable]) {
            completion(YES, nil);   // 没装 Crane：直接走普通启动
            return;
        }
        NSString *bundle = target.bundleIdentifier;
        NSString *wanted = target.containerIdentifier;
        id manager = POCraneManager();
        if (![self isBundleSupported:bundle]) {
            PXLog(@"clone", @"%@ 不受 Crane 支持，按普通启动", bundle);
            completion(YES, nil);   // 该应用本身不支持分身
            return;
        }
        if ([POCraneActive(manager, bundle) isEqualToString:wanted]) {
            PXLog(@"clone", @"%@ 已在目标容器 %@，无需切换", bundle, wanted);
            completion(YES, nil);   // 已在目标容器，由调用方决定是否复用
            return;
        }

        pid_t oldPid = 0;
        BOOL running = NO;
        if (!POCraneProcess(bundle, &oldPid, &running)) {
            completion(NO, POCraneError(POCraneInvalidData, @"读不到进程状态"));
            return;
        }

        __block BOOL finished = NO;
        __block NSTimeInterval startedAt = NSDate.timeIntervalSinceReferenceDate;
        void (^finish)(BOOL, NSError *) = ^(BOOL ok, NSError *error) {
            if (finished) return;
            finished = YES;
            PXLogSlow(@"switch", NSDate.timeIntervalSinceReferenceDate - startedAt,
                      [NSString stringWithFormat:@"activate %@", target.identityKey]);
            PXLog(@"switch", @"完成 %@ ok=%d err=%@ 用时%.0fms", target.identityKey, ok,
                  error.localizedDescription ?: @"none",
                  (NSDate.timeIntervalSinceReferenceDate - startedAt) * 1000.0);
            completion(ok, error);
        };

        void (^switchNow)(void) = ^{
            if (!POCraneSignature(manager, POCraneBioSelector, "v", @[@"@", @"@", @"@?"])) {
                finish(NO, POCraneError(POCraneUnsupportedABI, @"Crane 切换接口签名不符"));
                return;
            }
            void (^handler)(BOOL) = ^(BOOL success) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (finished) return;
                    if (!success) {
                        finish(NO, POCraneError(POCraneVerificationFailed, @"认证或切换被拒绝"));
                        return;
                    }
                    PXLog(@"clone", @"auth ok, readback=%@ want=%@", POCraneActive(manager, bundle), wanted);
                    if (![POCraneActive(manager, bundle) isEqualToString:wanted]) {
                        finish(NO, POCraneError(POCraneVerificationFailed, @"回读的容器与目标不一致"));
                        return;
                    }
                    finish(YES, nil);
                });
            };
            ((void (*)(id, SEL, id, id, void (^)(BOOL)))objc_msgSend)(manager,
                NSSelectorFromString(POCraneBioSelector), wanted, bundle, [handler copy]);
        };

        if (!running && POCranePidExited(oldPid)) {
            switchNow();
            return;
        }

        // 先终止旧进程，只等真实退出；ACK 不当作已退出。
        Class serviceClass = NSClassFromString(@"FBSystemService");
        id service = (serviceClass && POCraneSignature(serviceClass, @"sharedInstance", "@", @[]))
            ? ((id (*)(id, SEL))objc_msgSend)(serviceClass, NSSelectorFromString(@"sharedInstance")) : nil;
        if (!service ||
            !POCraneSignature(service, POCraneTerminateSelector, "v",
                              @[@"@", @"q", [NSString stringWithUTF8String:@encode(BOOL)], @"@", @"@?"])) {
            finish(NO, POCraneError(POCraneUnsupportedABI, @"终止接口签名不符"));
            return;
        }
        void (^ack)(void) = ^{};
        ((void (*)(id, SEL, id, long long, BOOL, id, void (^)(void)))objc_msgSend)(
            service, NSSelectorFromString(POCraneTerminateSelector), bundle, 1LL, YES,
            @"SplitX 切换分身", ack);

        __block NSUInteger polls = 0;
        __block void (^wait)(void);
        wait = ^{
            if (finished) return;
            polls++;
            pid_t pid = 0;
            BOOL nowRunning = NO;
            BOOL known = POCraneProcess(bundle, &pid, &nowRunning);
            BOOL gone = known ? (!nowRunning && pid == 0 && POCranePidExited(oldPid)) : POCranePidExited(oldPid);
            PXLog(@"clone", @"poll=%lu pid=%d running=%d exited=%d", (unsigned long)polls, pid, nowRunning, gone);
            if (gone || !known) {
                if (!known) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), switchNow);
                } else {
                    switchNow();
                }
                return;
            }
            if (known && pid != 0 && pid != oldPid) {
                finish(NO, POCraneError(POCraneTerminationFailed, @"旧进程未退出就出现了新进程"));
                return;
            }
            if (polls >= 50) {   // 5 秒
                finish(NO, POCraneError(POCraneTimedOut, @"旧进程未在 5 秒内退出"));
                return;
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), wait);
        };
        wait();
    });
}

@end
