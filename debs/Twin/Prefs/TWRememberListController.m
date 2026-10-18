// TWRememberListController.m — 「已记忆的窗口」。
//
// 数据面（0.4.0 形态快照）：{ "bundleID|containerID" : @{p,l,docked,side,updated} }
// 优先走 TWRememberAllStates()（并行任务提供，主进程里才有），拿不到就由
// TWSpecifiers 直接读 TWKeyRememberStates 现算同样的 {key,bundleID,containerID,
// p,l,docked,side,updated,summary} —— 面板在任何进程状态下都不会空转。
// 删除 / 重置只写 jbroot 私有 plist（TWPrefs），绝不碰真实 Preferences。
#import "TWRememberListController.h"
#import "TWSpecifiers.h"
#import "TWPath.h"
#import "TWPrefs.h"

@interface TWRememberListController ()
@property (nonatomic, strong) NSArray<NSDictionary *> *entries;
@end

@implementation TWRememberListController

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = @"已记忆的窗口";
        self.toolbarItems = @[
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
            [[UIBarButtonItem alloc] initWithTitle:@"重置全部"
                                             style:UIBarButtonItemStylePlain
                                            target:self
                                            action:@selector(resetAllTapped)],
        ];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    [self reloadEntries];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.toolbarHidden = NO;
    [self reloadEntries];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.navigationController.toolbarHidden = YES;
}

- (void)reloadEntries {
    self.entries = TWRememberSnapshot();
    [self.tableView reloadData];
}

- (void)resetAllTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重置记忆大小及位置"
                                                                   message:@"所有应用（含各自容器）的窗口形态记忆都会被清空，下次打开应用将使用默认窗口。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak TWRememberListController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"重置" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        TWRememberWipe();
        [weakSelf reloadEntries];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.entries.count ? (NSInteger)self.entries.count : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"按「应用 + 容器」各记一份：竖屏/横屏的窗口 frame、是否处于缩小(贴边)态、停在左还是右。下次打开同一个容器就按上次的样子出现。左滑可逐条删除。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"remember"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"remember"];
    if (!self.entries.count) {
        cell.textLabel.text = @"暂无记忆";
        cell.detailTextLabel.text = @"打开分屏窗口并调整大小/位置后会自动记下。";
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSDictionary *entry = self.entries[(NSUInteger)indexPath.row];
    NSString *bundleID = entry[@"bundleID"];
    NSString *name = TWPrefsAppName(bundleID);
    NSString *badge = [entry[@"containerID"] length] ? [NSString stringWithFormat:@"（%@）", entry[@"containerID"]] : @"（默认容器）";
    cell.textLabel.text = [NSString stringWithFormat:@"%@ %@", name, badge];
    NSString *summary = entry[@"summary"];
    if (![summary isKindOfClass:NSString.class] || !summary.length) summary = bundleID;
    cell.detailTextLabel.text = summary;
    cell.detailTextLabel.numberOfLines = 2;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return self.entries.count > 0;
}

- (void)tableView:(UITableView *)tableView
        commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
         forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if (indexPath.row >= (NSInteger)self.entries.count) return;
    NSString *key = self.entries[(NSUInteger)indexPath.row][@"key"];
    if (!TWRememberDeleteState(key)) return;
    [self reloadEntries];
}

@end