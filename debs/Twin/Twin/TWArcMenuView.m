// TWArcMenuView.m
// 角落弧形菜单（0.4.0）：条目 = { bundleID, containerID, title, badge }，
// 一个应用有几个容器就有几个图标，角标用 @"默"/@"分" 之类区分。
#import "TWArcMenuView.h"
#import "TWArcGeometry.h"
#import "TWPrefs.h"

// ParallelX 的动画数值（从其二进制扫出：0.16 / 0.40 / 0.34 / 0.72）
static const NSTimeInterval TWPXPresentDuration = 0.16;
static const NSTimeInterval TWPXDismissDuration = 0.40;
static const NSTimeInterval TWPXItemDuration    = 0.34;
static const CGFloat        TWPXSpringDamping   = 0.72;
#import <AudioToolbox/AudioServices.h>
#import <objc/message.h>
#import <string.h>
#import <math.h>

#pragma mark - icon fetching (SpringBoard process)

// Never call a private selector without checking its actual argument/return ABI.
static const char *TWIconType(const char *type) {
    while (type && *type && strchr("rnNoORV", *type)) type++;
    return type ?: "";
}

static NSMethodSignature *TWIconSignature(id target, SEL selector, NSUInteger arguments) {
    @try {
        if (!target || ![target respondsToSelector:selector]) return nil;
        NSMethodSignature *sig = [target methodSignatureForSelector:selector];
        return sig.numberOfArguments == arguments ? sig : nil;
    } @catch (__unused NSException *exception) { return nil; }
}

