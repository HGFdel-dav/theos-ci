// TWArcMenuView.m
#import "TWArcMenuView.h"
#import "TWArcGeometry.h"
#import <AudioToolbox/AudioServices.h>

#pragma mark - icon fetching (SpringBoard process)

static UIImage *TWIconImageForBundleID(NSString *bundleID) {
    UIImage *icon = nil;
    // 1) LSApplicationProxy iconDataForVariant:
    Class proxyCls = NSClassFromString(@"LSApplicationProxy");
    if (proxyCls) {
        id (*msg)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        SEL selProxy = NSSelectorFromString(@"applicationProxyForIdentifier:");
        id proxy = selProxy ? msg(proxyCls, selProxy, bundleID) : nil;
        if (proxy) {
            SEL selIcon = NSSelectorFromString(@"iconDataForVariant:");
            id data = selIcon ? msg(proxy, selIcon, @(4)) : nil;
            if ([data isKindOfClass:[NSData class]]) icon = [UIImage imageWithData:data];
        }
    }
    // 2) SBIconController model fallback (SpringBoard private, always present here)
    if (!icon) {
        Class iconCtlCls = NSClassFromString(@"SBIconController");
        if (iconCtlCls) {
            id (*msg)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            SEL selShared = NSSelectorFromString(@"sharedInstance");
            id controller = selShared ? msg(iconCtlCls, selShared) : nil;
            id model = controller ? msg(controller, NSSelectorFromString(@"model")) : nil;
            if (model) {
                id iconObj = msg(model, NSSelectorFromString(@"expectedIconForDisplayIdentifier:"), bundleID);
                if (!iconObj) iconObj = msg(model, NSSelectorFromString(@"iconForDisplayIdentifier:"), bundleID);
                if (iconObj) {
                    id img = msg(iconObj, NSSelectorFromString(@"generateIconImage:"), @(1));
                    if ([img isKindOfClass:[UIImage class]]) icon = img;
                }
            }
        }
    }
    return icon;
}

NSString *TWDisplayNameForBundleID(NSString *bundleID) {
    Class proxyCls = NSClassFromString(@"LSApplicationProxy");
    if (proxyCls) {
        id (*msg)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        id proxy = msg(proxyCls, NSSelectorFromString(@"applicationProxyForIdentifier:"), bundleID);
        if (proxy) {
            id name = msg(proxy, NSSelectorFromString(@"localizedName"));
            if ([name isKindOfClass:[NSString class]] && [name length]) return name;
        }
    }
    return bundleID;
}

#pragma mark - item view

@interface TWArcItemView : UIView
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UIView *glowView;
@property (nonatomic, assign) BOOL highlighted;
@property (nonatomic, assign) CGPoint targetCenter;
@end

@implementation TWArcItemView
- (instancetype)initWithBundleID:(NSString *)bundleID image:(UIImage *)image {
    CGFloat size = 78;
    if ((self = [super initWithFrame:CGRectMake(0, 0, size, size)])) {
        _bundleID = [bundleID copy];
        self.layer.cornerRadius = 20;
        self.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.55];
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
        self.layer.borderWidth = 0.5;
        _glowView = [[UIView alloc] initWithFrame:self.bounds];
        _glowView.backgroundColor = [UIColor clearColor];
        _glowView.layer.borderColor = [UIColor systemBlueColor].CGColor;
        _glowView.layer.borderWidth = 2.5;
        _glowView.layer.cornerRadius = 20;
        _glowView.alpha = 0;
        [self addSubview:_glowView];
        _imageView = [[UIImageView alloc] initWithFrame:CGRectMake(9, 9, size - 18, size - 18)];
        _imageView.image = image;
        _imageView.contentMode = UIViewContentModeScaleAspectFit;
        _imageView.layer.cornerRadius = 13;
        _imageView.clipsToBounds = YES;
        [self addSubview:_imageView];
    }
    return self;
}
- (void)setHighlighted:(BOOL)highlighted {
    _highlighted = highlighted;
    CGFloat scale = highlighted ? 1.18 : 1.0;
    CGFloat glowAlpha = highlighted ? 1.0 : 0.0;
    [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        self.transform = CGAffineTransformMakeScale(scale, scale);
        self.glowView.alpha = glowAlpha;
    } completion:nil];
}
@end

#pragma mark - menu view

@implementation TWArcMenuView {
    NSMutableArray<TWArcItemView *> *_items;
    NSArray<NSString *> *_bundleIDs;
    CGPoint _triggerPoint;
    CGPoint _anchor;
    NSInteger _side;
    CGFloat _radius;
    UIView *_backgroundBand;
    CAGradientLayer *_bandGradient;
    CAShapeLayer *_bandMask;
    UIView *_dimView;
    CGFloat _menuScale;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        _items = [NSMutableArray array];
        _menuScale = 1.0;
    }
    return self;
}

