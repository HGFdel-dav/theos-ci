//
//  DNBSelectionController.m
//  DebsNewsBatch
//

#import "DNBSelectionController.h"
#import "DNBNewsBarView.h"
#import "DNBRowTarget.h"
#import "DNBDownloader.h"
#import "DNBNewsStore.h"
#import "DNBNewsItem.h"
#import "DNBCommon.h"
#import "DNBLogic.h"
#import "DNBPanelViewController.h"

@interface DNBSelectionController () <DNBNewsBarDelegate, DNBDownloaderDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIViewController *vc;
@property (nonatomic, weak) UIScrollView *scroll;
@property (nonatomic, strong) DNBNewsBarView *bar;
@property (nonatomic, strong) UIView *host;
@property (nonatomic, strong) UILongPressGestureRecognizer *rowLongPress;
@property (nonatomic, strong) NSLayoutConstraint *barBottom;
@property (nonatomic, strong) NSMutableArray<DNBRowTarget *> *targets;
@property (nonatomic, strong) NSMutableOrderedSet<NSString *> *chosen;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *statusByKey;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *keyByItemKey;
@property (nonatomic, strong) NSTimer *tick;
@property (nonatomic, strong) DNBDownloader *downloader;
@property (nonatomic, assign) NSInteger lastDiscovered;
@property (nonatomic, assign) NSInteger lastLogTick;
@property (nonatomic, assign) BOOL observing;
@end

@implementation DNBSelectionController

+ (instancetype)sharedController
{
    static DNBSelectionController *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = [DNBSelectionController new];
        c.chosen = [NSMutableOrderedSet orderedSet];
        c.statusByKey = [NSMutableDictionary dictionary];
        c.keyByItemKey = [NSMutableDictionary dictionary];
        c.targets = [NSMutableArray array];
    });
    return c;
}

+ (void)start
{
    DNBSelectionController *c = [self sharedController];
    if (c.tick) {
        return;
    }
    DNBLog(@"选择管家启动");
    __weak typeof(c) weakSelf = c;
    c.tick = [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:YES block:^(NSTimer *t) {
        [weakSelf onTick];
    }];
    [c onTick];
}

- (BOOL)bound
{
    return self.vc != nil && self.bar.superview != nil;
}

#pragma mark - 找页面

- (UIWindow *)keyWindow
{
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow && w.windowLevel == UIWindowLevelNormal) {
                return w;
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [UIApplication sharedApplication].windows.firstObject;
#pragma clang diagnostic pop
}

/* 在控制器树里找标题为「新闻」且里面真有表格的页面 */
- (UIViewController *)newsViewControllerFrom:(UIViewController *)root depth:(NSInteger)depth
{
    if (!root || depth > 8) {
        return nil;
    }
    if ([root.navigationItem.title isEqualToString:@"新闻"] && [self listViewIn:root.view depth:0]) {
        return root;
    }
    UIViewController *found = [self newsViewControllerFrom:root.presentedViewController depth:depth + 1];
    if (found) {
        return found;
    }
    if ([root isKindOfClass:[UINavigationController class]]) {
        return [self newsViewControllerFrom:((UINavigationController *)root).visibleViewController depth:depth + 1];
    }
    if ([root isKindOfClass:[UITabBarController class]]) {
        return [self newsViewControllerFrom:((UITabBarController *)root).selectedViewController depth:depth + 1];
    }
    for (UIViewController *child in root.childViewControllers) {
        found = [self newsViewControllerFrom:child depth:depth + 1];
        if (found) {
            return found;
        }
    }
    return nil;
}

- (UIScrollView *)listViewIn:(UIView *)view depth:(NSInteger)depth
{
    if (!view || depth > 14) {
        return nil;
    }
    if ([view isKindOfClass:[UITableView class]] || [view isKindOfClass:[UICollectionView class]]) {
        if (CGRectGetHeight(view.bounds) > 120) {
            return (UIScrollView *)view;
        }
    }
    for (UIView *sub in view.subviews) {
        UIScrollView *found = [self listViewIn:sub depth:depth + 1];
        if (found) {
            return found;
        }
    }
    return nil;
}

