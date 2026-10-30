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

static BOOL DNBIsDescendant(UIViewController *child, UIViewController *ancestor)
{
    UIViewController *p = child.parentViewController;
    while (p) {
        if (p == ancestor) {
            return YES;
        }
        p = p.parentViewController;
    }
    return NO;
}

static NSMutableArray<DNBSelectionController *> *DNBAllControllers(void)
{
    static NSMutableArray *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = [NSMutableArray array];
    });
    return list;
}

@interface DNBSelectionController () <DNBNewsBarDelegate, DNBDownloaderDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIViewController *vc;
@property (nonatomic, weak) UIScrollView *scroll;
@property (nonatomic, strong) DNBNewsBarView *bar;
@property (nonatomic, strong) UIView *host;
@property (nonatomic, strong) NSMutableArray<DNBRowTarget *> *targets;
@property (nonatomic, strong) NSMutableOrderedSet<NSString *> *chosen;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *statusByKey;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *keyByItemKey;
@property (nonatomic, strong) NSTimer *tick;
@property (nonatomic, strong) DNBDownloader *downloader;
@property (nonatomic, assign) NSInteger attachAttempts;
@property (nonatomic, strong) NSLayoutConstraint *barBottom;
@property (nonatomic, strong) UILongPressGestureRecognizer *rowLongPress;
@property (nonatomic, assign) NSInteger lastDiscovered;
@end

@implementation DNBSelectionController

#pragma mark - 挂载

+ (DNBSelectionController *)controllerForViewController:(UIViewController *)vc
{
    if (!vc) {
        return nil;
    }
    for (DNBSelectionController *c in DNBAllControllers()) {
        if (c.vc == vc) {
            return c;
        }
    }
    return nil;
}

+ (instancetype)attachToViewController:(UIViewController *)vc
{
    if (!vc || !vc.view) {
        return nil;
    }
    /* 同一个页面可能有多层宿主控制器，已经在同一支上挂过就直接复用，避免出现两条 */
    for (DNBSelectionController *c in DNBAllControllers()) {
        UIViewController *other = c.vc;
        if (!other) {
            continue;
        }
        if (other == vc || DNBIsDescendant(vc, other) || DNBIsDescendant(other, vc)) {
            return c;
        }
    }
    DNBSelectionController *c = [DNBSelectionController new];
    c.vc = vc;
    [DNBAllControllers() addObject:c];
    [c beginAttach];
    return c;
}

- (void)beginAttach
{
    self.attachAttempts = 0;
    [self tryFindScrollView];
}

- (void)tryFindScrollView
{
    UIViewController *vc = self.vc;
    if (!vc || !vc.view) {
        return;
    }
    UIScrollView *sv = [self findScrollViewInView:vc.view depth:0];
    if (sv) {
        if ([self rowViews].count > 0 || self.attachAttempts < 2) {
            [self buildUIWithScrollView:sv];
            return;
        }
        [self.host removeFromSuperview];
        self.host = nil;
        [self.bar removeFromSuperview];
        self.bar = nil;
    }
    self.attachAttempts++;
    if (self.attachAttempts >= 12) {
        DNBLog(@"新闻页没找到列表，放弃挂载 title=%@", vc.navigationItem.title);
        [DNBAllControllers() removeObject:self];
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf tryFindScrollView];
    });
}

/* 找承载新闻行的滚动视图：优先真正装得下新闻行的，跳过我们自己的视图 */
- (UIScrollView *)findScrollViewInView:(UIView *)view depth:(NSInteger)depth
{
    if (!view || depth > 12) {
        return nil;
    }
    if ([view isKindOfClass:[UIScrollView class]] && view != self.host) {
        UIScrollView *sv = (UIScrollView *)view;
        if (CGRectGetHeight(sv.bounds) > 120) {
            if (self.attachAttempts < 2) {
                return sv;
            }
            /* 只有真正装着新闻行的滚动视图才算 */
            for (UIView *sub in sv.subviews) {
                if (CGRectGetHeight(sub.frame) >= 40 && [self keyForView:sub depth:0]) {
                    return sv;
                }
            }
        }
    }
    for (UIView *sub in view.subviews) {
        UIScrollView *found = [self findScrollViewInView:sub depth:depth + 1];
        if (found) {
            return found;
        }
    }
    return nil;
}

