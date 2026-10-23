#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, SCArcGestureState) {
    SCArcGestureStateIdle = 0,
    SCArcGestureStateBegan,
    SCArcGestureStateRecognizing,
    SCArcGestureStateMenuPresented,
    SCArcGestureStateItemSelected,
    SCArcGestureStateCancelled
};

@interface SCArcGestureStateMachine : NSObject
@property (nonatomic, assign) SCArcGestureState currentState;
@property (nonatomic, assign) NSInteger triggerCorner; // 0=左下 1=右下 2=左上 3=右上
@property (nonatomic, assign) CGPoint initialTouchPoint;
@property (nonatomic, assign) CGPoint currentTouchPoint;
@property (nonatomic, assign) NSTimeInterval gestureBeginTime;

- (void)reset;
- (BOOL)shouldTransitionToState:(SCArcGestureState)newState;
- (void)transitionToState:(SCArcGestureState)newState;
- (BOOL)isInCornerRegion:(CGPoint)point screenBounds:(CGRect)bounds;
- (NSInteger)cornerForPoint:(CGPoint)point screenBounds:(CGRect)bounds;
- (CGFloat)distanceFromCorner:(CGPoint)point corner:(NSInteger)corner bounds:(CGRect)bounds;
@end

@implementation SCArcGestureStateMachine

- (instancetype)init {
    if (self = [super init]) {
        [self reset];
    }
    return self;
}

- (void)reset {
    _currentState = SCArcGestureStateIdle;
    _triggerCorner = -1;
    _initialTouchPoint = CGPointZero;
    _currentTouchPoint = CGPointZero;
    _gestureBeginTime = 0;
}

- (BOOL)shouldTransitionToState:(SCArcGestureState)newState {
    // 状态转移规则
    switch (_currentState) {
        case SCArcGestureStateIdle:
            return newState == SCArcGestureStateBegan;
        case SCArcGestureStateBegan:
            return newState == SCArcGestureStateRecognizing || newState == SCArcGestureStateCancelled;
        case SCArcGestureStateRecognizing:
            return newState == SCArcGestureStateMenuPresented || newState == SCArcGestureStateCancelled;
        case SCArcGestureStateMenuPresented:
            return newState == SCArcGestureStateItemSelected || newState == SCArcGestureStateCancelled;
        default:
            return newState == SCArcGestureStateIdle;
    }
}

- (void)transitionToState:(SCArcGestureState)newState {
    if (![self shouldTransitionToState:newState]) {
        NSLog(@"[SC] Invalid state transition %ld → %ld", (long)_currentState, (long)newState);
        return;
    }
    NSLog(@"[SC] State transition %ld → %ld", (long)_currentState, (long)newState);
    _currentState = newState;
}

- (BOOL)isInCornerRegion:(CGPoint)point screenBounds:(CGRect)bounds {
    CGFloat threshold = 50; // 角落触发阈值
    BOOL leftEdge = point.x < threshold;
    BOOL rightEdge = point.x > bounds.size.width - threshold;
    BOOL topEdge = point.y < threshold;
    BOOL bottomEdge = point.y > bounds.size.height - threshold;
    
    return (leftEdge || rightEdge) && (topEdge || bottomEdge);
}

- (NSInteger)cornerForPoint:(CGPoint)point screenBounds:(CGRect)bounds {
    CGFloat midX = bounds.size.width / 2;
    CGFloat midY = bounds.size.height / 2;
    
    if (point.x < midX && point.y > midY) return 0; // 左下
    if (point.x > midX && point.y > midY) return 1; // 右下
    if (point.x < midX && point.y < midY) return 2; // 左上
    if (point.x > midX && point.y < midY) return 3; // 右上
    
    return -1;
}

- (CGFloat)distanceFromCorner:(CGPoint)point corner:(NSInteger)corner bounds:(CGRect)bounds {
    CGPoint cornerPt;
    switch (corner) {
        case 0: cornerPt = CGPointMake(0, bounds.size.height); break;
        case 1: cornerPt = CGPointMake(bounds.size.width, bounds.size.height); break;
        case 2: cornerPt = CGPointMake(0, 0); break;
        case 3: cornerPt = CGPointMake(bounds.size.width, 0); break;
        default: return CGFLOAT_MAX;
    }
    
    CGFloat dx = point.x - cornerPt.x;
    CGFloat dy = point.y - cornerPt.y;
    return sqrt(dx*dx + dy*dy);
}

@end
