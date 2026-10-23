#import <UIKit/UIKit.h>

@interface SCDebugOverlay : UIView
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, strong) NSMutableArray<UIView *> *cornerViews;

+ (instancetype)sharedOverlay;
- (void)showCornerRegions:(NSArray<NSValue *> *)regions; // CGRect wrapped
- (void)showTriggerPoint:(CGPoint)point;
- (void)hide;
@end

@implementation SCDebugOverlay

+ (instancetype)sharedOverlay {
    static SCDebugOverlay *s = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
        s = [[self alloc] initWithFrame:keyWindow.bounds];
        s.userInteractionEnabled = NO;
        s.backgroundColor = [UIColor clearColor];
        [keyWindow addSubview:s];
    });
    return s;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        _enabled = NO;
        _cornerViews = [NSMutableArray array];
    }
    return self;
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    self.hidden = !enabled;
    if (!enabled) {
        [self hide];
    }
}

- (void)showCornerRegions:(NSArray<NSValue *> *)regions {
    if (!_enabled) return;
    
    [self hide];
    
    for (NSValue *rectValue in regions) {
        CGRect rect = rectValue.CGRectValue;
        UIView *v = [[UIView alloc] initWithFrame:rect];
        v.backgroundColor = [UIColor colorWithRed:1.0 green:0.6 blue:0.0 alpha:0.3];
        v.layer.borderColor = [UIColor orangeColor].CGColor;
        v.layer.borderWidth = 2;
        [self addSubview:v];
        [_cornerViews addObject:v];
    }
}

- (void)showTriggerPoint:(CGPoint)point {
    if (!_enabled) return;
    
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(point.x - 5, point.y - 5, 10, 10)];
    dot.backgroundColor = [UIColor redColor];
    dot.layer.cornerRadius = 5;
    [self addSubview:dot];
    [_cornerViews addObject:dot];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [dot removeFromSuperview];
        [self->_cornerViews removeObject:dot];
    });
}

- (void)hide {
    for (UIView *v in _cornerViews) {
        [v removeFromSuperview];
    }
    [_cornerViews removeAllObjects];
}

@end
