#import "PXCloneMenu.h"
#import "PXCloneCrane.h"
#import "PXClonePrefs.h"
#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/message.h>
#include <string.h>

// The ParallelX menu model lives in exactly one preference domain. On device
// com.moxuan.parallelx.plist holds applications / customActions /
// applicationNames / shortcutSymbols / shortcutImages, and that is the whole
// menu. bottomSwipeUp/Down/Left/Right are *values* of the gesture action keys
// (back / close / quit), not preference domains - writing to such a domain is
// invisible to ParallelX forever.
static NSString *const PXPXDomain = @"com.moxuan.parallelx";
static NSString *const PXPXDockNotification = @"com.moxuan.parallelx.dock-updated";

// Virtual records are written in the exact shape ParallelX uses for its own
// custom actions (id/title/app/appTitle/kind/type) so its renderer resolves
// them like any other entry instead of skipping an unknown id prefix.
NSString *const PXCloneVirtualPrefix = @"px.custom.";
NSString *const PXCloneRecordType = @"clonex.open";

// Prefix used by this plugin's earlier builds; swept during every sync so an
// old install cannot leave dead rows behind.
static NSString *const PXCloneLegacyPrefix = @"px.clone.";

enum { PXMaxCleanupSweep = 4096 };

#pragma mark - Identifier

static NSString *PXVirtualIdentifier(NSString *bundleID, NSString *containerID) {
    uint64_t hash = 1469598103934665603ULL;
    NSString *seed = [NSString stringWithFormat:@"clonex|%@|%@", bundleID, containerID];
    const char *bytes = seed.UTF8String;
    for (size_t i = 0; i < strlen(bytes); i++) {
        hash ^= (uint8_t)bytes[i];
        hash *= 1099511628211ULL;
    }
    uint64_t second = hash ^ 0x9E3779B97F4A7C15ULL;
    return [NSString stringWithFormat:@"%@%08X-%04X-%04X-%04X-%012llX",
            PXCloneVirtualPrefix,
            (unsigned)(hash >> 32), (unsigned)((hash >> 16) & 0xFFFF),
            (unsigned)(hash & 0xFFFF), (unsigned)((second >> 48) & 0xFFFF),
            (unsigned long long)(second & 0xFFFFFFFFFFFFULL)];
}

static NSMutableDictionary<NSString *, NSDictionary *> *PXMap(void) {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

// Rebuild from the Crane container list; the reverse lookup must survive a
// process restart, so it is never persisted.
static void PXRebuildMap(void) {
    NSMutableDictionary *map = PXMap();
    [map removeAllObjects];
    for (NSDictionary *app in PXCloneCrane.cachedCatalog) {
        NSString *bundle = app[@"bundle"];
        NSArray<NSDictionary *> *containers = app[@"containers"];
        if (![bundle isKindOfClass:NSString.class] || !bundle.length) continue;
        if (![containers isKindOfClass:NSArray.class] || containers.count < 2) continue;
        for (NSDictionary *container in containers) {
            NSString *containerID = container[@"container"];
            if (![containerID isKindOfClass:NSString.class] || !containerID.length) continue;
            map[PXVirtualIdentifier(bundle, containerID)] = @{@"bundle": bundle,
                                                              @"container": containerID};
        }
    }
}

NSDictionary<NSString *, NSString *> *PXCloneItemForIdentifier(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class]) return nil;
    if (![identifier hasPrefix:PXCloneVirtualPrefix]) return nil;
    NSDictionary *hit = PXMap()[identifier];
    if (hit) return hit;
    PXRebuildMap();
    return PXMap()[identifier];
}

BOOL PXCloneIsVirtualIdentifier(NSString *identifier) {
    return PXCloneItemForIdentifier(identifier) != nil;
}

#pragma mark - Preferences

static id PXRead(NSString *key) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)PXPXDomain);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)PXPXDomain);
    return value ? (__bridge_transfer id)value : nil;
}

static void PXWrite(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)PXPXDomain);
}

#pragma mark - Icon (app icon + 默/分 badge)