#pragma mark - 绑定 / 解绑

- (void)onTick
{
    UIViewController *news = [self newsViewControllerFrom:[self keyWindow].rootViewController depth:0];
    if (!news) {
        if (self.vc) {
            DNBLog(@"离开新闻页，摘除覆盖层");
            [self unbind];
        }
        return;
    }
    if (self.vc == news && self.bar.superview) {
        [self refreshRows];
        return;
    }
    [self bindToViewController:news];
    [self refreshRows];
}

- (void)unbind
{
    if (self.observing && self.scroll) {
        @try {
            [self.scroll removeObserver:self forKeyPath:@"contentOffset"];
        } @catch (__unused NSException *e) {
        }
        self.observing = NO;
    }
    [self.rowLongPress.view removeGestureRecognizer:self.rowLongPress];
    self.rowLongPress = nil;
    [self.bar removeFromSuperview];
    self.bar = nil;
    [self.host removeFromSuperview];
    self.host = nil;
    [self.targets removeAllObjects];
    self.vc = nil;
    self.scroll = nil;
    self.lastDiscovered = -1;
}

- (void)bindToViewController:(UIViewController *)vc
{
    UIScrollView *list = [self listViewIn:vc.view depth:0];
    if (!list) {
        return;
    }
    [self unbind];
    self.vc = vc;
    self.scroll = list;

    DNBLog(@"贴到新闻页：list=%@", NSStringFromClass([list class]));

    self.host = [[UIView alloc] initWithFrame:CGRectZero];
    self.host.backgroundColor = [UIColor clearColor];
    self.host.clipsToBounds = YES;
    self.host.hidden = YES;
    self.host.userInteractionEnabled = NO;
    [vc.view addSubview:self.host];

    self.bar = [[DNBNewsBarView alloc] initWithFrame:CGRectMake(16, 0, vc.view.bounds.size.width - 32, 44)];
    self.bar.delegate = self;
    self.bar.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:self.bar];
    [self.bar.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:16].active = YES;
    [self.bar.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-16].active = YES;
    [self.bar.heightAnchor constraintEqualToConstant:44].active = YES;
    self.barBottom = [self.bar.bottomAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.bottomAnchor constant:-58];
    self.barBottom.active = YES;

    self.rowLongPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleRowLongPress:)];
    self.rowLongPress.minimumPressDuration = 0.45;
    self.rowLongPress.cancelsTouchesInView = NO;
    self.rowLongPress.delegate = self;
    [list addGestureRecognizer:self.rowLongPress];

    /* 滚动时立刻跟随，不等定时器 */
    [list addObserver:self forKeyPath:@"contentOffset" options:0 context:NULL];
    self.observing = YES;

    /* 恢复已有选择状态 */
    [self applyStateToBar];
}

- (void)applyStateToBar
{
    if (!self.bar) {
        return;
    }
    BOOL running = (self.bar.state == DNBNewsBarStateRunning);
    self.bar.hidden = (self.chosen.count == 0 && !running);
    if (self.chosen.count > 0) {
        self.bar.state = DNBNewsBarStateSelecting;
        self.bar.selectedCount = self.chosen.count;
        self.host.hidden = NO;
        self.host.userInteractionEnabled = YES;
    }
}

#pragma mark - 行扫描

- (NSString *)keyForView:(UIView *)view depth:(NSInteger)depth
{
    if (!view || depth > 7) {
        return nil;
    }
    NSString *label = view.accessibilityLabel;
    if (label.length) {
        dnb_row_label row;
        if (dnb_parse_row_label(label.UTF8String, &row) == DNB_ROW_IS_NEWS) {
            return [NSString stringWithUTF8String:row.key];
        }
    }
    for (UIView *sub in view.subviews) {
        NSString *k = [self keyForView:sub depth:depth + 1];
        if (k) {
            return k;
        }
    }
    return nil;
}

