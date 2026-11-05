#import "LocalCleanStatusConfig.h"
#import "LocalCleanStatusPreferences.h"
#import <stdatomic.h>

static atomic_uint_least32_t lcsFlags;
uint32_t local_cleanstatus_currentFlags(void) { return atomic_load_explicit(&lcsFlags, memory_order_acquire); }

@interface LocalCleanStatusConfig ()
@property(atomic, copy) NSDictionary *snapshot;
@property(nonatomic, strong) dispatch_queue_t reloadQueue;
@end

static void local_cleanstatus_preferencesChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                 const void *object, CFDictionaryRef info) {
    (void)center; (void)name; (void)object; (void)info;
    LocalCleanStatusConfig *config = (__bridge LocalCleanStatusConfig *)observer;
    dispatch_async(config.reloadQueue, ^{ [config local_cleanstatus_reload]; });
}

@implementation LocalCleanStatusConfig
+ (instancetype)local_cleanstatus_shared {
    static LocalCleanStatusConfig *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}
- (instancetype)init {
    if ((self = [super init])) {
        _reloadQueue = dispatch_queue_create("com.local.cleanstatus.preferences", DISPATCH_QUEUE_SERIAL);
        _snapshot = local_cleanstatus_sanitizedPreferences(@{}); // fail closed until background read finishes
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)self, local_cleanstatus_preferencesChanged,
            (__bridge CFStringRef)local_cleanstatus_preferencesChangedNotification, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        dispatch_async(_reloadQueue, ^{ [self local_cleanstatus_reload]; });
    }
    return self;
}
- (void)local_cleanstatus_reload {
    NSDictionary *values = local_cleanstatus_readPreferences();
    uint32_t flags = 0;
    for (NSUInteger i = 0; i < LocalCleanStatusFeatureCount; i++) {
        if (local_cleanstatus_bool(values[[NSString stringWithUTF8String:local_cleanstatus_featureNames[i]]])) flags |= local_cleanstatus_featureBit((LocalCleanStatusFeature)i);
    }
    self.snapshot = values;
    atomic_store_explicit(&lcsFlags, local_cleanstatus_effectiveFlags(local_cleanstatus_bool(values[@"enabled"]), flags), memory_order_release);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:local_cleanstatus_preferencesChangedNotification object:self];
    });
}
- (BOOL)local_cleanstatus_isEnabled { return local_cleanstatus_bool(self.snapshot[@"enabled"]); }
- (id)local_cleanstatus_valueForKey:(NSString *)key defaultValue:(id)defaultValue { return self.snapshot[key] ?: defaultValue; }
- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self);
}
@end
