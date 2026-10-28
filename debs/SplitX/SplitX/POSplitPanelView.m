//
//  POSplitPanelView.m
//  SplitX
//
//  形态照 ParallelX：半圆手柄拖出后，弹出一整块磨砂玻璃，图标在玻璃里
//  沿弧线散开，越远越斜；悬停项浮起放大、其余压暗；松手选中项先弹一下再收。
//
//  面板参数全部来自 POSplitXSettings，不写死。
//

#import "POSplitXLog.h"
#import "POSplitXSettings.h"
#import "POSplitPanelView.h"
#import "POSplitTarget.h"
#import "POApplicationHelper.h"
#import "POQuickSwitchMetrics.h"
#import <math.h>

static const CGFloat PQHitRadius = 48.0;
static const NSUInteger PQMaxItems = 12;

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
@property (nonatomic, assign) CGFloat baseRotation;
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
    CGFloat width = MAX(tileSize, iconSize) + 12.0;
    CGFloat height = tileSize + 20.0;
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

        _label = [[UILabel alloc] initWithFrame:CGRectMake(0, CGRectGetMaxY(_tileView.frame) + 3, width, 13)];
        _label.text = title;
        _label.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        _label.textColor = UIColor.whiteColor;
        _label.textAlignment = NSTextAlignmentCenter;
        _label.adjustsFontSizeToFitWidth = YES;
        _label.minimumScaleFactor = 0.7;
        _label.layer.shadowColor = UIColor.blackColor.CGColor;
        _label.layer.shadowOpacity = 0.5;
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

- (void)setBaseRotation:(CGFloat)baseRotation {
    _baseRotation = baseRotation;
    self.transform = CGAffineTransformMakeRotation(baseRotation);
}

/// 悬停：1.14 放大 + 满亮度 + 轻微上浮；其余 0.42 压暗。
- (void)setHighlighted:(BOOL)highlighted {
    if (_highlighted == highlighted) return;
    _highlighted = highlighted;
    [self applyVisualStateAnimated:YES];
}

- (void)setChosen:(BOOL)chosen {
    _chosen = chosen;
    [self applyVisualStateAnimated:YES];
}

/// 入场初始态：未悬停，统一压暗。
- (void)applyDimmedInitialState {
    _highlighted = NO;
    _chosen = NO;
    [self applyVisualStateAnimated:NO];
}

- (void)applyVisualStateAnimated:(BOOL)animated {
    CGFloat scale = 1.0;
    CGFloat alpha = 0.42;
    CGFloat lift = 0.0;
    if (_chosen) {
        scale = 1.22;
        alpha = 1.0;
        lift = -3.0;
    } else if (_highlighted) {
        scale = 1.14;
        alpha = 1.0;
        lift = -2.0;
    }
    void (^apply)(void) = ^{
        self.tileView.alpha = alpha;
        self.label.alpha = alpha;
        self.badge.alpha = alpha;
        CGAffineTransform t = CGAffineTransformMakeRotation(self.baseRotation);
        t = CGAffineTransformScale(t, scale, scale);
        self.transform = CGAffineTransformTranslate(t, 0, lift);
        self.layer.shadowOpacity = (alpha > 0.9) ? 0.42 : 0.0;
    };
    if (!animated) { apply(); return; }
    [UIView animateWithDuration:_chosen ? 0.20 : 0.14
                          delay:0
         usingSpringWithDamping:0.72
          initialSpringVelocity:0.35
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:apply
                     completion:nil];
}

@end

#pragma mark - 面板

@interface POSplitPanelView ()
@property (nonatomic, strong) UIVisualEffectView *backgroundView;
@property (nonatomic, strong) NSMutableArray<POSplitPanelItem *> *items;
@property (nonatomic, strong) NSArray<POSplitTarget *> *targets;
@property (nonatomic, assign) NSInteger hoveredIndex;
@property (nonatomic, assign) BOOL presenting;
@property (nonatomic, assign) CGPoint revealOrigin;
@property (nonatomic, assign) CGFloat iconSize;
@property (nonatomic, assign) CGFloat tileSize;
@property (nonatomic, assign) CGFloat spacing;
@property (nonatomic, assign) CGFloat radius;
@property (nonatomic, assign) CGFloat panelAlphaValue;
@property (nonatomic, assign) NSInteger columns;
- (void)reloadMetrics;
- (void)buildItems;
- (void)applyRevealForPoint:(CGPoint)point;
@end

@implementation POSplitPanelView

