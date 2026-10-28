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

static const NSUInteger PQMaxItems = 12;
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
    CGFloat width = MAX(tileSize, iconSize) + 10.0;
    CGFloat height = tileSize + 18.0;
    if ((self = [super initWithFrame:CGRectMake(0, 0, width, height)])) {
        _target = target;

        UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialLight];
        _tileView = [[UIVisualEffectView alloc] initWithEffect:effect];
        _tileView.frame = CGRectMake((width - tileSize) / 2, 0, tileSize, tileSize);
        _tileView.layer.cornerRadius = tileSize * 0.30;
        _tileView.layer.cornerCurve = kCACornerCurveContinuous;
        _tileView.layer.borderWidth = 0.5;
        _tileView.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.30].CGColor;
        _tileView.clipsToBounds = YES;
        _tileView.userInteractionEnabled = NO;
        [self addSubview:_tileView];

        _iconView = [[UIImageView alloc] initWithFrame:CGRectInset(_tileView.frame, 5, 5)];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.image = [POApplicationHelper imageForBundleId:target.bundleIdentifier];
        [self addSubview:_iconView];

        _label = [[UILabel alloc] initWithFrame:CGRectMake(0, CGRectGetMaxY(_tileView.frame) + 2, width, 13)];
        _label.text = title;
        _label.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        _label.textColor = UIColor.whiteColor;
        _label.textAlignment = NSTextAlignmentCenter;
        _label.adjustsFontSizeToFitWidth = YES;
        _label.minimumScaleFactor = 0.7;
        _label.layer.shadowColor = UIColor.blackColor.CGColor;
        _label.layer.shadowOpacity = 0.55;
        _label.layer.shadowRadius = 2;
        _label.layer.shadowOffset = CGSizeMake(0, 1);
        [self addSubview:_label];

        if (badge.length) {
            CGFloat badgeWidth = MAX(18.0, 12.0 + badge.length * 7.0);
            _badge = [[UIView alloc] initWithFrame:CGRectMake(CGRectGetMaxX(_tileView.frame) - badgeWidth + 4,
                                                              2, badgeWidth, 16)];
            _badge.backgroundColor = [UIColor colorWithWhite:0 alpha:0.62];
            _badge.layer.cornerRadius = 8;
            _badge.userInteractionEnabled = NO;
            [self addSubview:_badge];
            _badgeLabel = [[UILabel alloc] initWithFrame:_badge.bounds];
            _badgeLabel.text = badge;
            _badgeLabel.font = [UIFont systemFontOfSize:9 weight:UIFontWeightBold];
            _badgeLabel.textColor = UIColor.whiteColor;
            _badgeLabel.textAlignment = NSTextAlignmentCenter;
            [_badge addSubview:_badgeLabel];
        }
    }
    return self;
}

/// 入场初态：未悬停，压暗。
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
    CGFloat scale = 1.0;
    CGFloat alpha = 0.42;
    CGFloat lift = 0.0;
    if (_chosen) {
        scale = 1.22;
        alpha = 1.0;
        lift = 8.0;
    } else if (_highlighted) {
        scale = 1.16;
        alpha = 1.0;
        lift = 6.0;
    }
    void (^apply)(void) = ^{
        self.tileView.alpha = alpha;
        self.label.alpha = alpha;
        self.badge.alpha = alpha;
        CGAffineTransform t = CGAffineTransformMakeScale(scale, scale);
        self.transform = CGAffineTransformTranslate(t, cos(self.angle) * lift, sin(self.angle) * lift);
        self.layer.shadowOpacity = (alpha > 0.9) ? 0.42 : 0.0;
    };
    if (!animated) { apply(); return; }
    [UIView animateWithDuration:_chosen ? 0.20 : 0.14
                          delay:0
         usingSpringWithDamping:0.70
          initialSpringVelocity:0.4
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:apply
                     completion:nil];
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
@property (nonatomic, assign) CGFloat itemTileSize;
@property (nonatomic, assign) CGFloat itemIconSize;
@property (nonatomic, assign) CGFloat span;          // 弧度
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

    // 半径：不能超出上下边缘。
    CGFloat verticalRoom = MIN(self.centerPoint.y, CGRectGetHeight(self.bounds) - self.centerPoint.y);
    CGFloat usable = MAX(70.0, verticalRoom - self.itemTileSize / 2.0 - 8.0);
    self.radius = MIN(settings.fanRadius, usable);

    CGFloat spanDegrees = settings.fanSpan * M_PI / 180.0;
    CGFloat step = ordered.count > 1 ? spanDegrees / (CGFloat)(ordered.count - 1) : 0;
    step = MIN(MAX(step, PQMinAngleStep), PQMaxAngleStep);
    self.span = ordered.count > 1 ? step * (CGFloat)(ordered.count - 1) : 0;
    [self rebuildShape];

    CGFloat direction = self.expandsRight ? 1.0 : -1.0;
    for (NSUInteger i = 0; i < ordered.count; i++) {
        CGFloat angle = -M_PI_2 - self.span / 2.0 + step * (CGFloat)i;
        POSplitPanelItem *item = [[POSplitPanelItem alloc] initWithTarget:ordered[i]
                                                                 iconSize:self.itemIconSize
                                                                 tileSize:self.itemTileSize
                                                                    title:titles[i]
                                                                    badge:badges[i]];
        item.angle = angle;
        item.radius = self.radius;
        CGFloat x = self.centerPoint.x + direction * cos(angle) * self.radius;
        CGFloat y = self.centerPoint.y + sin(angle) * self.radius;
        if (!self.expandsRight) item.angle = M_PI - angle;   // 向左时镜像
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
    if (distance < self.radius - self.itemTileSize * 0.85 ||
        distance > self.radius + self.itemTileSize * 0.85) {
        return -1;
    }
    CGFloat angle = atan2(dy, dx);
    NSInteger best = -1;
    CGFloat bestDelta = 1.4;   // ~80°
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

    if (recognizer.state == UIGestureRecognizerStateBegan) {
        CGRect handleFrame = [handle convertRect:handle.bounds toView:coordinateView];
        CGPoint handleCenter = CGPointMake(CGRectGetMidX(handleFrame), CGRectGetMidY(handleFrame));
        BOOL handleOnLeft = handleCenter.x <= CGRectGetMidX(coordinateView.bounds);
        self.expandsRight = handleOnLeft;

        POSplitXSettings *settings = [POSplitXSettings shared];
        CGFloat radius = settings.fanRadius;
        CGFloat tile = settings.tileSize;
        CGFloat width = radius + tile + 16.0;
        CGFloat height = 2.0 * radius + tile + 16.0;

        // 圆心放在手柄内侧边缘。
        CGFloat cx = handleOnLeft ? CGRectGetMaxX(handleFrame) : CGRectGetMinX(handleFrame);
        CGFloat cy = handleCenter.y;
        CGFloat x = handleOnLeft ? cx - tile / 2.0 - 8.0 : cx - width + tile / 2.0 + 8.0;
        CGFloat y = cy - height / 2.0;
        self.frame = CGRectMake(x, y, width, height);
        self.centerPoint = CGPointMake(handleOnLeft ? tile / 2.0 + 8.0 : width - tile / 2.0 - 8.0,
                                       height / 2.0);

        [self buildItems];
        if (self.items.count == 0) return NO;

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

        [UIView animateWithDuration:0.34 delay:0 usingSpringWithDamping:0.76 initialSpringVelocity:0.5
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
    [UIView animateWithDuration:0.16 animations:^{
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
