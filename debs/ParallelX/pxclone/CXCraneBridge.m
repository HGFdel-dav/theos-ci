// CXCraneBridge.m
//
// Crane 容器桥。调用形态、签名守卫、回读校验全部沿用 Twin 0.9.x 里已经
// 跑过的版本（TW C -> CX 改名，去掉 Twin 的评价逻辑），要点：
//   * 优先无认证接口 setActiveContainerIdentifier:forApplicationWithIdentifier:reloadApplication:
//   * 回读 activeContainerIdentifier 确认，未确认不宣称成功
//   * 兜底走旧版带认证接口（仅当无认证接口不存在）
#import "CXCraneBridge.h"
#import "CXLog.h"
#include <string.h>
#include <stdlib.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static BOOL CXSwitchInFlight = NO;   // 主队列专用：同一时间只允许一次切换

static BOOL CXSignature(id target, SEL sel, const char *result, NSArray<NSString *> *args) {
    if (!target || ![target respondsToSelector:sel]) return NO;
    Method method = class_getInstanceMethod(object_getClass(target), sel);
    const char *types = method ? method_getTypeEncoding(method) : NULL;
    if (!types) return NO;
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:types];
    if (sig.numberOfArguments != args.count + 2 || strcmp(sig.methodReturnType, result)) return NO;
    for (NSUInteger i = 0; i < args.count; i++) {
        const char *actual = [sig getArgumentTypeAtIndex:i + 2];
        const char *expected = args[i].UTF8String;
        // Swift 桥接出来的对象参数常带类名（@"NSString"），对象类按首字符匹配
        if (expected[0] == '@' && expected[1] == '\0') {
            if (!actual || actual[0] != '@' || actual[1] == '?') return NO;
        } else if (strcmp(actual, expected)) return NO;
    }
    return YES;
}

static id CXMsgSend(id target, SEL sel) {
    if (!target || !sel) return nil;
    id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return fn(target, sel);
}

static id CXMsgSendStr(id target, SEL sel, id arg) {
    if (!target || !sel) return nil;
    id (*fn)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
    return fn(target, sel, arg);
}

@implementation CXCraneBridge

static NSArray<NSString *> *CXCraneCandidatePaths(void) {
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
    // RootHide：真实的隐藏根是 .jbroot-<UUID> 目录（/var/jb、.jbroot 都可能只是符号链接）
    NSArray<NSString *> *bases = @[
        @"/var/containers/Bundle/Application",
        @"/var/mobile/Containers/Shared/AppGroup",
        @"/var/mobile/Containers/Bundle/Application",
    ];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *base in bases) {
        NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:base error:nil];
        if (!entries.count) continue;
        for (NSString *name in entries) {
            if (![name hasPrefix:@".jbroot"]) continue;
            addRoot([base stringByAppendingPathComponent:name]);
        }
    }
    return paths;
}

static Class CXCraneManagerClass(void) {
    Class cls = NSClassFromString(@"CraneManager");
    if (cls) return cls;
    for (NSString *path in CXCraneCandidatePaths()) {
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) continue;
        if (dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) {
            cls = NSClassFromString(@"CraneManager");
            if (cls) break;
        }
    }
    return cls;
}

+ (NSArray<NSString *> *)diagnosticLines {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    Class existing = NSClassFromString(@"CraneManager");
    [lines addObject:[NSString stringWithFormat:@"CraneManager 类: %@", existing ? @"已存在" : @"未加载"]];
    for (NSString *path in CXCraneCandidatePaths()) {
        BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:path];
        [lines addObject:[NSString stringWithFormat:@"%@ %@", exists ? @"✓" : @"✗", path]];
    }
    return lines;
}

+ (BOOL)isCraneAvailable {
    return CXCraneManagerClass() != nil;
}

+ (id)sharedManager {
    Class cls = CXCraneManagerClass();
    if (!cls) return nil;
    SEL sel = NSSelectorFromString(@"sharedManager");
    if (!CXSignature(cls, sel, @encode(id), @[])) return nil;
    return CXMsgSend(cls, sel);
}