static id TWIconObject(id target, NSString *name, id argument, BOOL hasArgument) {
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *sig = TWIconSignature(target, selector, hasArgument ? 3 : 2);
    if (!sig || TWIconType(sig.methodReturnType)[0] != '@') return nil;
    if (hasArgument && TWIconType([sig getArgumentTypeAtIndex:2])[0] != '@') return nil;
    @try {
        if (hasArgument) return ((id (*)(id, SEL, id))objc_msgSend)(target, selector, argument);
        return ((id (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (__unused NSException *exception) { return nil; }
}

static id TWIconScalar(id target, NSString *name, NSInteger value) {
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *sig = TWIconSignature(target, selector, 3);
    if (!sig || TWIconType(sig.methodReturnType)[0] != '@') return nil;
    @try {
        // Match the scalar type, not NSNumber or a variadic prototype.
        const char *type = TWIconType([sig getArgumentTypeAtIndex:2]);
        if (!strcmp(type, @encode(int))) return ((id (*)(id, SEL, int))objc_msgSend)(target, selector, (int)value);
        if (!strcmp(type, @encode(unsigned int))) return ((id (*)(id, SEL, unsigned int))objc_msgSend)(target, selector, (unsigned int)value);
        if (!strcmp(type, @encode(long))) return ((id (*)(id, SEL, long))objc_msgSend)(target, selector, (long)value);
        if (!strcmp(type, @encode(unsigned long))) return ((id (*)(id, SEL, unsigned long))objc_msgSend)(target, selector, (unsigned long)value);
        if (!strcmp(type, @encode(long long))) return ((id (*)(id, SEL, long long))objc_msgSend)(target, selector, (long long)value);
        if (!strcmp(type, @encode(unsigned long long))) return ((id (*)(id, SEL, unsigned long long))objc_msgSend)(target, selector, (unsigned long long)value);
    } @catch (__unused NSException *exception) {}
    return nil; // Unknown signatures safely fall through to a placeholder.
}

static UIImage *TWIconImageForBundleID(NSString *bundleID) {
    id proxy = TWIconObject(NSClassFromString(@"LSApplicationProxy"), @"applicationProxyForIdentifier:", bundleID, YES);
    // 0.9.8：变体依次试，别只试一个（不同 iOS 返回的变体不同，试不到就整排变灰块）。
    for (NSNumber *variant in @[@4, @2, @0]) {
        id data = TWIconScalar(proxy, @"iconDataForVariant:", variant.integerValue);
        UIImage *icon = [data isKindOfClass:[NSData class]] ? [UIImage imageWithData:data] : nil;
        if (icon) return icon;
    }
    id controller = TWIconObject(NSClassFromString(@"SBIconController"), @"sharedInstance", nil, NO);
    id model = TWIconObject(controller, @"model", nil, NO);
    id iconObj = TWIconObject(model, @"expectedIconForDisplayIdentifier:", bundleID, YES);
    if (!iconObj) iconObj = TWIconObject(model, @"iconForDisplayIdentifier:", bundleID, YES);
    id image = TWIconScalar(iconObj, @"generateIconImage:", 1);
    if ([image isKindOfClass:[UIImage class]]) return image;
    return nil;
}

#pragma mark - item view

@interface TWArcItemView : UIView
@property (nonatomic, copy) NSDictionary *entry;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UIView *glowView;
@property (nonatomic, strong) UILabel *badgeLabel;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, assign, getter=isHighlighted) BOOL highlighted;
@property (nonatomic, assign) CGPoint targetCenter;
@property (nonatomic, assign) CGFloat baseScale;
@end

@implementation TWArcItemView
- (void)applyIconScalePercent:(CGFloat)pct backgroundAlphaPercent:(CGFloat)alphaPct {
    if (!isfinite(pct) || pct <= 0) pct = 70;
    if (!isfinite(alphaPct)) alphaPct = 100;
    CGFloat side = CGRectGetWidth(self.bounds);
    CGFloat shrink = side * (1.0 - MIN(pct, 100.0) / 100.0) * 0.5;
    _imageView.frame = CGRectInset(self.bounds, shrink, shrink);
    _imageView.layer.cornerRadius = MAX(0, self.layer.cornerRadius - shrink * 0.5);
    self.backgroundColor = [UIColor colorWithWhite:0.12 alpha:MAX(0, MIN(alphaPct, 100.0)) / 100.0];
}
- (instancetype)initWithEntry:(NSDictionary *)entry image:(UIImage *)image size:(CGFloat)size {
    if ((self = [super initWithFrame:CGRectMake(0, 0, size, size)])) {
        _entry = [entry copy];
        CGFloat radius = size * 0.26;
        self.layer.cornerRadius = radius;
        self.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.55];
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
        self.layer.borderWidth = 0.5;
        _glowView = [[UIView alloc] initWithFrame:self.bounds];
        _glowView.backgroundColor = [UIColor clearColor];
        _glowView.layer.borderColor = [UIColor systemBlueColor].CGColor;
        _glowView.layer.borderWidth = 2.5;
        _glowView.layer.cornerRadius = radius;
        _glowView.alpha = 0;
        [self addSubview:_glowView];
        CGFloat inset = MAX(5.0, size * 0.16);
        _imageView = [[UIImageView alloc] initWithFrame:CGRectMake(inset, inset, size - inset * 2, size - inset * 2)];
        _imageView.image = image;
        _imageView.contentMode = UIViewContentModeScaleAspectFit;
        _imageView.layer.cornerRadius = radius * 0.75;
        _imageView.clipsToBounds = YES;
        [self addSubview:_imageView];

        // 角标：区分同一个应用的哪个容器（默 / 分 / 名）
        NSString *badge = [entry[@"badge"] isKindOfClass:NSString.class] ? entry[@"badge"] : nil;
        if (badge.length) {
            CGFloat badgeHeight = MAX(13.0, size * 0.36);
            _badgeLabel = [[UILabel alloc] init];
            _badgeLabel.text = badge;
            _badgeLabel.font = [UIFont systemFontOfSize:MAX(9.0, badgeHeight * 0.64) weight:UIFontWeightHeavy];
            _badgeLabel.textColor = UIColor.whiteColor;
            _badgeLabel.textAlignment = NSTextAlignmentCenter;
            _badgeLabel.backgroundColor = [badge isEqualToString:@"默"] ? [UIColor systemGrayColor] : [UIColor systemPinkColor];
            CGSize text = [_badgeLabel sizeThatFits:CGSizeMake(size * 2, badgeHeight)];
            CGFloat width = MAX(badgeHeight, text.width + badgeHeight * 0.6);
            _badgeLabel.frame = CGRectMake((size - width) / 2, size - badgeHeight * 0.75, width, badgeHeight);
            _badgeLabel.layer.cornerRadius = badgeHeight / 2;
            _badgeLabel.layer.borderWidth = 1.5;
            _badgeLabel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.9].CGColor;
            _badgeLabel.clipsToBounds = YES;
            [self addSubview:_badgeLabel];
        }

        // 名字气泡：高亮时浮在图标上方
        NSString *title = [entry[@"title"] isKindOfClass:NSString.class] ? entry[@"title"] : nil;
        if (!title.length) title = [entry[@"bundleID"] isKindOfClass:NSString.class] ? entry[@"bundleID"] : @"";
        if (title.length) {
            _nameLabel = [[UILabel alloc] init];
            _nameLabel.text = title;
            _nameLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
            _nameLabel.textColor = UIColor.whiteColor;
            _nameLabel.backgroundColor = [UIColor colorWithWhite:0.09 alpha:0.9];
            _nameLabel.textAlignment = NSTextAlignmentCenter;
            _nameLabel.alpha = 0;
            CGSize text = [_nameLabel sizeThatFits:CGSizeMake(260, 22)];
            CGFloat width = MIN(260, text.width + 20);
            _nameLabel.frame = CGRectMake((size - width) / 2, -28, width, 22);
            _nameLabel.layer.cornerRadius = 11;
            _nameLabel.clipsToBounds = YES;
            [self addSubview:_nameLabel];
        }
    }
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    _highlighted = highlighted;
    BOOL glowOn = TWArcOrigBool(@"arcSelectedIconEnabled", YES);
    CGFloat scale = (self.baseScale > 0 ? self.baseScale : 1) * ((highlighted && glowOn) ? 1.18 : 1);
    CGFloat glowAlpha = (highlighted && glowOn) ? 1.0 : 0.0;
    [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        self.transform = CGAffineTransformMakeScale(scale, scale);
        self.glowView.alpha = glowAlpha;
        self.nameLabel.alpha = highlighted ? 1.0 : 0.0;
    } completion:nil];
}
@end

