//
//  DNBPanelViewController.m
//  DebsNewsBatch
//
//  「新闻批量下载」面板：勾选新闻条目 -> 批量下载对应 deb 到 Downloads/DEBs/。
//

#import "DNBPanelViewController.h"
#import "DNBCommon.h"
#import "DNBNewsStore.h"
#import "DNBDownloader.h"
#import "DNBLogic.h"

static UIColor *DNBBackgroundColor(void)
{
    return [UIColor colorWithRed:0.043 green:0.051 blue:0.070 alpha:1.0];
}
static UIColor *DNBCardColor(void)
{
    return [UIColor colorWithRed:0.078 green:0.094 blue:0.129 alpha:1.0];
}
static UIColor *DNBAccentColor(void)
{
    return [UIColor colorWithRed:0.227 green:0.627 blue:1.0 alpha:1.0];
}
static UIColor *DNBSecondaryTextColor(void)
{
    return [UIColor colorWithWhite:0.62 alpha:1.0];
}

#pragma mark - 列表单元格

@interface DNBCell : UITableViewCell
@property (nonatomic, strong) UIImageView *checkView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *statusLabel;
- (void)applyItem:(DNBNewsItem *)item selected:(BOOL)selected status:(NSString *)status color:(UIColor *)color;
@end

@implementation DNBCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = DNBCardColor();
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _checkView = [[UIImageView alloc] init];
        _checkView.contentMode = UIViewContentModeScaleAspectFit;
        _checkView.tintColor = DNBAccentColor();

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [UIColor whiteColor];
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

        _subtitleLabel = [[UILabel alloc] init];
        _subtitleLabel.font = [UIFont systemFontOfSize:11.5];
        _subtitleLabel.textColor = DNBSecondaryTextColor();
        _subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;

        _statusLabel = [[UILabel alloc] init];
        _statusLabel.font = [UIFont systemFontOfSize:11.0];
        _statusLabel.textAlignment = NSTextAlignmentRight;
        _statusLabel.numberOfLines = 2;
        _statusLabel.lineBreakMode = NSLineBreakByTruncatingTail;

        [self.contentView addSubview:_checkView];
        [self.contentView addSubview:_titleLabel];
        [self.contentView addSubview:_subtitleLabel];
        [self.contentView addSubview:_statusLabel];
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat width = self.contentView.bounds.size.width;
    CGFloat height = self.contentView.bounds.size.height;
    self.checkView.frame = CGRectMake(14, (height - 24) / 2.0, 24, 24);
    CGFloat statusWidth = 108;
    CGFloat textX = CGRectGetMaxX(self.checkView.frame) + 12;
    CGFloat textW = width - textX - statusWidth - 12;
    self.titleLabel.frame = CGRectMake(textX, 10, textW, 19);
    self.subtitleLabel.frame = CGRectMake(textX, 30, textW, 16);
    self.statusLabel.frame = CGRectMake(width - statusWidth - 12, 12, statusWidth, 34);
}

- (void)applyItem:(DNBNewsItem *)item selected:(BOOL)selected status:(NSString *)status color:(UIColor *)color
{
    NSString *symbol = selected ? @"checkmark.circle.fill" : @"circle";
    self.checkView.image = [[UIImage systemImageNamed:symbol] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    self.checkView.tintColor = selected ? DNBAccentColor() : [UIColor colorWithWhite:0.35 alpha:1.0];

    self.titleLabel.text = [NSString stringWithFormat:@"%@ %@", item.name ?: @"", item.version ?: @""];
    self.subtitleLabel.text = [NSString stringWithFormat:@"%@ · %@", item.displayArch, item.sourceName ?: @"未知源"];
    self.statusLabel.text = status ?: @"";
    self.statusLabel.textColor = color ?: DNBSecondaryTextColor();
}

@end

#pragma mark - 面板

@interface DNBPanelViewController () <UITableViewDataSource, UITableViewDelegate, DNBDownloaderDelegate>
@property (nonatomic, strong) UIView *headerView;
@property (nonatomic, strong) UISegmentedControl *filterControl;
@property (nonatomic, strong) UIButton *selectAllButton;
@property (nonatomic, strong) UIButton *clearButton;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) UISwitch *overwriteSwitch;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *bottomBar;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *stopButton;
@property (nonatomic, strong) UIButton *downloadButton;

