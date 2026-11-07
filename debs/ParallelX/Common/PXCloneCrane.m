#import "PXCloneCrane.h"
#import "PXCloneRuntime.h"
#import "PXRootHideCompat.h"
#import <dlfcn.h>
#import <objc/message.h>
#include <stdlib.h>

NSString *const PXCloneErrorDomain = @"com.niubiprass.parallelxclone.crane";

static NSError *PXCraneError(PXCloneCraneError code, NSString *message) {
    return [NSError errorWithDomain:PXCloneErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"crane error"}];
}

static NSArray<NSString *> *PXCandidateLibraries(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    void (^addRoot)(NSString *) = ^(NSString *root) {
        if (!root.length) return;
        NSString *path = [root stringByAppendingPathComponent:@"usr/lib/libcrane.dylib"];
        if (![paths containsObject:path]) [paths addObject:path];
    };
    addRoot(PXCloneJBROOT(@"/"));
    addRoot(@"/var/jb");
    for (NSString *base in @[@"/var/mobile/Containers/Shared/AppGroup",
                             @"/var/containers/Bundle/Application",
                             @"/var/mobile/Containers/Bundle/Application"]) {
        NSArray *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:base error:nil];
        for (NSString *name in entries) {
            if (![name hasPrefix:@".jbroot-"]) continue;
            addRoot([base stringByAppendingPathComponent:name]);
        }
    }
    return paths;
}

static Class PXCraneManagerClass(void) {
    Class cls = NSClassFromString(@"CraneManager");
    if (cls) return cls;
    for (NSString *path in PXCandidateLibraries()) {
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) continue;
        if (dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) {
            cls = NSClassFromString(@"CraneManager");
            if (cls) break;
        }
    }
    return cls;
}

static id PXSharedManager(void) {
    Class cls = PXCraneManagerClass();
    SEL selector = NSSelectorFromString(@"sharedManager");
    if (!PXCloneClassResponds(cls, selector)) return nil;
    if (!PXCloneClassMethodMatches(cls, selector, @encode(id), @[], NULL)) return nil;
    return PXCloneSendId((id)cls, selector);
}

static NSString *PXStringResult(id target, SEL selector, id argument) {
    if (!PXCloneInstanceMethodMatches(target, selector, @encode(id), @[@"@"])) return @"";
    id result = PXCloneSendId1(target, selector, argument);
    return [result isKindOfClass:NSString.class] ? result : @"";
}

static NSArray<NSString *> *PXStringArrayResult(id target, SEL selector, id _Nullable argument) {
    if (argument) {
        if (!PXCloneInstanceMethodMatches(target, selector, @encode(id), @[@"@"])) return @[];
    } else if (!PXCloneInstanceMethodMatches(target, selector, @encode(id), @[])) {
        return @[];
    }
    id result = argument ? PXCloneSendId1(target, selector, argument)
                         : PXCloneSendId(target, selector);
    if (![result isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (id item in (NSArray *)result)
        if ([item isKindOfClass:NSString.class] && [item length]) [out addObject:item];
    return out;
}

static BOOL PXSupported(id manager, NSString *bundle) {
    SEL selector = NSSelectorFromString(@"isApplicationSupportedByCrane:");
    if (!PXCloneInstanceMethodMatches(manager, selector, @encode(BOOL), @[@"@"])) return NO;
    return PXCloneSendBool1(manager, selector, bundle);
}

static NSString *PXDisplayName(id manager, NSString *container, NSString *bundle) {
    SEL longSelector = NSSelectorFromString(@"displayNameForContainerWithIdentifier:ofApplicationWithIdentifier:shouldUseShortVersion:");
    if (PXCloneInstanceMethodMatches(manager, longSelector, @encode(id), @[@"@", @"@", [NSString stringWithUTF8String:@encode(BOOL)]])) {
        id (*fn)(id, SEL, id, id, BOOL) = (id (*)(id, SEL, id, id, BOOL))objc_msgSend;
        @try {
            id name = fn(manager, longSelector, container, bundle, NO);
            if ([name isKindOfClass:NSString.class] && [name length]) return name;
        } @catch (__unused NSException *exception) { }
    }
    SEL shortSelector = NSSelectorFromString(@"displayNameForContainerWithIdentifier:ofApplicationWithIdentifier:");
    if (PXCloneInstanceMethodMatches(manager, shortSelector, @encode(id), @[@"@", @"@"])) {
        id (*fn)(id, SEL, id, id) = (id (*)(id, SEL, id, id))objc_msgSend;
        @try {
            id name = fn(manager, shortSelector, container, bundle);
            if ([name isKindOfClass:NSString.class] && [name length]) return name;
        } @catch (__unused NSException *exception) { }
    }
    return @"";
}

@implementation PXCloneCrane

+ (BOOL)prepareManager {
    return PXSharedManager() != nil;
}

static NSArray<NSDictionary *> *PXCatalog;

+ (NSArray<NSDictionary *> *)cachedCatalog {
    @synchronized (self) { return PXCatalog ?: @[]; }
}

+ (void)refreshCatalogWithCompletion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSDictionary *> *catalog = [self buildCatalog];
        @synchronized (self) { PXCatalog = catalog; }
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(catalog, nil); });
    });
}

