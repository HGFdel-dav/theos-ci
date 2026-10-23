#import <Foundation/Foundation.h>

#define SC_PREFS_DOMAIN @"com.susudear.screencoreprefs"

@interface SCPreferences : NSObject
+ (instancetype)sharedInstance;
- (id)valueForKey:(NSString *)key defaultValue:(id)defaultValue;
- (void)setValue:(id)value forKey:(NSString *)key;
- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)defaultValue;
- (CGFloat)floatForKey:(NSString *)key defaultValue:(CGFloat)defaultValue;
- (void)synchronize;
@end

@implementation SCPreferences {
    NSMutableDictionary *_cache;
}

+ (instancetype)sharedInstance {
    static SCPreferences *s = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [[self alloc] init];
    });
    return s;
}

- (instancetype)init {
    if (self = [super init]) {
        _cache = [NSMutableDictionary dictionary];
        [self reload];
    }
    return self;
}

- (void)reload {
    CFPreferencesAppSynchronize((__bridge CFStringRef)SC_PREFS_DOMAIN);
    CFArrayRef keys = CFPreferencesCopyKeyList((__bridge CFStringRef)SC_PREFS_DOMAIN,
                                                kCFPreferencesCurrentUser,
                                                kCFPreferencesAnyHost);
    if (!keys) return;
    
    for (NSString *key in (__bridge NSArray *)keys) {
        id value = (__bridge id)CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                           (__bridge CFStringRef)SC_PREFS_DOMAIN);
        if (value) _cache[key] = value;
    }
    CFRelease(keys);
}

- (id)valueForKey:(NSString *)key defaultValue:(id)defaultValue {
    id v = _cache[key];
    return v ?: defaultValue;
}

- (void)setValue:(id)value forKey:(NSString *)key {
    _cache[key] = value;
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFTypeRef)value,
                             (__bridge CFStringRef)SC_PREFS_DOMAIN);
}

- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)defaultValue {
    id v = _cache[key];
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    return defaultValue;
}

- (CGFloat)floatForKey:(NSString *)key defaultValue:(CGFloat)defaultValue {
    id v = _cache[key];
    if ([v isKindOfClass:[NSNumber class]]) return [v doubleValue];
    return defaultValue;
}

- (void)synchronize {
    CFPreferencesAppSynchronize((__bridge CFStringRef)SC_PREFS_DOMAIN);
}

@end