/* 可见行：优先用单元格接口，退化才扫子视图 */
- (NSArray<UIView *> *)rowViews
{
    UIScrollView *sv = self.scroll;
    if (!sv) {
        return @[];
    }
    if ([sv isKindOfClass:[UITableView class]]) {
        NSArray *cells = ((UITableView *)sv).visibleCells;
        if (cells.count) {
            return cells;
        }
    } else if ([sv isKindOfClass:[UICollectionView class]]) {
        UICollectionView *cv = (UICollectionView *)sv;
        NSMutableArray *cells = [NSMutableArray array];
        for (NSIndexPath *ip in [cv indexPathsForVisibleItems]) {
            UICollectionViewCell *c = [cv cellForItemAtIndexPath:ip];
            if (c) {
                [cells addObject:c];
            }
        }
        if (cells.count) {
            return cells;
        }
    }
    NSMutableArray *rows = [NSMutableArray array];
    for (UIView *v in sv.subviews) {
        if (v == self.host || v.hidden) {
            continue;
        }
        if (CGRectGetHeight(v.frame) >= 40 && [self keyForView:v depth:0]) {
            [rows addObject:v];
        }
    }
    return rows;
}

- (void)refreshRows
{
    UIScrollView *sv = self.scroll;
    UIViewController *vc = self.vc;
    if (!sv || !vc || !self.bar) {
        return;
    }
    self.host.frame = [vc.view convertRect:sv.bounds fromView:sv];
    if (self.host.hidden) {
        return;
    }
    [vc.view bringSubviewToFront:self.host];
    [vc.view bringSubviewToFront:self.bar];
    self.host.userInteractionEnabled = YES;

    NSArray<UIView *> *rows = [self rowViews];
    NSInteger used = 0;
    NSInteger discovered = 0;
    for (UIView *row in rows) {
        NSString *key = [self keyForView:row depth:0];
        if (!key) {
            continue;
        }
        discovered++;
        DNBRowTarget *target = nil;
        if (used < (NSInteger)self.targets.count) {
            target = self.targets[used];
        } else {
            target = [[DNBRowTarget alloc] initWithFrame:CGRectZero];
            [target addTarget:self action:@selector(targetTapped:) forControlEvents:UIControlEventTouchUpInside];
            [self.host addSubview:target];
            [self.targets addObject:target];
        }
        used++;
        target.hidden = NO;
        target.rowKey = key;
        target.frame = [self.host convertRect:row.frame fromView:sv];
        target.chosen = [self.chosen containsObject:key];
        target.statusText = self.statusByKey[key];
    }
    for (NSInteger i = used; i < (NSInteger)self.targets.count; i++) {
        self.targets[i].hidden = YES;
    }

    if (discovered != self.lastDiscovered) {
        self.lastDiscovered = discovered;
        DNBLog(@"覆盖层更新：可见行 %ld，已贴 %ld", (long)discovered, (long)used);
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([keyPath isEqualToString:@"contentOffset"]) {
        [self refreshRows];
    }
}

#pragma mark - 长按进入选择

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other
{
    return YES;
}

- (void)handleRowLongPress:(UILongPressGestureRecognizer *)g
{
    if (g.state != UIGestureRecognizerStateBegan || self.chosen.count > 0) {
        return;
    }
    CGPoint p = [g locationInView:self.scroll];
    NSString *key = nil;
    for (UIView *row in [self rowViews]) {
        if (CGRectContainsPoint(row.frame, p)) {
            key = [self keyForView:row depth:0];
            break;
        }
    }
    if (!key.length) {
        DNBLog(@"长按没落在行上 (%.0f,%.0f)", p.x, p.y);
        return;
    }
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    [self.chosen addObject:key];
    self.bar.hidden = NO;
    self.bar.state = DNBNewsBarStateSelecting;
    self.host.hidden = NO;
    self.host.userInteractionEnabled = YES;
    [self syncBar];
    [self refreshRows];
}

- (void)syncBar
{
    self.bar.selectedCount = self.chosen.count;
    if (self.chosen.count == 0) {
        self.bar.allSelected = NO;
    }
}

- (void)targetTapped:(DNBRowTarget *)target
{
    NSString *key = target.rowKey;
    if (!key.length) {
        return;
    }
    if ([self.chosen containsObject:key]) {
        [self.chosen removeObject:key];
    } else {
        [self.chosen addObject:key];
    }
    target.chosen = !target.chosen;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self syncBar];
    if (self.chosen.count == 0) {
        [self resetToIdle];
        return;
    }
    [self refreshRows];
}

