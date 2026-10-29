//
//  POSplitPanelView.m
//  SplitX
//
//  无整块底板；只有各自独立的轻玻璃图标。
//  图标按真实尺寸分环排布，屏内放不下的条目分页，不再挤叠。
//
//  拖动时按手指和圆心的夹角判悬停，松手选中；选中项先向外弹一下再收。
//

#import "POSplitXLog.h"
#import "POSplitXSettings.h"
#import "POSplitPanelView.h"
#import "POSplitTarget.h"
#import "POApplicationHelper.h"
#import "POQuickSwitchMetrics.h"
#import "POFanLayout.h"
#import <math.h>


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
    // SplitX 自绘轻玻璃托，不实例化 PX 的私有 Swift 图标类。
    CGFloat icon = iconSize;
    CGFloat tile = MAX(tileSize, icon + 8.0);
    CGFloat width = tile + 6.0;
    if ((self = [super initWithFrame:CGRectMake(0, 0, width, width)])) {
        _target = target;
        self.backgroundColor = UIColor.clearColor;
        self.accessibilityLabel = title;
        self.isAccessibilityElement = YES;

        // 原来那块 92% 不透明的白方托删除，改为每个图标独立的薄玻璃。
        UIVisualEffectView *bubble = [[UIVisualEffectView alloc] initWithEffect:
            [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
        bubble.frame = CGRectMake(3, 3, tile, tile);
        bubble.layer.cornerRadius = square ? tile * 0.28 : tile / 2.0;
        bubble.layer.cornerCurve = kCACornerCurveContinuous;
        bubble.clipsToBounds = YES;
        bubble.userInteractionEnabled = NO;
        bubble.layer.borderWidth = 0.5;
        bubble.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.30].CGColor;
        [self addSubview:bubble];
        _tileView = bubble;

        // 图标尺寸严格取 iconSize，不再从 tileSize 的 inset 反推成另一个数值。
        _iconView = [[UIImageView alloc] initWithFrame:
            CGRectMake((width - icon) / 2.0, (width - icon) / 2.0, icon, icon)];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.layer.cornerRadius = square ? icon * 0.22 : icon * 0.50;
        _iconView.layer.cornerCurve = kCACornerCurveContinuous;
        _iconView.clipsToBounds = YES;
        _iconView.image = [POApplicationHelper imageForBundleId:target.bundleIdentifier];
        _iconView.userInteractionEnabled = NO;
        [self addSubview:_iconView];
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.10;
        self.layer.shadowRadius = 3.0;
        self.layer.shadowOffset = CGSizeMake(0, 1);

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
        self.layer.shadowOpacity = (alpha > 0.95) ? 0.18 : 0.10;
    };
    if (!animated) { apply(); return; }
    [UIView animateWithDuration:_chosen ? 0.20 : 0.14 delay:0
         usingSpringWithDamping:0.70 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:apply completion:nil];
}

@end

#pragma mark - 扇形菜单

@interface POSplitPanelView () <UIGestureRecognizerDelegate>
@property (nonatomic, assign) CGRect coordinateBounds;
@property (nonatomic, assign) CGPoint anchorInSuperview;
@property (nonatomic, assign) NSUInteger pageIndex;
@property (nonatomic, assign) NSUInteger pageCount;
@property (nonatomic, strong) UIView *pager;
@property (nonatomic, strong) UIButton *previousButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) UILabel *pageLabel;
@property (nonatomic, strong) NSMutableArray<POSplitPanelItem *> *items;
@property (nonatomic, strong) NSArray<POSplitTarget *> *targets;
@property (nonatomic, assign) NSInteger hoveredIndex;
@property (nonatomic, assign) BOOL presenting;
@property (nonatomic, assign) BOOL selectionPending;
@property (nonatomic, assign) NSUInteger presentationGeneration;
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
        UITapGestureRecognizer *emptyTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(emptyAreaTapped:)];
        emptyTap.delegate = self;
        emptyTap.cancelsTouchesInView = NO;
        [self addGestureRecognizer:emptyTap];

        // 不创建扇形毛玻璃、遮罩、多边形边线；旧 alpha 配置也无法让底板重现。
        _pager = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 32, 78)];
        _pager.backgroundColor = UIColor.clearColor;
        _previousButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _previousButton.frame = CGRectMake(0, 0, 32, 26);
        [_previousButton setImage:[UIImage systemImageNamed:@"chevron.up"] forState:UIControlStateNormal];
        [_previousButton addTarget:self action:@selector(previousPage) forControlEvents:UIControlEventTouchUpInside];
        [_pager addSubview:_previousButton];
        _pageLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 26, 32, 26)];
        _pageLabel.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightMedium];
        _pageLabel.textAlignment = NSTextAlignmentCenter;
        _pageLabel.textColor = UIColor.secondaryLabelColor;
        [_pager addSubview:_pageLabel];
        _nextButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _nextButton.frame = CGRectMake(0, 52, 32, 26);
        [_nextButton setImage:[UIImage systemImageNamed:@"chevron.down"] forState:UIControlStateNormal];
        [_nextButton addTarget:self action:@selector(nextPage) forControlEvents:UIControlEventTouchUpInside];
        [_pager addSubview:_nextButton];
        [self addSubview:_pager];

        _items = [NSMutableArray array];
        _hoveredIndex = -1;
        _hoverHaptics = [[UISelectionFeedbackGenerator alloc] init];
        _confirmHaptics = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        self.hidden = YES;
    }
    return self;
}

