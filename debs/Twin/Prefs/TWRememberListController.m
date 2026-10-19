// TWRememberListController.m — 「记忆的窗口」（0.5.0 按设计稿④重建）。
//
// 三节：记忆范围（记忆功能开关 + 记住哪些应用 全部/指定）、
//       恢复方式（自动恢复到上次尺寸 + 显示「恢复上次尺寸」按钮）、
//       已记忆（逐条 + 清除全部记忆）。
// 数据面：TWRememberSnapshot()（形态快照），删除/清空只写 jbroot 私有 plist。
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
        self.title = @"记忆的窗口";
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
    [self reloadEntries];
}

- (void)reloadEntries {
    self.entries = TWRememberSnapshot();
    [self.tableView reloadData];
}

#pragma mark - 偏好读写

- (BOOL)boolPref:(NSString *)key def:(BOOL)def {
    return [[TWPrefs shared] boolForKey:key defaultValue:def];
}

- (void)setBoolPref:(NSString *)key value:(BOOL)v {
    [[TWPrefs shared] setBool:v forKey:key];
    [[TWPrefs shared] synchronize];
}

- (void)switchChanged:(UISwitch *)sw {
    NSArray<NSString *> *keys = @[TWKeyRememberSize, TWKeyRememberAutoRestore];
    if (sw.tag >= 0 && sw.tag < (NSInteger)keys.count) {
        [self setBoolPref:keys[(NSUInteger)sw.tag] value:sw.isOn];
    }
}

- (void)segmentChanged:(UISegmentedControl *)seg {
    [[TWPrefs shared] setInteger:seg.selectedSegmentIndex forKey:TWKeyRememberAppsScope];
    [[TWPrefs shared] synchronize];
}

#pragma mark - 单元格构造

- (UITableViewCell *)switchCell:(NSString *)title key:(NSString *)key def:(BOOL)def tag:(NSInteger)tag {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"switch"];
    cell.textLabel.text = title;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = [self boolPref:key def:def];
    sw.tag = tag;
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

- (UITableViewCell *)segmentCell:(NSString *)title titles:(NSArray<NSString *> *)titles selected:(NSInteger)selected {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"segment"];
    cell.textLabel.text = title;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:titles];
    seg.selectedSegmentIndex = MIN(MAX(selected, 0), (NSInteger)titles.count - 1);
    [seg addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    seg.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:seg];
    [NSLayoutConstraint activateConstraints:@[
        [seg.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
        [seg.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
    ]];
    return cell;
}

#pragma mark - table data

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 2;
    if (section == 1) return 1;
    return self.entries.count ? (NSInteger)self.entries.count + 1 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"记忆范围";
    if (section == 1) return @"恢复方式";
    return @"已记忆";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != 2) return nil;
    return @"按「应用 + 容器」各记一份：竖屏/横屏的窗口 frame、是否处于缩小(贴边)态、停在左还是右。下次打开同一个容器就按上次的样子出现。左滑可逐条删除。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            return [self switchCell:@"记忆大小位置" key:TWKeyRememberSize def:YES tag:0];
        }
        return [self segmentCell:@"记住哪些应用" titles:@[@"全部", @"指定"]
                        selected:[[TWPrefs shared] integerForKey:TWKeyRememberAppsScope defaultValue:0]];
    }
    if (indexPath.section == 1) {
        // 「显示恢复按钮」在引擎里没有对应实现，先不摆这个开关，避免假功能。
        return [self switchCell:@"自动恢复到上次尺寸" key:TWKeyRememberAutoRestore def:YES tag:1];
    }

    // ---- 已记忆 ----
    if (self.entries.count && indexPath.row >= (NSInteger)self.entries.count) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"clear"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"clear"];
        cell.textLabel.text = @"重置记忆大小及位置";
        cell.textLabel.textColor = UIColor.systemBlueColor;
        cell.textLabel.textAlignment = NSTextAlignmentNatural;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"remember"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"remember"];
    if (!self.entries.count) {
        cell.textLabel.text = @"暂无记忆";
        cell.textLabel.textColor = UIColor.labelColor;
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
    cell.textLabel.textColor = UIColor.labelColor;
    NSString *summary = entry[@"summary"];
    if (![summary isKindOfClass:NSString.class] || !summary.length) summary = bundleID;
    cell.detailTextLabel.text = summary;
    cell.detailTextLabel.numberOfLines = 2;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 2 && self.entries.count > 0 && indexPath.row < (NSInteger)self.entries.count;
}

- (void)tableView:(UITableView *)tableView
        commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
         forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if (indexPath.section != 2) return;
    if (indexPath.row >= (NSInteger)self.entries.count) return;
    NSString *key = self.entries[(NSUInteger)indexPath.row][@"key"];
    if (!TWRememberDeleteState(key)) return;
    [self reloadEntries];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 2 && self.entries.count && indexPath.row == (NSInteger)self.entries.count) {
        [self confirmWipe];
    }
}

- (void)confirmWipe {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清除全部记忆"
                                                                   message:@"所有应用（含各自容器）的窗口形态记忆都会被清空，下次打开应用将使用默认窗口。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak TWRememberListController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"清除" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        TWRememberWipe();
        [weakSelf reloadEntries];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