#pragma mark - 全选

- (NSArray<NSString *> *)allRowKeys
{
    UIScrollView *sv = self.scroll;
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    if ([sv isKindOfClass:[UITableView class]]) {
        UITableView *tv = (UITableView *)sv;
        id<UITableViewDataSource> ds = tv.dataSource;
        NSInteger sections = 1;
        if ([ds respondsToSelector:@selector(numberOfSectionsInTableView:)]) {
            sections = [ds numberOfSectionsInTableView:tv];
        }
        for (NSInteger s = 0; s < sections; s++) {
            NSInteger rows = [ds tableView:tv numberOfRowsInSection:s];
            for (NSInteger r = 0; r < rows && keys.count < 800; r++) {
                NSIndexPath *ip = [NSIndexPath indexPathForRow:r inSection:s];
                UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
                if (!cell && [ds respondsToSelector:@selector(tableView:cellForRowAtIndexPath:)]) {
                    cell = [ds tableView:tv cellForRowAtIndexPath:ip];
                    [cell setNeedsLayout];
                    [cell layoutIfNeeded];
                }
                NSString *k = [self keyForView:cell depth:0];
                if (k) {
                    [keys addObject:k];
                }
            }
        }
    } else if ([sv isKindOfClass:[UICollectionView class]]) {
        UICollectionView *cv = (UICollectionView *)sv;
        id<UICollectionViewDataSource> ds = cv.dataSource;
        NSInteger sections = [ds numberOfSectionsInCollectionView:cv];
        for (NSInteger s = 0; s < sections; s++) {
            NSInteger rows = [ds collectionView:cv numberOfItemsInSection:s];
            for (NSInteger r = 0; r < rows && keys.count < 800; r++) {
                NSIndexPath *ip = [NSIndexPath indexPathForItem:r inSection:s];
                UICollectionViewCell *cell = [cv cellForItemAtIndexPath:ip];
                if (!cell) {
                    cell = [ds collectionView:cv cellForItemAtIndexPath:ip];
                    [cell setNeedsLayout];
                    [cell layoutIfNeeded];
                }
                NSString *k = [self keyForView:cell depth:0];
                if (k) {
                    [keys addObject:k];
                }
            }
        }
    }
    if (keys.count == 0) {
        for (UIView *row in [self rowViews]) {
            NSString *k = [self keyForView:row depth:0];
            if (k) {
                [keys addObject:k];
            }
        }
    }
    return keys;
}

#pragma mark - 选择 → 条目

- (NSArray<DNBNewsItem *> *)resolveItemsForKeys:(NSArray<NSString *> *)keys
{
    NSArray<DNBNewsItem *> *all = [DNBNewsStore sharedStore].items;
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *key in keys) {
        NSArray *parts = [key componentsSeparatedByString:@"\t"];
        if (parts.count != 3) {
            continue;
        }
        dnb_row_label row;
        memset(&row, 0, sizeof(row));
        strncpy(row.name, [parts[0] UTF8String], sizeof(row.name) - 1);
        strncpy(row.version, [parts[1] UTF8String], sizeof(row.version) - 1);
        strncpy(row.arch, [parts[2] UTF8String], sizeof(row.arch) - 1);
        for (DNBNewsItem *item in all) {
            if (dnblogic_row_matches(&row, item.name.UTF8String, item.version.UTF8String, item.architecture.UTF8String)) {
                [out addObject:item];
                break;
            }
        }
    }
    return out;
}

#pragma mark - 底条回调

- (void)barDidTapBody:(DNBNewsBarView *)bar
{
    [self resetToIdle];
}

- (void)barDidTapCancel:(DNBNewsBarView *)bar
{
    [self resetToIdle];
}

- (void)barDidTapDone:(DNBNewsBarView *)bar
{
    [self resetToIdle];
}

