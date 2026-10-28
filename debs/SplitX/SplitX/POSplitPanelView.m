//
//  POSplitPanelView.m
//  SplitX
//
//  形态照 ParallelX：半圆手柄拖出后，弹出一整块磨砂玻璃，图标在玻璃里
//  按斜向两列铺开（不是竖表），选中项浮起高亮。
//

#import "POSplitPanelView.h"
#import "POSplitTarget.h"
#import "POApplicationHelper.h"
#import "POQuickSwitchMetrics.h"

static const CGFloat PQItemWidth = 78.0;
static const CGFloat PQItemHeight = 82.0;
static const CGFloat PQStagger = 12.0;
static const CGFloat PQPanelRadius = 30.0;
static const CGFloat PQHitRadius = 46.0;
static const NSUInteger PQMaxItems = 10;

@interface POSplitPanelItem : UIView
@property (nonatomic, strong) POSplitTarget *target;
@property (nonatomic, strong) UIView *tileView;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) UIView *badge;
@property (nonatomic, strong) UILabel *badgeLabel;
@property (nonatomic, assign) BOOL highlighted;
@end

@implementation POSplitPanelItem

- (instancetype)initWithTarget:(POSplitTarget *)target {
    if ((self = [super initWithFrame:CGRectMake(0, 0, PQItemWidth, PQItemHeight)])) {
        _target = target;
        UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialLight];
        _tileView = [[UIVisualEffectView alloc] initWithEffect:effect];
        _tileView.frame = CGRectMake((PQItemWidth - 62) / 2, 2, 62, 62);
        _tileView.layer.cornerRadius = 19;
        _tileView.layer.cornerCurve = kCACornerCurveContinuous;
        _tileView.clipsToBounds = YES;
        _tileView.userInteractionEnabled = NO;
        [self addSubview:_tileView];

        _iconView = [[UIImageView alloc] initWithFrame:CGRectMake((PQItemWidth - 50) / 2, 8, 50, 50)];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.image = [POApplicationHelper imageForBundleId:target.bundleIdentifier];
        [self addSubview:_iconView];

        _label = [[UILabel alloc] initWithFrame:CGRectMake(0, 66, PQItemWidth, 14)];
        _label.text = target.isDefaultContainer ? @"默认" : target.containerDisplayName;
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

        _badge = [[UIView alloc] initWithFrame:CGRectMake(CGRectGetMaxX(_tileView.frame) - 16, 4, 18, 16)];
        _badge.backgroundColor = [UIColor colorWithWhite:0 alpha:0.62];
        _badge.layer.cornerRadius = 8;
        _badge.userInteractionEnabled = NO;
        [self addSubview:_badge];
        _badgeLabel = [[UILabel alloc] initWithFrame:_badge.bounds];
        _badgeLabel.text = target.isDefaultContainer ? @"默" : @"分";
        _badgeLabel.font = [UIFont systemFontOfSize:9 weight:UIFontWeightBold];
        _badgeLabel.textColor = UIColor.whiteColor;
        _badgeLabel.textAlignment = NSTextAlignmentCenter;
        [_badge addSubview:_badgeLabel];
    }
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    _highlighted = highlighted;
    [UIView animateWithDuration:0.14 animations:^{
        self.tileView.alpha = highlighted ? 1.0 : 0.55;
        self.transform = highlighted ? CGAffineTransformMakeScale(1.06, 1.06)
                                     : CGAffineTransformIdentity;
    }];
}

@end

@interface POSplitPanelView ()
@property (nonatomic, strong) UIVisualEffectView *backgroundView;
@property (nonatomic, strong) NSMutableArray<POSplitPanelItem *> *items;
@property (nonatomic, strong) NSArray<POSplitTarget *> *targets;
@property (nonatomic, assign) NSInteger hoveredIndex;
@property (nonatomic, assign) BOOL presenting;
@end

@implementation POSplitPanelView

- (instancetype)init {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.backgroundColor = UIColor.clearColor;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.34;
        self.layer.shadowRadius = 14;
        self.layer.shadowOffset = CGSizeZero;

        _backgroundView = [[UIVisualEffectView alloc] initWithEffect:
            [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialLight]];
        _backgroundView.layer.cornerRadius = PQPanelRadius;
        _backgroundView.layer.cornerCurve = kCACornerCurveContinuous;
        _backgroundView.layer.masksToBounds = YES;
        _backgroundView.userInteractionEnabled = NO;
        [self addSubview:_backgroundView];

        _items = [NSMutableArray array];
        _hoveredIndex = -1;
        self.hidden = YES;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.backgroundView.frame = self.bounds;
}

