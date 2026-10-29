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
                         badge:(NSString *)badge
                        square:(BOOL)square;
- (void)applyDimmedInitialState;
@end

@implementation POSplitPanelItem

- (instancetype)initWithTarget:(POSplitTarget *)target
                      iconSize:(CGFloat)iconSize
                      tileSize:(CGFloat)tileSize
                         title:(NSString *)title
                         badge:(NSString *)badge
                        square:(BOOL)square {
    // PX 那种：白色圆托 + 圆角图标，没有文字。
    CGFloat tile = tileSize;
    CGFloat icon = iconSize;
    CGFloat width = tile + 6.0;
    if ((self = [super initWithFrame:CGRectMake(0, 0, width, width)])) {
        _target = target;
        self.backgroundColor = UIColor.clearColor;

        UIView *bubble = [[UIView alloc] initWithFrame:CGRectMake(3, 3, tile, tile)];
        bubble.backgroundColor = [UIColor colorWithWhite:0.98 alpha:0.92];
        bubble.layer.cornerRadius = square ? tile * 0.30 : tile / 2.0;
        bubble.layer.borderWidth = 0.5;
        bubble.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.10].CGColor;
        bubble.layer.shadowColor = UIColor.blackColor.CGColor;
        bubble.layer.shadowOpacity = 0.10;
        bubble.layer.shadowRadius = 4;
        bubble.layer.shadowOffset = CGSizeMake(0, 1);
        bubble.userInteractionEnabled = NO;
        [self addSubview:bubble];
        _tileView = bubble;

        CGFloat inset = MAX(2.0, icon * 0.05);
        _iconView = [[UIImageView alloc] initWithFrame:CGRectInset(bubble.frame, inset, inset)];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.layer.cornerRadius = square ? icon * 0.22 : icon * 0.50;
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
    if (_chosen) { scale = _baseScale * 1.38; alpha = 1.0; lift = 12.0; }
    else if (_highlighted) { scale = _baseScale * 1.20; alpha = 1.0; lift = 8.0; }

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
@property (nonatomic, strong) UISelectionFeedbackGenerator *hoverHaptics;
@property (nonatomic, strong) UIImpactFeedbackGenerator *confirmHaptics;
@property (nonatomic, assign) BOOL hapticsEnabled;
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
        _hoverHaptics = [[UISelectionFeedbackGenerator alloc] init];
        _confirmHaptics = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
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
    CGFloat centerAngle = self.expandsRight ? 0.0 : M_PI;
    CGFloat start = centerAngle - self.span / 2.0;
    CGFloat end = centerAngle + self.span / 2.0;
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
    self.hapticsEnabled = settings.hapticFeedback;

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

    // 半径以设置为准；放不下就减少环数，宁少勿叠。
    CGFloat ringUnit = self.itemTileSize * 1.15 + settings.ringGap;
    CGFloat usableRadius = MAX(120.0, self.radius);
    CGFloat innerRadius = MIN(usableRadius * 0.5, 96.0);
    NSInteger maxRings = (NSInteger)floor((usableRadius - innerRadius) / MAX(ringUnit, 1.0)) + 1;
    maxRings = MIN(MAX(maxRings, 1), 4);
    self.span = MIN((settings.fanSpan + 40.0) * M_PI / 180.0, 200.0 * M_PI / 180.0);

    NSInteger caps[4] = {settings.ring1, settings.ring2, settings.ring3, settings.ring4};
    if (caps[0] + caps[1] + caps[2] + caps[3] <= 0) {
        // 全调成 0 时不能把所有图标塞在圆心，回到默认环容量。
        caps[0] = 7; caps[1] = 10; caps[2] = 13; caps[3] = 16;
        PXLogW(@"panel", @"环容量全为 0，使用默认 7/10/13/16");
    }
    NSUInteger capacity = 0;
    for (int r = 0; r < maxRings; r++) capacity += (NSUInteger)MAX(caps[r], 0);
    if (capacity == 0) capacity = ordered.count;
    NSUInteger beforeTrim = ordered.count;
    if (ordered.count > capacity) ordered = [ordered subarrayWithRange:NSMakeRange(0, capacity)];
    PXLog(@"panel", @"layout items=%lu->%lu groups=%lu rings=%ld unit=%.1f inner=%.1f radius=%.1f span=%.0f caps=%ld,%ld,%ld,%ld gap=%.1f tile=%.1f icon=%.1f anchor=%.1f,%.1f size=%@",
          (unsigned long)beforeTrim, (unsigned long)ordered.count, (unsigned long)groupOrder.count,
          (long)maxRings, ringUnit, innerRadius, self.radius, self.span * 180.0 / M_PI,
          (long)caps[0], (long)caps[1], (long)caps[2], (long)caps[3], settings.ringGap,
          self.itemTileSize, self.itemIconSize, self.centerPoint.x, self.centerPoint.y,
          NSStringFromCGSize(self.bounds.size));

    NSMutableArray<NSNumber *> *ringOf = [NSMutableArray array];
    NSInteger ringIndex = 0;
    NSInteger usedInRing = 0;
    for (NSUInteger i = 0; i < ordered.count; i++) {
        while (ringIndex < maxRings - 1 && usedInRing >= MAX(caps[ringIndex], 0)) {
            ringIndex++;
            usedInRing = 0;
        }
        [ringOf addObject:@(ringIndex)];
        usedInRing++;
    }
    [self rebuildShape];

    CGFloat centerAngle = self.expandsRight ? 0.0 : M_PI;   // 永远朝屏幕内侧张开
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
        CGFloat angle = centerAngle;
        if (ringCount > 1) angle += -self.span / 2.0 + self.span * ((CGFloat)posInRing / (CGFloat)(ringCount - 1));
        CGFloat ringRadius = MIN(self.radius, innerRadius + (CGFloat)ring * ringUnit);

        POSplitPanelItem *item = [[POSplitPanelItem alloc] initWithTarget:ordered[i]
                                                                 iconSize:self.itemIconSize
                                                                 tileSize:self.itemTileSize
                                                                    title:titles[i]
                                                                    badge:badges[i]
                                                                   square:settings.squareIcons];
        item.angle = angle;
        item.radius = ringRadius;
        item.baseScale = 0.99 + (CGFloat)((i * 53) % 5) / 5.0 * 0.06;
        CGFloat x = self.centerPoint.x + cos(angle) * ringRadius;
        CGFloat y = self.centerPoint.y + sin(angle) * ringRadius;
        item.center = CGPointMake(x, y);
        [item applyDimmedInitialState];
        [self addSubview:item];
        [self.items addObject:item];
        PXLog(@"panel", @"item %lu/%lu ring=%lu angle=%.0f r=%.0f center=%.0f,%.0f scale=%.2f target=%@",
              (unsigned long)(i + 1), (unsigned long)ordered.count, (unsigned long)ring,
              angle * 180.0 / M_PI, ringRadius, x, y, item.baseScale, ordered[i].identityKey);
    }

    PXLog(@"panel", @"fan ready items=%lu radius=%.0f", (unsigned long)ordered.count, self.radius);
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
    CGFloat bestScore = 1.0;
    NSInteger nearest = -1;
    CGFloat nearestScore = 9.0;
    for (NSUInteger i = 0; i < self.items.count; i++) {
        POSplitPanelItem *item = self.items[i];
        CGFloat target = item.angle;
        CGFloat delta = fabs(atan2(sin(angle - target), cos(angle - target)));
        if (delta > 0.55) continue;                                  // 角度差太大
        CGFloat radial = fabs(distance - item.radius) / self.itemTileSize;
        if (radial > 1.1) continue;                                  // 不在同一环
        CGFloat score = delta / 0.55 * 0.7 + radial / 1.1 * 0.3;
        if (score < nearestScore) { nearestScore = score; nearest = (NSInteger)i; }
        if (score < bestScore) { bestScore = score; best = (NSInteger)i; }
    }
    PXLog(@"panel", @"hit pt=%.0f,%.0f dist=%.0f angle=%.0fdeg -> %ld candidate=%ld score=%.2f items=%lu",
           point.x, point.y, distance, angle * 180.0 / M_PI, (long)best, (long)nearest, nearestScore,
           (unsigned long)self.items.count);
    if (best >= 0) {
        POSplitTarget *target = self.targets[(NSUInteger)best];
        PXLog(@"panel", @"hit target=%@ itemCenter=%.0f,%.0f itemRadius=%.0f itemAngle=%.0f",
              target.identityKey, self.items[(NSUInteger)best].center.x,
              self.items[(NSUInteger)best].center.y, self.items[(NSUInteger)best].radius,
              self.items[(NSUInteger)best].angle * 180.0 / M_PI);
    }
    return best;
}