- (void)resetToIdle
{
    [self.chosen removeAllObjects];
    [self.statusByKey removeAllObjects];
    if (!self.bar) {
        return;
    }
    self.bar.state = DNBNewsBarStateIdle;
    self.bar.hidden = YES;
    self.bar.selectedCount = 0;
    [self.bar applyTintColor:nil];
    self.host.hidden = YES;
    self.host.userInteractionEnabled = NO;
    for (DNBRowTarget *t in self.targets) {
        t.hidden = YES;
    }
}

- (void)barDidTapSelectAll:(DNBNewsBarView *)bar
{
    NSArray<NSString *> *keys = [self allRowKeys];
    if (keys.count == 0) {
        DNBLog(@"全选：一行都没取到");
        return;
    }
    [self.chosen removeAllObjects];
    [self.chosen addObjectsFromArray:keys];
    [self syncBar];
    self.bar.allSelected = (self.chosen.count >= keys.count);
    DNBLog(@"全选：%lu 行", (unsigned long)keys.count);
    [self refreshRows];
}

- (void)barDidTapDownload:(DNBNewsBarView *)bar
{
    NSArray<DNBNewsItem *> *items = [self resolveItemsForKeys:self.chosen.array];
    if (items.count == 0) {
        DNBLog(@"下载中止：%lu 条选择在 news.plist 里找不到", (unsigned long)self.chosen.count);
        bar.titleLabel.text = @"所选条目已不在列表里";
        return;
    }
    [self.keyByItemKey removeAllObjects];
    NSArray<NSString *> *keys = self.chosen.array;
    for (NSUInteger i = 0; i < MIN(keys.count, (NSUInteger)items.count); i++) {
        self.keyByItemKey[[items[i] uniqueKey]] = keys[i];
    }
    DNBLog(@"开始批量下载 %lu 条", (unsigned long)items.count);
    self.downloader = [[DNBDownloader alloc] initWithItems:items overwrite:NO writeRecord:YES];
    self.downloader.delegate = self;
    bar.hidden = NO;
    bar.state = DNBNewsBarStateRunning;
    [bar applyTintColor:[UIColor systemGrayColor]];
    [self.downloader start];
}

- (void)barDidTapStop:(DNBNewsBarView *)bar
{
    [self.downloader stop];
}

- (void)barDidLongPress:(DNBNewsBarView *)bar
{
    UIViewController *vc = self.vc;
    if (!vc) {
        return;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"DebsNewsBatch" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"打开批量面板" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [vc presentViewController:[DNBPanelViewController new] animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = bar;
    sheet.popoverPresentationController.sourceRect = bar.bounds;
    [vc presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 下载回调

- (void)downloader:(DNBDownloader *)downloader itemDidChange:(DNBNewsItem *)item state:(DNBItemState)state detail:(NSString *)detail
{
    NSString *key = self.keyByItemKey[[item uniqueKey]];
    if (!key) {
        return;
    }
    NSString *text = nil;
    switch (state) {
        case DNBItemStateDownloading: text = @"下载中"; break;
        case DNBItemStateFinished: text = @"完成"; break;
        case DNBItemStateFailed: text = @"失败"; break;
        case DNBItemStateSkipped: text = @"已存在"; break;
        case DNBItemStateCancelled: text = @"已取消"; break;
        default: break;
    }
    if (text) {
        self.statusByKey[key] = text;
    }
    [self refreshRows];
}

- (void)downloader:(DNBDownloader *)downloader progressChanged:(NSInteger)done total:(NSInteger)total
{
    [self.bar showProgressDone:done total:total success:downloader.successCount failed:downloader.failedCount];
}

- (void)downloaderDidFinish:(DNBDownloader *)downloader success:(NSInteger)success failed:(NSInteger)failed skipped:(NSInteger)skipped
{
    [self.bar showSummarySuccess:success failed:failed skipped:skipped];
    [self.chosen removeAllObjects];
    self.bar.selectedCount = 0;
    DNBLog(@"批量下载结束：成功 %ld 失败 %ld 跳过 %ld", (long)success, (long)failed, (long)skipped);
    [self refreshRows];
}

@end
