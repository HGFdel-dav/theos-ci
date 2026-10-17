//  DBUploadPanel — 批量上传面板实现
//  选择模式：目标仓库 + 多选 .deb → 上传模式：串行队列、可停止
//  → 结果模式：逐文件 成功/失败 明细
#import "DBUploadPanel.h"
#import "DBCommon.h"
#import "DBGitHubClient.h"

typedef NS_ENUM(NSInteger, DBUploadMode) {
    DBUploadModeSelect = 0,
    DBUploadModeUploading = 1,
    DBUploadModeResult = 2
};

@interface DBUploadRootViewController : UITableViewController
@end

@implementation DBUploadPanelViewController

+ (void)presentFromViewController:(UIViewController *)presenter {
    UIViewController *target = presenter ?: DBTopViewController();
    if (!target || target.presentedViewController) return;
    DBUploadRootViewController *root = [[DBUploadRootViewController alloc] init];
    DBUploadPanelViewController *nav =
        [[DBUploadPanelViewController alloc] initWithRootViewController:root];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [target presentViewController:nav animated:YES completion:nil];
}

@end

#pragma mark - 根视图控制器

@interface DBUploadRootViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSArray<NSString *> *filePaths;
@property (nonatomic, strong) NSMutableArray<DBDebInfo *> *infos;      // 与 filePaths 对应
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *fileSizes;
@property (nonatomic, strong) NSMutableIndexSet *selectedSet;
@property (nonatomic, strong) NSArray<NSDictionary *> *repos;
@property (nonatomic, assign) NSInteger repoIndex;

@property (nonatomic, assign) DBUploadMode mode;
@property (nonatomic, strong) DBGitHubClient *client;
@property (nonatomic, strong) NSArray<NSString *> *queuePaths;         // 选定待上传
@property (nonatomic, assign) NSUInteger doneCount;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *results; // @{file, ok, text}
@property (nonatomic, assign) BOOL stopRequested;
@end

@implementation DBUploadRootViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"批量上传";
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                      target:self
                                                      action:@selector(closeTapped)];
    self.tableView.estimatedRowHeight = 60.0;
    self.tableView.rowHeight = UITableViewAutomaticDimension;

    _filePaths = [DBScanDebFiles() copy];
    _fileSizes = [NSMutableDictionary dictionary];
    _infos = [NSMutableArray array];
    _selectedSet = [NSMutableIndexSet indexSet];
    _repos = [DBLoadBoundRepos() copy];
    _repoIndex = 0;
    _results = [NSMutableArray array];
    _mode = DBUploadModeSelect;
    _doneCount = 0;
    _stopRequested = NO;

    // 后台解析包名（dpkg-deb / 内置 ar 解析），完成后刷新列表
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        NSMutableArray *parsed = [NSMutableArray array];
        for (NSString *p in s->_filePaths) {
            [parsed addObject:[DBDebInfo infoForDebAtPath:p]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            s->_infos = parsed;
            [s.tableView reloadData];
        });
    });

    [self.navigationController setToolbarHidden:NO animated:NO];
    [self reloadToolbar];
}

#pragma mark - 工具栏

- (void)reloadToolbar {
    UIBarButtonItem *flex =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                      target:nil action:nil];
    if (_mode == DBUploadModeSelect) {
        NSUInteger n = _selectedSet.count;
        BOOL allSelected = (_filePaths.count > 0 && n == _filePaths.count);
        UIBarButtonItem *toggle = [[UIBarButtonItem alloc]
                                   initWithTitle:allSelected ? @"清空" : @"全选"
                                   style:UIBarButtonItemStylePlain
                                   target:self action:@selector(toggleAllTapped)];
        UIBarButtonItem *start = [[UIBarButtonItem alloc]
                                  initWithTitle:[NSString stringWithFormat:@"开始上传 (%lu)", (unsigned long)n]
                                  style:UIBarButtonItemStyleDone
                                  target:self action:@selector(startUpload)];
        start.enabled = (n > 0);
        self.toolbarItems = @[toggle, flex, start];
    } else if (_mode == DBUploadModeUploading) {
        UIBarButtonItem *stop = [[UIBarButtonItem alloc]
                                 initWithTitle:@"停止后续文件"
                                 style:UIBarButtonItemStylePlain
                                 target:self action:@selector(stopTapped)];
        self.toolbarItems = @[stop, flex];
    } else {
        UIBarButtonItem *done = [[UIBarButtonItem alloc]
                                 initWithTitle:@"完成"
                                 style:UIBarButtonItemStyleDone
                                 target:self action:@selector(closeTapped)];
        self.toolbarItems = @[done, flex];
    }
}

#pragma mark - 表数据

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2; // 0: 目标仓库 / 1: 文件或结果
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    if (_mode == DBUploadModeSelect) return MAX((NSInteger)_filePaths.count, 1);
    if (_mode == DBUploadModeUploading) return (NSInteger)_queuePaths.count;
    return (NSInteger)_results.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"目标仓库";
    if (_mode == DBUploadModeSelect) return @"选择文件";
    if (_mode == DBUploadModeUploading) return @"上传进度";
    return [NSString stringWithFormat:@"逐文件结果（成功 %lu / %lu）",
            (unsigned long)[self successCount], (unsigned long)_results.count];
}

