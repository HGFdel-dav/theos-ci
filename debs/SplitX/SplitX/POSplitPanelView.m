//
//  POSplitPanelView.m
//  SplitX
//
//  ParallelX 那种半圆菜单：手柄所在位置是圆心，图标沿半圆弧散开，
//  玻璃底板也是扇形，不是一整块矩形。
//
//  拖动时按手指和圆心的夹角判悬停，松手选中；选中项先向外弹一下再收。
//

#import "POSplitXLog.h"
#import "POSplitXSettings.h"
#import "POSplitPanelView.h"
#import "POSplitTarget.h"
#import "POApplicationHelper.h"
#import "POQuickSwitchMetrics.h"
#import <math.h>

static const NSUInteger PQMaxItems = 40;
static const CGFloat PQMinAngleStep = 18.0 * M_PI / 180.0;
static const CGFloat PQMaxAngleStep = 30.0 * M_PI / 180.0;

@class POSplitPanelItem;

#pragma mark - 单项

@interface POSplitPanelItem : UIView
@property (nonatomic, strong) POSplitTarget *target;
@property (nonatomic, strong) UIView *tileView;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) UIView *badge;
@property (nonatomic, strong) UILabel *badgeLabel;
@property (nonatomic, assign) BOOL highlighted;
@property (nonatomic, assign) BOOL chosen;
@property (nonatomic, assign) CGFloat angle;
@property (nonatomic, assign) CGFloat radius;
@property (nonatomic, assign) CGFloat baseScale;
- (instancetype)initWithTarget:(POSplitTarget *)target
                      iconSize:(CGFloat)iconSize
                      tileSize:(CGFloat)tileSize
                         title:(NSString *)title
                         badge:(NSString *)badge;
- (void)applyDimmedInitialState;
@end

@implementation POSplitPanelItem

- (instancetype)initWithTarget:(POSplitTarget *)target
                      iconSize:(CGFloat)iconSize
                      tileSize:(CGFloat)tileSize
                         title:(NSString *)title
                         badge:(NSString *)badge {
    // PX 那种：白色圆托 + 圆角图标，没有文字。
    CGFloat tile = tileSize;
    CGFloat icon = iconSize;
    CGFloat width = tile + 10.0;
    if ((self = [super initWithFrame:CGRectMake(0, 0, width, width)])) {
        _target = target;
        self.backgroundColor = UIColor.clearColor;

        UIView *bubble = [[UIView alloc] initWithFrame:CGRectMake(5, 5, tile, tile)];
        bubble.backgroundColor = [UIColor colorWithWhite:0.98 alpha:0.92];
        bubble.layer.cornerRadius = tile / 2.0;
        bubble.layer.borderWidth = 0.5;
        bubble.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.10].CGColor;
        bubble.layer.shadowColor = UIColor.blackColor.CGColor;
        bubble.layer.shadowOpacity = 0.18;
        bubble.layer.shadowRadius = 6;
        bubble.layer.shadowOffset = CGSizeMake(0, 2);
        bubble.userInteractionEnabled = NO;
        [self addSubview:bubble];
        _tileView = bubble;

        CGFloat inset = icon * 0.12 + 5.0;
        _iconView = [[UIImageView alloc] initWithFrame:CGRectInset(bubble.frame, inset, inset)];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.layer.cornerRadius = icon * 0.24;
        _iconView.layer.cornerCurve = kCACornerCurveContinuous;
        _iconView.clipsToBounds = YES;
        _iconView.image = [POApplicationHelper imageForBundleId:target.bundleIdentifier];
        [self addSubview:_iconView];

        if (badge.length) {
            CGFloat size = 15.0;
            _badge = [[UIView alloc] initWithFrame:CGRectMake(width - size - 4, 4, size, size)];
            _badge.backgroundColor = [UIColor colorWithWhite:0 alpha:0.72];
            _badge.layer.cornerRadius = size / 2.0;
            _badge.userInteractionEnabled = NO;
            [self addSubview:_badge];
            _badgeLabel = [[UILabel alloc] initWithFrame:_badge.bounds];
            _badgeLabel.text = badge;
            _badgeLabel.font = [UIFont systemFontOfSize:8 weight:UIFontWeightBold];
            _badgeLabel.textColor = UIColor.whiteColor;
            _badgeLabel.textAlignment = NSTextAlignmentCenter;
            [_badge addSubview:_badgeLabel];
        }
        self.layer.shadowColor = UIColor.clearColor.CGColor;
        _baseScale = 1.0;
    }
    return self;
}