- (void)buildUIWithScrollView:(UIScrollView *)scroll
{
    UIViewController *vc = self.vc;
    if (!vc) {
        return;
    }
    self.scroll = scroll;
    self.targets = [NSMutableArray array];
    self.chosen = [NSMutableOrderedSet orderedSet];
    self.statusByKey = [NSMutableDictionary dictionary];
    self.keyByItemKey = [NSMutableDictionary dictionary];

    /* 勾选层放在页面最上层（不是列表里面），否则会被 App 的单元格盖住：看不见也点不到 */
    self.host = [[UIView alloc] initWithFrame:CGRectZero];
    self.host.backgroundColor = [UIColor clearColor];
    self.host.clipsToBounds = YES;
    self.host.userInteractionEnabled = NO;
    self.host.hidden = YES;
    [vc.view addSubview:self.host];

    self.bar = [[DNBNewsBarView alloc] initWithFrame:CGRectMake(16, 0, vc.view.bounds.size.width - 32, 44)];
    self.bar.hidden = YES;   /* 平时不显示，选了东西才出现 */
    self.bar.delegate = self;
    self.bar.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:self.bar];
    [self.bar.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:16].active = YES;
    [self.bar.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-16].active = YES;
    [self.bar.heightAnchor constraintEqualToConstant:44].active = YES;
    self.barBottom = [self.bar.bottomAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.bottomAnchor constant:-58];
    self.barBottom.active = YES;

    self.host.userInteractionEnabled = NO;   /* 非选择态：触摸直接透给 App */

    /* 长按任意一条新闻 → 进入选择态并选中它（平时点行仍是 App 自己的跳转） */
    self.rowLongPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleRowLongPress:)];
    self.rowLongPress.minimumPressDuration = 0.45;
    self.rowLongPress.cancelsTouchesInView = NO;
    self.rowLongPress.delegate = self;
    [scroll addGestureRecognizer:self.rowLongPress];

    [vc.view bringSubviewToFront:self.bar];
    [scroll addObserver:self forKeyPath:@"contentOffset" options:NSKeyValueObservingOptionNew context:NULL];

    __weak typeof(self) weakSelf = self;
    self.tick = [NSTimer scheduledTimerWithTimeInterval:0.35 repeats:YES block:^(NSTimer *t) {
        [weakSelf refreshRows];
    }];
    [self refreshRows];
    DNBLog(@"新闻页已挂载：scroll=%@ 行数=%lu", NSStringFromClass([scroll class]), (unsigned long)[self rowViews].count);
}

#pragma mark - 摘除

- (void)detach
{
    [self.tick invalidate];
    self.tick = nil;
    @try {
        [self.scroll removeObserver:self forKeyPath:@"contentOffset"];
    } @catch (__unused NSException *e) {
    }
    [self.rowLongPress.view removeGestureRecognizer:self.rowLongPress];
    self.rowLongPress = nil;
    [self.bar removeFromSuperview];
    [self.host removeFromSuperview];
    [self.downloader stop];
    self.downloader = nil;
    [DNBAllControllers() removeObject:self];
    DNBLog(@"新闻页已摘除");
}

- (BOOL)attached
{
    return (self.bar.superview != nil);
}

#pragma mark - 行扫描