#pragma mark - menu view

@interface TWArcMenuView ()
- (UIImage *)placeholderImageForEntry:(NSDictionary *)entry;
- (NSInteger)selectedIndex;
- (NSDictionary *)entryAtIndex:(NSInteger)index;
@end

@implementation TWArcMenuView {
    NSMutableArray<TWArcItemView *> *_items;
    NSArray<NSDictionary *> *_entries;
    CGPoint _triggerPoint;
    CGPoint _anchor;
    NSInteger _corner;
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
        _corner = TWCornerBottomRight;
    }
    return self;
}

- (void)presentFromTriggerPoint:(CGPoint)point entries:(NSArray<NSDictionary *> *)entries corner:(NSInteger)corner radius:(CGFloat)radius menuScale:(CGFloat)menuScale {
    [self dismissAnimated:NO];
    if (![entries isKindOfClass:NSArray.class] || !entries.count) return;
    // 截图/录屏时隐藏（ScreenCore 的 hideArcFromScreenCaptureEnabled）
    BOOL hideCapture = TWArcOrigBool(@"hideArcFromScreenCaptureEnabled", NO);
    SEL hideSel = NSSelectorFromString(@"_setHideFromCapture:");
    if ([self respondsToSelector:hideSel]) {
        @try { ((void (*)(id, SEL, BOOL))objc_msgSend)(self, hideSel, hideCapture); } @catch (__unused NSException *e) {}
    }
    _entries = [entries copy];
    _triggerPoint = point;
    _corner = (corner < 0 || corner > 3) ? TWCornerBottomRight : corner;
    _menuScale = isfinite(menuScale) && menuScale > 0.1 ? MIN(menuScale, 2) : 1;
    NSInteger count = (NSInteger)_entries.count;

    // ---- 几何：ScreenCore 的 90° 角落扇形 + 多环排布 ----
    TWPrefs *prefs = [TWPrefs shared];
    CGFloat itemSize = TWArcOrigNumber(@"arcIconSize", 28.0);
    if (!isfinite(itemSize) || itemSize < 20) itemSize = 28;
    // 原版的 28 是「图标大小」的下限值，屏幕上实际画出来的图标比这个大得多；
    // 直接拿 28 当直径做出来只有指甲盖大小（实测效果），所以按屏幕尺寸换算。
    CGFloat iconVisual = MAX(44.0, itemSize * 1.75);
    iconVisual = MIN(iconVisual, 120.0);
    NSInteger firstRow = (NSInteger)TWArcOrigNumber(@"arcFirstRowItemCount", 5.0);
    CGFloat ringGap = TWArcOrigNumber(@"arcIconSpacing", 0.0);

    // 以下全部对应 ScreenCore 的同名参数。
    CGFloat menuPct = TWArcOrigNumber(@"arcMenuScalePercent", 100.0);
    if (isfinite(menuPct) && menuPct > 10) _menuScale *= MIN(menuPct, 200.0) / 100.0;
    CGFloat iconScalePct = TWArcOrigNumber(@"arcAppIconScalePercent", 70.0);
    if (!isfinite(iconScalePct)) iconScalePct = 70;
    CGFloat iconBgPct = TWArcOrigNumber(@"arcIconBackgroundAlphaPercent", 100.0);
    if (!isfinite(iconBgPct)) iconBgPct = 100;
    CGFloat offX = TWArcOrigNumber(@"arcOffsetX", 0.0);
    CGFloat offY = TWArcOrigNumber(@"arcOffsetY", 0.0);
    BOOL landscapeNow = self.bounds.size.width > self.bounds.size.height;
    radius += TWArcOrigNumber(@"arcPortraitOffsetDistance", 0.0);
    if (landscapeNow) {
        radius += TWArcOrigNumber(@"arcLandscapeOffsetDistance", 0.0);
        CGFloat landPct = TWArcOrigNumber(@"arcLandscapeMenuScalePercent", 100.0);
        if (isfinite(landPct) && landPct > 10) _menuScale *= MIN(landPct, 400.0) / 100.0;
    }
    NSInteger iconShape = (NSInteger)TWArcOrigNumber(@"arcAppIconShape", 0.0);

    CGFloat margin = iconVisual * 0.5 + 14;
    _anchor = [TWArcGeometry anchorForCorner:_corner margin:margin bounds:self.bounds];
    BOOL leftSide = (_corner == TWCornerBottomLeft || _corner == TWCornerTopLeft);
    BOOL topSide = (_corner == TWCornerTopLeft || _corner == TWCornerTopRight);
    _anchor = CGPointMake(_anchor.x + (leftSide ? offX : -offX),
                          _anchor.y + (topSide ? offY : -offY));
    _radius = [TWArcGeometry clampedRadius:radius anchor:_anchor corner:_corner bounds:self.bounds];

    NSArray<NSValue *> *centers = [TWArcGeometry centersForCount:count
                                                   firstRowCount:firstRow
                                                        iconSize:iconVisual
                                                           radius:_radius
                                                         ringGap:ringGap
                                                          anchor:_anchor
                                                          corner:_corner
                                                          bounds:self.bounds];
    if (centers.count < (NSUInteger)count) return;

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
    _bandGradient.startPoint = CGPointMake(_corner == TWCornerBottomLeft || _corner == TWCornerTopLeft ? 1 : 0,
                                           _corner == TWCornerTopLeft || _corner == TWCornerTopRight ? 1 : 0);
    _bandGradient.endPoint = CGPointMake(0.5, 0.5);
    _bandMask = [CAShapeLayer layer];
    _bandMask.strokeColor = UIColor.whiteColor.CGColor;
    _bandMask.fillColor = UIColor.clearColor.CGColor;
    _bandMask.lineWidth = (iconVisual + 16) * _menuScale;
    _bandMask.lineCap = kCALineCapRound;
    _bandGradient.mask = _bandMask;
    [_backgroundBand.layer addSublayer:_bandGradient];
    _backgroundBand.hidden = !TWArcOrigBool(@"arcBackgroundEnabled", NO);
    CGFloat bgAlpha = TWArcOrigNumber(@"arcBackgroundAlpha", 0.3);
    _backgroundBand.alpha = (isfinite(bgAlpha) && bgAlpha > 0) ? MIN(bgAlpha, 1.0) : 0.3;
    [self addSubview:_backgroundBand];

    // items
    for (NSInteger i = 0; i < count; i++) {
        NSDictionary *entry = _entries[i];
        NSString *bundleID = [entry[@"bundleID"] isKindOfClass:NSString.class] ? entry[@"bundleID"] : nil;
        UIImage *icon = bundleID.length ? TWIconImageForBundleID(bundleID) : nil;
        if (!icon) icon = [self placeholderImageForEntry:entry];
        TWArcItemView *item = [[TWArcItemView alloc] initWithEntry:entry image:icon size:iconVisual];
        [item applyIconScalePercent:iconScalePct backgroundAlphaPercent:iconBgPct];
        if (iconShape == 1) {
            item.layer.cornerRadius = iconVisual / 2.0;
            item.imageView.layer.cornerRadius = iconVisual / 2.0;
        }
        item.baseScale = _menuScale;
        CGPoint center = [centers[(NSUInteger)i] CGPointValue];
        item.targetCenter = center;
        item.center = _triggerPoint;
        item.alpha = 0;
        item.transform = CGAffineTransformMakeScale(0.2, 0.2);
        [self addSubview:item];
        [_items addObject:item];
    }
    [self updateBandPath];

    // ---- 动画：ParallelX 的数值（0.16 展开 / 0.34 单图标 / 阻尼 0.72）----
    _dimView.alpha = 0.001;
    [UIView animateWithDuration:TWPXPresentDuration animations:^{ self->_dimView.alpha = 0.18; }];

    BOOL springOn = TWArcOrigBool(@"arcSpringAnimationEnabled", NO);
    CGFloat damping = TWArcOrigNumber(@"arcSpringDamping", 0.68);
    if (!isfinite(damping) || damping <= 0 || damping > 1) damping = 0.68;
    CGFloat bgFinal = _backgroundBand.hidden ? 0 : _backgroundBand.alpha;
    NSTimeInterval baseDelay = 0.02;
    [_items enumerateObjectsUsingBlock:^(TWArcItemView *item, NSUInteger idx, BOOL *stop) {
        NSTimeInterval delay = baseDelay * (double)idx;
        void (^anim)(void) = ^{
            item.alpha = 1;
            item.center = item.targetCenter;
            item.transform = CGAffineTransformMakeScale(self->_menuScale, self->_menuScale);
            self->_backgroundBand.alpha = bgFinal;
        };
        if (springOn) {
            [UIView animateWithDuration:TWPXItemDuration delay:delay
                 usingSpringWithDamping:damping initialSpringVelocity:0
                                options:UIViewAnimationOptionCurveEaseOut
                             animations:anim completion:nil];
        } else {
            [UIView animateWithDuration:TWPXItemDuration delay:delay
                                options:UIViewAnimationOptionCurveEaseOut
                             animations:anim completion:nil];
        }
    }];
    _presented = YES;
}