- (void)applyDimmedInitialState {
    _highlighted = NO;
    _chosen = NO;
    [self applyVisualStateAnimated:NO];
}

- (void)setHighlighted:(BOOL)highlighted {
    if (_highlighted == highlighted) return;
    _highlighted = highlighted;
    [self applyVisualStateAnimated:YES];
}

- (void)setChosen:(BOOL)chosen {
    _chosen = chosen;
    [self applyVisualStateAnimated:YES];
}

- (void)applyVisualStateAnimated:(BOOL)animated {
    CGFloat scale = _baseScale;
    CGFloat alpha = 0.75;
    CGFloat lift = 0.0;
    if (_chosen) { scale = _baseScale * 1.20; alpha = 1.0; lift = 9.0; }
    else if (_highlighted) { scale = _baseScale * 1.14; alpha = 1.0; lift = 6.0; }

    void (^apply)(void) = ^{
        self.alpha = alpha;
        CGAffineTransform t = CGAffineTransformMakeScale(scale, scale);
        self.transform = CGAffineTransformTranslate(t, cos(self.angle) * lift / scale,
                                                    sin(self.angle) * lift / scale);
        self.tileView.layer.shadowOpacity = (alpha > 0.95) ? 0.30 : 0.14;
    };
    if (!animated) { apply(); return; }
    [UIView animateWithDuration:_chosen ? 0.20 : 0.14 delay:0
         usingSpringWithDamping:0.70 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:apply completion:nil];
}

@end

#pragma mark - 扇形菜单

@interface POSplitPanelView ()
@property (nonatomic, strong) UIVisualEffectView *backgroundView;
@property (nonatomic, strong) CAShapeLayer *shapeMask;
@property (nonatomic, strong) CAShapeLayer *edgeLayer;
@property (nonatomic, strong) NSMutableArray<POSplitPanelItem *> *items;
@property (nonatomic, strong) NSArray<POSplitTarget *> *targets;
@property (nonatomic, assign) NSInteger hoveredIndex;
@property (nonatomic, assign) BOOL presenting;
@property (nonatomic, assign) CGPoint centerPoint;   // 相对自身
@property (nonatomic, assign) CGFloat radius;
@property (nonatomic, assign) CGFloat baseScale;
@property (nonatomic, assign) CGFloat itemTileSize;
@property (nonatomic, assign) CGFloat itemIconSize;
@property (nonatomic, assign) CGFloat span;          // 弧度
@property (nonatomic, assign) CGFloat animationScale;
@end

@implementation POSplitPanelView

- (instancetype)init {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.backgroundColor = UIColor.clearColor;

        _backgroundView = [[UIVisualEffectView alloc] initWithEffect:
            [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialLight]];
        _backgroundView.userInteractionEnabled = NO;
        _backgroundView.layer.masksToBounds = YES;
        [self addSubview:_backgroundView];

        _shapeMask = [CAShapeLayer layer];
        _backgroundView.layer.mask = _shapeMask;

        _edgeLayer = [CAShapeLayer layer];
        _edgeLayer.fillColor = UIColor.clearColor.CGColor;
        _edgeLayer.strokeColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor;
        _edgeLayer.lineWidth = 0.8;
        [self.layer addSublayer:_edgeLayer];

        _items = [NSMutableArray array];
        _hoveredIndex = -1;
        self.hidden = YES;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.backgroundView.frame = self.bounds;
    [self rebuildShape];
}

/// 扇形路径：圆心 + 半径 + 张角。
- (UIBezierPath *)fanPathWithRadius:(CGFloat)radius {
    CGFloat start = -M_PI_2 - self.span / 2.0;
    CGFloat end = -M_PI_2 + self.span / 2.0;
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:self.centerPoint];
    [path addArcWithCenter:self.centerPoint radius:radius startAngle:start endAngle:end clockwise:YES];
    [path closePath];
    return path;
}

- (void)rebuildShape {
    if (self.radius <= 0) return;
    UIBezierPath *path = [self fanPathWithRadius:self.radius];
    _shapeMask.frame = self.bounds;
    _shapeMask.path = path.CGPath;
    _edgeLayer.frame = self.bounds;
    _edgeLayer.path = path.CGPath;
}

#pragma mark 排布

- (NSString *)badgeForTargets:(NSArray<POSplitTarget *> *)sameBundle index:(NSUInteger)index {
    if (sameBundle.count <= 1) return nil;
    POSplitTarget *target = sameBundle[index];
    if (target.isDefaultContainer) return @"默";
    return [NSString stringWithFormat:@"%lu", (unsigned long)index];
}