- (NSString *)keyForView:(UIView *)view depth:(NSInteger)depth
{
    if (!view || depth > 5) {
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

- (NSArray<UIView *> *)rowViews
{
    NSMutableArray *rows = [NSMutableArray array];
    UIScrollView *sv = self.scroll;
    if (!sv) {
        return rows;
    }
    for (UIView *v in sv.subviews) {
        if (v == self.host || v.hidden || v.alpha < 0.02f) {
            continue;
        }
        if (CGRectGetHeight(v.frame) < 40 || CGRectGetWidth(v.frame) < 120) {
            continue;
        }
        if ([self keyForView:v depth:0]) {
            [rows addObject:v];
        }
    }
    return rows;
}

- (void)refreshRows
{
    UIScrollView *sv = self.scroll;
    UIViewController *vc = self.vc;
    if (!sv || !vc) {
        return;
    }
    /* 勾选层始终贴住列表可视区域，坐标由列表内容换算过来 */
    self.host.frame = [vc.view convertRect:sv.bounds fromView:sv];
    if (self.host.hidden) {
        return;
    }

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
    [self.vc.view bringSubviewToFront:self.host];
    [self.vc.view bringSubviewToFront:self.bar];

    if (discovered != self.lastDiscovered) {
        self.lastDiscovered = discovered;
        DNBLog(@"覆盖层更新：发现行 %ld，显示勾选 %ld", (long)discovered, (long)used);
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other
{
    return YES;
}

- (UIView *)rowViewAtPoint:(CGPoint)pointInScroll
{
    for (UIView *row in [self rowViews]) {
        if (CGRectContainsPoint(row.frame, pointInScroll)) {
            return row;
        }
    }
    return nil;
}

- (void)handleRowLongPress:(UILongPressGestureRecognizer *)g
{
    if (g.state != UIGestureRecognizerStateBegan) {
        return;
    }
    if (self.bar.state != DNBNewsBarStateIdle) {
        return;
    }
    CGPoint p = [g locationInView:self.scroll];
    UIView *row = [self rowViewAtPoint:p];
    if (!row) {
        return;
    }
    NSString *key = [self keyForView:row depth:0];
    if (!key.length) {
        return;
    }
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
    [self enterSelection];
    [self.chosen addObject:key];
    [self syncBar];
    [self refreshRows];
}

- (void)enterSelection
{
    self.bar.state = DNBNewsBarStateSelecting;
    self.bar.hidden = NO;
    self.host.userInteractionEnabled = YES;
    self.host.hidden = NO;
    [self refreshRows];
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
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
    [self syncBar];
    if (self.chosen.count == 0) {
        [self resetToIdle];
    }
}

- (void)syncBar
{
    self.bar.selectedCount = self.chosen.count;
    if (self.chosen.count == 0) {
        self.bar.allSelected = NO;
    }
}

#pragma mark - 滚动跟随

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([keyPath isEqualToString:@"contentOffset"]) {
        [self refreshRows];
    }
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
            for (NSInteger r = 0; r < rows && keys.count < 600; r++) {
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
            for (NSInteger r = 0; r < rows && keys.count < 600; r++) {
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

#pragma mark - 选择解析

/* rowKey（名称\t版本\t架构）→ 新闻条目 */
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
    if (bar.state == DNBNewsBarStateDone) {
        [self resetToIdle];
        return;
    }
    [self.chosen removeAllObjects];
    [self.statusByKey removeAllObjects];
    bar.state = DNBNewsBarStateSelecting;
    bar.selectedCount = 0;
    self.host.hidden = NO;
    [self refreshRows];
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
    BOOL wasRunning = (self.bar.state == DNBNewsBarStateRunning);
    [self.chosen removeAllObjects];
    [self.statusByKey removeAllObjects];
    self.bar.state = DNBNewsBarStateIdle;
    self.bar.selectedCount = 0;
    self.bar.hidden = YES;
    [self.bar applyTintColor:nil];
    self.host.hidden = YES;
    self.host.userInteractionEnabled = NO;
    if (!wasRunning) {
        [self refreshRows];
    }
}

- (void)barDidTapSelectAll:(DNBNewsBarView *)bar
{
    NSArray<NSString *> *keys = [self allRowKeys];
    if (keys.count == 0) {
        return;
    }
    [self.chosen removeAllObjects];
    [self.chosen addObjectsFromArray:keys];
    [self syncBar];
    self.bar.allSelected = (self.chosen.count >= keys.count);
    [self refreshRows];
}

- (void)barDidTapDownload:(DNBNewsBarView *)bar
{
    NSArray<DNBNewsItem *> *items = [self resolveItemsForKeys:self.chosen.array];
    if (items.count == 0) {
        DNBLog(@"下载中止：选的 %lu 条在 news.plist 里找不到对应条目", (unsigned long)self.chosen.count);
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
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"DebsNewsBatch" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"打开批量面板" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        DNBPanelViewController *p = [DNBPanelViewController new];
        [vc presentViewController:p animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"查看日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *log = [NSString stringWithContentsOfFile:DNBLogPath() encoding:NSUTF8StringEncoding error:NULL];
        UITextView *tv = [UITextView new];
        tv.editable = NO;
        tv.text = log.length ? log : @"（暂无日志）";
        tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        UIViewController *r = [UIViewController new];
        r.view.backgroundColor = [UIColor systemBackgroundColor];
        tv.frame = r.view.bounds;
        tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [r.view addSubview:tv];
        r.title = @"日志";
        [vc.navigationController pushViewController:r animated:YES];
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