- (void)updateBandPath {
    if (!_bandMask) return;
    CGFloat start = [TWArcGeometry startAngleForCorner:_corner];
    CGFloat sweep = [TWArcGeometry sweepAngle];
    // UIBezierPath 与我们的 UIKit 角度约定一致（0 = 向右，角度增大 = 顺时针）。
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path addArcWithCenter:_anchor radius:_radius startAngle:start endAngle:start + sweep clockwise:YES];
    _bandMask.path = path.CGPath;
}

// 图标取不到时不再画一块空灰板（那看起来就是"图标被盖住了"），
// 改成带首字的彩色圆角块，一眼能认。
- (UIImage *)placeholderImageForEntry:(NSDictionary *)entry {
    NSString *title = [entry[@"title"] isKindOfClass:NSString.class] ? entry[@"title"] : nil;
    if (!title.length) title = [entry[@"bundleID"] isKindOfClass:NSString.class] ? entry[@"bundleID"] : @"?";
    NSString *letter = title.length ? [title substringToIndex:1] : @"?";
    CGSize size = CGSizeMake(96, 96);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *img = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size.width, size.height)
                                                            cornerRadius:size.width * 0.26];
        [[UIColor colorWithWhite:0.25 alpha:1.0] setFill];
        [path fill];
        NSDictionary *attrs = @{ NSFontAttributeName: [UIFont systemFontOfSize:46 weight:UIFontWeightSemibold],
                                 NSForegroundColorAttributeName: UIColor.whiteColor };
        CGSize text = [letter sizeWithAttributes:attrs];
        [letter drawAtPoint:CGPointMake((size.width - text.width) / 2, (size.height - text.height) / 2)
             withAttributes:attrs];
    }];
    return img;
}

