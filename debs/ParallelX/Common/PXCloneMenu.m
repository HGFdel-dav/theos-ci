#import "PXCloneMenu.h"
#import "PXCloneCrane.h"
#import "PXClonePrefs.h"
#import <CoreFoundation/CoreFoundation.h>
#import <notify.h>

NSString *const PXCloneVirtualPrefix = @"px.clone.";

// alpha391 keeps each gesture menu in its own suite; com.moxuan.parallelx is
// kept for older builds and the app-side settings export.
static NSArray<NSString *> *PXPXDomains(void) {
    static NSArray *domains;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        domains = @[@"bottomSwipeRight", @"bottomSwipeUp", @"bottomSwipeDown",
                    @"bottomSwipeLeft", @"com.moxuan.parallelx"];
    });
    return domains;
}
static NSString *const PXPXDockNotification = @"com.moxuan.parallelx.dock-updated";

static NSMutableDictionary<NSString *, NSDictionary *> *PXMap(void) {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

static NSString *PXVirtualIdentifier(NSString *bundleID, NSString *containerID) {
    return [NSString stringWithFormat:@"%@%@#%@", PXCloneVirtualPrefix, bundleID, containerID];
}

BOOL PXCloneIsVirtualIdentifier(NSString *identifier) {
    return [identifier isKindOfClass:NSString.class] &&
           [identifier hasPrefix:PXCloneVirtualPrefix];
}

NSDictionary<NSString *, NSString *> *PXCloneItemForIdentifier(NSString *identifier) {
    if (!PXCloneIsVirtualIdentifier(identifier)) return nil;
    NSDictionary *hit = PXMap()[identifier];
    if (hit) return hit;

    NSRange hash = [identifier rangeOfString:@"#" options:NSBackwardsSearch];
    if (hash.location == NSNotFound || hash.location <= PXCloneVirtualPrefix.length) return nil;
    NSString *bundle = [identifier substringWithRange:
                        NSMakeRange(PXCloneVirtualPrefix.length,
                                    hash.location - PXCloneVirtualPrefix.length)];
    NSString *container = [identifier substringFromIndex:hash.location + 1];
    if (!bundle.length || !container.length) return nil;
    NSDictionary *item = @{@"bundle": bundle, @"container": container};
    PXMap()[identifier] = item;
    return item;
}

static id PXRead(NSString *domain, NSString *key) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)domain);
    return value ? (__bridge_transfer id)value : nil;
}

static void PXWrite(NSString *domain, NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)domain);
}

static void PXSyncDomain(NSString *domain) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ PXCloneSyncMenu(); });
        return;
    }

    NSMutableArray<NSString *> *applications = [NSMutableArray array];
    id apps = PXRead(domain, @"applications");
    if ([apps isKindOfClass:NSArray.class])
        for (id item in (NSArray *)apps)
            if ([item isKindOfClass:NSString.class] && [item length]) [applications addObject:item];

    NSMutableArray<NSDictionary *> *actions = [NSMutableArray array];
    id rawActions = PXRead(domain, @"customActions");
    if ([rawActions isKindOfClass:NSArray.class])
        for (id item in (NSArray *)rawActions)
            if ([item isKindOfClass:NSDictionary.class]) [actions addObject:item];

    NSMutableDictionary *names = [NSMutableDictionary dictionary];
    id rawNames = PXRead(domain, @"applicationNames");
    if ([rawNames isKindOfClass:NSDictionary.class]) [names addEntriesFromDictionary:rawNames];

    NSMutableDictionary *symbols = [NSMutableDictionary dictionary];
    id rawSymbols = PXRead(domain, @"shortcutSymbols");
    if ([rawSymbols isKindOfClass:NSDictionary.class]) [symbols addEntriesFromDictionary:rawSymbols];

    NSMutableDictionary *images = [NSMutableDictionary dictionary];
    id rawImages = PXRead(domain, @"shortcutImages");
    if ([rawImages isKindOfClass:NSDictionary.class]) [images addEntriesFromDictionary:rawImages];

    NSMutableDictionary<NSString *, NSDictionary *> *map = PXMap();
    [map removeAllObjects];

    NSArray<NSDictionary *> *catalog = PXCloneCrane.cachedCatalog;
    NSMutableSet<NSString *> *desired = [NSMutableSet set];
    for (NSDictionary *app in catalog) {
        NSString *bundle = app[@"bundle"];
        NSArray<NSDictionary *> *containers = app[@"containers"];
        if (!bundle.length || containers.count < 2) continue;

        NSString *appTitle = app[@"name"] ?: bundle;
        for (NSDictionary *container in containers) {
            NSString *containerID = container[@"container"];
            if (!containerID.length) continue;
            if (![PXClonePrefs.shared isVisibleBundle:bundle container:containerID]) continue;

            BOOL isDefault = [container[@"isDefault"] boolValue];
            NSString *identifier = PXVirtualIdentifier(bundle, containerID);
            [desired addObject:identifier];
            map[identifier] = @{@"bundle": bundle, @"container": containerID};

            if (![applications containsObject:identifier]) [applications addObject:identifier];
            names[identifier] = [NSString stringWithFormat:@"%@ · %@", appTitle,
                                 isDefault ? @"默认" : (container[@"name"] ?: containerID)];

            BOOL exists = NO;
            for (NSDictionary *record in actions)
                if ([record[@"id"] isEqual:identifier]) { exists = YES; break; }
            if (!exists) {
                [actions addObject:@{
                    @"id": identifier,
                    @"title": names[identifier],
                    @"app": bundle,
                    @"appTitle": appTitle,
                    @"kind": @"quick",
                    @"type": @"clonex.open",
                }];
            }
            if (!symbols[identifier]) symbols[identifier] = @"square.on.square";
        }
    }

    // Remove only our records that are no longer valid; leave PX's entries and
    // their order untouched.
    NSMutableSet<NSString *> *stale = [NSMutableSet set];
    for (NSString *identifier in applications)
        if (PXCloneIsVirtualIdentifier(identifier) && ![desired containsObject:identifier])
            [stale addObject:identifier];
    if (stale.count) {
        [applications filterUsingPredicate:[NSPredicate predicateWithBlock:
            ^BOOL(NSString *identifier, id bindings) {
                return ![stale containsObject:identifier];
            }]];
        NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:actions.count];
        for (NSDictionary *record in actions) {
            NSString *identifier = record[@"id"];
            if ([identifier isKindOfClass:NSString.class] && [stale containsObject:identifier]) continue;
            [filtered addObject:record];
        }
        actions = filtered;
        for (NSString *identifier in stale) {
            [names removeObjectForKey:identifier];
            [symbols removeObjectForKey:identifier];
            [images removeObjectForKey:identifier];
        }
    }

    PXWrite(domain, @"applications", applications);
    PXWrite(domain, @"customActions", actions);
    PXWrite(domain, @"applicationNames", names);
    PXWrite(domain, @"shortcutSymbols", symbols);
    PXWrite(domain, @"shortcutImages", images);
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
}

void PXCloneSyncMenu(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ PXCloneSyncMenu(); });
        return;
    }
    for (NSString *domain in PXPXDomains()) PXSyncDomain(domain);
    notify_post(PXPXDockNotification.UTF8String);
}