- (void)setHoveredIndex:(NSInteger)index {
    if (_hoveredIndex == index) return;
    _hoveredIndex = index;
    for (NSUInteger i = 0; i < self.items.count; i++) {
        self.items[i].highlighted = ((NSInteger)i == index);
    }
    if (self.hapticsEnabled && index >= 0 && index < (NSInteger)self.targets.count) {
        [self.hoverHaptics selectionChanged];
        [self.hoverHaptics prepare];
    }
    if (index >= 0 && index < (NSInteger)self.targets.count) {
        PXLog(@"panel", @"hover idx=%ld target=%@", (long)index, self.targets[(NSUInteger)index].identityKey);
        [self.selectionDelegate quickSwitchTableView:self didHoverTarget:self.targets[index]];
    } else {
        PXLog(@"panel", @"hover clear idx=%ld", (long)index);
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
        CGFloat tile = settings.tileSize;
        // 先按屏幕到手的距离定半径，不要用还没定的 view 高度反推。
        CGFloat screenHeight = CGRectGetHeight(coordinateView.bounds);
        CGFloat room = MIN(handleCenter.y, screenHeight - handleCenter.y) - 16.0;
        CGFloat radius = MAX(90.0, MIN(settings.fanRadius, room));
        self.radius = radius;
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

        // 半径是建完才算准的，按它重设高度，别让最外环顶出屏幕。
        CGFloat realHeight = MIN(CGRectGetHeight(coordinateView.bounds) - 16.0,
                                 2.0 * self.radius + self.itemTileSize + 16.0);
        self.frame = CGRectMake(CGRectGetMinX(self.frame), cy - realHeight / 2.0,
                                CGRectGetWidth(self.frame), realHeight);

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
        PXLog(@"panel", @"present left=%d center=%.0f,%.0f radius=%.0f height=%.0f", handleOnLeft,
              self.centerPoint.x, self.centerPoint.y, self.radius, CGRectGetHeight(self.frame));
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
        if (self.hapticsEnabled && index >= 0 && index < (NSInteger)self.targets.count) {
        [self.hoverHaptics selectionChanged];
        [self.hoverHaptics prepare];
    }
    if (index >= 0 && index < (NSInteger)self.targets.count) {
            POSplitTarget *target = self.targets[index];
            PXLog(@"panel", @"select %@", target.identityKey);
            if (self.hapticsEnabled) [self.confirmHaptics impactOccurred];
            for (NSUInteger i = 0; i < self.items.count; i++) {
                self.items[i].chosen = ((NSInteger)i == index);
                self.items[i].highlighted = NO;
            }
            [self.selectionDelegate quickSwitchTableView:self didSelectTarget:target];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.17 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self dismissImmediately]; });
        } else {
            PXLog(@"panel", @"select miss pt=%.0f,%.0f hovered=%ld items=%lu",
                  point.x, point.y, (long)self.hoveredIndex, (unsigned long)self.items.count);
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
    for (POSplitPanelItem *item in self.items) {
        [UIView animateWithDuration:0.18 * self.animationScale delay:0
             usingSpringWithDamping:0.9 initialSpringVelocity:0.2
                            options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            item.center = self.centerPoint;
            item.alpha = 0;
            item.transform = CGAffineTransformMakeScale(0.4, 0.4);
        } completion:nil];
    }
    [UIView animateWithDuration:0.20 * self.animationScale animations:^{
        self.alpha = 0;
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
