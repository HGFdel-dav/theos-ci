#import "../headers/AXTriggerZoneManager.h"

@implementation AXTriggerZoneManager {
    NSMutableDictionary<NSNumber *, NSValue *> *_customZones; // corner → CGRect
}

- (instancetype)init {
    if (self = [super init]) {
        _customZones = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)setCustomZone:(CGRect)zone forCorner:(NSInteger)corner {
    _customZones[@(corner)] = [NSValue valueWithCGRect:zone];
    NSLog(@"[ArcX] Set custom zone for corner %ld: %@", (long)corner, NSStringFromCGRect(zone));
}

- (CGRect)zoneForCorner:(NSInteger)corner defaultZone:(CGRect)defaultZone {
    NSValue *v = _customZones[@(corner)];
    return v ? v.CGRectValue : defaultZone;
}

- (BOOL)shouldTriggerAtPoint:(CGPoint)point inView:(UIView *)view {
    CGRect screenBounds = view.bounds;
    for (NSNumber *cornerNum in _customZones) {
        CGRect zone = _customZones[cornerNum].CGRectValue;
        if (CGRectContainsPoint(zone, point)) {
            return YES;
        }
    }
    return NO;
}

@end
