#import <UIKit/UIKit.h>

@interface SCGestureVelocityTracker : NSObject
@property (nonatomic, assign) CGPoint lastPoint;
@property (nonatomic, assign) NSTimeInterval lastTimestamp;
@property (nonatomic, assign) CGPoint velocity;

- (void)updateWithPoint:(CGPoint)point timestamp:(NSTimeInterval)timestamp;
- (CGFloat)velocityMagnitude;
- (CGFloat)velocityAngle;
- (BOOL)isSwipeGesture:(CGFloat)threshold;
- (void)reset;
@end

@implementation SCGestureVelocityTracker

- (void)updateWithPoint:(CGPoint)point timestamp:(NSTimeInterval)timestamp {
    if (_lastTimestamp > 0) {
        CGFloat dt = timestamp - _lastTimestamp;
        if (dt > 0) {
            _velocity = CGPointMake((point.x - _lastPoint.x) / dt,
                                   (point.y - _lastPoint.y) / dt);
        }
    }
    _lastPoint = point;
    _lastTimestamp = timestamp;
}

- (CGFloat)velocityMagnitude {
    return sqrt(_velocity.x * _velocity.x + _velocity.y * _velocity.y);
}

- (CGFloat)velocityAngle {
    return atan2(_velocity.y, _velocity.x);
}

- (BOOL)isSwipeGesture:(CGFloat)threshold {
    return [self velocityMagnitude] > threshold;
}

- (void)reset {
    _lastPoint = CGPointZero;
    _lastTimestamp = 0;
    _velocity = CGPointZero;
}

@end