@property (nonatomic, strong) NSArray<DNBNewsItem *> *visibleItems;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedKeys;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *states;
@property (nonatomic, strong) DNBDownloader *downloader;
@property (nonatomic, assign) NSInteger filter;
@end

@implementation DNBPanelViewController

#pragma mark 生命周期

- (instancetype)init
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _selectedKeys = [NSMutableSet set];
        _states = [NSMutableDictionary dictionary];
        _filter = DNB_FILTER_ALL;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"新闻批量下载";
    self.view.backgroundColor = DNBBackgroundColor();

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"刷新" style:UIBarButtonItemStylePlain
                                         target:self action:@selector(handleReload)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone
                                         target:self action:@selector(handleDone)];
    self.navigationController.navigationBar.tintColor = DNBAccentColor();

    [self buildHeader];
    [self buildTable];
    [self buildBottomBar];
    [self reloadFromDisk];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];

    CGRect bounds = self.view.bounds;
    CGFloat topInset = self.view.safeAreaInsets.top;
    CGFloat bottomInset = self.view.safeAreaInsets.bottom;
    CGFloat width = bounds.size.width;
    CGFloat headerHeight = 104.0;

    self.headerView.frame = CGRectMake(0, topInset, width, headerHeight);
    self.filterControl.frame = CGRectMake(12, 10, width - 24, 32);
    self.selectAllButton.frame = CGRectMake(12, 52, 66, 32);
    self.clearButton.frame = CGRectMake(84, 52, 66, 32);
    self.overwriteSwitch.frame = CGRectMake(width - 63, 52, 51, 31);
    self.countLabel.frame = CGRectMake(160, 52, width - 160 - 74, 32);

    CGFloat bottomHeight = 100.0 + bottomInset;
    CGFloat bottomY = bounds.size.height - bottomHeight;
    self.bottomBar.frame = CGRectMake(0, bottomY, width, bottomHeight);
    self.progressView.frame = CGRectMake(14, 14, width - 28, 4);
    self.statusLabel.frame = CGRectMake(14, 24, width - 28, 18);
    self.stopButton.frame = CGRectMake(14, 48, 92, 38);
    self.downloadButton.frame = CGRectMake(114, 48, width - 128, 38);

    self.tableView.frame = CGRectMake(0, topInset + headerHeight, width,
                                      MAX(0.0, bottomY - topInset - headerHeight));
}

#pragma mark 界面搭建

- (void)buildHeader
{
    self.headerView = [[UIView alloc] init];
    self.headerView.backgroundColor = DNBBackgroundColor();
    [self.view addSubview:self.headerView];

    self.filterControl = [[UISegmentedControl alloc] initWithItems:@[ @"全部", @"arm64", @"arm64e", @"未下载" ]];
    self.filterControl.selectedSegmentIndex = 0;
    if (@available(iOS 13.0, *)) {
        self.filterControl.selectedSegmentTintColor = DNBAccentColor();
        [self.filterControl setTitleTextAttributes:@{ NSForegroundColorAttributeName : [UIColor whiteColor] }
                                          forState:UIControlStateSelected];
        [self.filterControl setTitleTextAttributes:@{ NSForegroundColorAttributeName : [UIColor colorWithWhite:0.85 alpha:1.0] }
                                          forState:UIControlStateNormal];
    }
    [self.filterControl addTarget:self action:@selector(handleFilterChanged) forControlEvents:UIControlEventValueChanged];
    [self.headerView addSubview:self.filterControl];

    self.selectAllButton = [self smallButton:@"全选" action:@selector(handleSelectAll)];
    [self.headerView addSubview:self.selectAllButton];

    self.clearButton = [self smallButton:@"全不选" action:@selector(handleClearSelection)];
    [self.headerView addSubview:self.clearButton];

    self.countLabel = [[UILabel alloc] init];
    self.countLabel.font = [UIFont systemFontOfSize:11.5];
    self.countLabel.textColor = DNBSecondaryTextColor();
    self.countLabel.textAlignment = NSTextAlignmentRight;
    [self.headerView addSubview:self.countLabel];

    self.overwriteSwitch = [[UISwitch alloc] init];
    self.overwriteSwitch.onTintColor = DNBAccentColor();
    self.overwriteSwitch.transform = CGAffineTransformMakeScale(0.82, 0.82);
    self.overwriteSwitch.on = NO;
    [self.overwriteSwitch addTarget:self action:@selector(handleOverwriteChanged) forControlEvents:UIControlEventValueChanged];
    [self.headerView addSubview:self.overwriteSwitch];

    UILabel *hint = [[UILabel alloc] init];
    hint.text = @"覆盖";
    hint.font = [UIFont systemFontOfSize:11.0];
    hint.textColor = DNBSecondaryTextColor();
    hint.frame = CGRectMake(self.headerView.bounds.size.width - 108, 58, 40, 20);
    hint.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [self.headerView addSubview:hint];
}

