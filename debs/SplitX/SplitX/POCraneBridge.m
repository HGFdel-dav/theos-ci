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
    if (!controllerClass) {
        PXLogW(@"clone", @"process: 没有 SBApplicationController，按未运行处理");
        *pid = 0; *running = NO; return YES;
    }
    SEL lookup = NSSelectorFromString(@"applicationWithBundleIdentifier:");
    BOOL sharedOK = POCraneSignature(controllerClass, @"sharedInstance", "@", @[]);
    if (!sharedOK) {
        PXLogW(@"clone", @"process: controller sharedInstance ABI 不符");
        return NO;
    }
    id controller = ((id (*)(id, SEL))objc_msgSend)(controllerClass, NSSelectorFromString(@"sharedInstance"));
    // sharedInstance 是类方法；applicationWithBundleIdentifier: 是实例方法。
    BOOL lookupOK = POCraneSignature(controller, @"applicationWithBundleIdentifier:", "@", @[@"@"]) ||
                    [controller respondsToSelector:lookup];
    if (!lookupOK) {
        PXLogW(@"clone", @"process: controller 实例没有 %@ (class=%@)，按未运行处理",
               NSStringFromSelector(lookup), NSStringFromClass([controller class]));
        *pid = 0; *running = NO; return YES;
    }
    id app = ((id (*)(id, SEL, id))objc_msgSend)(controller, lookup, bundle);
    if (!app) {
        PXLogW(@"clone", @"process: %@ 没有 SBApplication，按未运行处理", bundle);
        *pid = 0; *running = NO; return YES;
    }
    if (!POCraneSignature(app, @"processState", "@", @[])) {
        PXLogW(@"clone", @"process: %@ processState ABI 不符 (class=%@)，按未运行处理", bundle, NSStringFromClass([app class]));
        *pid = 0; *running = NO; return YES;
    }
    id state = ((id (*)(id, SEL))objc_msgSend)(app, NSSelectorFromString(@"processState"));
    if (!state) {
        PXLogW(@"clone", @"process: %@ processState=nil，按未运行处理", bundle);
        *pid = 0; *running = NO; return YES;
    }
    BOOL pidInt = POCraneSignature(state, @"pid", @encode(int), @[]);
    BOOL pidLong = POCraneSignature(state, @"pid", @encode(long long), @[]);
    if (!pidInt && !pidLong) {
        PXLogW(@"clone", @"process: %@ pid ABI 不符 (state=%@)，按未运行处理", bundle, NSStringFromClass([state class]));
        *pid = 0; *running = NO; return YES;
    }
    if (pidLong) {
        *pid = (pid_t)((long long (*)(id, SEL))objc_msgSend)(state, NSSelectorFromString(@"pid"));
    } else {
        *pid = (pid_t)((int (*)(id, SEL))objc_msgSend)(state, NSSelectorFromString(@"pid"));
    }
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

/// 旧版本 settings 对象可能没有 containers getter；KVC 必须逐键保护。
static id POCRaneObjectValue(id object, NSString *key) {
    if (!object) return nil;
    if ([object isKindOfClass:NSDictionary.class]) return ((NSDictionary *)object)[key];
    @try {
        SEL sel = NSSelectorFromString(key);
        if (POCraneSignature(object, key, "@", @[]))
            return ((id (*)(id, SEL))objc_msgSend)(object, sel);
        return [object valueForKey:key];
    } @catch (NSException *exception) {
        return nil;
    }
}

static id POCRaneContainersFromSettings(id settings) {
    return POCRaneObjectValue(settings, @"containers") ?: POCRaneObjectValue(settings, @"Containers");
}