- (void)presentFromTriggerPoint:(CGPoint)point bundleIDs:(NSArray<NSString *> *)bundleIDs side:(NSInteger)side radius:(CGFloat)radius menuScale:(CGFloat)menuScale {
    [self dismissAnimated:NO];
    _bundleIDs = [bundleIDs copy];
    _triggerPoint = point;
    _side = side;
    _radius = radius;
    _menuScale = menuScale > 0.1 ? menuScale : 1.0;
    _anchor = [TWArcGeometry anchorForTriggerPoint:point side:side bounds:self.bounds];

    // dim
    _dimView = [[UIView alloc] initWithFrame:self.bounds];
    _dimView.backgroundColor = [UIColor blackColor];
    _dimView.alpha = 0;
    [self addSubview:_dimView];

    // gradient arc band behind the items
    _backgroundBand = [[UIView alloc] initWithFrame:self.bounds];
    _bandGradient = [CAGradientLayer layer];
    _bandGradient.frame = self.bounds;
    _bandGradient.colors = @[(id)[UIColor systemBlueColor].CGColor,
                             (id)[UIColor cyanColor].CGColor];
    _bandGradient.startPoint = CGPointMake(0.5, 0.5);
    _bandGradient.endPoint = CGPointMake(side == 0 ? 1 : 0, 0.5);
    _bandMask = [CAShapeLayer layer];
    _bandMask.strokeColor = UIColor.whiteColor.CGColor;
    _bandMask.fillColor = UIColor.clearColor.CGColor;
    _bandMask.lineWidth = 110 * _menuScale;
    _bandMask.lineCap = kCALineCapRound;
    _bandGradient.mask = _bandMask;
    [_backgroundBand.layer addSublayer:_bandGradient];
    _backgroundBand.alpha = 0.22;
    [self addSubview:_backgroundBand];

    // items
    NSInteger count = (NSInteger)_bundleIDs.count;
    for (NSInteger i = 0; i < count; i++) {
        NSString *bundleID = _bundleIDs[i];
        UIImage *icon = TWIconImageForBundleID(bundleID);
        if (!icon) icon = [self placeholderImage];
        TWArcItemView *item = [[TWArcItemView alloc] initWithBundleID:bundleID image:icon];
        CGPoint center = [TWArcGeometry centerForItemAtIndex:i count:count radius:_radius anchor:_anchor side:_side bounds:self.bounds];
        item.targetCenter = center;
        item.center = _triggerPoint;
        item.alpha = 0;
        item.transform = CGAffineTransformMakeScale(0.2, 0.2);
        [self addSubview:item];
        [_items addObject:item];
    }
    [self updateBandPath];

    // spring in
    _dimView.alpha = 0.001;
    [UIView animateWithDuration:0.18 animations:^{ self->_dimView.alpha = 0.18; }];

    NSTimeInterval baseDelay = 0.02;
    [_items enumerateObjectsUsingBlock:^(TWArcItemView *item, NSUInteger idx, BOOL *stop) {
        NSTimeInterval delay = baseDelay * (double)idx;
        [UIView animateWithDuration:0.34 delay:delay
             usingSpringWithDamping:0.72 initialSpringVelocity:0 options:UIViewAnimationOptionCurveEaseOut
             animations:^{
                 item.alpha = 1;
                 item.center = item.targetCenter;
                 item.transform = CGAffineTransformMakeScale(self->_menuScale, self->_menuScale);
                 self->_backgroundBand.alpha = 0.5;
             } completion:nil];
    }];
    _presented = YES;
}

- (void)updateBandPath {
    // Arc band: same sweep angles as the item placement.
    NSInteger count = MAX((NSInteger)_bundleIDs.count, 1);
    CGFloat startAngle = M_PI / 2.0;
    CGFloat sweep = 1.45f * (M_PI / 2.0);
    CGFloat step = (count > 1) ? sweep / (count - 1) : 0;
    CGFloat a0, a1;
    if (_side == 0) {
        a0 = startAngle;
        a1 = startAngle - step * (count - 1);
    } else {
        a0 = M_PI - startAngle;
        a1 = M_PI - (startAngle - step * (count - 1));
    }
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path addArcWithCenter:_anchor radius:_radius startAngle:a0 endAngle:a1 clockwise:NO];
    _bandMask.path = path.CGPath;
}

- (UIImage *)placeholderImage {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(56, 56), NO, 0);
    [[UIColor secondarySystemBackgroundColor] setFill];
    UIRectFill(CGRectMake(0, 0, 56, 56));
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

- (void)updateSelectionAtPoint:(CGPoint)point {
    TWArcItemView *hit = nil;
    for (TWArcItemView *item in _items) {
        CGRect hitRect = CGRectInset(item.frame, -16, -16);
        if (CGRectContainsPoint(hitRect, point)) { hit = item; break; }
    }
    for (TWArcItemView *item in _items) {
        BOOL should = (item == hit);
        if (item.isHighlighted != should) item.highlighted = should;
    }
    if (hit && !hit.isHighlighted) {
        UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [gen impactOccurred];
    }
}

- (NSString *)finishSelectionAtPoint:(CGPoint)point {
    NSString *selected = nil;
    for (TWArcItemView *item in _items) {
        CGRect hitRect = CGRectInset(item.frame, -16, -16);
        if (CGRectContainsPoint(hitRect, point)) { selected = item.bundleID; item.highlighted = NO; break; }
    }
    [self dismissAnimated:selected != nil];
    return selected;
}

- (void)dismissAnimated:(BOOL)animated {
    _presented = NO;
    if (animated) {
        [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
            for (TWArcItemView *item in self->_items) {
                item.alpha = 0;
                item.transform = CGAffineTransformMakeScale(0.4, 0.4);
            }
            self->_backgroundBand.alpha = 0;
            self->_dimView.alpha = 0;
        } completion:^(BOOL finished) {
            [self cleanup];
        }];
    } else {
        [self cleanup];
    }
}

- (void)cleanup {
    [self.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    [_items removeAllObjects];
    _bundleIDs = nil;
    _backgroundBand = nil;
    _bandGradient = nil;
    _bandMask = nil;
    _dimView = nil;
}

@end