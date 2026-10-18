// TWContainerListController.m
#import "TWContainerListController.h"
#import "TWSpecifiers.h"
#import "TWPath.h"
#import "TWPrefs.h"
#import <objc/message.h>
#import <dlfcn.h>

#pragma mark - 容器列表的读写（只写 jbroot 私有 plist）

static void TWSaveContainers(NSArray<NSDictionary *> *containers) {
    NSMutableArray *clean = [NSMutableArray array];
    for (id item in containers) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *bundleID = item[@"bundleID"];
        if (![bundleID isKindOfClass:NSString.class] || !bundleID.length) continue;
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"bundleID"] = bundleID;
        entry[@"containerID"] = [item[@"containerID"] isKindOfClass:NSString.class] ? item[@"containerID"] : @"";
        NSString *name = item[@"name"];
        entry[@"name"] = [name isKindOfClass:NSString.class] ? name : TWPrefsAppName(bundleID);
        NSString *badge = item[@"badge"];
        entry[@"badge"] = [badge isKindOfClass:NSString.class] && badge.length ? badge : @"分";
        entry[@"enabled"] = [item[@"enabled"] respondsToSelector:@selector(boolValue)] ? @([item[@"enabled"] boolValue]) : @YES;
        [clean addObject:entry];
    }
    [[TWPrefs shared] setObject:(clean.count ? clean : nil) forKey:TWKeyCraneContainers];
    [[TWPrefs shared] synchronize];
}

#pragma mark - Crane 反射（Crane 未装时全部返回空，页面照样能用）
// 注意：Preferences 进程里 CraneManager 默认不存在，必须先 dlopen libcrane.dylib
// （与 SpringBoard 侧 TWCraneBridge.m 同一套路径回退），否则容器列表永远是空的。

static Class TWCraneManagerClass(void) {
    static Class cls;
    static BOOL looked;
    if (!looked) {
        looked = YES;
        cls = NSClassFromString(@"CraneManager");
        if (!cls) {
            NSMutableArray<NSString *> *paths = [NSMutableArray array];
            NSString *root = TWJBRootPath();
            if (root.length) [paths addObject:[root stringByAppendingPathComponent:@"usr/lib/libcrane.dylib"]];
            [paths addObjectsFromArray:@[@"/var/jb/usr/lib/libcrane.dylib", @"/usr/lib/libcrane.dylib"]];
            for (NSString *path in paths) {
                if ([NSFileManager.defaultManager fileExistsAtPath:path] &&
                    dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) {
                    cls = NSClassFromString(@"CraneManager");
                    if (cls) break;
                }
            }
        }
    }
    return cls;
}

static id TWCraneCall(NSString *selectorName, NSArray *arguments) {
    Class cls = TWCraneManagerClass();
    if (!cls) return nil;
    SEL sel = NSSelectorFromString(selectorName);
    if (![cls respondsToSelector:sel]) return nil;
    if (arguments.count == 0) return ((id (*)(id, SEL))objc_msgSend)(cls, sel);
    if (arguments.count == 1) return ((id (*)(id, SEL, id))objc_msgSend)(cls, sel, arguments[0]);
    return ((id (*)(id, SEL, id, id, BOOL))objc_msgSend)(cls, sel, arguments[0], arguments[1], NO);
}

// Crane 的容器显示名（方法名按已解包的 com.wkk.crane 1.3.17 原样使用）。
static NSString *TWCraneContainerName(NSString *containerID, NSString *bundleID) {
    if (!containerID.length) return @"默认容器";
    id name = TWCraneCall(@"displayNameForContainerWithIdentifier:ofApplicationWithIdentifier:shouldUseShortVersion:",
                          @[containerID, bundleID]);
    if ([name isKindOfClass:NSString.class] && [name length]) return name;
    return containerID;
}

// Crane 里"有非默认容器"的应用。
static NSArray<NSString *> *TWCraneAppsWithContainers(void) {
    id list = TWCraneCall(@"identfiersOfApplicationsThatHaveNonDefaultContainers", @[]);
    NSMutableArray<NSString *> *apps = [NSMutableArray array];
    if ([list isKindOfClass:NSArray.class]) {
        for (id item in list) if ([item isKindOfClass:NSString.class] && [item length]) [apps addObject:item];
    }
    return apps;
}

static NSArray<NSString *> *TWCraneContainerIDsForBundleID(NSString *bundleID) {
    id list = TWCraneCall(@"containerIdentifiersOfApplicationWithIdentifier:", @[bundleID ?: @""]);
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    if ([list isKindOfClass:NSArray.class]) {
        for (id item in list) if ([item isKindOfClass:NSString.class]) [ids addObject:item];
    }
    return ids;
}

#pragma mark - 分身应用（容器）

@implementation TWContainerListController {
    NSArray<NSDictionary *> *_containers;   // 已加入
    NSArray<NSString *> *_candidates;       // Crane 里还有容器的应用
}

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = @"分身应用（容器）";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.rightBarButtonItem = self.editButtonItem;
    [self reloadData];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadData];
}