- (void)buildItems {
    for (POSplitPanelItem *item in self.items) [item removeFromSuperview];
    [self.items removeAllObjects];

    POSplitXSettings *settings = [POSplitXSettings shared];
    self.itemIconSize = settings.iconSize;
    self.itemTileSize = settings.tileSize;
    self.animationScale = MAX(0.45, MIN(2.0, 100.0 / MAX(settings.animationSpeed, 1.0)));

    NSArray<POSplitTarget *> *all = [POApplicationHelper quickSwitchTargets];
    if (all.count > PQMaxItems) all = [all subarrayWithRange:NSMakeRange(0, PQMaxItems)];
    if (all.count == 0) { self.targets = @[]; return; }

    // 同应用的分身挨在一起。
    NSMutableArray<NSString *> *groupOrder = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableArray<POSplitTarget *> *> *grouped = [NSMutableDictionary dictionary];
    for (POSplitTarget *target in all) {
        NSString *bundle = target.bundleIdentifier;
        if (!grouped[bundle]) {
            grouped[bundle] = [NSMutableArray array];
            [groupOrder addObject:bundle];
        }
        [grouped[bundle] addObject:target];
    }

    NSMutableArray<POSplitTarget *> *ordered = [NSMutableArray array];
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSMutableArray<NSString *> *badges = [NSMutableArray array];
    for (NSString *bundle in groupOrder) {
        NSArray<POSplitTarget *> *same = grouped[bundle];
        NSString *appName = [POApplicationHelper displayNameForBundleId:bundle] ?: bundle;
        for (NSUInteger i = 0; i < same.count; i++) {
            POSplitTarget *target = same[i];
            [ordered addObject:target];
            NSString *title = same.count > 1
                ? (i == 0 ? [NSString stringWithFormat:@"%@ · %@", appName, target.displayTitle] : target.displayTitle)
                : appName;
            [titles addObject:title];
            [badges addObject:[self badgeForTargets:same index:i] ?: @""];
        }
    }
    self.targets = ordered;

    // 半径：先保证相邻图标的弧距够，再受上下边缘限制。
    // PX 那样铺满一片：分三圈，越外圈放得越多，角度交错。
    CGFloat maxRadius = MIN(CGRectGetWidth(self.bounds) - self.itemTileSize - 18.0,
                            MIN(self.centerPoint.y, CGRectGetHeight(self.bounds) - self.centerPoint.y)
                                - self.itemTileSize * 0.7 - 6.0);
    maxRadius = MAX(maxRadius, 110.0);
    CGFloat innerRadius = MAX(92.0, maxRadius * 0.40);
    self.radius = maxRadius;
    self.span = (settings.fanSpan + 40.0) * M_PI / 180.0;

    // 按环容量填充：先填内环，满了才进下一环。
    NSInteger caps[4] = {settings.ring1, settings.ring2, settings.ring3, settings.ring4};
    NSMutableArray<NSNumber *> *ringOf = [NSMutableArray array];
    NSUInteger capacity = 0;
    for (int r = 0; r < 4; r++) capacity += (NSUInteger)MAX(caps[r], 0);
    if (capacity == 0) capacity = ordered.count;
    if (ordered.count > capacity) ordered = [ordered subarrayWithRange:NSMakeRange(0, capacity)];

    NSInteger ringIndex = 0;
    NSInteger usedInRing = 0;
    for (NSUInteger i = 0; i < ordered.count; i++) {
        while (ringIndex < 3 && usedInRing >= MAX(caps[ringIndex], 0)) {
            ringIndex++;
            usedInRing = 0;
        }
        [ringOf addObject:@(ringIndex)];
        usedInRing++;
    }
    [self rebuildShape];

    CGFloat direction = self.expandsRight ? 1.0 : -1.0;
    for (NSUInteger i = 0; i < ordered.count; i++) {
        NSUInteger ring = ringOf[i].unsignedIntegerValue;
        NSUInteger ringCount = 1;
        NSUInteger posInRing = 0;
        for (NSUInteger j = 0; j < ordered.count; j++) {
            if (ringOf[j].unsignedIntegerValue == ring) {
                if (j < i) posInRing++;
                ringCount++;
            }
        }
        ringCount -= 1;
        CGFloat angle = -M_PI_2;
        if (ringCount > 1) angle += -self.span / 2.0 + self.span * ((CGFloat)posInRing / (CGFloat)(ringCount - 1));
        CGFloat ringRadius = self.radius * 0.42 + (CGFloat)ring * (self.itemTileSize + settings.ringGap);

        POSplitPanelItem *item = [[POSplitPanelItem alloc] initWithTarget:ordered[i]
                                                                 iconSize:self.itemIconSize
                                                                 tileSize:self.itemTileSize
                                                                    title:titles[i]
                                                                    badge:badges[i]];
        item.angle = angle;
        item.radius = ringRadius;
        item.baseScale = 0.90 + (CGFloat)((i * 53) % 7) / 7.0 * 0.22;
        CGFloat x = self.centerPoint.x + direction * cos(angle) * ringRadius;
        CGFloat y = self.centerPoint.y + sin(angle) * ringRadius;
        if (!self.expandsRight) item.angle = M_PI - angle;
        item.center = CGPointMake(x, y);
        [item applyDimmedInitialState];
        [self addSubview:item];
        [self.items addObject:item];
    }

    PXLog(@"panel", @"fan items=%lu groups=%lu radius=%.0f span=%.0fdeg size=%@",
          (unsigned long)ordered.count, (unsigned long)groupOrder.count, self.radius,
          self.span * 180.0 / M_PI, NSStringFromCGSize(self.bounds.size));
}