// 本视图没有整块背景路径，布局只由 POFanBuild 的图标位置决定。

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
    if (all.count == 0) {
        self.targets = @[];
        self.pageCount = 0;
        self.pager.hidden = YES;
        [self endEmptyRebuildIfPresenting];
        return;
    }

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
    // 固定一页的几何槽位。容量受真实图标尺寸与屏内矩形约束，绝不隐藏或缩放剩余账号。
    int caps[4] = {(int)settings.ring1, (int)settings.ring2, (int)settings.ring3, (int)settings.ring4};
    // 触摸框只比玻璃托多几像素，不再叠加一整份 6pt 留白，否则屏内只剩两环。
    CGFloat side = MAX(self.itemTileSize, self.itemIconSize + 6.0);
    CGRect safe = self.coordinateBounds;
    POFanLayout layout = POFanBuild(CGRectGetMinX(safe), CGRectGetMinY(safe), CGRectGetMaxX(safe), CGRectGetMaxY(safe),
        self.anchorInSuperview.x, self.anchorInSuperview.y, self.expandsRight,
        settings.fanRadius, settings.fanSpan, side, settings.itemSpacing, settings.ringGap, caps);
    if (layout.count <= 0) {
        self.targets = @[];
        self.pageCount = 0;
        self.pager.hidden = YES;
        PXLogW(@"panel", @"no safe slots side=%.0f radius=%.0f bounds=%@", side, settings.fanRadius, NSStringFromCGRect(safe));
        [self endEmptyRebuildIfPresenting];
        return;
    }
    NSUInteger capacity = (NSUInteger)layout.count;
    self.pageCount = (ordered.count + capacity - 1) / capacity;
    self.pageIndex = MIN(self.pageIndex, self.pageCount - 1);
    NSUInteger first = self.pageIndex * capacity;
    NSUInteger count = MIN(capacity, ordered.count - first);
    self.targets = [ordered subarrayWithRange:NSMakeRange(first, count)];
    self.radius = settings.fanRadius;
    self.span = settings.fanSpan * M_PI / 180.0;

    CGFloat minX = layout.minX, maxX = layout.maxX, minY = layout.minY, maxY = layout.maxY;
    CGRect pagerInSuperview = CGRectMake(
        MIN(MAX(self.anchorInSuperview.x - 16.0, CGRectGetMinX(safe)), CGRectGetMaxX(safe) - 32.0),
        MIN(MAX(self.anchorInSuperview.y - 39.0, CGRectGetMinY(safe)), CGRectGetMaxY(safe) - 78.0), 32.0, 78.0);
    if (self.pageCount > 1) {
        minX = MIN(minX, CGRectGetMinX(pagerInSuperview)); maxX = MAX(maxX, CGRectGetMaxX(pagerInSuperview));
        minY = MIN(minY, CGRectGetMinY(pagerInSuperview)); maxY = MAX(maxY, CGRectGetMaxY(pagerInSuperview));
    }
    // 动画锚点、画布和图标坐标一次性确定；不再先布局后修改高度导致圆心跑偏。
    self.transform = CGAffineTransformIdentity;
    self.bounds = CGRectMake(0, 0, maxX - minX, maxY - minY);
    self.centerPoint = CGPointMake(self.anchorInSuperview.x - minX, self.anchorInSuperview.y - minY);
    self.layer.anchorPoint = CGPointMake(self.centerPoint.x / CGRectGetWidth(self.bounds),
                                         self.centerPoint.y / CGRectGetHeight(self.bounds));
    self.layer.position = self.anchorInSuperview;
    self.pager.frame = CGRectOffset(pagerInSuperview, -minX, -minY);
    self.pager.hidden = self.pageCount <= 1;
    self.pageLabel.text = [NSString stringWithFormat:@"%lu/%lu", (unsigned long)(self.pageIndex + 1), (unsigned long)self.pageCount];
    self.previousButton.enabled = self.pageIndex > 0;
    self.nextButton.enabled = self.pageIndex + 1 < self.pageCount;

    PXLog(@"panel", @"layout total=%lu page=%lu/%lu slots=%lu rings=%d side=%.0f icon=%.0f tile=%.0f radius=%.0f span=%.0f caps=%d,%d,%d,%d board=removed",
          (unsigned long)ordered.count, (unsigned long)(self.pageIndex + 1), (unsigned long)self.pageCount,
          (unsigned long)capacity, layout.rings, side, self.itemIconSize, self.itemTileSize,
          settings.fanRadius, settings.fanSpan, caps[0], caps[1], caps[2], caps[3]);
    for (NSUInteger i = 0; i < count; i++) {
        POFanPoint position = layout.points[i];
        POSplitTarget *target = self.targets[i];
        POSplitPanelItem *item = [[POSplitPanelItem alloc] initWithTarget:target
            iconSize:self.itemIconSize tileSize:self.itemTileSize title:titles[first + i]
            badge:badges[first + i] square:settings.squareIcons];
        item.angle = position.angle;
        item.radius = position.radius;
        item.baseScale = 1.0;
        item.center = CGPointMake(position.x - minX, position.y - minY);
        [item applyDimmedInitialState];
        [item addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(itemTapped:)]];
        [self addSubview:item];
        [self.items addObject:item];
        PXLog(@"panel", @"item %lu ring=%d angle=%.0f r=%.0f center=%.0f,%.0f target=%@",
              (unsigned long)i, position.ring, position.angle * 180.0 / M_PI,
              position.radius, item.center.x, item.center.y, target.identityKey);
    }
    [self bringSubviewToFront:self.pager];
    self.hoveredIndex = -1;
    PXLog(@"panel", @"fan ready items=%lu total=%lu page=%lu radius=%.0f", (unsigned long)self.items.count,
          (unsigned long)ordered.count, (unsigned long)(self.pageIndex + 1), self.radius);
}