+ (BOOL)isApplicationSupportedByCrane:(NSString *)bundleID {
    id manager = [self sharedManager];
    if (!manager || !bundleID.length) return NO;
    SEL sel = NSSelectorFromString(@"isApplicationSupportedByCrane:");
    if (!CXSignature(manager, sel, @encode(BOOL), @[@"@"])) return NO;
    BOOL (*fn)(id, SEL, id) = (BOOL (*)(id, SEL, id))objc_msgSend;
    return fn(manager, sel, bundleID) != 0;
}

+ (NSString *)activeContainerForBundleID:(NSString *)bundleID {
    id manager = [self sharedManager];
    if (!manager || !bundleID.length) return @"";
    SEL sel = NSSelectorFromString(@"activeContainerIdentifierForApplicationWithIdentifier:");
    if (!CXSignature(manager, sel, @encode(id), @[@"@"])) return @"";
    id result = CXMsgSendStr(manager, sel, bundleID);
    return [result isKindOfClass:NSString.class] ? result : @"";
}

+ (NSArray<NSDictionary *> *)containersForBundleID:(NSString *)bundleID {
    id manager = [self sharedManager];
    if (!manager || !bundleID.length) return @[];
    SEL sel = NSSelectorFromString(@"containerIdentifiersOfApplicationWithIdentifier:");
    if (!CXSignature(manager, sel, @encode(id), @[@"@"])) return @[];
    id list = CXMsgSendStr(manager, sel, bundleID);
    if (![list isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *ordered = [NSMutableArray array];
    if (![list containsObject:@"DEFAULT"]) [ordered addObject:@"DEFAULT"];
    for (id identifier in list)
        if ([identifier isKindOfClass:NSString.class] && [identifier length]) [ordered addObject:identifier];
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *identifier in ordered) {
        if ([seen containsObject:identifier]) continue;
        [seen addObject:identifier];
        NSString *name = [self displayNameForContainer:identifier bundleID:bundleID];
        BOOL isDefault = [identifier isEqualToString:@"DEFAULT"];
        [result addObject:@{@"containerID": identifier,
                            @"name": name.length ? name : identifier,
                            @"isDefault": @(isDefault)}];
    }
    return result;
}

+ (NSArray<NSString *> *)applicationsWithNonDefaultContainers {
    id manager = [self sharedManager];
    if (!manager) return @[];
    SEL sel = NSSelectorFromString(@"identfiersOfApplicationsThatHaveNonDefaultContainers");
    if (!CXSignature(manager, sel, @encode(id), @[])) return @[];
    id list = CXMsgSend(manager, sel);
    if (![list isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (id item in list)
        if ([item isKindOfClass:NSString.class] && [item length]) [out addObject:item];
    return out;
}

+ (NSString *)displayNameForContainer:(NSString *)containerID bundleID:(NSString *)bundleID {
    id manager = [self sharedManager];
    if (!manager || !containerID.length || !bundleID.length) return @"";
    SEL sel = NSSelectorFromString(@"displayNameForContainerWithIdentifier:ofApplicationWithIdentifier:shouldUseShortVersion:");
    if (CXSignature(manager, sel, @encode(id), @[@"@", @"@", [NSString stringWithUTF8String:@encode(BOOL)]])) {
        id (*fn)(id, SEL, id, id, BOOL) = (id (*)(id, SEL, id, id, BOOL))objc_msgSend;
        id name = fn(manager, sel, containerID, bundleID, NO);
        if ([name isKindOfClass:NSString.class] && [name length]) return name;
    }
    SEL shortSel = NSSelectorFromString(@"displayNameForContainerWithIdentifier:ofApplicationWithIdentifier:");
    if (CXSignature(manager, shortSel, @encode(id), @[@"@", @"@"])) {
        id (*fn)(id, SEL, id, id) = (id (*)(id, SEL, id, id))objc_msgSend;
        id name = fn(manager, shortSel, containerID, bundleID);
        if ([name isKindOfClass:NSString.class]) return name ?: @"";
    }
    return @"";
}

+ (void)prepareLaunchForBundleID:(NSString *)bundleID
                     containerID:(NSString *)containerID
                      completion:(void (^)(BOOL))completion {
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![bundleID isKindOfClass:NSString.class] || !bundleID.length) { completion(YES); return; }
        if (![containerID isKindOfClass:NSString.class] || !containerID.length ||
            [containerID isEqualToString:@"DEFAULT"]) { completion(YES); return; }
        if (![self isCraneAvailable]) { completion(YES); return; }   // 没装 Crane：普通打开
        if (![self isApplicationSupportedByCrane:bundleID]) { completion(YES); return; }
        [self switchBundleID:bundleID toContainer:containerID completion:completion];
    });
}

