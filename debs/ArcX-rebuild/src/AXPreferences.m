#import "../headers/AXPreferences.h"
#import <Foundation/Foundation.h>

#define AX_PREFS_DOMAIN @"com.arcx.prefs"

@implementation AXPreferences {
    NSMutableDictionary *_cache;
}

+ (instancetype)sharedInstance {
    static AXPreferences *s = nil;
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
    CFPreferencesAppSynchronize((__bridge CFStringRef)AX_PREFS_DOMAIN);
}

- (BOOL)gestureEnhancementEnabled {
    id v = (__bridge id)CFPreferencesCopyAppValue(CFSTR("enhancementEnabled"),
                                                   (__bridge CFStringRef)AX_PREFS_DOMAIN);
    return v ? [v boolValue] : YES; // 默认开启
}

- (CGFloat)sensitivityFactor {
    id v = (__bridge id)CFPreferencesCopyAppValue(CFSTR("sensitivityFactor"),
                                                   (__bridge CFStringRef)AX_PREFS_DOMAIN);
    return v ? [v doubleValue] : 1.2; // 默认 1.2x
}

- (CGRect)customTriggerZoneForCorner:(NSInteger)corner {
    NSString *key = [NSString stringWithFormat:@"zone_corner%ld", (long)corner];
    id v = (__bridge id)CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                   (__bridge CFStringRef)AX_PREFS_DOMAIN);
    if (v && [v isKindOfClass:[NSString class]]) {
        return CGRectFromString(v);
    }
    return CGRectZero; // 未自定义
}

@end
