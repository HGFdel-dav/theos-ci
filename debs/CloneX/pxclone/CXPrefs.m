// CXPrefs.m
#import "CXPrefs.h"
#import <CoreFoundation/CoreFoundation.h>
#import <notify.h>

NSString *const CXKeyCloneApps = @"CXCloneApps";
NSString *const CXKeyAskEachTime = @"CXAskEachTime";

static NSString *const CXDomain = @"com.niubiprass.clonex";
static CFStringRef CXDomainRef(void) { return (__bridge CFStringRef)CXDomain; }
static NSString *const CXChangedNotification = @"com.niubiprass.clonex/changed";

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

- (NSDictionary<NSString *,NSString *> *)cloneApps {
    id value = [self objectForKey:CXKeyCloneApps];
    if (![value isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (id key in value) {
        if (![key isKindOfClass:NSString.class] || ![key length]) continue;
        id container = value[key];
        if ([container isKindOfClass:NSString.class] && [container length]) out[key] = container;
    }
    return out;
}

- (NSString *)containerForBundleID:(NSString *)bundleID {
    if (!bundleID.length) return nil;
    return [self cloneApps][bundleID];
}

- (void)setContainer:(NSString *)containerID forBundleID:(NSString *)bundleID {
    if (!bundleID.length || !containerID.length) return;
    NSMutableDictionary *apps = [[self cloneApps] mutableCopy];
    apps[bundleID] = containerID;
    CFPreferencesSetAppValue((__bridge CFStringRef)CXKeyCloneApps,
                             (__bridge CFPropertyListRef)apps, CXDomainRef());
    [self synchronize];
}

- (void)removeContainerForBundleID:(NSString *)bundleID {
    if (!bundleID.length) return;
    NSMutableDictionary *apps = [[self cloneApps] mutableCopy];
    [apps removeObjectForKey:bundleID];
    CFPreferencesSetAppValue((__bridge CFStringRef)CXKeyCloneApps,
                             (__bridge CFPropertyListRef)apps, CXDomainRef());
    [self synchronize];
}

- (void)synchronize {
    CFPreferencesAppSynchronize(CXDomainRef());
    notify_post(CXChangedNotification.UTF8String);
}

@end