- (UIButton *)smallButton:(NSString *)title action:(SEL)action
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    button.backgroundColor = DNBCardColor();
    button.layer.cornerRadius = 8.0;
    [button setTitleColor:[UIColor colorWithWhite:0.92 alpha:1.0] forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)buildTable
{
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = DNBBackgroundColor();
    self.tableView.separatorColor = [UIColor colorWithWhite:0.16 alpha:1.0];
    self.tableView.rowHeight = 58.0;
    self.tableView.tableFooterView = [[UIView alloc] init];
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 8, 0);
    [self.tableView registerClass:[DNBCell class] forCellReuseIdentifier:@"DNBCell"];
    [self.view addSubview:self.tableView];
}

- (void)buildBottomBar
{
    self.bottomBar = [[UIView alloc] init];
    self.bottomBar.backgroundColor = [UIColor colorWithRed:0.06 green:0.07 blue:0.10 alpha:1.0];
    [self.view addSubview:self.bottomBar];

    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    self.progressView.progressTintColor = DNBAccentColor();
    self.progressView.trackTintColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    self.progressView.progress = 0.0;
    [self.bottomBar addSubview:self.progressView];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.font = [UIFont systemFontOfSize:11.5];
    self.statusLabel.textColor = DNBSecondaryTextColor();
    self.statusLabel.text = @"勾选要下载的新闻条目后点右侧按钮";
    [self.bottomBar addSubview:self.statusLabel];

    self.stopButton = [self smallButton:@"停止" action:@selector(handleStop)];
    self.stopButton.enabled = NO;
    self.stopButton.alpha = 0.5;
    [self.stopButton setTitleColor:[UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0] forState:UIControlStateNormal];
    [self.bottomBar addSubview:self.stopButton];

    self.downloadButton = [self smallButton:@"下载选中" action:@selector(handleDownload)];
    self.downloadButton.backgroundColor = DNBAccentColor();
    self.downloadButton.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    [self.downloadButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.bottomBar addSubview:self.downloadButton];
}

#pragma mark 数据

- (void)reloadFromDisk
{
    [[DNBNewsStore sharedStore] reload];
    self.filter = self.filterControl.selectedSegmentIndex;
    self.visibleItems = [[DNBNewsStore sharedStore] itemsMatchingFilter:self.filter];

    /* 丢掉已经不在新闻里的选择（例如源被删），避免误下载 */
    NSMutableSet<NSString *> *live = [NSMutableSet set];
    for (DNBNewsItem *item in [DNBNewsStore sharedStore].items) {
        [live addObject:[item uniqueKey]];
    }
    NSMutableSet<NSString *> *keep = [NSMutableSet set];
    for (NSString *key in self.selectedKeys) {
        if ([live containsObject:key]) {
            [keep addObject:key];
        }
    }
    self.selectedKeys = keep;

    [self.tableView reloadData];
    [self updateCounters];
}

- (void)updateCounters
{
    NSInteger total = (NSInteger)[DNBNewsStore sharedStore].items.count;
    NSInteger shown = (NSInteger)self.visibleItems.count;
    self.countLabel.text = [NSString stringWithFormat:@"已选 %lu · 列表 %ld/%ld",
                            (unsigned long)self.selectedKeys.count, (long)shown, (long)total];
    BOOL running = self.downloader.running;
    NSString *title = self.selectedKeys.count > 0
        ? [NSString stringWithFormat:@"下载选中 (%lu)", (unsigned long)self.selectedKeys.count]
        : @"下载选中";
    [self.downloadButton setTitle:title forState:UIControlStateNormal];
    self.downloadButton.enabled = !running && self.selectedKeys.count > 0;
    self.downloadButton.alpha = self.downloadButton.enabled ? 1.0 : 0.5;
    self.filterControl.enabled = !running;
    self.selectAllButton.enabled = !running;
    self.clearButton.enabled = !running;
    self.overwriteSwitch.enabled = !running;
}

