// CXPrefs.m
#import "CXPrefs.h"
#import <CoreFoundation/CoreFoundation.h>
#import <notify.h>

NSString *const CXKeyHiddenItems = @"CXHiddenItems";
NSString *const CXKeyDiagCraneOK = @"CXDiagCraneOK";

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

- (void)setBool:(BOOL)value forKey:(NSString *)key {
    if (!key.length) return;
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)@(value), CXDomainRef());
    [self synchronize];
}

- (NSArray<NSString *> *)hiddenItems {
    id value = [self objectForKey:CXKeyHiddenItems];
    if (![value isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id item in value) if ([item isKindOfClass:NSString.class] && [item length]) [out addObject:item];
    return out;
}

- (BOOL)isItemShownInMenu:(NSString *)bundleID containerID:(NSString *)containerID {
    if (!bundleID.length || !containerID.length) return NO;
    NSString *key = [NSString stringWithFormat:@"%@#%@", bundleID, containerID];
    return ![[self hiddenItems] containsObject:key];
}

- (void)setItemInMenu:(NSString *)bundleID containerID:(NSString *)containerID shown:(BOOL)shown {
    if (!bundleID.length || !containerID.length) return;
    NSString *key = [NSString stringWithFormat:@"%@#%@", bundleID, containerID];
    NSMutableArray *hidden = [[self hiddenItems] mutableCopy];
    [hidden removeObject:key];
    if (!shown) [hidden addObject:key];
    CFPreferencesSetAppValue((__bridge CFStringRef)CXKeyHiddenItems,
                             (__bridge CFPropertyListRef)hidden, CXDomainRef());
    [self synchronize];
}

- (void)synchronize {
    CFPreferencesAppSynchronize(CXDomainRef());
    notify_post(CXChangedNotification.UTF8String);
}

@end