- (void)reloadData {
    _containers = TWCraneContainers();
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    for (NSString *bundleID in TWCraneAppsWithContainers()) {
        BOOL known = NO;
        for (NSDictionary *entry in _containers) {
            if ([entry[@"bundleID"] isEqualToString:bundleID]) { known = YES; break; }
        }
        if (!known) [candidates addObject:bundleID];
    }
    _candidates = candidates;
    [self.tableView reloadData];
}

#pragma mark - 增删改

- (void)toggleContainerAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= (NSInteger)_containers.count) return;
    NSMutableArray *all = [_containers mutableCopy];
    NSMutableDictionary *entry = [all[(NSUInteger)indexPath.row] mutableCopy];
    BOOL enabled = [entry[@"enabled"] boolValue];
    entry[@"enabled"] = @(!enabled);
    all[(NSUInteger)indexPath.row] = entry;
    TWSaveContainers(all);
    [self reloadData];
}

- (void)removeContainerAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= (NSInteger)_containers.count) return;
    NSMutableArray *all = [_containers mutableCopy];
    [all removeObjectAtIndex:(NSUInteger)indexPath.row];
    TWSaveContainers(all);
    [self reloadData];
}

- (void)addContainer:(NSString *)containerID forBundleID:(NSString *)bundleID {
    NSMutableArray *all = [_containers mutableCopy];
    for (NSDictionary *entry in all) {
        if ([entry[@"bundleID"] isEqualToString:bundleID] && [entry[@"containerID"] isEqualToString:containerID ?: @""]) return;
    }
    NSString *name = TWCraneContainerName(containerID, bundleID);
    [all addObject:@{@"bundleID": bundleID,
                     @"containerID": containerID ?: @"",
                     @"name": name.length ? name : TWPrefsAppName(bundleID),
                     @"badge": containerID.length ? @"分" : @"默",
                     @"enabled": @YES}];
    TWSaveContainers(all);
    [self reloadData];
}

- (void)pickContainerForBundleID:(NSString *)bundleID {
    NSArray<NSString *> *ids = TWCraneContainerIDsForBundleID(bundleID);
    NSString *appName = TWPrefsAppName(bundleID);
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"%@ 的容器", appName]
                                                                  message:@"选一个容器，菜单里就会多一个图标（角标区分）。"
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    __weak TWContainerListController *weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"默认容器" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [weakSelf addContainer:@"" forBundleID:bundleID];
    }]];
    for (NSString *containerID in ids) {
        NSString *title = TWCraneContainerName(containerID, bundleID);
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [weakSelf addContainer:containerID forBundleID:bundleID];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
        sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2.0, self.view.bounds.size.height / 2.0, 1, 1);
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return _containers.count ? (NSInteger)_containers.count : 1;
    return _candidates.count ? (NSInteger)_candidates.count : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"已加入菜单的容器" : @"Crane 里还有容器的应用";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return _containers.count
            ? @"点一下切换「是否出现在菜单里」，左滑删除。角标：默＝默认容器，分＝分身容器。"
            : @"还没有容器。先在 Crane 里给应用建好容器，再在下面把它加进来。";
    }
    return TWCraneManagerClass()
        ? @"点应用 → 选容器，即可把它加进 Arc 菜单。一个应用可以加入多个容器。"
        : @"没有检测到 Crane（com.wkk.crane）。装好 Crane 并重启后，这里会列出已有容器的应用。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"container"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"container"];

    if (indexPath.section == 0) {
        if (!_containers.count) {
            cell.textLabel.text = @"暂无容器";
            cell.detailTextLabel.text = TWCraneManagerClass() ? @"从下面选择一个应用开始。" : @"需要先安装 Crane。";
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
        NSDictionary *entry = _containers[(NSUInteger)indexPath.row];
        NSString *bundleID = entry[@"bundleID"];
        BOOL enabled = [entry[@"enabled"] boolValue];
        cell.textLabel.text = [NSString stringWithFormat:@"%@", TWPrefsAppName(bundleID)];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"角标 %@ ｜ %@ ｜ %@",
                                     entry[@"badge"], entry[@"name"], bundleID];
        cell.accessoryType = enabled ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.textLabel.textColor = enabled ? [UIColor labelColor] : [UIColor tertiaryLabelColor];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }

    if (!_candidates.count) {
        cell.textLabel.text = TWCraneManagerClass() ? @"没有更多容器" : @"未检测到 Crane";
        cell.detailTextLabel.text = @"";
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSString *bundleID = _candidates[(NSUInteger)indexPath.row];
    cell.textLabel.text = TWPrefsAppName(bundleID);
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ ｜ %lu 个容器",
                                 bundleID, (unsigned long)TWCraneContainerIDsForBundleID(bundleID).count];
    cell.textLabel.textColor = [UIColor labelColor];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        if (_containers.count) [self toggleContainerAtIndexPath:indexPath];
        return;
    }
    if (_candidates.count) [self pickContainerForBundleID:_candidates[(NSUInteger)indexPath.row]];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 0 && _containers.count > 0;
}