static NSString *POCRaneRowString(id row, NSString *key) {
    id value = POCRaneObjectValue(row, key);
    return POCraneString(value) ? value : nil;
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

+ (NSArray<POSplitTarget *> *)allTargetsForBundleIdentifier:(NSString *)bundleIdentifier {
    if (!POCraneString(bundleIdentifier)) return @[];
    NSMutableArray<POSplitTarget *> *targets = [NSMutableArray array];
    id manager = POCraneManager();
    NSString *listName = @"containerIdentifiersOfApplicationWithIdentifier:";
    NSString *settingsName = @"applicationSettingsForApplicationWithIdentifier:";
    NSMutableOrderedSet<NSString *> *ids = [NSMutableOrderedSet orderedSetWithObject:POSplitDefaultContainerIdentifier];
    NSMutableDictionary<NSString *, NSString *> *rowNames = [NSMutableDictionary dictionary];
    @try {
        id list = POCraneSignature(manager, listName, "@", @[@"@"])
            ? ((id (*)(id, SEL, id))objc_msgSend)(manager, NSSelectorFromString(listName), bundleIdentifier) : nil;
        // 缺少 selector 时也要回退，不能在检查失败处提前 return DEFAULT。
        if (![list isKindOfClass:NSArray.class] || [(NSArray *)list count] == 0) {
            id settings = POCraneSignature(manager, settingsName, "@", @[@"@"])
                ? ((id (*)(id, SEL, id))objc_msgSend)(manager, NSSelectorFromString(settingsName), bundleIdentifier) : nil;
            id rows = POCRaneContainersFromSettings(settings);
            if ([rows isKindOfClass:NSDictionary.class]) {
                NSDictionary *dictionary = rows;
                for (id key in dictionary) {
                    if (!POCraneString(key)) continue;
                    [ids addObject:key];
                    NSString *name = POCRaneRowString(dictionary[key], @"name");
                    if (name) rowNames[key] = name;
                }
                list = @[];
            } else {
                list = [rows isKindOfClass:NSArray.class] ? rows : @[];
            }
            PXLog(@"clone", @"%@ raw fallback settings=%@ rowsType=%@", bundleIdentifier,
                  settings ? NSStringFromClass([settings class]) : @"nil",
                  rows ? NSStringFromClass([rows class]) : @"nil");
        }
        for (id row in ([list isKindOfClass:NSArray.class] ? (NSArray *)list : @[])) {
            NSString *identifier = POCraneString(row) ? row : POCRaneRowString(row, @"identifier");
            if (!identifier) continue;
            [ids addObject:identifier];
            NSString *name = POCraneString(row) ? nil : POCRaneRowString(row, @"name");
            if (name) rowNames[identifier] = name;
        }
    } @catch (NSException *exception) {
        PXLogE(@"clone", @"%@ raw enumeration exception %@: %@", bundleIdentifier, exception.name, exception.reason);
    }
    // 日志只连接归一后的字符串，不对未知 Crane 对象直接 componentsJoinedByString。
    PXLog(@"clone", @"%@ 原始容器列表=%@", bundleIdentifier, [ids.array componentsJoinedByString:@","]);
    for (NSString *identifier in ids) {
        BOOL isDefault = [identifier isEqualToString:POSplitDefaultContainerIdentifier];
        NSString *name = isDefault ? @"默认" : rowNames[identifier];
        @try {
            if (!isDefault && !name.length) name = [self displayNameForContainer:identifier bundle:bundleIdentifier];
        } @catch (NSException *exception) {
            PXLogW(@"clone", @"%@/%@ name exception=%@", bundleIdentifier, identifier, exception.reason);
        }
        [targets addObject:[POSplitTarget targetWithBundleIdentifier:bundleIdentifier container:identifier
                                                        displayName:name.length ? name : identifier]];
    }
    return targets;
}

+ (NSString *)visibilityKeyForTarget:(POSplitTarget *)target {
    return [NSString stringWithFormat:@"cloneShow.%@.%@", target.bundleIdentifier, target.containerIdentifier];
}

+ (NSArray<POSplitTarget *> *)targetsForBundleIdentifier:(NSString *)bundleIdentifier {
    NSArray<POSplitTarget *> *all = [self allTargetsForBundleIdentifier:bundleIdentifier];
    NSMutableArray<POSplitTarget *> *visible = [NSMutableArray array];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.niubiprass.splitx"];
    for (POSplitTarget *target in all) {
        if (target.isDefaultContainer && all.count > 1 && ![POSplitXSettings shared].cloneShowDefault) continue;
        id show = [defaults objectForKey:[self visibilityKeyForTarget:target]];
        if ([show respondsToSelector:@selector(boolValue)] && ![show boolValue]) continue;
        [visible addObject:target];
    }
    PXLog(@"clone", @"%@ visible=%lu raw=%lu", bundleIdentifier, (unsigned long)visible.count, (unsigned long)all.count);
    return visible;
}

+ (NSArray<NSString *> *)applicationsWithNonDefaultContainers {
    id manager = POCraneManager();
    NSString *listName = @"identfiersOfApplicationsThatHaveNonDefaultContainers";
    if (!manager) return @[];
    NSMutableOrderedSet<NSString *> *bundles = [NSMutableOrderedSet orderedSet];
    @try {
        if (POCraneSignature(manager, listName, "@", @[])) {
            id list = ((id (*)(id, SEL))objc_msgSend)(manager, NSSelectorFromString(listName));
            if ([list isKindOfClass:NSArray.class] || [list isKindOfClass:NSSet.class]) {
                for (id bundle in list) if (POCraneString(bundle)) [bundles addObject:bundle];
            }
        }
    } @catch (NSException *exception) {
        PXLogW(@"clone", @"apps enumeration exception=%@", exception.reason);
    }
    if (bundles.count) return bundles.array;

    // 与已有应用选择器同源：LSApplicationWorkspace 优先，文件系统作为旧系统兜底。
    NSMutableOrderedSet<NSString *> *installed = [NSMutableOrderedSet orderedSet];
    @try {
        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        id workspace = POCraneSignature(workspaceClass, @"defaultWorkspace", "@", @[])
            ? ((id (*)(id, SEL))objc_msgSend)(workspaceClass, NSSelectorFromString(@"defaultWorkspace")) : nil;
        id apps = POCraneSignature(workspace, @"allApplications", "@", @[])
            ? ((id (*)(id, SEL))objc_msgSend)(workspace, NSSelectorFromString(@"allApplications")) : nil;
        if ([apps isKindOfClass:NSArray.class]) {
            for (id app in apps) {
                NSString *identifier = POCRaneRowString(app, @"applicationIdentifier");
                if (identifier) [installed addObject:identifier];
            }
        }
    } @catch (NSException *exception) {
        PXLogW(@"clone", @"LS enumeration exception=%@", exception.reason);
    }
    if (!installed.count) {
        NSFileManager *fm = NSFileManager.defaultManager;
        for (NSString *base in @[@"/var/mobile/Containers/Bundle/Application", @"/var/containers/Bundle/Application"]) {
            for (NSString *container in [fm contentsOfDirectoryAtPath:base error:NULL]) {
                if ([container hasPrefix:@"."]) continue;
                NSString *directory = [base stringByAppendingPathComponent:container];
                for (NSString *name in [fm contentsOfDirectoryAtPath:directory error:NULL]) {
                    if (![name.pathExtension isEqualToString:@"app"]) continue;
                    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                        [[directory stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"Info.plist"]];
                    NSString *identifier = info[@"CFBundleIdentifier"];
                    if (POCraneString(identifier)) [installed addObject:identifier];
                }
            }
        }
    }
    for (NSString *bundle in installed) {
        if ([self allTargetsForBundleIdentifier:bundle].count > 1) [bundles addObject:bundle];
    }
    PXLog(@"clone", @"apps fallback inspected=%lu withClones=%lu", (unsigned long)installed.count, (unsigned long)bundles.count);
    return bundles.array;
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
            // ParallelX/Twin 在当前 Crane 上优先走无认证接口；带认证接口在第二账号上会直接回调 NO。
            SEL plainSelector = NSSelectorFromString(@"setActiveContainerIdentifier:forApplicationWithIdentifier:reloadApplication:");
            BOOL plainResponds = [manager respondsToSelector:plainSelector];
            BOOL plainABI = POCraneSignature(manager, NSStringFromSelector(plainSelector), "v",
                                             @[@"@", @"@", [NSString stringWithUTF8String:@encode(BOOL)]]);
            PXLog(@"clone", @"plain selector responds=%d abi=%d", plainResponds, plainABI);
            if (plainResponds && plainABI) {
                PXLog(@"clone", @"%@ 使用 ParallelX 无认证切换 reload:NO target=%@", bundle, wanted);
                @try {
                    ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(manager, plainSelector, wanted, bundle, NO);
                } @catch (NSException *exception) {
                    finish(NO, POCraneError(POCraneVerificationFailed, [NSString stringWithFormat:@"无认证切换异常 %@", exception.reason]));
                    return;
                }
                __block NSUInteger readbacks = 0;
                __block void (^verifyPlain)(void);
                verifyPlain = ^{
                    if (finished) return;
                    NSString *active = POCraneActive(manager, bundle);
                    PXLog(@"clone", @"plain readback=%lu active=%@ want=%@", (unsigned long)readbacks, active ?: @"nil", wanted);
                    if ([active isEqualToString:wanted]) {
                        finish(YES, nil);
                        return;
                    }
                    if (++readbacks >= 30) {
                        finish(NO, POCraneError(POCraneVerificationFailed, @"无认证切换回读不一致"));
                        return;
                    }
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), verifyPlain);
                };
                verifyPlain();
                return;
            }
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
