// TWArcMenuView.m
// 角落弧形菜单（0.4.0）：条目 = { bundleID, containerID, title, badge }，
// 一个应用有几个容器就有几个图标，角标用 @"默"/@"分" 之类区分。
#import "TWArcMenuView.h"
#import "TWArcGeometry.h"
#import "TWPrefs.h"
#import "TWRuntimeLog.h"

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
    // ⓿ 最稳的一条：UIImage 的私有接口（Preferences / SpringBoard 里都能用）
    SEL clsSel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if ([UIImage respondsToSelector:clsSel]) {
        UIImage *img = ((id (*)(id, SEL, id, long, double))objc_msgSend)(
            UIImage.class, clsSel, bundleID, 0, (double)UIScreen.mainScreen.scale);
        if ([img isKindOfClass:UIImage.class] && img.size.width > 0) {
            TWRuntimeLog(@"[icon] %@ → UIImage 私有接口 OK", bundleID);
            return img;
        }
    }
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

// Average colour of the app icon, so the container badge matches it instead of
// using a fixed grey/pink pill.
static UIColor *TWDominantColor(UIImage *image) {
    if (![image isKindOfClass:UIImage.class]) return [UIColor colorWithWhite:0.18 alpha:0.7];
    CGImageRef cg = image.CGImage;
    if (!cg) return [UIColor colorWithWhite:0.18 alpha:0.7];
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (!w || !h) return [UIColor colorWithWhite:0.18 alpha:0.7];
    size_t total = w * h;
    size_t step = total > 4096 ? total / 4096 : 1;
    uint8_t *data = (uint8_t *)calloc(total * 4, 1);
    if (!data) return [UIColor colorWithWhite:0.18 alpha:0.7];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(data, w, h, 8, w * 4, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!ctx) { free(data); return [UIColor colorWithWhite:0.18 alpha:0.7]; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    CGContextRelease(ctx);
    double r = 0, g = 0, b = 0, weight = 0;
    for (size_t i = 0; i < total; i += step) {
        uint8_t a = data[i * 4 + 3];
        if (a < 128) continue;
        double lum = 0.299 * data[i * 4] + 0.587 * data[i * 4 + 1] + 0.114 * data[i * 4 + 2];
        if (lum > 238) continue;
        r += data[i * 4] * a; g += data[i * 4 + 1] * a; b += data[i * 4 + 2] * a; weight += a;
    }
    free(data);
    if (weight <= 0) return [UIColor colorWithWhite:0.18 alpha:0.7];
    UIColor *base = [UIColor colorWithRed:r / weight / 255.0 green:g / weight / 255.0 blue:b / weight / 255.0 alpha:1];
    return [base colorWithAlphaComponent:0.92];
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
        // Glass circle, matching the side panel: translucent blur, thin bright
        // rim and an inset app icon instead of a flat dark plate.
        CGFloat radius = size * 0.5;
        self.layer.cornerRadius = radius;
        self.backgroundColor = [UIColor clearColor];
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
        self.layer.borderWidth = 1.0;
        self.clipsToBounds = YES;
        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:
            [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        glass.frame = self.bounds;
        glass.userInteractionEnabled = NO;
        glass.layer.cornerRadius = radius;
        glass.clipsToBounds = YES;
        [self insertSubview:glass atIndex:0];
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

        // Container badge stays (it is the only way to tell 默/分 apart), but
        // small, translucent and rim-lit instead of a large flat pill.
        NSString *badge = [entry[@"badge"] isKindOfClass:NSString.class] ? entry[@"badge"] : nil;
        if (badge.length) {
            CGFloat bh = MAX(10.0, size * 0.25);
            _badgeLabel = [[UILabel alloc] init];
            _badgeLabel.text = badge;
            _badgeLabel.font = [UIFont systemFontOfSize:MAX(7.5, bh * 0.62) weight:UIFontWeightSemibold];
            _badgeLabel.textColor = [UIColor colorWithWhite:1 alpha:0.96];
            _badgeLabel.textAlignment = NSTextAlignmentCenter;
            _badgeLabel.backgroundColor = TWDominantColor(image);
            CGSize text = [_badgeLabel sizeThatFits:CGSizeMake(size, bh)];
            CGFloat bw = MAX(bh, text.width + bh * 0.55);
            _badgeLabel.frame = CGRectMake((size - bw) / 2, size - bh * 0.82, bw, bh);
            _badgeLabel.layer.cornerRadius = bh / 2;
            _badgeLabel.layer.cornerCurve = kCACornerCurveContinuous;
            _badgeLabel.layer.borderWidth = 0.5;
            _badgeLabel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.38].CGColor;
            _badgeLabel.clipsToBounds = YES;
            _badgeLabel.layer.shadowColor = UIColor.blackColor.CGColor;
            _badgeLabel.layer.shadowOpacity = 0.35;
            _badgeLabel.layer.shadowRadius = 2;
            _badgeLabel.layer.shadowOffset = CGSizeMake(0, 1);
            [self addSubview:_badgeLabel];
        }

        // Match the side panel: icons only, no floating application-name bubble.

    }
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    _highlighted = highlighted;
    BOOL glowOn = TWArcOrigBool(@"arcSelectedIconEnabled", YES);
    CGFloat scale = (self.baseScale > 0 ? self.baseScale : 1) * ((highlighted && glowOn) ? 1.34 : 1);
    CGFloat glowAlpha = (highlighted && glowOn) ? 1.0 : 0.0;
    [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        self.transform = CGAffineTransformMakeScale(scale, scale);
        self.glowView.alpha = glowAlpha;
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
    UITapGestureRecognizer *_twTap;
    __weak TWArcItemView *_twHighlighted;
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
    CGFloat _startAngle;
    CGFloat _sweepAngle;
    UIView *_itemsContainer;
    NSArray<UIView *> *_rowContainers;
    CGAffineTransform _presentTranslation;
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

    // ARC has its own size/spacing domain; a handle-menu preference must not
    // silently override arcIconSize. Values are points, not a guessed 1.35 multiplier.
    CGFloat iconVisual = TWArcOrigNumber(@"arcIconSize", 28);
    if (!isfinite(iconVisual) || iconVisual < 1) iconVisual = 28;
    iconVisual = MIN(iconVisual, 80);
    NSInteger firstRow = (NSInteger)TWArcOrigNumber(@"arcFirstRowItemCount", 5);
    firstRow = MIN(MAX(firstRow, 1), 20);
    CGFloat ringGap = TWArcOrigNumber(@"arcIconSpacing", 0);
    if (!isfinite(ringGap) || ringGap < 0) ringGap = 0;
    BOOL landscapeNow = CGRectGetWidth(self.bounds) > CGRectGetHeight(self.bounds);
    NSString *scaleKey = landscapeNow ? @"arcLandscapeMenuScalePercent" : @"arcMenuScalePercent";
    CGFloat menuPct = TWArcOrigNumber(scaleKey, 100);
    if (!isfinite(menuPct) || menuPct < 1) menuPct = 100;
    _menuScale *= MIN(menuPct, landscapeNow ? 400 : 150) / 100;
    CGFloat iconScalePct = TWArcOrigNumber(@"arcAppIconScalePercent", 70);
    CGFloat iconBgPct = TWArcOrigNumber(@"arcIconBackgroundAlphaPercent", 100);
    NSInteger iconShape = (NSInteger)TWArcOrigNumber(@"arcAppIconShape", 0);
    BOOL leftSide = _corner == TWCornerBottomLeft || _corner == TWCornerTopLeft;
    BOOL mirrored = TWArcOrigBool(@"arcSymmetricMirrorEnabled", NO);
    _startAngle = [TWArcGeometry menuStartAngleForCorner:_corner mirrored:mirrored];
    _sweepAngle = [TWArcGeometry menuSweepAngleForCorner:_corner mirrored:mirrored];

    CGFloat offX = TWArcOrigNumber(@"arcOffsetX", 0), offY = TWArcOrigNumber(@"arcOffsetY", 0);
    offX = isfinite(offX) ? MAX(0, offX) : 0;
    offY = isfinite(offY) ? MAX(0, offY) : 0;
    // These are translations, not additions to row radius. Portrait is diagonal;
    // landscape keys describe notch-side / non-notch-side horizontal translation.
    CGFloat distance = TWArcOrigNumber(landscapeNow ? @"arcLandscapeOffsetDistance" : @"arcPortraitOffsetDistance", 0);
    if (!isfinite(distance) || distance < 0) distance = 0;
    if (landscapeNow) {
        CGFloat notchDistance = TWArcOrigNumber(@"arcLandscapeHorizontalOffset", 0);
        if (!isfinite(notchDistance) || notchDistance < 0) notchDistance = 0;
        UIEdgeInsets safe = self.window.safeAreaInsets;
        BOOL notchOnLeft = safe.left > safe.right;
        if (fabs(safe.left - safe.right) < 0.5) {
            // UIKit landscape-left places the device top/notch at the left.
            notchOnLeft = self.window.windowScene.interfaceOrientation == UIInterfaceOrientationLandscapeLeft;
        }
        offX += leftSide == notchOnLeft ? notchDistance : distance;
    } else {
        offX += distance / M_SQRT2;
        offY += distance / M_SQRT2;
    }
    // Positive value pushes the fan anchor outside the screen, which pulls the
    // icons towards the edge (the old panel had no such control).
    CGFloat edgeInset = TWArcOrigNumber(@"arcMenuEdgeInset", 0);
    if (!isfinite(edgeInset)) edgeInset = 0;
    edgeInset = MIN(MAX(edgeInset, 0), 160);
    _anchor = [TWArcGeometry triggerAnchorForCorner:_corner offsetX:offX offsetY:offY bounds:self.bounds];
    _anchor.x += leftSide ? -edgeInset : edgeInset;
    _anchor.y += (_corner == TWCornerTopLeft || _corner == TWCornerTopRight) ? -edgeInset : edgeInset;
    _radius = isfinite(radius) && radius > 0 ? radius : MAX(104, iconVisual * 2 + ringGap);
    CGFloat scaledIcon = iconVisual * _menuScale;
    _radius *= _menuScale;
    // Rings grow by one icon each: ring 1 = firstRow, ring 2 = firstRow+1 ...
    NSMutableArray<NSNumber *> *ringCounts = [NSMutableArray array];
    for (NSInteger i = 0; i < 4; i++) [ringCounts addObject:@(firstRow + (NSInteger)i)];
    NSArray<NSValue *> *centers = [TWArcGeometry centersForCount:count firstRowCount:firstRow
        ringCounts:ringCounts iconSize:scaledIcon radius:_radius ringGap:ringGap * _menuScale
        anchor:_anchor startAngle:_startAngle sweepAngle:_sweepAngle bounds:self.bounds];
    if (centers.count != (NSUInteger)count) return;

    if (!_twTap) {
        _twTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(twHandleTap:)];
        [self addGestureRecognizer:_twTap];
    }
    // dim
    _dimView = [[UIView alloc] initWithFrame:self.bounds];
    _dimView.userInteractionEnabled = NO;
    _dimView.backgroundColor = [UIColor blackColor];
    _dimView.alpha = 0;
    [self addSubview:_dimView];

    // No background band: the side panel has none, and this layer was the
    // green/teal blob visible behind the icons. Keep the ivars unused rather
    // than drawing a second visual language.
    // ---- 布局：先把图标摆到最终位置，再做入场动画（原版顺序）----
    CGFloat slide = MIN(self.bounds.size.width, self.bounds.size.height);
    if (!isfinite(slide) || slide < 1) slide = 300;
    CGAffineTransform entry = CGAffineTransformMakeTranslation(leftSide ? -slide : slide,
                                                               (point.y > CGRectGetMidY(self.bounds)) ? slide : -slide);
    UIView *itemsContainer = [[UIView alloc] initWithFrame:self.bounds];
    itemsContainer.userInteractionEnabled = YES;
    itemsContainer.backgroundColor = UIColor.clearColor;
    [self addSubview:itemsContainer];

    // 按离圆心的半径分行：同一环一起动，环与环之间只差弹簧参数，没有逐个图标的延迟。
    NSMutableArray<NSNumber *> *rowRadii = [NSMutableArray array];
    for (NSInteger i = 0; i < count; i++) {
        CGPoint c = [centers[(NSUInteger)i] CGPointValue];
        CGFloat r = hypot(c.x - _anchor.x, c.y - _anchor.y);
        BOOL known = NO;
        for (NSNumber *v in rowRadii) if (fabs(v.doubleValue - r) < 1.5) { known = YES; break; }
        if (!known) [rowRadii addObject:@(r)];
    }
    [rowRadii sortUsingSelector:@selector(compare:)];
    NSMutableArray<UIView *> *rowViews = [NSMutableArray array];
    for (NSUInteger r = 0; r < rowRadii.count; r++) {
        UIView *row = [[UIView alloc] initWithFrame:self.bounds];
        row.userInteractionEnabled = YES;
        row.backgroundColor = UIColor.clearColor;
        [itemsContainer addSubview:row];
        [rowViews addObject:row];
    }

    // items
    for (NSInteger i = 0; i < count; i++) {
        NSDictionary *entry = _entries[i];
        NSString *bundleID = [entry[@"bundleID"] isKindOfClass:NSString.class] ? entry[@"bundleID"] : nil;
        UIImage *icon = bundleID.length ? TWIconImageForBundleID(bundleID) : nil;
        if (!icon) icon = [self placeholderImageForEntry:entry];
        TWArcItemView *item = [[TWArcItemView alloc] initWithEntry:entry image:icon size:scaledIcon];
        [item applyIconScalePercent:iconScalePct backgroundAlphaPercent:iconBgPct];
        if (iconShape == 1) {
            item.layer.cornerRadius = scaledIcon / 2.0;
            item.imageView.layer.cornerRadius = CGRectGetWidth(item.imageView.bounds) / 2.0;
        }
        item.baseScale = 1; // frame already uses scaledIcon; never apply scale twice
        CGPoint center = [centers[(NSUInteger)i] CGPointValue];
        item.targetCenter = center;
        item.center = center;                                  // 最终位置，不再汇聚到触点
        item.alpha = 1;
        item.transform = CGAffineTransformIdentity;
        NSUInteger rowIndex = 0;
        CGFloat best = CGFLOAT_MAX;
        CGFloat distance = hypot(center.x - _anchor.x, center.y - _anchor.y);
        for (NSUInteger r = 0; r < rowRadii.count; r++) {
            CGFloat delta = fabs(rowRadii[r].doubleValue - distance);
            if (delta < best) { best = delta; rowIndex = r; }
        }
        [rowViews[rowIndex] addSubview:item];
        [_items addObject:item];
    }

    _itemsContainer = itemsContainer;
    _rowContainers = rowViews;
    _presentTranslation = entry;

    // ---- 入场：整体或每环平移 + 总容器淡入；全部同时启动 ----
    _dimView.alpha = 0.001;
    [UIView animateWithDuration:TWPXPresentDuration animations:^{ self->_dimView.alpha = 0.18; }];

    [UIView performWithoutAnimation:^{
        itemsContainer.alpha = 0;
        for (UIView *row in rowViews) row.transform = entry;
    }];
    [UIView animateWithDuration:TWPXPresentDuration delay:0
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ itemsContainer.alpha = 1; } completion:nil];

    BOOL springOn = TWArcOrigBool(@"arcSpringAnimationEnabled", NO);
    CGFloat baseDamping = TWArcOrigNumber(@"arcSpringDamping", 0.68);
    if (!isfinite(baseDamping) || baseDamping <= 0 || baseDamping > 1) baseDamping = 0.68;
    NSUInteger rowCount = rowViews.count;
    [rowViews enumerateObjectsUsingBlock:^(UIView *row, NSUInteger i, BOOL *stop) {
        CGFloat t = rowCount >= 2 ? (CGFloat)i / (CGFloat)(rowCount - 1) : 1.0;
        void (^anim)(void) = ^{ row.transform = CGAffineTransformIdentity; };
        if (springOn) {
            [UIView animateWithDuration:0.34 + 0.12 * t delay:0
                 usingSpringWithDamping:MIN(1.0, baseDamping + 0.20 * (1.0 - t))
                  initialSpringVelocity:0.55 + 0.25 * t
                                options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                             animations:anim completion:nil];
        } else {
            [UIView animateWithDuration:TWPXPresentDuration delay:0
                                options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                             animations:anim completion:nil];
        }
    }];
    _presented = YES;
}