- (NSUInteger)successCount {
    NSUInteger ok = 0;
    for (NSDictionary *r in _results) {
        if ([r[@"ok"] boolValue]) ok++;
    }
    return ok;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"dbbox";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:cellID];
        cell.detailTextLabel.numberOfLines = 0;
    }
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.textLabel.textColor = [UIColor labelColor];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    if (indexPath.section == 0) {
        [self configureRepoCell:cell];
        return cell;
    }

    if (_mode == DBUploadModeSelect) {
        if (!_filePaths.count) {
            cell.textLabel.text = @"没有可上传的 .deb";
            cell.detailTextLabel.text = @"请先把 .deb 放入 Debs 的「管理文件」目录";
            return cell;
        }
        NSString *path = _filePaths[(NSUInteger)indexPath.row];
        cell.textLabel.text = [path lastPathComponent];
        NSNumber *sizeNum = _fileSizes[path];
        if (!sizeNum) {
            NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
            sizeNum = @(attr.fileSize);
            _fileSizes[path] = sizeNum;
        }
        NSMutableString *detail = [NSMutableString stringWithString:DBHumanSize(sizeNum.unsignedLongLongValue)];
        DBDebInfo *info = (_infos.count > (NSUInteger)indexPath.row) ? _infos[(NSUInteger)indexPath.row] : nil;
        if (info.parsed) {
            [detail appendFormat:@"\n%@_%@_%@", info.package,
             info.version.length ? info.version : @"?", info.architecture.length ? info.architecture : @"?"];
        } else if (info) {
            [detail appendString:@"\n（未解析出包名，将使用原文件名）"];
        }
        cell.detailTextLabel.text = detail;
        cell.accessoryType = [_selectedSet containsIndex:(NSUInteger)indexPath.row]
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        return cell;
    }

    if (_mode == DBUploadModeUploading) {
        NSString *path = _queuePaths[(NSUInteger)indexPath.row];
        cell.textLabel.text = [path lastPathComponent];
        if ((NSUInteger)indexPath.row < _results.count) {
            NSDictionary *r = _results[(NSUInteger)indexPath.row];
            BOOL ok = [r[@"ok"] boolValue];
            cell.textLabel.text = [NSString stringWithFormat:@"%@ %@", ok ? @"✓" : @"✗", [path lastPathComponent]];
            cell.detailTextLabel.text = r[@"text"];
            cell.detailTextLabel.textColor = ok ? [UIColor systemGreenColor] : [UIColor systemRedColor];
        } else if ((NSUInteger)indexPath.row == _doneCount) {
            if (_stopRequested) {
                cell.detailTextLabel.text = @"已停止";
                cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            } else {
                cell.detailTextLabel.text = @"上传中…";
                UIActivityIndicatorView *sp = [[UIActivityIndicatorView alloc]
                                               initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
                [sp startAnimating];
                cell.accessoryView = sp;
            }
        } else {
            cell.detailTextLabel.text = @"等待";
        }
        return cell;
    }

    // 结果模式
    NSDictionary *r = _results[(NSUInteger)indexPath.row];
    BOOL ok = [r[@"ok"] boolValue];
    cell.textLabel.text = [NSString stringWithFormat:@"%@ %@", ok ? @"✓" : @"✗", r[@"file"]];
    cell.textLabel.textColor = ok ? [UIColor systemGreenColor] : [UIColor systemRedColor];
    cell.detailTextLabel.text = r[@"text"];
    return cell;
}

- (void)configureRepoCell:(UITableViewCell *)cell {
    if (_repos.count == 0) {
        cell.textLabel.text = @"未绑定仓库";
        cell.detailTextLabel.text = @"请先在 Debs「源 → 我的越狱源」绑定 GitHub 仓库";
        cell.detailTextLabel.textColor = [UIColor systemRedColor];
        cell.accessoryType = UITableViewCellAccessoryNone;
        return;
    }
    NSDictionary *repo = _repos[(NSUInteger)_repoIndex];
    cell.textLabel.text = DBRepoDisplayName(repo);
    NSString *dir = DBRepoUploadDir(repo);
    cell.detailTextLabel.text = dir.length ? [NSString stringWithFormat:@"上传目录：%@", dir] : @"上传目录：仓库根目录";
    cell.accessoryType = _repos.count > 1 ? UITableViewCellAccessoryDisclosureIndicator
                                          : UITableViewCellAccessoryNone;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_mode != DBUploadModeSelect) return;
    if (indexPath.section == 0) {
        [self presentRepoPicker];
        return;
    }
    if (!_filePaths.count) return;
    NSUInteger idx = (NSUInteger)indexPath.row;
    if ([_selectedSet containsIndex:idx]) {
        [_selectedSet removeIndex:idx];
    } else {
        [_selectedSet addIndex:idx];
    }
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    [self reloadToolbar];
}

