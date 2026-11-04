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

+ (NSString *)activeContainerForBundle:(NSString *)bundleID {
    id manager = PXSharedManager();
    if (!manager || !bundleID.length) return @"";
    return PXStringResult(manager,
        NSSelectorFromString(@"activeContainerIdentifierForApplicationWithIdentifier:"), bundleID);
}

+ (BOOL)selectContainer:(NSString *)containerID forBundle:(NSString *)bundleID error:(NSError **)error {
    if (!containerID.length || !bundleID.length) {
        if (error) *error = PXCraneError(PXCloneCraneErrorInvalidArgument, @"empty container/bundle");
        return NO;
    }
    id manager = PXSharedManager();
    if (!manager) {
        if (error) *error = PXCraneError(PXCloneCraneErrorUnavailable, @"CraneManager unavailable");
        return NO;
    }
    if (!PXSupported(manager, bundleID)) {
        if (error) *error = PXCraneError(PXCloneCraneErrorUnsupported, @"app not supported by Crane");
        return NO;
    }

    SEL selector = NSSelectorFromString(@"setActiveContainerIdentifier:forApplicationWithIdentifier:reloadApplication:");
    if (!PXCloneInstanceMethodMatches(manager, selector, @encode(void), @[@"@", @"@", [NSString stringWithUTF8String:@encode(BOOL)]])) {
        if (error) *error = PXCraneError(PXCloneCraneErrorABI, @"switch ABI mismatch");
        return NO;
    }
    @try {
        ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(manager, selector, containerID, bundleID, NO);
    } @catch (NSException *exception) {
        if (error) *error = PXCraneError(PXCloneCraneErrorSwitchFailed, exception.reason ?: @"switch threw");
        return NO;
    }
    NSString *now = [self activeContainerForBundle:bundleID];
    if (![now isEqualToString:containerID]) {
        if (error) *error = PXCraneError(PXCloneCraneErrorSwitchFailed, @"active container did not change");
        return NO;
    }
    return YES;
}

+ (BOOL)requestReloadForBundle:(NSString *)bundleID error:(NSError **)error {
    if (!bundleID.length) {
        if (error) *error = PXCraneError(PXCloneCraneErrorInvalidArgument, @"empty bundle");
        return NO;
    }
    id manager = PXSharedManager();
    SEL selector = NSSelectorFromString(@"reloadApplicationWithIdentifier:");
    if (!manager || !PXCloneInstanceMethodMatches(manager, selector, @encode(void), @[@"@"])) {
        if (error) *error = PXCraneError(PXCloneCraneErrorABI, @"reload ABI mismatch");
        return NO;
    }
    @try { PXCloneSendVoid1(manager, selector, bundleID); }
    @catch (NSException *exception) {
        if (error) *error = PXCraneError(PXCloneCraneErrorReloadFailed, exception.reason ?: @"reload threw");
        return NO;
    }
    return YES;
}

@end