- (void)updateBandPath { return;
    if (!_bandMask) return;
    CGFloat start = _startAngle;
    CGFloat sweep = _sweepAngle;
    // UIBezierPath 与我们的 UIKit 角度约定一致（0 = 向右，角度增大 = 顺时针）。
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path addArcWithCenter:_anchor radius:_radius startAngle:start endAngle:start + sweep clockwise:(sweep > 0)];
    _bandMask.path = path.CGPath;
}

// 图标取不到时不再画一块空灰板（那看起来就是"图标被盖住了"），
// 改成带首字的彩色圆角块，一眼能认。
- (UIImage *)placeholderImageForEntry:(NSDictionary *)entry {
    NSString *title = [entry[@"title"] isKindOfClass:NSString.class] ? entry[@"title"] : nil;
    NSString *action = [entry[@"actionID"] isKindOfClass:NSString.class] ? entry[@"actionID"] : nil;
    if (action.length) {
        NSDictionary *symbols = @{@"px.action.dark":@"moon.fill", @"px.action.record":@"record.circle",
            @"px.action.rotation":@"lock.rotation", @"px.action.window":@"rectangle.on.rectangle",
            @"px.action.screenshot":@"camera.viewfinder", @"px.action.recent":@"clock.arrow.circlepath",
            @"px.action.brightness":@"sun.max.fill", @"px.action.search":@"magnifyingglass",
            @"px.action.kayoko":@"doc.on.clipboard", @"px.action.restart":@"arrow.clockwise"};
        UIImage *glyph = [UIImage systemImageNamed:symbols[action] ?: @"bolt.fill"];
        if (glyph) return [glyph imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    }
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

// 松手时若没落在图标上，取最近的一个（60pt 以内），不用精确"停"在图标上。
- (TWArcItemView *)nearestItemAtPoint:(CGPoint)point limit:(CGFloat)limit {
    TWArcItemView *best = nil;
    CGFloat bestD = limit;
    for (TWArcItemView *item in _items) {
        CGFloat d = hypot(point.x - item.targetCenter.x, point.y - item.targetCenter.y);
        if (d < bestD) { bestD = d; best = item; }
    }
    return best;
}

- (void)twHandleTap:(UITapGestureRecognizer *)g {
    if (!_presented) return;
    CGPoint p = [g locationInView:self];
    TWArcItemView *item = [self itemAtPoint:p];
    if (!item) item = [self nearestItemAtPoint:p limit:60.0];
    if (!item) return;
    NSDictionary *entry = item.entry;
    [self dismissAnimated:YES];
    if (entry && self.onPickEntry) self.onPickEntry(entry, NO);
}

- (TWArcItemView *)itemAtPoint:(CGPoint)point {
    if (!_presented || !isfinite(point.x) || !isfinite(point.y)) return nil;
    TWArcItemView *hit = nil;
    CGFloat nearest = CGFLOAT_MAX;
    for (TWArcItemView *item in _items) {
        CGFloat half = CGRectGetWidth(item.bounds) / 2 + 22;
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
    if (hit) _twHighlighted = hit;
    if (newlySelected && [[TWPrefs shared] boolForKey:TWKeyArcHaptic defaultValue:YES]) {
        UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [gen impactOccurred];
    }
}

- (NSDictionary *)finishSelectionAtPoint:(CGPoint)point {
    TWArcItemView *item = [self itemAtPoint:point];
    if (!item) item = _twHighlighted;                       // 松手那一刻手指一抖也不会丢
    if (!item) item = [self nearestItemAtPoint:point limit:90.0];
    TWRuntimeLog(@"[arc] release p=%.0f,%.0f hit=%@", point.x, point.y,
                 item.entry[@"title"] ?: @"(none)");
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
        UIView *dismissedContainer = _itemsContainer;
        NSArray<UIView *> *dismissedRows = _rowContainers;
        CGAffineTransform back = _presentTranslation;
        [_items removeAllObjects];
        _entries = nil;
        _backgroundBand = nil;
        _bandGradient = nil;
        _bandMask = nil;
        _dimView = nil;
        _itemsContainer = nil;
        _rowContainers = nil;
        [UIView animateWithDuration:TWPXDismissDuration delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            for (TWArcItemView *item in dismissedItems) item.alpha = 0;
            for (UIView *row in dismissedRows) row.transform = back;   // 原路退回，不缩小
            dismissedContainer.alpha = 0;
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
    _itemsContainer = nil;
    _rowContainers = nil;
}

@end