static UIImage *PXBadgedIcon(NSString *bundleID, BOOL isDefault) {
    SEL sel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (![UIImage respondsToSelector:sel]) return nil;
    UIImage *base = ((id (*)(id, SEL, id, long, double))objc_msgSend)(
        UIImage.class, sel, bundleID, 0, (double)UIScreen.mainScreen.scale);
    if (![base isKindOfClass:UIImage.class] || base.size.width <= 0) return nil;

    CGSize size = CGSizeMake(120, 120);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        (void)context;
        [base drawInRect:CGRectMake(0, 0, size.width, size.height)];
        CGFloat diameter = 44;
        CGRect badge = CGRectMake(size.width - diameter - 2, size.height - diameter - 2,
                                  diameter, diameter);
        [[UIColor colorWithWhite:0 alpha:0.78] setFill];
        [[UIBezierPath bezierPathWithOvalInRect:badge] fill];
        NSDictionary *attributes = @{
            NSFontAttributeName: [UIFont systemFontOfSize:24 weight:UIFontWeightBold],
            NSForegroundColorAttributeName: UIColor.whiteColor,
        };
        NSString *mark = isDefault ? @"默" : @"分";
        CGSize textSize = [mark sizeWithAttributes:attributes];
        [mark drawAtPoint:CGPointMake(badge.origin.x + (diameter - textSize.width) / 2,
                                      badge.origin.y + (diameter - textSize.height) / 2)
           withAttributes:attributes];
    }];
}

#pragma mark - Sync