- (void)tableView:(UITableView *)tableView
        commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
         forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) [self removeContainerAtIndexPath:indexPath];
}

@end

#pragma mark - Arc 图标顺序

@implementation TWArcOrderController {
    NSMutableArray<NSString *> *_order;
    NSArray<NSString *> *_suggestions;
}

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = @"Arc 图标顺序";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.rightBarButtonItem = self.editButtonItem;
    // 0.4.5：leftBarButtonItem 会顶掉系统返回键 —— 必须补 leftItemsSupplementBackButton，
    // 否则子页没有返回键，只能杀后台退出（用户实测反馈）。
    self.navigationItem.leftItemsSupplementBackButton = YES;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"加入"
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self
                                                                            action:@selector(addBundleIDTapped)];
    [self reloadData];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadData];
}

- (void)reloadData {
    _order = [TWArcOrderList() mutableCopy] ?: [NSMutableArray array];
    NSMutableArray<NSString *> *suggestions = [NSMutableArray array];
    for (NSDictionary *entry in TWCraneContainers()) {
        NSString *bundleID = entry[@"bundleID"];
        if (bundleID.length && ![_order containsObject:bundleID] && ![suggestions containsObject:bundleID]) {
            [suggestions addObject:bundleID];
        }
    }
    _suggestions = suggestions;
    [self.tableView reloadData];
}

- (void)save {
    TWSetArcOrderList(_order);
}

- (void)addBundleIDTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"加入 Arc 菜单"
                                                                   message:@"输入应用的 bundleID（例如 com.tencent.xin）。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"bundleID";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak TWArcOrderController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"加入" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *text = alert.textFields.firstObject.text ?: @"";
        text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!text.length) return;
        TWArcOrderController *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (![strongSelf->_order containsObject:text]) [strongSelf->_order addObject:text];
        [strongSelf save];
        [strongSelf reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return _order.count ? (NSInteger)_order.count : 1;
    return _suggestions.count ? (NSInteger)_suggestions.count : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"菜单里的顺序（从上到下）" : @"分身里有容器的应用";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return _order.count
            ? @"点「编辑」拖动排序，顺序就是 Arc 菜单里图标的排列顺序；左滑删除（只影响菜单，不动 Crane 的容器）。"
            : @"列表为空：点左上角「加入」手动填 bundleID，或从下面的应用列表加入。";
    }
    return @"点一下把该应用加入菜单；容器层面的选择在「分身应用（容器）」里做。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"order"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"order"];

    if (indexPath.section == 0) {
        if (!_order.count) {
            cell.textLabel.text = @"暂无条目";
            cell.detailTextLabel.text = @"从下面的应用列表加入，或点右上角「编辑」后拖动。";
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
        NSString *bundleID = _order[(NSUInteger)indexPath.row];
        cell.textLabel.text = [NSString stringWithFormat:@"%ld. %@", (long)(indexPath.row + 1), TWPrefsAppName(bundleID)];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ ｜ %lu 个容器",
                                     bundleID, (unsigned long)[self containerCountForBundleID:bundleID]];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    if (!_suggestions.count) {
        cell.textLabel.text = @"没有更多可加入的应用";
        cell.detailTextLabel.text = @"";
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSString *bundleID = _suggestions[(NSUInteger)indexPath.row];
    cell.textLabel.text = TWPrefsAppName(bundleID);
    cell.detailTextLabel.text = bundleID;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (NSUInteger)containerCountForBundleID:(NSString *)bundleID {
    NSUInteger count = 0;
    for (NSDictionary *entry in TWCraneContainers()) {
        if ([entry[@"bundleID"] isEqualToString:bundleID]) count++;
    }
    return count;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1 || !_suggestions.count) return;
    NSString *bundleID = _suggestions[(NSUInteger)indexPath.row];
    if (![_order containsObject:bundleID]) [_order addObject:bundleID];
    [self save];
    [self reloadData];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 0 && _order.count > 0;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 0 && _order.count > 1;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView
           editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 0) return UITableViewCellEditingStyleNone;
    return _order.count > 0 ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView *)tableView
        commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
         forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if (indexPath.row >= (NSInteger)_order.count) return;
    [_order removeObjectAtIndex:(NSUInteger)indexPath.row];
    [self save];
    [self reloadData];
}

- (void)tableView:(UITableView *)tableView
        moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath
       toIndexPath:(NSIndexPath *)destinationIndexPath {
    if (sourceIndexPath.section != 0 || destinationIndexPath.section != 0) return;
    if (sourceIndexPath.row >= (NSInteger)_order.count || destinationIndexPath.row >= (NSInteger)_order.count) return;
    NSString *moved = _order[(NSUInteger)sourceIndexPath.row];
    [_order removeObjectAtIndex:(NSUInteger)sourceIndexPath.row];
    [_order insertObject:moved atIndex:(NSUInteger)destinationIndexPath.row];
    [self save];
    [self.tableView reloadData];
}

@end