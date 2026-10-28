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
#import "POCraneBridge.h"
#import <objc/message.h>
#import <objc/runtime.h>
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

static id POCraneManager(void) {
    Class cls = NSClassFromString(@"CraneManager");
    if (!cls) return nil;
    SEL shared = NSSelectorFromString(@"sharedManager");
    if (!POCraneSignature(cls, @"sharedManager", "@", @[])) return nil;
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
    if (!controllerClass) return NO;
    SEL lookup = NSSelectorFromString(@"applicationWithBundleIdentifier:");
    if (!POCraneSignature(controllerClass, @"sharedInstance", "@", @[]) ||
        !POCraneSignature(controllerClass, @"applicationWithBundleIdentifier:", "@", @[@"@"])) return NO;
    id controller = ((id (*)(id, SEL))objc_msgSend)(controllerClass, NSSelectorFromString(@"sharedInstance"));
    id app = ((id (*)(id, SEL, id))objc_msgSend)(controller, lookup, bundle);
    if (!app || !POCraneSignature(app, @"processState", "@", @[])) return NO;
    id state = ((id (*)(id, SEL))objc_msgSend)(app, NSSelectorFromString(@"processState"));
    if (!state) return NO;
    if (!POCraneSignature(state, @"pid", @encode(int), @[])) return NO;
    *pid = (pid_t)((int (*)(id, SEL))objc_msgSend)(state, NSSelectorFromString(@"pid"));
    *running = NO;
    if (POCraneSignature(state, @"isRunning", @encode(BOOL), @[])) {
        *running = ((BOOL (*)(id, SEL))objc_msgSend)(state, NSSelectorFromString(@"isRunning")) != 0;
    }
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

+ (NSArray<POSplitTarget *> *)targetsForBundleIdentifier:(NSString *)bundleIdentifier {
    NSMutableArray<POSplitTarget *> *targets = [NSMutableArray array];
    if (!POCraneString(bundleIdentifier)) return targets;
    [targets addObject:[POSplitTarget targetWithBundleIdentifier:bundleIdentifier
                                                       container:POSplitDefaultContainerIdentifier
                                                     displayName:@"默认"]];
    id manager = POCraneManager();
    if (!manager) {
        PXLog(@"clone", @"%@ 无 CraneManager，只给 DEFAULT", bundleIdentifier);
        return targets;
    }
    if (![self isBundleSupported:bundleIdentifier]) {
        PXLog(@"clone", @"%@ 不受 Crane 支持，只给 DEFAULT", bundleIdentifier);
        return targets;
    }
    if (!POCraneSignature(manager, @"applicationSettingsForApplicationWithIdentifier:", "@", @[@"@"])) {
        PXLogW(@"clone", @"applicationSettings ABI 不符，%@ 只给 DEFAULT", bundleIdentifier);
        return targets;
    }
    id settings = ((id (*)(id, SEL, id))objc_msgSend)(
        manager, NSSelectorFromString(@"applicationSettingsForApplicationWithIdentifier:"), bundleIdentifier);
    id rows = POCRaneContainersFromSettings(settings);
    NSString *keys = @"-";
    if ([settings isKindOfClass:NSDictionary.class]) {
        keys = [[(NSDictionary *)settings allKeys] componentsJoinedByString:@","];
    }
    PXLog(@"clone", @"%@ settings=%@ keys=%@ containers=%@", bundleIdentifier,
          settings ? NSStringFromClass([settings class]) : @"nil", keys,
          [rows isKindOfClass:NSArray.class] ? [NSString stringWithFormat:@"%lu", (unsigned long)[rows count]] : @"nil");
    if ([rows isKindOfClass:NSArray.class]) {
        for (id row in [rows subarrayWithRange:NSMakeRange(0, MIN(3, [rows count]))]) {
            NSString *rowKeys = [row isKindOfClass:NSDictionary.class]
                ? [[(NSDictionary *)row allKeys] componentsJoinedByString:@","] : @"-";
            PXLog(@"clone", @"  row %@ keys=%@", NSStringFromClass([row class]), rowKeys);
        }
    }
    if (![rows isKindOfClass:NSArray.class]) return targets;
    NSMutableSet<NSString *> *seen = [NSMutableSet setWithObject:POSplitDefaultContainerIdentifier];
    for (id row in rows) {
        NSString *identifier = POCRaneRowString(row, @"identifier");
        NSString *name = POCRaneRowString(row, @"name");
        if (!POCraneString(identifier) || [seen containsObject:identifier]) continue;
        [seen addObject:identifier];
        [targets addObject:[POSplitTarget targetWithBundleIdentifier:bundleIdentifier
                                                           container:identifier
                                                         displayName:POCraneString(name) ? name : identifier]];
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
        PXLog(@"clone", @"target %@/%@ available=%d", target.bundleIdentifier, target.containerIdentifier, [self isAvailable]);
        if (![self isAvailable]) {
            completion(YES, nil);   // 没装 Crane：直接走普通启动
            return;
        }
        NSString *bundle = target.bundleIdentifier;
        NSString *wanted = target.containerIdentifier;
        id manager = POCraneManager();
        if (![self isBundleSupported:bundle]) {
            completion(YES, nil);   // 该应用本身不支持分身
            return;
        }
        if ([POCraneActive(manager, bundle) isEqualToString:wanted]) {
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
            if (gone) {
                switchNow();
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