/// 按当前页真实图标位置命中，不在圆心附近提前猜中远处图标。
- (NSInteger)indexAtPoint:(CGPoint)point {
    NSInteger best = -1;
    CGFloat bestDistance = CGFLOAT_MAX;
    for (NSUInteger i = 0; i < self.items.count; i++) {
        POSplitPanelItem *item = self.items[i];
        CGFloat half = CGRectGetWidth(item.bounds) / 2.0 + 8.0;
        CGFloat dx = point.x - item.center.x, dy = point.y - item.center.y;
        if (fabs(dx) > half || fabs(dy) > half) continue;
        CGFloat distance = hypot(dx, dy);
        if (distance < bestDistance) { bestDistance = distance; best = (NSInteger)i; }
    }
    PXLog(@"panel", @"hit pt=%.0f,%.0f -> %ld page=%lu items=%lu", point.x, point.y, (long)best,
          (unsigned long)(self.pageIndex + 1), (unsigned long)self.items.count);
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

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    return touch.view == self;
}

- (void)emptyAreaTapped:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateEnded || !_presenting || self.selectionPending) return;
    PXLog(@"panel", @"empty area cancels menu");
    [self dismissImmediately];
}

- (void)endEmptyRebuildIfPresenting {
    if (!_presenting) return;
    _hoveredIndex = -1;
    [self.selectionDelegate quickSwitchTableViewDidClearHover:self];
    [self dismissImmediately];
}

- (void)previousPage {
    if (!_presenting || self.selectionPending || self.pageIndex == 0) return;
    self.pageIndex--;
    [self buildItems];
    PXLog(@"panel", @"page previous -> %lu/%lu", (unsigned long)(self.pageIndex + 1), (unsigned long)self.pageCount);
}

