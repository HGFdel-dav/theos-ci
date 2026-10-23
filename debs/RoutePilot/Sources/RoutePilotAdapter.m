#import "RoutePilotAdapter.h"

@interface RoutePilotAdapterRegistry ()
@property (nonatomic, strong) NSMutableArray<id<RoutePilotAdapter>> *routepilot_app_adapters;
@end

@implementation RoutePilotAdapterRegistry

+ (instancetype)routepilot_app_shared {
    static RoutePilotAdapterRegistry *registry;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        registry = [[self alloc] init];
    });
    return registry;
}

- (instancetype)init {
    self = [super init];
    if (self) _routepilot_app_adapters = [NSMutableArray array];
    return self;
}

- (NSArray<id<RoutePilotAdapter>> *)routepilot_app_availableAdapters {
    @synchronized (self) { return [_routepilot_app_adapters copy]; }
}

- (id<RoutePilotAdapter>)routepilot_app_activeAdapter {
    @synchronized (self) {
        for (id<RoutePilotAdapter> adapter in _routepilot_app_adapters) {
            RoutePilotAdapterState state = [adapter routepilot_app_state];
            if (state == RoutePilotAdapterStateReady || state == RoutePilotAdapterStateApplying) return adapter;
        }
    }
    return nil;
}

- (void)routepilot_app_registerAdapter:(id<RoutePilotAdapter>)adapter {
    if (!adapter) return;
    @synchronized (self) {
        for (id<RoutePilotAdapter> existing in _routepilot_app_adapters) {
            if ([existing.routepilot_app_identifier isEqualToString:adapter.routepilot_app_identifier]) return;
        }
        [_routepilot_app_adapters addObject:adapter];
    }
}

@end