- (instancetype)init {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.backgroundColor = UIColor.clearColor;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.34;
        self.layer.shadowRadius = 16;
        self.layer.shadowOffset = CGSizeZero;

        _backgroundView = [[UIVisualEffectView alloc] initWithEffect:
            [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialLight]];
        _backgroundView.layer.cornerCurve = kCACornerCurveContinuous;
        _backgroundView.layer.masksToBounds = YES;
        _backgroundView.layer.borderWidth = 0.5;
        _backgroundView.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.24].CGColor;
        _backgroundView.userInteractionEnabled = NO;
        [self addSubview:_backgroundView];

        _items = [NSMutableArray array];
        _hoveredIndex = -1;
        self.hidden = YES;
        [self reloadMetrics];
    }
    return self;
}

- (void)reloadMetrics {
    POSplitXSettings *settings = [POSplitXSettings shared];
    _iconSize = settings.iconSize;
    _tileSize = settings.tileSize;
    _spacing = settings.itemSpacing;
    _radius = settings.panelRadius;
    _panelAlphaValue = settings.panelAlpha;
    _columns = MAX(1, MIN(3, settings.panelColumns));
    _backgroundView.layer.cornerRadius = _radius;
    _backgroundView.alpha = _panelAlphaValue;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.backgroundView.frame = self.bounds;
}

#pragma mark - 排布

/// 组内序号角标：默认 = 默，分身 = 1、2…；同应用只有一项时不带角标。
- (NSString *)badgeForTargets:(NSArray<POSplitTarget *> *)sameBundle index:(NSUInteger)index {
    if (sameBundle.count <= 1) return nil;
    POSplitTarget *target = sameBundle[index];
    if (target.isDefaultContainer) return @"默";
    return [NSString stringWithFormat:@"%lu", (unsigned long)index];
}

- (void)buildItems {
    for (POSplitPanelItem *item in self.items) [item removeFromSuperview];
    [self.items removeAllObjects];
    [self reloadMetrics];

    NSArray<POSplitTarget *> *all = [POApplicationHelper quickSwitchTargets];
    if (all.count > PQMaxItems) all = [all subarrayWithRange:NSMakeRange(0, PQMaxItems)];

    // 同一应用的分身挨在一起，显示名以第一项带应用名。
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
            NSString *title = appName;
            if (same.count > 1) {
                title = (i == 0) ? [NSString stringWithFormat:@"%@ · %@", appName, target.displayTitle]
                                 : target.displayTitle;
            }
            [titles addObject:title];
            [badges addObject:[self badgeForTargets:same index:i] ?: @""];
        }
    }
    self.targets = ordered;

    CGFloat itemWidth = MAX(_tileSize, _iconSize) + 12.0;
    CGFloat itemHeight = _tileSize + 20.0;
    CGFloat stride = _tileSize + _spacing;
    NSUInteger rows = (NSUInteger)ceil((double)ordered.count / (double)_columns);
    CGFloat pad = 10.0;
    CGFloat stagger = MAX(6.0, itemWidth * 0.18);

    self.bounds = CGRectMake(0, 0,
                             itemWidth * _columns + pad * 2 + stagger * MAX(1, rows - 1),
                             MAX(itemHeight, rows * stride) + pad * 2);

    [ordered enumerateObjectsUsingBlock:^(POSplitTarget *target, NSUInteger index, BOOL *stop) {
        NSUInteger column = index % self->_columns;
        NSUInteger row = index / self->_columns;
        POSplitPanelItem *item = [[POSplitPanelItem alloc] initWithTarget:target
                                                                 iconSize:self->_iconSize
                                                                 tileSize:self->_tileSize
                                                                    title:titles[index]
                                                                    badge:badges[index]];
        // 越往外越斜，形成 PX 那种散开的弧；左右由 expandsRight 决定方向。
        CGFloat rotation = (3.0 + (CGFloat)row * 0.8) * (self->_columns > 1 ? (CGFloat)column : 1.0);
        if (!self.expandsRight) rotation = -rotation;

        CGFloat x = pad + column * itemWidth + (self.expandsRight ? row * stagger : -row * stagger);
        CGFloat y = pad + row * stride + (column == 1 ? 6.0 : 0.0);
        // 组与组之间留一点空隙：容器切换的那一项之后断开。
        item.frame = CGRectMake(x + (column ? 4.0 : 0), y, itemWidth, itemHeight);
        item.baseRotation = rotation * M_PI / 180.0;
        [item applyDimmedInitialState];
        [self addSubview:item];
        [self.items addObject:item];
    }];
    PXLog(@"panel", @"build items=%lu groups=%lu columns=%ld size=%@",
          (unsigned long)ordered.count, (unsigned long)groupOrder.count, (long)_columns,
          NSStringFromCGSize(self.bounds.size));
}

