// PXPArcMenuView.m
#import "PXPArcMenuView.h"
#import "PXPArcGeometry.h"
#import <AudioToolbox/AudioServices.h>
#import <objc/message.h>
#import <string.h>
#import <math.h>

#pragma mark - icon fetching (SpringBoard process)

// Never call a private selector without checking its actual argument/return ABI.
static const char *PXPIconType(const char *type) {
    while (type && *type && strchr("rnNoORV", *type)) type++;
    return type ?: "";
}

static NSMethodSignature *PXPIconSignature(id target, SEL selector, NSUInteger arguments) {
    @try {
        if (!target || ![target respondsToSelector:selector]) return nil;
        NSMethodSignature *sig = [target methodSignatureForSelector:selector];
        return sig.numberOfArguments == arguments ? sig : nil;
    } @catch (__unused NSException *exception) { return nil; }
}

static id PXPIconObject(id target, NSString *name, id argument, BOOL hasArgument) {
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *sig = PXPIconSignature(target, selector, hasArgument ? 3 : 2);
    if (!sig || PXPIconType(sig.methodReturnType)[0] != '@') return nil;
    if (hasArgument && PXPIconType([sig getArgumentTypeAtIndex:2])[0] != '@') return nil;
    @try {
        if (hasArgument) return ((id (*)(id, SEL, id))objc_msgSend)(target, selector, argument);
        return ((id (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (__unused NSException *exception) { return nil; }
}

static id PXPIconScalar(id target, NSString *name, NSInteger value) {
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *sig = PXPIconSignature(target, selector, 3);
    if (!sig || PXPIconType(sig.methodReturnType)[0] != '@') return nil;
    @try {
        // Match the scalar type, not NSNumber or a variadic prototype.
        const char *type = PXPIconType([sig getArgumentTypeAtIndex:2]);
        if (!strcmp(type, @encode(int))) return ((id (*)(id, SEL, int))objc_msgSend)(target, selector, (int)value);
        if (!strcmp(type, @encode(unsigned int))) return ((id (*)(id, SEL, unsigned int))objc_msgSend)(target, selector, (unsigned int)value);
        if (!strcmp(type, @encode(long))) return ((id (*)(id, SEL, long))objc_msgSend)(target, selector, (long)value);
        if (!strcmp(type, @encode(unsigned long))) return ((id (*)(id, SEL, unsigned long))objc_msgSend)(target, selector, (unsigned long)value);
        if (!strcmp(type, @encode(long long))) return ((id (*)(id, SEL, long long))objc_msgSend)(target, selector, (long long)value);
        if (!strcmp(type, @encode(unsigned long long))) return ((id (*)(id, SEL, unsigned long long))objc_msgSend)(target, selector, (unsigned long long)value);
    } @catch (__unused NSException *exception) {}
    return nil; // Unknown signatures safely fall through to a placeholder.
}

static UIImage *PXPIconImageForBundleID(NSString *bundleID) {
    id proxy = PXPIconObject(NSClassFromString(@"LSApplicationProxy"), @"applicationProxyForIdentifier:", bundleID, YES);
    id data = PXPIconScalar(proxy, @"iconDataForVariant:", 4);
    UIImage *icon = [data isKindOfClass:[NSData class]] ? [UIImage imageWithData:data] : nil;
    if (!icon) {
        id controller = PXPIconObject(NSClassFromString(@"SBIconController"), @"sharedInstance", nil, NO);
        id model = PXPIconObject(controller, @"model", nil, NO);
        id iconObj = PXPIconObject(model, @"expectedIconForDisplayIdentifier:", bundleID, YES);
        if (!iconObj) iconObj = PXPIconObject(model, @"iconForDisplayIdentifier:", bundleID, YES);
        id image = PXPIconScalar(iconObj, @"generateIconImage:", 1);
        if ([image isKindOfClass:[UIImage class]]) icon = image;
    }
    return icon;
}

#pragma mark - item view

@interface PXPArcItemView : UIView
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UIView *glowView;
@property (nonatomic, assign, getter=isHighlighted) BOOL highlighted;
@property (nonatomic, assign) CGPoint targetCenter;
@property (nonatomic, assign) CGFloat baseScale;
@end

@implementation PXPArcItemView
- (instancetype)initWithBundleID:(NSString *)bundleID image:(UIImage *)image size:(CGFloat)size {
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
    CGFloat scale = (self.baseScale > 0 ? self.baseScale : 1) * (highlighted ? 1.18 : 1);
    CGFloat glowAlpha = highlighted ? 1.0 : 0.0;
    [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        self.transform = CGAffineTransformMakeScale(scale, scale);
        self.glowView.alpha = glowAlpha;
    } completion:nil];
}
@end

#pragma mark - menu view

@implementation PXPArcMenuView {
    NSMutableArray<PXPArcItemView *> *_items;
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
    _menuScale = isfinite(menuScale) && menuScale > 0.1 ? MIN(menuScale, 2) : 1;
    _radius = [PXPArcGeometry radiusForItemCount:_bundleIDs.count preferredRadius:radius menuScale:_menuScale bounds:self.bounds];
    CGFloat itemSize = [PXPArcGeometry itemSizeForCount:_bundleIDs.count radius:_radius menuScale:_menuScale];
    if (itemSize <= 0 || !_bundleIDs.count) return;
    _anchor = [PXPArcGeometry anchorForTriggerPoint:point side:side radius:_radius itemSize:itemSize menuScale:_menuScale bounds:self.bounds];

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
    _bandMask.lineWidth = (itemSize + 18) * _menuScale;
    _bandMask.lineCap = kCALineCapRound;
    _bandGradient.mask = _bandMask;
    [_backgroundBand.layer addSublayer:_bandGradient];
    _backgroundBand.alpha = 0.22;
    [self addSubview:_backgroundBand];

    // items
    NSInteger count = (NSInteger)_bundleIDs.count;
    for (NSInteger i = 0; i < count; i++) {
        NSString *bundleID = _bundleIDs[i];
        UIImage *icon = PXPIconImageForBundleID(bundleID);
        if (!icon) icon = [self placeholderImage];
        PXPArcItemView *item = [[PXPArcItemView alloc] initWithBundleID:bundleID image:icon size:itemSize];
        item.baseScale = _menuScale;
        CGPoint center = [PXPArcGeometry centerForItemAtIndex:i count:count radius:_radius anchor:_anchor side:_side bounds:self.bounds];
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
    [_items enumerateObjectsUsingBlock:^(PXPArcItemView *item, NSUInteger idx, BOOL *stop) {
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
    // UIBezierPath uses downward-positive y, unlike the math placement above.
    [path addArcWithCenter:_anchor radius:_radius startAngle:-a0 endAngle:-a1 clockwise:(_side == 0)];
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

- (PXPArcItemView *)itemAtPoint:(CGPoint)point {
    if (!_presented || !isfinite(point.x) || !isfinite(point.y)) return nil;
    PXPArcItemView *hit = nil;
    CGFloat nearest = CGFLOAT_MAX;
    for (PXPArcItemView *item in _items) {
        CGFloat half = CGRectGetWidth(item.bounds) * _menuScale / 2 + 12;
        CGRect hitRect = CGRectMake(item.targetCenter.x - half, item.targetCenter.y - half, half * 2, half * 2);
        CGFloat distance = hypot(point.x - item.targetCenter.x, point.y - item.targetCenter.y);
        if (CGRectContainsPoint(hitRect, point) && distance < nearest) { hit = item; nearest = distance; }
    }
    return hit;
}

- (void)updateSelectionAtPoint:(CGPoint)point {
    PXPArcItemView *hit = [self itemAtPoint:point];
    BOOL newlySelected = (hit != nil && !hit.isHighlighted);
    for (PXPArcItemView *item in _items) {
        BOOL should = (item == hit);
        if (item.isHighlighted != should) item.highlighted = should;
    }
    if (newlySelected) {
        UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [gen impactOccurred];
    }
}

- (NSString *)finishSelectionAtPoint:(CGPoint)point {
    PXPArcItemView *item = [self itemAtPoint:point];
    NSString *selected = item.bundleID;
    item.highlighted = NO;
    [self dismissAnimated:selected != nil];
    return selected;
}

- (void)dismissAnimated:(BOOL)animated {
    _presented = NO;
    if (animated) {
        // Detach this generation's state before an asynchronous completion.
        // A new presentation may replace the ivars while these views fade out.
        NSArray<UIView *> *dismissedViews = [self.subviews copy];
        NSArray<PXPArcItemView *> *dismissedItems = [_items copy];
        UIView *dismissedBand = _backgroundBand;
        UIView *dismissedDim = _dimView;
        [_items removeAllObjects];
        _bundleIDs = nil;
        _backgroundBand = nil;
        _bandGradient = nil;
        _bandMask = nil;
        _dimView = nil;
        [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn animations:^{
            for (PXPArcItemView *item in dismissedItems) {
                item.alpha = 0;
                item.transform = CGAffineTransformMakeScale(0.4, 0.4);
            }
            dismissedBand.alpha = 0;
            dismissedDim.alpha = 0;
        } completion:^(BOOL finished) {
            for (UIView *view in dismissedViews) [view removeFromSuperview];
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