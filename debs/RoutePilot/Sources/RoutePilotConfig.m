#import "RoutePilotConfig.h"
#import "RoutePilotPreferences.h"

@interface RoutePilotConfig ()
@property (atomic, copy) NSDictionary *snapshot;
@property (nonatomic, strong) dispatch_queue_t reloadQueue;
@end

static void routepilot_app_preferencesDidChange(CFNotificationCenterRef center, void *observer,
                                          CFStringRef name, const void *object, CFDictionaryRef info) {
    RoutePilotConfig *config = (__bridge RoutePilotConfig *)observer;
    dispatch_async(config.reloadQueue, ^{
        [config routepilot_app_reload];
    });
}

@implementation RoutePilotConfig

+ (instancetype)routepilot_app_shared {
    static RoutePilotConfig *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _reloadQueue = dispatch_queue_create("com.niubiprass.routepilot.preferences", DISPATCH_QUEUE_SERIAL);
        [self routepilot_app_reload];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)self, routepilot_app_preferencesDidChange,
            (__bridge CFStringRef)RoutePilotPreferencesChanged, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        // Close the window between the first read and observer registration.
        dispatch_async(_reloadQueue, ^{ [self routepilot_app_reload]; });
    }
    return self;
}

- (void)routepilot_app_reload {
    self.snapshot = routepilot_app_readPreferences();
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:RoutePilotPreferencesChanged object:self];
    });
}

- (id)routepilot_app_valueForKey:(NSString *)key defaultValue:(id)defaultValue {
    return self.snapshot[key] ?: defaultValue;
}

- (BOOL)routepilot_app_isEnabled {
    id value = [self routepilot_app_valueForKey:@"enabled" defaultValue:@(NO)];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : NO;
}

- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
}

@end