+ (void)switchBundleID:(NSString *)bundleID
           toContainer:(NSString *)containerID
            completion:(void (^)(BOOL))completion {
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (CXSwitchInFlight) { completion(NO); return; }
        id manager = [self sharedManager];
        if (!manager || ![self isApplicationSupportedByCrane:bundleID]) { completion(NO); return; }

        NSString *current = [self activeContainerForBundleID:bundleID];
        if ([current isEqualToString:containerID]) { completion(YES); return; }

        // ① 首选：无认证接口（Crane 官方公开，ScreenCore 同款链路）
        SEL plain = NSSelectorFromString(@"setActiveContainerIdentifier:forApplicationWithIdentifier:reloadApplication:");
        if ([manager respondsToSelector:plain]) {
            SEL reload = NSSelectorFromString(@"reloadApplicationWithIdentifier:");
            if (!CXSignature(manager, plain, @encode(void), @[@"@", @"@", [NSString stringWithUTF8String:@encode(BOOL)]]) ||
                !CXSignature(manager, reload, @encode(void), @[@"@"])) {
                completion(NO); return;
            }
            CXSwitchInFlight = YES;
            @try {
                ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(manager, plain, containerID, bundleID, NO);
            } @catch (__unused NSException *e) { CXSwitchInFlight = NO; completion(NO); return; }
            NSString *now = [self activeContainerForBundleID:bundleID];
            BOOL ok = [now isEqualToString:containerID];
            CXLog(@"[crane] %@ want=%@ before=%@ after=%@ ok=%d", bundleID, containerID, current ?: @"?", now ?: @"?", ok);
            if (!ok) { CXSwitchInFlight = NO; completion(NO); return; }
            @try { ((void (*)(id, SEL, id))objc_msgSend)(manager, reload, bundleID); }
            @catch (__unused NSException *e) {}
            // 重载会把应用拉起，等它落定再让分屏窗口接管，避免抢同一个 App
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                CXSwitchInFlight = NO;
                completion(YES);
            });
            return;
        }

        // ② 兜底：旧版 Crane 只有带认证的接口
        SEL bio = NSSelectorFromString(@"setActiveContainerIdentifier:forApplicationWithIdentifier:usingBiometricsIfNeededWithSuccessHandler:");
        SEL active = NSSelectorFromString(@"activeContainerIdentifierForApplicationWithIdentifier:");
        if (!CXSignature(manager, bio, @encode(void), @[@"@", @"@", @"@?"]) ||
            !CXSignature(manager, active, @encode(id), @[@"@"])) {
            completion(NO); return;
        }
        CXSwitchInFlight = YES;
        __block BOOL finished = NO;
        void (^finish)(BOOL) = ^(BOOL success) {
            if (finished) return;
            finished = YES;
            BOOL verified = success && [[self activeContainerForBundleID:bundleID] isEqualToString:containerID];
            CXSwitchInFlight = NO;
            completion(verified);
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 45 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (!finished) finish(NO);
        });
        void (^callback)(BOOL) = ^(BOOL success) {
            dispatch_async(dispatch_get_main_queue(), ^{ finish(success); });
        };
        @try {
            ((void (*)(id, SEL, id, id, void (^)(BOOL)))objc_msgSend)(manager, bio, containerID, bundleID, callback);
        } @catch (__unused NSException *e) { finish(NO); }
    });
}

@end
