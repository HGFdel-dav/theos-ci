// TWCraneAppsController.m
// Manage { bundleID : containerID } entries written into TWPrefs.
#import "TWCraneAppsController.h"
#import "TWPath.h"
#import "TWPrefs.h"
#import <objc/message.h>

NSString *TWLocalizedNameForBundleID(NSString *bundleID) {
    Class proxyCls = NSClassFromString(@"LSApplicationProxy");
    if (proxyCls) {
        id (*msg)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        id proxy = msg(proxyCls, NSSelectorFromString(@"applicationProxyForIdentifier:"), bundleID);
        if (proxy) {
            id name = msg(proxy, NSSelectorFromString(@"localizedName"));
            if ([name isKindOfClass:[NSString class]] && [name length]) return name;
        }
    }
    return bundleID;
}

#pragma mark - picker (choose an app to add)

@implementation TWAppPickerController {
    NSArray<NSDictionary *> *_allApps;      // {id, name}
    NSArray<NSDictionary *> *_filteredApps;
    UISearchController *_search;
}

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = @"选择应用";
        _allApps = [self loadApps];
        _filteredApps = _allApps;
    }
    return self;
}

- (NSArray<NSDictionary *> *)loadApps {
    NSMutableArray *apps = [NSMutableArray array];
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (workspaceClass) {
        id (*msg)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id workspace = msg(workspaceClass, NSSelectorFromString(@"defaultWorkspace"));
        id list = workspace ? msg(workspace, NSSelectorFromString(@"allApplications")) : nil;
        if ([list isKindOfClass:[NSArray class]]) {
            for (id proxy in list) {
                NSString *bundleID = [proxy valueForKey:@"bundleIdentifier"];
                if (![bundleID isKindOfClass:[NSString class]] || !bundleID.length) continue;
                if ([bundleID hasPrefix:@"com.apple."]) continue;
                NSString *name = [proxy valueForKey:@"localizedName"];
                [apps addObject:@{@"id": bundleID, @"name": (name.length ? name : bundleID)}];
            }
        }
    }
    [apps sortUsingComparator:^NSComparisonResult(id a, id b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    return apps;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _search = [[UISearchController alloc] initWithSearchResultsController:nil];
    _search.searchResultsUpdater = self;
    _search.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = _search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_filteredApps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"app"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"app"];
    NSDictionary *entry = _filteredApps[(NSUInteger)indexPath.row];
    cell.textLabel.text = entry[@"name"];
    cell.detailTextLabel.text = entry[@"id"];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *entry = _filteredApps[(NSUInteger)indexPath.row];
    NSString *bundleID = entry[@"id"];
    NSString *appName = entry[@"name"];
    NSString *current = [[TWPrefs shared] craneApps][bundleID];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"%@ 的 Crane 容器", appName]
                                                                   message:@"输入该应用的 Crane 容器 ID（在 Crane 设置中查看）。留空并保存将移除此应用。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"容器 ID";
        tf.text = current;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *text = alert.textFields.firstObject.text ?: @"";
        text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (text.length) {
            [[TWPrefs shared] setCraneApp:text forBundleID:bundleID];
        } else {
            [[TWPrefs shared] removeCraneAppForBundleID:bundleID];
        }
        [self.navigationController popViewControllerAnimated:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = searchController.searchBar.text ?: @"";
    query = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!query.length) {
        _filteredApps = _allApps;
    } else {
        NSPredicate *p = [NSPredicate predicateWithFormat:@"name CONTAINS[cd] %@ OR id CONTAINS[cd] %@", query, query];
        _filteredApps = [_allApps filteredArrayUsingPredicate:p];
    }
    [self.tableView reloadData];
}

@end

#pragma mark - editor (list of configured apps)

@implementation TWCraneAppsController {
    NSArray<NSString *> *_bundleIDs;
}

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = @"分身应用列表";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                                            target:self
                                                                                            action:@selector(addTapped)];
    [self reloadData];
    // refresh when returning from the picker
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadData)
                                                 name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)reloadData {
    _bundleIDs = [[TWPrefs shared] craneApps].allKeys;
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_bundleIDs.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"点击应用可修改容器 ID；左滑删除。容器 ID 可在 Crane 的设置中查看。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"craneApp"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"craneApp"];
    NSString *bundleID = _bundleIDs[(NSUInteger)indexPath.row];
    NSString *container = [[TWPrefs shared] craneApps][bundleID];
    cell.textLabel.text = TWLocalizedNameForBundleID(bundleID);
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ ｜ 容器: %@", bundleID, container.length ? container : @"(空)"];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *bundleID = _bundleIDs[(NSUInteger)indexPath.row];
    NSString *appName = TWLocalizedNameForBundleID(bundleID);
    NSString *current = [[TWPrefs shared] craneApps][bundleID];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"%@ 的 Crane 容器", appName]
                                                                   message:@"输入该应用的 Crane 容器 ID。留空并保存将移除此应用。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"容器 ID";
        tf.text = current;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *text = alert.textFields.firstObject.text ?: @"";
        text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (text.length) {
            [[TWPrefs shared] setCraneApp:text forBundleID:bundleID];
        } else {
            [[TWPrefs shared] removeCraneAppForBundleID:bundleID];
        }
        [self reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
                                            forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        NSString *bundleID = _bundleIDs[(NSUInteger)indexPath.row];
        [[TWPrefs shared] removeCraneAppForBundleID:bundleID];
        [self reloadData];
    }
}

- (void)addTapped {
    TWAppPickerController *picker = [[TWAppPickerController alloc] init];
    [self.navigationController pushViewController:picker animated:YES];
}

@end