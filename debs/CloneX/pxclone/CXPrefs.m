// CXPrefs.m
#import "CXPrefs.h"
#import <CoreFoundation/CoreFoundation.h>
#import <notify.h>

NSString *const CXKeyMenuItems = @"CXMenuItems";

static NSString *const CXDomain = @"com.niubiprass.clonex";
static NSString *const CXChangedNotification = @"com.niubiprass.clonex/changed";
static CFStringRef CXDomainRef(void) { return (__bridge CFStringRef)CXDomain; }

@implementation CXPrefs

+ (instancetype)shared {
    static CXPrefs *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[CXPrefs alloc] init]; });
    return shared;
}

- (id)objectForKey:(NSString *)key {
    if (!key.length) return nil;
    CFPreferencesAppSynchronize(CXDomainRef());
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CXDomainRef());
    return value ? (__bridge_transfer id)value : nil;
}

- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)def {
    id value = [self objectForKey:key];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : def;
}

- (NSArray<NSDictionary *> *)menuItems {
    id value = [self objectForKey:CXKeyMenuItems];
    if (![value isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id item in value) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *bundle = item[@"bundleID"];
        NSString *container = item[@"containerID"];
        if (![bundle isKindOfClass:NSString.class] || !bundle.length) continue;
        if (![container isKindOfClass:NSString.class] || !container.length) continue;
        [out addObject:@{@"bundleID": bundle, @"containerID": container}];
    }
    return out;
}

- (BOOL)isContainer:(NSString *)containerID shownForBundleID:(NSString *)bundleID {
    if (!bundleID.length || !containerID.length) return NO;
    for (NSDictionary *item in [self menuItems])
        if ([item[@"bundleID"] isEqual:bundleID] && [item[@"containerID"] isEqual:containerID]) return YES;
    return NO;
}

- (void)toggleContainer:(NSString *)containerID bundleID:(NSString *)bundleID {
    if (!bundleID.length || !containerID.length) return;
    NSMutableArray *items = [[self menuItems] mutableCopy];
    NSUInteger index = NSNotFound;
    for (NSUInteger i = 0; i < items.count; i++) {
        NSDictionary *item = items[i];
        if ([item[@"bundleID"] isEqual:bundleID] && [item[@"containerID"] isEqual:containerID]) {
            index = i;
            break;
        }
    }
    if (index != NSNotFound) [items removeObjectAtIndex:index];
    else [items addObject:@{@"bundleID": bundleID, @"containerID": containerID}];
    CFPreferencesSetAppValue((__bridge CFStringRef)CXKeyMenuItems,
                             (__bridge CFPropertyListRef)items, CXDomainRef());
    [self synchronize];
}

- (void)removeAllMenuItems {
    CFPreferencesSetAppValue((__bridge CFStringRef)CXKeyMenuItems,
                             (__bridge CFPropertyListRef)@[], CXDomainRef());
    [self synchronize];
}

- (void)synchronize {
    CFPreferencesAppSynchronize(CXDomainRef());
    notify_post(CXChangedNotification.UTF8String);
}

@end