- (NSInteger)indexAtPoint:(CGPoint)point {
    NSInteger best = -1;
    CGFloat bestDistance = PQHitRadius;
    for (NSUInteger i = 0; i < self.items.count; i++) {
        POSplitPanelItem *item = self.items[i];
        CGPoint c = CGPointMake(CGRectGetMidX(item.frame), CGRectGetMidY(item.frame));
        CGFloat d = hypot(point.x - c.x, point.y - c.y);
        if (d < bestDistance) { bestDistance = d; best = (NSInteger)i; }
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

#pragma mark - 呈现

- (BOOL)presentFromHandle:(UIView *)handle withRecognizer:(UIGestureRecognizer *)recognizer {
    UIView *coordinateView = self.superview;
    if (!coordinateView) return NO;

    if (recognizer.state == UIGestureRecognizerStateBegan) {
        CGRect handleFrame = [handle convertRect:handle.bounds toView:coordinateView];
        CGPoint center = CGPointMake(CGRectGetMidX(handleFrame), CGRectGetMidY(handleFrame));
        // 手柄在左就往右长，在右就往左长。
        BOOL handleOnLeft = center.x <= CGRectGetMidX(coordinateView.bounds);
        self.expandsRight = handleOnLeft;

        [self buildItems];
        if (self.items.count == 0) return NO;

        CGSize size = self.bounds.size;
        CGFloat x = handleOnLeft ? CGRectGetMaxX(handleFrame) + 6
                                 : CGRectGetMinX(handleFrame) - size.width - 6;
        CGFloat y = center.y - size.height / 2;
        y = MAX(8, MIN(y, CGRectGetHeight(coordinateView.bounds) - size.height - 8));
        self.frame = CGRectMake(x, y, size.width, size.height);

        self.layer.anchorPoint = CGPointMake(handleOnLeft ? 0 : 1, 0.5);
        self.layer.position = CGPointMake(handleOnLeft ? x : x + size.width, center.y);
        PXLog(@"panel", @"present items=%lu left=%d frame=%@ anchor=%.0f",
              (unsigned long)self.items.count, handleOnLeft, NSStringFromCGRect(self.frame),
              self.layer.anchorPoint.x);

        self.hidden = NO;
        self.alpha = 0;
        self.transform = CGAffineTransformMakeScale(0.88, 0.92);
        _presenting = YES;
        _revealOrigin = center;
        [self applyRevealForPoint:[recognizer locationInView:coordinateView]];
        [self.selectionDelegate quickSwitchTableViewWillAppear:self];
        [self setHoveredIndex:-1];
        [UIView animateWithDuration:0.34 delay:0 usingSpringWithDamping:0.74 initialSpringVelocity:0.55
                            options:UIViewAnimationOptionAllowUserInteraction animations:^{
            self.alpha = 1;
            self.transform = CGAffineTransformIdentity;
        } completion:nil];
        return YES;
    }

    if (!_presenting) return NO;
    CGPoint point = [recognizer locationInView:self];
    CGPoint touchInHost = [recognizer locationInView:coordinateView];

    if (recognizer.state == UIGestureRecognizerStateChanged) {
        // 手指还在手柄附近时只跟着“长出来”，进入面板后再判定悬停
        if (!CGRectContainsPoint(self.frame, touchInHost)) {
            [self applyRevealForPoint:touchInHost];
            return YES;
        }
        NSInteger hit = [self indexAtPoint:point];
        if (hit != self.hoveredIndex) PXLog(@"panel", @"hover idx=%ld pt=%@", (long)hit, NSStringFromCGPoint(point));
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
            // 让选中项先弹一下，再收面板。
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
    [UIView animateWithDuration:0.18 animations:^{
        self.alpha = 0;
        self.transform = CGAffineTransformMakeScale(0.94, 0.94);
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

- (void)applyRevealForPoint:(CGPoint)point {
    CGFloat distance = hypot(point.x - self.revealOrigin.x, point.y - self.revealOrigin.y);
    CGFloat progress = MIN(1.0, MAX(0.15, distance / 90.0));
    self.alpha = progress;
    CGFloat scale = 0.88 + 0.12 * progress;
    self.transform = CGAffineTransformMakeScale(scale, scale);
}

- (void)refreshLayoutDirection {
    if (_presenting) [self buildItems];
}

@end