- (NSString *)statusTextForItem:(DNBNewsItem *)item color:(UIColor **)color
{
    NSDictionary *state = self.states[[item uniqueKey]];
    if (state) {
        DNBItemState value = (DNBItemState)[state[@"state"] integerValue];
        NSString *detail = state[@"detail"];
        switch (value) {
            case DNBItemStateDownloading:
                if (color) { *color = DNBAccentColor(); }
                return detail.length ? detail : @"下载中…";
            case DNBItemStateFinished:
                if (color) { *color = [UIColor colorWithRed:0.30 green:0.85 blue:0.52 alpha:1.0]; }
                return detail.length ? detail : @"完成";
            case DNBItemStateFailed:
                if (color) { *color = [UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0]; }
                return detail.length ? detail : @"失败";
            case DNBItemStateSkipped:
                if (color) { *color = [UIColor colorWithWhite:0.55 alpha:1.0]; }
                return detail.length ? detail : @"已存在";
            case DNBItemStateCancelled:
                if (color) { *color = [UIColor colorWithWhite:0.55 alpha:1.0]; }
                return @"已取消";
            case DNBItemStateWaiting:
            default:
                if (color) { *color = DNBSecondaryTextColor(); }
                return detail.length ? detail : @"排队中";
        }
    }
    if ([[DNBNewsStore sharedStore] isDownloaded:item]) {
        if (color) { *color = [UIColor colorWithWhite:0.55 alpha:1.0]; }
        return @"已存在";
    }
    if (color) { *color = DNBSecondaryTextColor(); }
    return @"未下载";
}

#pragma mark 表格数据源

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)self.visibleItems.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    DNBCell *cell = [tableView dequeueReusableCellWithIdentifier:@"DNBCell" forIndexPath:indexPath];
    if (indexPath.row >= (NSInteger)self.visibleItems.count) {
        return cell;
    }
    DNBNewsItem *item = self.visibleItems[indexPath.row];
    UIColor *color = nil;
    NSString *status = [self statusTextForItem:item color:&color];
    [cell applyItem:item selected:[self.selectedKeys containsObject:[item uniqueKey]] status:status color:color];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    if (indexPath.row >= (NSInteger)self.visibleItems.count || self.downloader.running) {
        return;
    }
    DNBNewsItem *item = self.visibleItems[indexPath.row];
    NSString *key = [item uniqueKey];
    if ([self.selectedKeys containsObject:key]) {
        [self.selectedKeys removeObject:key];
    } else {
        [self.selectedKeys addObject:key];
    }
    [self.tableView reloadRowsAtIndexPaths:@[ indexPath ] withRowAnimation:UITableViewRowAnimationNone];
    [self updateCounters];
}

#pragma mark 交互

- (void)handleFilterChanged
{
    self.filter = self.filterControl.selectedSegmentIndex;
    self.visibleItems = [[DNBNewsStore sharedStore] itemsMatchingFilter:self.filter];
    [self.tableView reloadData];
    [self updateCounters];
}

- (void)handleSelectAll
{
    for (DNBNewsItem *item in self.visibleItems) {
        [self.selectedKeys addObject:[item uniqueKey]];
    }
    [self.tableView reloadData];
    [self updateCounters];
}

- (void)handleClearSelection
{
    [self.selectedKeys removeAllObjects];
    [self.tableView reloadData];
    [self updateCounters];
}

- (void)handleOverwriteChanged
{
    DNBLog(@"覆盖已存在：%@", self.overwriteSwitch.isOn ? @"开" : @"关");
}

- (void)handleReload
{
    if (self.downloader.running) {
        return;
    }
    [self reloadFromDisk];
    self.statusLabel.text = [NSString stringWithFormat:@"已刷新新闻：共 %lu 条",
                             (unsigned long)[DNBNewsStore sharedStore].items.count];
}

- (void)handleDone
{
    if (self.downloader.running) {
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"下载进行中"
                                                message:@"现在离开会中断剩余下载，确定吗？"
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"继续下载" style:UIAlertActionStyleCancel handler:nil]];
        __weak typeof(self) weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:@"离开并停止"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(__unused UIAlertAction *action) {
            [weakSelf.downloader stop];
            [weakSelf dismissSelf];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [self dismissSelf];
}