/// 按角度命中：先看离圆弧近不近，再取角度最近的一项。
- (NSInteger)indexAtPoint:(CGPoint)point {
    if (self.items.count == 0) return -1;
    CGFloat dx = point.x - self.centerPoint.x;
    CGFloat dy = point.y - self.centerPoint.y;
    CGFloat distance = hypot(dx, dy);
    if (distance > self.radius + self.itemTileSize * 1.2) {
        return -1;
    }
    CGFloat angle = atan2(dy, dx);
    NSInteger best = -1;
    CGFloat bestDelta = 0.62;   // ~35°
    for (NSUInteger i = 0; i < self.items.count; i++) {
        CGFloat target = self.items[i].angle;
        CGFloat delta = fabs(atan2(sin(angle - target), cos(angle - target)));
        if (delta < bestDelta) { bestDelta = delta; best = (NSInteger)i; }
    }
    return best;
}

- (void)setHoveredIndex:(NSInteger)index {
    if (_hoveredIndex == index) return;
    _hoveredIndex = index;
    for (NSUInteger i = 0; i < self.items.count; i++) {
        self.items[i].highlighted = ((NSInteger)i == index);
    }
    if (index >= 0 && index < (NSInteger)self.targets.count) {
        [self.selectionDelegate quickSwitchTableView:self didHoverTarget:self.targets[index]];
    } else {
        [self.selectionDelegate quickSwitchTableViewDidClearHover:self];
    }
}

#pragma mark 呈现