void PXCloneSyncMenu(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ PXCloneSyncMenu(); });
        return;
    }

    // Two fail-closed guards: the menu is only ever rewritten from a loaded
    // preference store and a populated catalog. Skipping is deliberate - the
    // sync removes everything that is not "desired", so running it on partial
    // data would silently delete the user's rows instead of retrying later.
    PXClonePrefs *prefs = PXClonePrefs.shared;
    if (!prefs || prefs.storageError) return;

    NSArray<NSDictionary *> *catalog = PXCloneCrane.cachedCatalog;
    if (catalog.count == 0) return;
    // Menu-open refresh is frequent. Do not regenerate PNGs, rewrite five
    // preferences, or redraw ParallelX when the catalog/visibility is unchanged.
    static NSArray *lastCatalog;
    static NSDictionary *lastVisibility;
    NSDictionary *visibility = prefs.snapshot;
    if ([lastCatalog isEqualToArray:catalog] && [lastVisibility isEqualToDictionary:visibility]) return;

    NSMutableArray<NSString *> *applications = [NSMutableArray array];
    id rawApplications = PXRead(@"applications");
    if ([rawApplications isKindOfClass:NSArray.class])
        for (id item in (NSArray *)rawApplications)
            if ([item isKindOfClass:NSString.class] && [item length]) [applications addObject:item];

    NSMutableArray<NSDictionary *> *actions = [NSMutableArray array];
    id rawActions = PXRead(@"customActions");
    if ([rawActions isKindOfClass:NSArray.class])
        for (id item in (NSArray *)rawActions)
            if ([item isKindOfClass:NSDictionary.class]) [actions addObject:item];

    NSMutableDictionary *names = [NSMutableDictionary dictionary];
    id rawNames = PXRead(@"applicationNames");
    if ([rawNames isKindOfClass:NSDictionary.class]) [names addEntriesFromDictionary:rawNames];

    NSMutableDictionary *symbols = [NSMutableDictionary dictionary];
    id rawSymbols = PXRead(@"shortcutSymbols");
    if ([rawSymbols isKindOfClass:NSDictionary.class]) [symbols addEntriesFromDictionary:rawSymbols];

    NSMutableDictionary *images = [NSMutableDictionary dictionary];
    id rawImages = PXRead(@"shortcutImages");
    if ([rawImages isKindOfClass:NSDictionary.class]) [images addEntriesFromDictionary:rawImages];

    // Our previous records are recognised by their marker in customActions, so
    // ParallelX's own px.custom.* actions are never mistaken for ours.
    NSMutableSet<NSString *> *previous = [NSMutableSet set];
    NSUInteger scanned = 0;
    for (NSDictionary *record in actions) {
        if (++scanned > (NSUInteger)PXMaxCleanupSweep) break;
        if (![record[@"type"] isEqual:PXCloneRecordType]) continue;
        id identifier = record[@"id"];
        if ([identifier isKindOfClass:NSString.class]) [previous addObject:identifier];
    }

    NSMutableDictionary<NSString *, NSDictionary *> *desired = [NSMutableDictionary dictionary];
    for (NSDictionary *app in catalog) {
        NSString *bundle = app[@"bundle"];
        NSArray<NSDictionary *> *containers = app[@"containers"];
        if (![bundle isKindOfClass:NSString.class] || !bundle.length) continue;
        if (![containers isKindOfClass:NSArray.class] || containers.count < 2) continue;

        for (NSDictionary *container in containers) {
            NSString *containerID = container[@"container"];
            if (![containerID isKindOfClass:NSString.class] || !containerID.length) continue;
            if (![PXClonePrefs.shared isVisibleBundle:bundle container:containerID]) continue;
            desired[PXVirtualIdentifier(bundle, containerID)] = @{@"bundle": bundle,
                                                                  @"container": containerID};
        }
    }

    // Drop only records of ours that are no longer valid; keep every other
    // entry, and keep the user's ordering for the ones that stay.
    NSMutableSet<NSString *> *stale = [NSMutableSet set];
    for (NSString *identifier in previous)
        if (!desired[identifier]) [stale addObject:identifier];
    for (NSString *identifier in applications)
        if ([identifier hasPrefix:PXCloneLegacyPrefix] && !desired[identifier])
            [stale addObject:identifier];
    if (stale.count) {
        [applications filterUsingPredicate:[NSPredicate predicateWithBlock:
            ^BOOL(NSString *identifier, id bindings) {
                (void)bindings;
                return ![stale containsObject:identifier];
            }]];
        NSMutableArray<NSDictionary *> *kept = [NSMutableArray arrayWithCapacity:actions.count];
        for (NSDictionary *record in actions) {
            id identifier = record[@"id"];
            if ([identifier isKindOfClass:NSString.class] && [stale containsObject:identifier]) continue;
            [kept addObject:record];
        }
        actions = kept;
        for (NSString *identifier in stale) {
            [names removeObjectForKey:identifier];
            [symbols removeObjectForKey:identifier];
            [images removeObjectForKey:identifier];
        }
    }

    NSMutableDictionary<NSString *, NSDictionary *> *map = PXMap();
    [map removeAllObjects];
    for (NSString *identifier in desired) {
        NSDictionary *item = desired[identifier];
        NSString *bundle = item[@"bundle"];
        NSString *containerID = item[@"container"];
        BOOL isDefault = NO;
        for (NSDictionary *app in catalog) {
            if (![app[@"bundle"] isEqual:bundle]) continue;
            for (NSDictionary *container in app[@"containers"])
                if ([container[@"container"] isEqual:containerID])
                    isDefault = [container[@"isDefault"] boolValue];
        }
        map[identifier] = item;

        if (![applications containsObject:identifier]) [applications addObject:identifier];

        NSString *appTitle = bundle;
        for (NSDictionary *app in catalog)
            if ([app[@"bundle"] isEqual:bundle] && [app[@"name"] length]) appTitle = app[@"name"];
        NSString *containerName = isDefault ? @"默认" : containerID;
        for (NSDictionary *app in catalog) {
            if (![app[@"bundle"] isEqual:bundle]) continue;
            for (NSDictionary *container in app[@"containers"])
                if ([container[@"container"] isEqual:containerID] && [container[@"name"] length])
                    containerName = container[@"name"];
        }
        names[identifier] = [NSString stringWithFormat:@"%@ · %@", appTitle, containerName];

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
                @"type": PXCloneRecordType,
            }];
        } else {
            // Keep PX's copy but refresh the marker so cleanup can always find it.
            for (NSDictionary *record in actions) {
                if (![record[@"id"] isEqual:identifier]) continue;
                if ([record[@"type"] isEqual:PXCloneRecordType]) continue;
                NSUInteger index = [actions indexOfObjectIdenticalTo:record];
                if (index != NSNotFound) {
                    NSMutableDictionary *fixed = [record mutableCopy];
                    fixed[@"type"] = PXCloneRecordType;
                    actions[index] = fixed;
                }
                break;
            }
        }
        if (!symbols[identifier]) symbols[identifier] = @"square.on.square";
        UIImage *icon = PXBadgedIcon(bundle, isDefault);
        if (icon) {
            NSData *png = UIImagePNGRepresentation(icon);
            if (png) images[identifier] = png;
        }
    }

    PXWrite(@"applications", applications);
    PXWrite(@"customActions", actions);
    PXWrite(@"applicationNames", names);
    PXWrite(@"shortcutSymbols", symbols);
    PXWrite(@"shortcutImages", images);
    if (CFPreferencesAppSynchronize((__bridge CFStringRef)PXPXDomain)) {
        lastCatalog = [catalog copy];
        lastVisibility = [visibility copy];
        notify_post(PXPXDockNotification.UTF8String);
    }
}