- (void)nextPage {
    if (!_presenting || self.selectionPending || self.pageIndex + 1 >= self.pageCount) return;
    self.pageIndex++;
    [self buildItems];
    PXLog(@"panel", @"page next -> %lu/%lu", (unsigned long)(self.pageIndex + 1), (unsigned long)self.pageCount);
}

- (void)selectIndex:(NSInteger)index {
    if (!_presenting || self.selectionPending || index < 0 || index >= (NSInteger)self.targets.count) return;
    self.selectionPending = YES;
    NSUInteger generation = self.presentationGeneration;
    POSplitTarget *target = self.targets[(NSUInteger)index];
    PXLog(@"panel", @"select %@ page=%lu", target.identityKey, (unsigned long)(self.pageIndex + 1));
    if (self.hapticsEnabled) [self.confirmHaptics impactOccurred];
    for (NSUInteger i = 0; i < self.items.count; i++) {
        self.items[i].highlighted = NO;
        self.items[i].chosen = ((NSInteger)i == index);
    }
    [self.selectionDelegate quickSwitchTableView:self didSelectTarget:target];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.17 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.presentationGeneration == generation) [self dismissImmediately];
    });
}

- (void)itemTapped:(UITapGestureRecognizer *)recognizer {
    NSUInteger index = [self.items indexOfObjectIdenticalTo:(POSplitPanelItem *)recognizer.view];
    if (index != NSNotFound) [self selectIndex:(NSInteger)index];
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
        UIEdgeInsets insets = coordinateView.safeAreaInsets;
        insets.top += 34.0; insets.bottom += 10.0;   // 让开设置页导航标题与 Home 条
        insets.left += 8.0; insets.right += 8.0;
        self.coordinateBounds = UIEdgeInsetsInsetRect(coordinateView.bounds, insets);
        self.presentationAnchorFrame = handleFrame;
        self.anchorInSuperview = CGPointMake(handleCenter.x + (handleOnLeft ? 1.0 : -1.0) * settings.panelEdgeInset,
                                             handleCenter.y);
        if (!_presenting) self.pageIndex = 0;
        self.presentationGeneration++;
        self.selectionPending = NO;
        [self buildItems];
        if (self.items.count == 0) return NO;
        self.hidden = NO;
        _presenting = YES;

        self.alpha = 0;
        // buildItems 已一次性确定真实手柄锚点，不再使用屏幕边缘替代圆心。
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
        if (!self.pager.hidden && CGRectContainsPoint(self.pager.frame, point)) {
            CGPoint pagerPoint = [self convertPoint:point toView:self.pager];
            if (CGRectContainsPoint(self.previousButton.frame, pagerPoint)) [self previousPage];
            else if (CGRectContainsPoint(self.nextButton.frame, pagerPoint)) [self nextPage];
            PXLog(@"panel", @"page control released; keep menu visible");
            return YES;
        }
        NSInteger index = [self indexAtPoint:point];
        if (index >= 0) [self selectIndex:index];
        else {
            PXLog(@"panel", @"select miss pt=%.0f,%.0f hovered=%ld items=%lu", point.x, point.y,
                  (long)self.hoveredIndex, (unsigned long)self.items.count);
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
    _selectionPending = NO;
    NSUInteger closingGeneration = ++self.presentationGeneration;
    NSArray<POSplitPanelItem *> *closingItems = [self.items copy];
    _hoveredIndex = -1;
    for (POSplitPanelItem *item in closingItems) {
        [UIView animateWithDuration:0.18 * self.animationScale delay:0
             usingSpringWithDamping:0.9 initialSpringVelocity:0.2
                            options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            item.center = self.centerPoint;
            item.alpha = 0;
            item.transform = CGAffineTransformMakeScale(0.4, 0.4);
        } completion:nil];
    }
    // 和 Galaxy 一样：整体向手柄收缩再淡出，不是只把透明度假到 0。
    [UIView animateWithDuration:0.20 * self.animationScale delay:0
         usingSpringWithDamping:0.9 initialSpringVelocity:0.2
                        options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        self.alpha = 0;
        self.transform = CGAffineTransformMakeScale(0.86, 0.86);
    } completion:^(BOOL finished) {
        if (self.presentationGeneration != closingGeneration || _presenting) return;
        self.hidden = YES;
        self.transform = CGAffineTransformIdentity;
        for (POSplitPanelItem *item in closingItems) { item.chosen = NO; }
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