- (NSInteger)selectedIndex {
    for (NSInteger i = 0; i < (NSInteger)_items.count; i++) {
        if (_items[(NSUInteger)i].isHighlighted) return i;
    }
    return -1;
}

- (NSDictionary *)entryAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_entries.count) return nil;
    return _entries[(NSUInteger)index];
}

- (TWArcItemView *)itemAtPoint:(CGPoint)point {
    if (!_presented || !isfinite(point.x) || !isfinite(point.y)) return nil;
    TWArcItemView *hit = nil;
    CGFloat nearest = CGFLOAT_MAX;
    for (TWArcItemView *item in _items) {
        CGFloat half = CGRectGetWidth(item.bounds) * _menuScale / 2 + 12;
        CGRect hitRect = CGRectMake(item.targetCenter.x - half, item.targetCenter.y - half, half * 2, half * 2);
        CGFloat distance = hypot(point.x - item.targetCenter.x, point.y - item.targetCenter.y);
        if (CGRectContainsPoint(hitRect, point) && distance < nearest) { hit = item; nearest = distance; }
    }
    return hit;
}

- (void)updateSelectionAtPoint:(CGPoint)point {
    TWArcItemView *hit = [self itemAtPoint:point];
    BOOL newlySelected = (hit != nil && !hit.isHighlighted);
    for (TWArcItemView *item in _items) {
        BOOL should = (item == hit);
        if (item.isHighlighted != should) item.highlighted = should;
    }
    if (newlySelected && [[TWPrefs shared] boolForKey:TWKeyArcHaptic defaultValue:YES]) {
        UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [gen impactOccurred];
    }
}

- (NSDictionary *)finishSelectionAtPoint:(CGPoint)point {
    TWArcItemView *item = [self itemAtPoint:point];
    NSDictionary *selected = item.entry;
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
        NSArray<TWArcItemView *> *dismissedItems = [_items copy];
        UIView *dismissedBand = _backgroundBand;
        UIView *dismissedDim = _dimView;
        [_items removeAllObjects];
        _entries = nil;
        _backgroundBand = nil;
        _bandGradient = nil;
        _bandMask = nil;
        _dimView = nil;
        [UIView animateWithDuration:TWPXDismissDuration delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn animations:^{
            for (TWArcItemView *item in dismissedItems) {
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
    _entries = nil;
    _backgroundBand = nil;
    _bandGradient = nil;
    _bandMask = nil;
    _dimView = nil;
}

@end