+ (NSArray<NSDictionary *> *)buildCatalog {
    id manager = PXSharedManager();
    if (!manager) return @[];
    SEL appsSelector = NSSelectorFromString(@"identfiersOfApplicationsThatHaveNonDefaultContainers");
    NSArray<NSString *> *bundles = PXStringArrayResult(manager, appsSelector, nil);
    if (!bundles.count) return @[];

    NSMutableArray<NSDictionary *> *catalog = [NSMutableArray array];
    for (NSString *bundle in bundles) {
        if (!PXSupported(manager, bundle)) continue;
        NSArray<NSString *> *identifiers = PXStringArrayResult(
            manager, NSSelectorFromString(@"containerIdentifiersOfApplicationWithIdentifier:"), bundle);
        if (identifiers.count < 2) continue;

        NSMutableArray<NSDictionary *> *containers = [NSMutableArray array];
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        if (![identifiers containsObject:@"DEFAULT"]) {
            [containers addObject:@{@"container": @"DEFAULT", @"name": @"默认", @"isDefault": @YES}];
            [seen addObject:@"DEFAULT"];
        }
        for (NSString *identifier in identifiers) {
            if ([seen containsObject:identifier]) continue;
            [seen addObject:identifier];
            BOOL isDefault = [identifier isEqualToString:@"DEFAULT"];
            NSString *name = isDefault ? @"默认" : PXDisplayName(manager, identifier, bundle);
            [containers addObject:@{@"container": identifier,
                                    @"name": name.length ? name : identifier,
                                    @"isDefault": @(isDefault)}];
        }
        if (containers.count < 2) continue;

        NSString *name = bundle;
        Class proxyClass = NSClassFromString(@"LSApplicationProxy");
        SEL proxySelector = NSSelectorFromString(@"applicationProxyForIdentifier:");
        if (proxyClass && PXCloneClassMethodMatches(proxyClass, proxySelector, @encode(id), @[@"@"], NULL)) {
            id proxy = PXCloneSendId1((id)proxyClass, proxySelector, bundle);
            SEL nameSelector = NSSelectorFromString(@"localizedName");
            if (proxy && PXCloneInstanceMethodMatches(proxy, nameSelector, @encode(id), @[])) {
                id localized = PXCloneSendId(proxy, nameSelector);
                if ([localized isKindOfClass:NSString.class] && [localized length]) name = localized;
            }
        }
        [catalog addObject:@{@"bundle": bundle, @"name": name, @"containers": containers}];
    }
    return catalog;
}

+ (NSArray<NSString *> *)containerIdentifiersForBundle:(NSString *)bundleID {
    id manager = PXSharedManager();
    if (!manager || !bundleID.length) return @[];
    if (!PXSupported(manager, bundleID)) return @[];
    return PXStringArrayResult(manager,
        NSSelectorFromString(@"containerIdentifiersOfApplicationWithIdentifier:"), bundleID);
}

// Crane keeps the full account list (DEFAULT + every clone, with the user's
// own names) in its preferences. The runtime selector returns only a subset,
// which truncated the chooser to two rows. Prefs are read-only here.
+ (NSArray<NSDictionary *> *)prefsContainersForBundle:(NSString *)bundleID {
    if (!bundleID.length) return @[];
    NSString *root = PXCloneJBROOT(@"/");
    NSString *path = [(root.length ? root : @"")
        stringByAppendingString:@"/var/mobile/Library/Preferences/com.opa334.craneprefs.plist"];
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![prefs isKindOfClass:NSDictionary.class]) return @[];
    id settings = prefs[[@"appSettings_" stringByAppendingString:bundleID]];
    if (![settings isKindOfClass:NSDictionary.class]) return @[];
    id list = ((NSDictionary *)settings)[@"Containers"];
    if (![list isKindOfClass:NSArray.class]) return @[];

    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSDictionary *entry in list) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        id identifier = entry[@"identifier"];
        if (![identifier isKindOfClass:NSString.class] || ![identifier length]) continue;
        if ([seen containsObject:identifier]) continue;
        [seen addObject:identifier];
        BOOL isDefault = [identifier isEqualToString:@"DEFAULT"];
        id name = entry[@"name"];
        NSString *title = [name isKindOfClass:NSString.class] && [name length] ? name : nil;
        if (!title.length) title = isDefault ? @"默认" : identifier;
        [out addObject:@{@"container": identifier, @"name": title, @"isDefault": @(isDefault)}];
    }
    return out.count >= 2 ? out : @[];
}

