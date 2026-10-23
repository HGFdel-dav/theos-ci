#import <Foundation/Foundation.h>

#define SC_NOTIF_APP_LAUNCHED @"com.susudear.screencore/app-launched"
#define SC_NOTIF_APP_TERMINATED @"com.susudear.screencore/app-terminated"
#define SC_NOTIF_CONTAINER_SWITCHED @"com.susudear.screencore/container-switched"
#define SC_NOTIF_PREFS_CHANGED @"com.susudear.screencore/prefs-changed"

typedef void(^SCNotificationHandler)(NSDictionary *userInfo);

@interface SCNotificationObserver : NSObject
+ (instancetype)sharedObserver;

- (void)observeAppLaunched:(SCNotificationHandler)handler;
- (void)observeAppTerminated:(SCNotificationHandler)handler;
- (void)observeContainerSwitched:(SCNotificationHandler)handler;
- (void)observePrefsChanged:(SCNotificationHandler)handler;

- (void)postAppLaunched:(NSString *)bundleID;
- (void)postAppTerminated:(NSString *)bundleID;
- (void)postContainerSwitched:(NSString *)bundleID containerID:(NSString *)containerID;
- (void)postPrefsChanged;
@end

@implementation SCNotificationObserver {
    NSMutableDictionary<NSString *, NSMutableArray<SCNotificationHandler> *> *_handlers;
}

+ (instancetype)sharedObserver {
    static SCNotificationObserver *s = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [[self alloc] init];
    });
    return s;
}

- (instancetype)init {
    if (self = [super init]) {
        _handlers = [NSMutableDictionary dictionary];
        [self setupDarwinObservers];
    }
    return self;
}

- (void)setupDarwinObservers {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                     (__bridge const void *)self,
                                     scDarwinCallback,
                                     (__bridge CFStringRef)SC_NOTIF_APP_LAUNCHED,
                                     NULL,
                                     CFNotificationSuspensionBehaviorDeliverImmediately);
    
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                     (__bridge const void *)self,
                                     scDarwinCallback,
                                     (__bridge CFStringRef)SC_NOTIF_PREFS_CHANGED,
                                     NULL,
                                     CFNotificationSuspensionBehaviorDeliverImmediately);
}

static void scDarwinCallback(CFNotificationCenterRef center,
                             void *observer,
                             CFStringRef name,
                             const void *object,
                             CFDictionaryRef userInfo) {
    [[SCNotificationObserver sharedObserver] handleDarwinNotification:(__bridge NSString *)name
                                                             userInfo:(__bridge NSDictionary *)userInfo];
}

- (void)handleDarwinNotification:(NSString *)name userInfo:(NSDictionary *)info {
    NSArray *handlers = _handlers[name];
    for (SCNotificationHandler handler in handlers) {
        handler(info);
    }
}

- (void)observeAppLaunched:(SCNotificationHandler)handler {
    [self addHandler:handler forNotification:SC_NOTIF_APP_LAUNCHED];
}

- (void)observeAppTerminated:(SCNotificationHandler)handler {
    [self addHandler:handler forNotification:SC_NOTIF_APP_TERMINATED];
}

- (void)observeContainerSwitched:(SCNotificationHandler)handler {
    [self addHandler:handler forNotification:SC_NOTIF_CONTAINER_SWITCHED];
}

- (void)observePrefsChanged:(SCNotificationHandler)handler {
    [self addHandler:handler forNotification:SC_NOTIF_PREFS_CHANGED];
}

- (void)addHandler:(SCNotificationHandler)handler forNotification:(NSString *)name {
    if (!_handlers[name]) {
        _handlers[name] = [NSMutableArray array];
    }
    [_handlers[name] addObject:[handler copy]];
}

- (void)postAppLaunched:(NSString *)bundleID {
    [self postNotification:SC_NOTIF_APP_LAUNCHED userInfo:@{@"bundleID": bundleID}];
}

- (void)postAppTerminated:(NSString *)bundleID {
    [self postNotification:SC_NOTIF_APP_TERMINATED userInfo:@{@"bundleID": bundleID}];
}

- (void)postContainerSwitched:(NSString *)bundleID containerID:(NSString *)containerID {
    [self postNotification:SC_NOTIF_CONTAINER_SWITCHED
                  userInfo:@{@"bundleID": bundleID, @"containerID": containerID ?: @""}];
}

- (void)postPrefsChanged {
    [self postNotification:SC_NOTIF_PREFS_CHANGED userInfo:nil];
}

- (void)postNotification:(NSString *)name userInfo:(NSDictionary *)info {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          (__bridge CFStringRef)name,
                                          NULL,
                                          (__bridge CFDictionaryRef)info,
                                          YES);
}

@end