#pragma mark - 排布

- (void)buildItems {
    for (POSplitPanelItem *item in self.items) [item removeFromSuperview];
    [self.items removeAllObjects];

    NSArray<POSplitTarget *> *all = [POApplicationHelper quickSwitchTargets];
    if (all.count > PQMaxItems) all = [all subarrayWithRange:NSMakeRange(0, PQMaxItems)];
    self.targets = all;

    CGFloat pad = 10.0;
    NSUInteger rows = (NSUInteger)ceil(all.count / 2.0);
    self.bounds = CGRectMake(0, 0, PQItemWidth * 2 + pad * 2, PQItemHeight * (rows ?: 1) + pad * 2);

    [all enumerateObjectsUsingBlock:^(POSplitTarget *target, NSUInteger index, BOOL *stop) {
        POSplitPanelItem *item = [[POSplitPanelItem alloc] initWithTarget:target];
        NSUInteger column = index % 2;
        NSUInteger row = index / 2;
        CGFloat x = pad + column * PQItemWidth + (self.expandsRight ? row * PQStagger : -row * PQStagger);
        CGFloat y = pad + row * PQItemHeight;
        if (column == 1) y += 6.0;   // 斜向错位，接近 PX 的扇形散开
        item.frame = CGRectMake(x + (column ? 6.0 : 0), y, PQItemWidth, PQItemHeight);
        item.tileView.alpha = 0.55;
        [self addSubview:item];
        [self.items addObject:item];
    }];
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
    if (index == _hoveredIndex) return;
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

- (BOOL)presentFromHandle:(UIView *)handle withRecognizer:(UILongPressGestureRecognizer *)recognizer {
    UIView *coordinateView = self.superview;
    if (!coordinateView) return NO;

    if (recognizer.state == UIGestureRecognizerStateBegan) {
        CGRect handleFrame = [handle convertRect:handle.bounds toView:coordinateView];
        CGPoint center = CGPointMake(CGRectGetMidX(handleFrame), CGRectGetMidY(handleFrame));
        self.expandsRight = center.x <= CGRectGetMidX(coordinateView.bounds);

        [self buildItems];
        if (self.items.count == 0) return NO;

        CGSize size = self.bounds.size;
        CGFloat x = self.expandsRight ? CGRectGetMinX(handleFrame) - 6
                                      : CGRectGetMaxX(handleFrame) - size.width + 6;
        CGFloat y = center.y - size.height / 2;
        y = MAX(8, MIN(y, CGRectGetHeight(coordinateView.bounds) - size.height - 8));
        self.frame = CGRectMake(x, y, size.width, size.height);

        self.layer.anchorPoint = CGPointMake(self.expandsRight ? 0 : 1, 0.5);
        self.layer.position = CGPointMake(x + (self.expandsRight ? 0 : size.width), center.y);

        self.hidden = NO;
        self.alpha = 0;
        self.transform = CGAffineTransformMakeScale(0.86, 0.9);
        _presenting = YES;
        [self.selectionDelegate quickSwitchTableViewWillAppear:self];
        [self setHoveredIndex:-1];
        [UIView animateWithDuration:0.24 delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.4
                            options:UIViewAnimationOptionAllowUserInteraction animations:^{
            self.alpha = 1;
            self.transform = CGAffineTransformIdentity;
        } completion:nil];
        return YES;
    }

    if (!_presenting) return NO;
    CGPoint point = [recognizer locationInView:self];

    if (recognizer.state == UIGestureRecognizerStateChanged) {
        [self setHoveredIndex:[self indexAtPoint:point]];
        return YES;
    }

    if (recognizer.state == UIGestureRecognizerStateEnded) {
        NSInteger index = [self indexAtPoint:point];
        if (index >= 0 && index < (NSInteger)self.targets.count) {
            [self.selectionDelegate quickSwitchTableView:self didSelectTarget:self.targets[index]];
        }
        [self dismissImmediately];
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
    _presenting = NO;
    _hoveredIndex = -1;
    [UIView animateWithDuration:0.16 animations:^{
        self.alpha = 0;
        self.transform = CGAffineTransformMakeScale(0.94, 0.94);
    } completion:^(BOOL finished) {
        self.hidden = YES;
        self.transform = CGAffineTransformIdentity;
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