+ (NSArray<NSDictionary *> *)containersForBundle:(NSString *)bundleID {
    NSArray<NSDictionary *> *fromPrefs = [self prefsContainersForBundle:bundleID];
    if (fromPrefs.count >= 2) return fromPrefs;
    id manager = PXSharedManager();
    if (!manager || !bundleID.length) return @[];
    NSArray<NSString *> *identifiers = [self containerIdentifiersForBundle:bundleID];
    if (identifiers.count < 2) return @[];

    NSMutableArray<NSDictionary *> *containers = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    if (![identifiers containsObject:@"DEFAULT"]) {
        [containers addObject:@{@"container": @"DEFAULT", @"name": @"默认", @"isDefault": @YES}];
        [seen addObject:@"DEFAULT"];
    }
    for (NSString *identifier in identifiers) {
        if ([seen containsObject:identifier]) continue;
        [seen addObject:identifier];
        BOOL isDefault = [identifier isEqualToString:@"DEFAULT"];
        NSString *name = isDefault ? @"默认" : PXDisplayName(manager, identifier, bundleID);
        [containers addObject:@{@"container": identifier,
                                @"name": name.length ? name : identifier,
                                @"isDefault": @(isDefault)}];
    }
    return containers.count >= 2 ? containers : @[];
}

+ (BOOL)isApplicationRunning:(NSString *)bundleID {
    Class cls = NSClassFromString(@"FBProcessManager");
    SEL shared = NSSelectorFromString(@"sharedInstance");
    if (!PXCloneClassMethodMatches(cls, shared, @encode(id), @[], NULL)) return NO;
    id manager = PXCloneSendId((id)cls, shared);
    SEL list = NSSelectorFromString(@"applicationProcessesForBundleIdentifier:");
    if (!PXCloneInstanceMethodMatches(manager, list, @encode(id), @[@"@"])) return NO;
    id processes = nil;
    @try { processes = PXCloneSendId1(manager, list, bundleID); }
    @catch (__unused NSException *exception) { return NO; }
    for (id process in processes) {
        SEL running = NSSelectorFromString(@"isRunning");
        if (PXCloneInstanceMethodMatches(process, running, @encode(BOOL), @[]) &&
            PXCloneSendBool(process, running)) return YES;
    }
    return NO;
}

+ (BOOL)terminateApplication:(NSString *)bundleID {
    Class cls = NSClassFromString(@"FBSystemService");
    SEL shared = NSSelectorFromString(@"sharedInstance");
    if (!PXCloneClassMethodMatches(cls, shared, @encode(id), @[], NULL)) return NO;
    id service = PXCloneSendId((id)cls, shared);
    SEL selector = NSSelectorFromString(@"terminateApplication:forReason:andReport:withDescription:completion:");
    void (^completion)(void) = ^{};
    @try {
        if (PXCloneInstanceMethodMatches(service, selector, @encode(void),
                @[@"@", [NSString stringWithUTF8String:@encode(NSInteger)],
                  [NSString stringWithUTF8String:@encode(BOOL)], @"@", @"@?"])) {
            ((void (*)(id, SEL, id, NSInteger, BOOL, id, id))objc_msgSend)(
                service, selector, bundleID, 1, YES, @"ParallelX account switch", completion);
            return YES;
        }
    } @catch (__unused NSException *exception) { return NO; }
    return NO;
}

+ (NSString *)activeContainerForBundle:(NSString *)bundleID {
    id manager = PXSharedManager();
    if (!manager || !bundleID.length) return @"";
    return PXStringResult(manager,
        NSSelectorFromString(@"activeContainerIdentifierForApplicationWithIdentifier:"), bundleID);
}

+ (BOOL)containerExists:(NSString *)containerID forBundle:(NSString *)bundleID {
    if (!containerID.length || !bundleID.length) return NO;
    id manager = PXSharedManager();
    if (!manager || !PXSupported(manager, bundleID)) return NO;
    if ([containerID isEqualToString:@"DEFAULT"]) return YES;
    NSArray *identifiers = PXStringArrayResult(manager,
        NSSelectorFromString(@"containerIdentifiersOfApplicationWithIdentifier:"), bundleID);
    return [identifiers containsObject:containerID];
}