- (void)presentRepoPicker {
    if (_repos.count <= 1) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"选择目标仓库"
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    [_repos enumerateObjectsUsingBlock:^(NSDictionary *repo, NSUInteger i, BOOL *stop) {
        [ac addAction:[UIAlertAction actionWithTitle:DBRepoDisplayName(repo)
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *action) {
            self->_repoIndex = (NSInteger)i;
            [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:0 inSection:0]]
                                  withRowAnimation:UITableViewRowAnimationNone];
        }]];
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = self.view;
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)toggleAllTapped {
    if (_filePaths.count == 0) return;
    if (_selectedSet.count == _filePaths.count) {
        [_selectedSet removeAllIndexes];
    } else {
        [_selectedSet addIndexesInRange:NSMakeRange(0, _filePaths.count)];
    }
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                  withRowAnimation:UITableViewRowAnimationNone];
    [self reloadToolbar];
}

#pragma mark - 上传流程

- (void)startUpload {
    if (_repos.count == 0) {
        [self alert:@"请先在 Debs「源 → 我的越狱源」绑定 GitHub 仓库，再开始批量上传"];
        return;
    }
    if (_selectedSet.count == 0) return;

    NSMutableArray *q = [NSMutableArray array];
    [_selectedSet enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx < _filePaths.count) [q addObject:_filePaths[idx]];
    }];
    if (!q.count) return;

    _queuePaths = q;
    _results = [NSMutableArray array];
    _doneCount = 0;
    _stopRequested = NO;
    _mode = DBUploadModeUploading;
    self.title = [NSString stringWithFormat:@"正在批量上传 · 已处理 0/%lu", (unsigned long)_queuePaths.count];
    [self reloadToolbar];
    [self.tableView reloadData];

    NSDictionary *repo = _repos[(NSUInteger)_repoIndex];
    _client = [[DBGitHubClient alloc] initWithRepo:repo];
    DBLOG(@"开始批量上传：%@ 共 %lu 个文件", DBRepoDisplayName(repo), (unsigned long)_queuePaths.count);

    __weak typeof(self) weakSelf = self;
    [_client prepareWithCompletion:^(NSError *err) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        if (err) {
            [s abortUploadWithError:err];
            return;
        }
        [s processNext];
    }];
}

- (void)abortUploadWithError:(NSError *)err {
    _mode = DBUploadModeSelect;
    _queuePaths = nil;
    _results = [NSMutableArray array];
    _doneCount = 0;
    self.title = @"批量上传";
    [self reloadToolbar];
    [self.tableView reloadData];
    [self alert:[NSString stringWithFormat:@"目标仓库准备失败：%@", err.localizedDescription]];
}

- (void)processNext {
    if (_stopRequested || _doneCount >= _queuePaths.count) {
        [self finishUpload];
        return;
    }
    NSUInteger idx = _doneCount;
    self.title = [NSString stringWithFormat:@"正在批量上传 · 已处理 %lu/%lu",
                  (unsigned long)idx, (unsigned long)_queuePaths.count];
    NSString *path = _queuePaths[idx];
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:(NSInteger)idx inSection:1]]
                          withRowAnimation:UITableViewRowAnimationNone];

    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
    if (!data.length) {
        [self appendResult:path ok:NO text:@"读取文件失败"];
        return;
    }
    DBDebInfo *info = nil;
    NSUInteger fi = [_filePaths indexOfObject:path];
    if (fi != NSNotFound && _infos.count > fi) info = _infos[fi];
    if (!info) info = [DBDebInfo infoForDebAtPath:path];
    NSString *target = [info targetFileNameWithFallback:[path lastPathComponent]];
    DBLOG(@"上传：%@ → %@", [path lastPathComponent], target);

    __weak typeof(self) weakSelf = self;
    [_client uploadData:data fileName:target completion:^(NSString *resultText, NSError *error) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        if (error) {
            [s appendResult:path ok:NO text:error.localizedDescription];
        } else {
            [s appendResult:path ok:YES text:resultText];
        }
    }];
}

- (void)appendResult:(NSString *)path ok:(BOOL)ok text:(NSString *)text {
    [_results addObject:@{@"file": [path lastPathComponent] ?: @"?",
                          @"ok": @(ok),
                          @"text": text ?: @""}];
    _doneCount++;
    DBLOG(@"结果 %lu/%lu：%@ %@", (unsigned long)_doneCount, (unsigned long)_queuePaths.count,
          ok ? @"成功" : @"失败", text);
    [self processNext];
}

- (void)stopTapped {
    _stopRequested = YES;
    [self.tableView reloadData];
    [self reloadToolbar];
}

- (void)finishUpload {
    _mode = DBUploadModeResult;
    self.title = @"批量上传逐文件结果";
    [self reloadToolbar];
    [self.tableView reloadData];
    DBLOG(@"批量上传结束：成功 %lu/%lu", (unsigned long)[self successCount], (unsigned long)_results.count);
}

#pragma mark - 其它

- (void)alert:(NSString *)message {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"批量上传"
                                                                message:message
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end