- (void)dismissSelf
{
    [self dismissViewControllerAnimated:YES completion:^{
        if (self.onDismiss) {
            self.onDismiss();
        }
    }];
}

- (void)handleStop
{
    if (!self.downloader.running) {
        return;
    }
    [self.downloader stop];
    self.statusLabel.text = @"已停止";
    [self updateCounters];
    [self.tableView reloadData];
}

- (void)handleDownload
{
    if (self.downloader.running) {
        return;
    }
    NSMutableArray<DNBNewsItem *> *targets = [NSMutableArray array];
    for (DNBNewsItem *item in [DNBNewsStore sharedStore].items) {
        if ([self.selectedKeys containsObject:[item uniqueKey]]) {
            [targets addObject:item];
        }
    }
    if (targets.count == 0) {
        return;
    }

    NSString *message = [NSString stringWithFormat:
        @"将依次下载 %lu 个软件包到 Downloads/DEBs/，源上没有的直接标记失败，不会覆盖已存在的文件（除非打开“覆盖”）。",
        (unsigned long)targets.count];
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"开始批量下载"
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"开始" style:UIAlertActionStyleDefault
                                             handler:^(__unused UIAlertAction *action) {
        [weakSelf beginDownloadWithItems:targets];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)beginDownloadWithItems:(NSArray<DNBNewsItem *> *)items
{
    [self.states removeAllObjects];
    for (DNBNewsItem *item in items) {
        self.states[[item uniqueKey]] = @{ @"state" : @(DNBItemStateWaiting), @"detail" : @"排队中" };
    }
    [self.tableView reloadData];

    self.downloader = [[DNBDownloader alloc] initWithItems:items
                                                overwrite:self.overwriteSwitch.isOn
                                              writeRecord:YES];
    self.downloader.delegate = self;
    [self.downloader start];

    self.stopButton.enabled = YES;
    self.stopButton.alpha = 1.0;
    self.progressView.progress = 0.0;
    self.statusLabel.text = [NSString stringWithFormat:@"准备下载 %lu 个…", (unsigned long)items.count];
    [self updateCounters];
}

#pragma mark 下载回调

- (void)downloader:(DNBDownloader *)downloader
     itemDidChange:(DNBNewsItem *)item
             state:(DNBItemState)state
            detail:(NSString *)detail
{
    self.states[[item uniqueKey]] = @{ @"state" : @(state), @"detail" : detail ?: @"" };
    NSInteger row = NSNotFound;
    NSInteger index = 0;
    for (DNBNewsItem *candidate in self.visibleItems) {
        if ([[candidate uniqueKey] isEqualToString:[item uniqueKey]]) {
            row = index;
            break;
        }
        index++;
    }
    if (row != NSNotFound) {
        NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:0];
        [self.tableView reloadRowsAtIndexPaths:@[ path ] withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (void)downloader:(DNBDownloader *)downloader progressChanged:(NSInteger)done total:(NSInteger)total
{
    self.progressView.progress = (float)(dnblogic_percent((size_t)done, (size_t)total) / 100.0);
    self.statusLabel.text = [NSString stringWithFormat:@"进度 %ld/%ld · 成功 %ld 失败 %ld 跳过 %ld",
                             (long)done, (long)total,
                             (long)downloader.successCount, (long)downloader.failedCount,
                             (long)downloader.skippedCount];
}

- (void)downloaderDidFinish:(DNBDownloader *)downloader
                    success:(NSInteger)success
                     failed:(NSInteger)failed
                    skipped:(NSInteger)skipped
{
    self.progressView.progress = 1.0;
    self.stopButton.enabled = NO;
    self.stopButton.alpha = 0.5;
    self.statusLabel.text = [NSString stringWithFormat:@"完成：成功 %ld · 失败 %ld · 跳过 %ld",
                             (long)success, (long)failed, (long)skipped];
    [[DNBNewsStore sharedStore] reload];
    [self.tableView reloadData];
    [self updateCounters];

    NSString *detail = [NSString stringWithFormat:@"位置：Documents/Downloads/DEBs/\n日志：Documents/debsnewsbatch.log"];
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"下载结束（成功 %ld）", (long)success]
                                            message:detail
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