+ (BOOL)switchToContainer:(NSString *)containerID forBundle:(NSString *)bundleID
                   reload:(BOOL)reload error:(NSError **)error {
    id manager = PXSharedManager();
    if (!manager || ![self containerExists:containerID forBundle:bundleID]) {
        if (error) *error = PXCraneError(PXCloneCraneErrorInvalidArgument, @"账号不存在或 Crane 不可用");
        return NO;
    }
    SEL plain = NSSelectorFromString(@"setActiveContainerIdentifier:forApplicationWithIdentifier:reloadApplication:");
    if (!PXCloneInstanceMethodMatches(manager, plain, @encode(void),
            @[@"@", @"@", [NSString stringWithUTF8String:@encode(BOOL)]])) {
        if (error) *error = PXCraneError(PXCloneCraneErrorABI, @"Crane 无切换接口");
        return NO;
    }
    @try {
        ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(manager, plain, containerID, bundleID, NO);
    } @catch (NSException *exception) {
        if (error) *error = PXCraneError(PXCloneCraneErrorSwitchFailed, exception.reason ?: @"Crane 切换异常");
        return NO;
    }
    if (reload) {
        SEL reloadSelector = NSSelectorFromString(@"reloadApplicationWithIdentifier:");
        if (PXCloneInstanceMethodMatches(manager, reloadSelector, @encode(void), @[@"@"])) {
            @try { ((void (*)(id, SEL, id))objc_msgSend)(manager, reloadSelector, bundleID); }
            @catch (__unused NSException *exception) { }
        }
    }
    return YES;
}

+ (BOOL)requestSwitchToContainer:(NSString *)containerID forBundle:(NSString *)bundleID
                           reply:(void (^)(BOOL))reply error:(NSError **)error {
    id manager = PXSharedManager();
    if (!reply || ![self containerExists:containerID forBundle:bundleID]) {
        if (error) *error = PXCraneError(PXCloneCraneErrorInvalidArgument, @"账号不存在或 Crane 不可用");
        return NO;
    }
    // Twin/ScreenCore both use the plain reload API first: it never prompts
    // for biometrics and returns immediately.
    SEL plain = NSSelectorFromString(@"setActiveContainerIdentifier:forApplicationWithIdentifier:reloadApplication:");
    if (PXCloneInstanceMethodMatches(manager, plain, @encode(void),
            @[@"@", @"@", [NSString stringWithUTF8String:@encode(BOOL)]])) {
        SEL reload = NSSelectorFromString(@"reloadApplicationWithIdentifier:");
        @try {
            ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(manager, plain, containerID, bundleID, NO);
            if (reload && PXCloneInstanceMethodMatches(manager, reload, @encode(void), @[@"@"]) && reply) {
                ((void (*)(id, SEL, id))objc_msgSend)(manager, reload, bundleID);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ reply(YES); });
            }
            return YES;
        } @catch (__unused NSException *exception) { }
    }
    // libcrane arm64e @0x84d4: v44@0:8@16@24B32@?36. The shorter
    // usingBiometrics selector defaults reload to YES; do not use it here.
    SEL selector = NSSelectorFromString(@"setActiveContainerIdentifier:forApplicationWithIdentifier:reloadApplication:usingBiometricsIfNeededWithSuccessHandler:");
    NSArray *arguments = @[@"@", @"@", [NSString stringWithUTF8String:@encode(BOOL)], @"@?"];
    if (!PXCloneInstanceMethodMatches(manager, selector, @encode(void), arguments)) {
        if (error) *error = PXCraneError(PXCloneCraneErrorABI, @"Crane 无重载验证接口不可用");
        return NO;
    }
    __block BOOL returned = NO;
    void (^callback)(BOOL) = ^(BOOL rawAuthenticationFlag) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (returned) return;
            returned = YES;
            // A real callback is a reason to VERIFY, never proof of success.
            // In libcrane 0x8694..0x86bc normal no-biometric switching sends NO.
            reply(rawAuthenticationFlag);
        });
    };
    @try {
        ((void (*)(id, SEL, id, id, BOOL, void (^)(BOOL)))objc_msgSend)(
            manager, selector, containerID, bundleID, NO, callback);
    } @catch (NSException *exception) {
        if (error) *error = PXCraneError(PXCloneCraneErrorSwitchFailed, exception.reason ?: @"Crane 切换异常");
        return NO;
    }
    return YES;
}


@end