- (BOOL)presentFromHandle:(UIView *)handle withRecognizer:(UIGestureRecognizer *)recognizer {
    UIView *coordinateView = self.superview;
    if (!coordinateView) return NO;

    if (recognizer.state == UIGestureRecognizerStateBegan || self.hidden) {
        CGRect handleFrame = [handle convertRect:handle.bounds toView:coordinateView];
        CGPoint handleCenter = CGPointMake(CGRectGetMidX(handleFrame), CGRectGetMidY(handleFrame));
        BOOL handleOnLeft = handleCenter.x <= CGRectGetMidX(coordinateView.bounds);
        self.expandsRight = handleOnLeft;

        POSplitXSettings *settings = [POSplitXSettings shared];
        CGFloat radius = settings.fanRadius;
        CGFloat tile = settings.tileSize;
        CGFloat width = radius + tile + 26.0;
        CGFloat height = 2.0 * radius + tile + 16.0;

        // 圆心放在手柄内侧边缘。
        CGFloat cx = handleOnLeft ? CGRectGetMaxX(handleFrame) : CGRectGetMinX(handleFrame);
        CGFloat cy = handleCenter.y;
        CGFloat edge = settings.panelEdgeInset;
        CGFloat x = handleOnLeft ? cx - tile / 2.0 - 14.0 + edge : cx - width + tile / 2.0 + 14.0 - edge;
        x = MIN(MAX(8.0, x), MAX(8.0, CGRectGetWidth(coordinateView.bounds) - width - 8.0));
        CGFloat y = cy - height / 2.0;
        self.frame = CGRectMake(x, y, width, height);
        self.centerPoint = CGPointMake(handleOnLeft ? tile / 2.0 + 14.0 : width - tile / 2.0 - 14.0,
                                       height / 2.0);

        [self buildItems];
        if (self.items.count == 0) return NO;
        self.hidden = NO;

        _presenting = YES;

        self.alpha = 0;
        self.layer.anchorPoint = CGPointMake(handleOnLeft ? 0 : 1, 0.5);
        self.layer.position = CGPointMake(handleOnLeft ? x : x + width, cy);
        self.transform = CGAffineTransformMakeScale(0.72, 0.72);

        [self.selectionDelegate quickSwitchTableViewWillAppear:self];
        [self setHoveredIndex:-1];

        // 图标从圆心飞出去。
        for (NSUInteger i = 0; i < self.items.count; i++) {
            POSplitPanelItem *item = self.items[i];
            CGPoint destination = item.center;
            item.center = self.centerPoint;
            item.alpha = 0;
            item.transform = CGAffineTransformMakeScale(0.3, 0.3);
            [UIView animateWithDuration:0.30
                                  delay:0.02 * i
                 usingSpringWithDamping:0.72
                  initialSpringVelocity:0.6
                                options:UIViewAnimationOptionAllowUserInteraction
                             animations:^{
                item.center = destination;
                item.alpha = 1;
                item.transform = CGAffineTransformIdentity;
            } completion:nil];
        }

        [UIView animateWithDuration:0.34 * self.animationScale delay:0 usingSpringWithDamping:0.76 initialSpringVelocity:0.5
                            options:UIViewAnimationOptionAllowUserInteraction animations:^{
            self.alpha = 1;
            self.transform = CGAffineTransformIdentity;
        } completion:nil];
        PXLog(@"panel", @"present left=%d center=%.0f,%.0f radius=%.0f", handleOnLeft,
              self.centerPoint.x, self.centerPoint.y, self.radius);
        return YES;
    }

    if (!_presenting) return NO;
    CGPoint point = [recognizer locationInView:self];

    if (recognizer.state == UIGestureRecognizerStateChanged) {
        NSInteger hit = [self indexAtPoint:point];
        if (hit != self.hoveredIndex) PXLog(@"panel", @"hover idx=%ld", (long)hit);
        [self setHoveredIndex:hit];
        return YES;
    }

    if (recognizer.state == UIGestureRecognizerStateEnded) {
        NSInteger index = [self indexAtPoint:point];
        if (index >= 0 && index < (NSInteger)self.targets.count) {
            POSplitTarget *target = self.targets[index];
            PXLog(@"panel", @"select %@", target.identityKey);
            for (NSUInteger i = 0; i < self.items.count; i++) {
                self.items[i].chosen = ((NSInteger)i == index);
                self.items[i].highlighted = NO;
            }
            [self.selectionDelegate quickSwitchTableView:self didSelectTarget:target];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.17 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self dismissImmediately]; });
        } else {
            [self dismissImmediately];
        }
        return YES;
    }

    if (recognizer.state == UIGestureRecognizerStateCancelled ||
        recognizer.state == UIGestureRecognizerStateFailed) {
        [self dismissImmediately];
        return YES;
    }
    return YES;
}

- (void)dismissImmediately {
    if (!_presenting) return;
    PXLog(@"panel", @"dismiss hovered=%ld", (long)_hoveredIndex);
    _presenting = NO;
    _hoveredIndex = -1;
    [UIView animateWithDuration:0.16 * self.animationScale animations:^{
        self.alpha = 0;
        self.transform = CGAffineTransformMakeScale(0.9, 0.9);
    } completion:^(BOOL finished) {
        self.hidden = YES;
        self.transform = CGAffineTransformIdentity;
        for (POSplitPanelItem *item in self.items) { item.chosen = NO; }
    }];
    [self.selectionDelegate quickSwitchTableViewDidDisappear:self];
}

- (void)quickSwitchTableView:(UIView<POQuickSwitchMenuPresenting> *)menu
    draggingDidChangeForQuickSwitchItem:(id)item
                             withPoint:(CGPoint)point {}
- (void)quickSwitchTableView:(UIView<POQuickSwitchMenuPresenting> *)menu
                   didDropApp:(SBApplication *)app
                     atPoint:(CGPoint)point {}
- (void)draggingDidEnterBoundsOfQuickSwitchTableView:(UIView<POQuickSwitchMenuPresenting> *)menu {}

- (void)refreshLayoutDirection {
    if (_presenting) [self buildItems];
}

@end
