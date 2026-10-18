// TWContainerListController.m — 「分身应用（容器）」（0.6.0 照 ScreenCore 原版重写）。
//
// 行样式与 ScreenCore 的 Crane 容器页一致：
//   [应用图标]  应用名 - 容器名            [开关]
//   · 自动列出 Crane 里所有带容器的应用（含「默认」容器），无需手动添加
//   · 开关控制该容器是否出现在 Twin 的弧形菜单里
//   · 图标用 _applicationIconImageForBundleIdentifier:format:scale:
//     （ScreenCore 同款私有方法），LSApplicationProxy 兜底
//   · Crane 未装时页面照常显示，只是没有行
#import "TWContainerListController.h"
#import "TWSpecifiers.h"
#import "TWPath.h"
#import "TWPrefs.h"
#import <objc/message.h>
#import <dlfcn.h>

#pragma mark - 容器列表读写（只写 jbroot 私有 plist）

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

#pragma mark - 应用图标（照抄 ScreenCore 的取法）

static UIImage *TWAppIcon(NSString *bundleID) {
    if (!bundleID.length) return nil;
    CGFloat scale = UIScreen.mainScreen.scale;
    // ① ScreenCore 同款：私有 UIImage 方法，Preferences 进程内可用
    SEL sel3 = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if ([UIImage respondsToSelector:sel3]) {
        UIImage *img = ((id (*)(id, SEL, id, long, double))objc_msgSend)(UIImage.class, sel3, bundleID, 0, (double)scale);
        if ([img isKindOfClass:UIImage.class] && img.size.width > 0) return img;
    }
    // ② 兜底：LSApplicationProxy iconDataForVariant:
    Class proxyCls = NSClassFromString(@"LSApplicationProxy");
    if (proxyCls) {
        id proxy = [proxyCls performSelector:NSSelectorFromString(@"applicationProxyForIdentifier:") withObject:bundleID];
        if (proxy) {
            SEL sel = NSSelectorFromString(@"iconDataForVariant:");
            if ([proxy respondsToSelector:sel]) {
                id data = ((id (*)(id, SEL, int))objc_msgSend)(proxy, sel, 2);
                if ([data isKindOfClass:NSData.class]) {
                    UIImage *img = [UIImage imageWithData:data scale:scale];
                    if (img) return img;
                }
            }
        }
    }
    return nil;
}

#pragma mark - Crane 反射（Crane 未装时全部返回空，页面照样能用）

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
    if (!containerID.length) return @"默认";
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
    NSArray<NSDictionary *> *_rows;   // {bundleID, containerID, enabled} 自动发现 + 开关状态
}

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = @"分身应用";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
    [refresh addTarget:self action:@selector(reloadContainers) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refresh;
    [self reloadContainers];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadContainers];
}

- (void)reloadContainers {
    // 旧数据：用户已有的开关状态（同一键，兼容 0.5.x 存储格式）
    NSDictionary *saved = [[TWPrefs shared] objectForKey:TWKeyCraneContainers];
    NSMutableDictionary<NSString *, NSNumber *> *enabledMap = [NSMutableDictionary dictionary];
    if ([saved isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)saved) {
            if (![item isKindOfClass:NSDictionary.class]) continue;
            NSString *bundleID = item[@"bundleID"];
            NSString *containerID = item[@"containerID"];
            if (![bundleID isKindOfClass:NSString.class]) continue;
            if (![containerID isKindOfClass:NSString.class]) containerID = @"";
            id enabled = item[@"enabled"];
            BOOL on = [enabled respondsToSelector:@selector(boolValue)] ? [enabled boolValue] : YES;
            enabledMap[[NSString stringWithFormat:@"%@|%@", bundleID, containerID]] = @(on);
        }
    }

    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (NSString *bundleID in TWCraneAppsWithContainers()) {
        NSMutableArray<NSString *> *ids = [NSMutableArray arrayWithObject:@""];
        [ids addObjectsFromArray:TWCraneContainerIDsForBundleID(bundleID)];
        for (NSString *containerID in ids) {
            NSString *mapKey = [NSString stringWithFormat:@"%@|%@", bundleID, containerID];
            NSNumber *enabled = enabledMap[mapKey];
            [rows addObject:@{
                @"bundleID": bundleID,
                @"containerID": containerID,
                @"enabled": enabled ?: @YES,   // 新发现默认开（与 ScreenCore 一致）
            }];
        }
    }
    _rows = rows;
    [self.refreshControl endRefreshing];
    [self.tableView reloadData];
}

- (void)persistRows {
    NSMutableArray<NSDictionary *> *saved = [NSMutableArray array];
    for (NSDictionary *row in _rows) {
        [saved addObject:@{
            @"bundleID": row[@"bundleID"],
            @"containerID": row[@"containerID"] ?: @"",
            @"name": TWPrefsAppName(row[@"bundleID"]),
            @"badge": [row[@"containerID"] length] ? @"分" : @"默",
            @"enabled": row[@"enabled"] ?: @YES,
        }];
    }
    TWSaveContainers(saved);
}

- (void)switchToggled:(UISwitch *)sw {
    NSInteger idx = sw.tag;
    if (idx < 0 || idx >= (NSInteger)_rows.count) return;
    NSMutableArray *updated = [_rows mutableCopy];
    NSMutableDictionary *row = [updated[(NSUInteger)idx] mutableCopy];
    row[@"enabled"] = @(sw.isOn);
    updated[(NSUInteger)idx] = row;
    _rows = updated;
    [self persistRows];
}

#pragma mark - 开关行（分身打开）

- (void)masterSwitchToggled:(UISwitch *)sw {
    [[TWPrefs shared] setBool:sw.isOn forKey:TWKeyCraneEnabled];
    [[TWPrefs shared] synchronize];
}

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    return _rows.count ? (NSInteger)_rows.count : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 1 ? @"CRANE 分身" : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return nil;
    if (!_rows.count) {
        return @"没有发现容器。先在 Crane 里给应用建好容器，再回来下拉刷新。";
    }
    return @"「应用名 - 容器名」：开关控制它是否出现在 Twin 的弧形菜单里。\n容器 ID 可在 Crane 设置中查看。\n\n⚠️ 认证取消或容器核验不符时不会打开应用。";
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 58;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"master"];
        cell.textLabel.text = @"分身打开";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [[TWPrefs shared] boolForKey:TWKeyCraneEnabled defaultValue:YES];
        [sw addTarget:self action:@selector(masterSwitchToggled:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"crane"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"crane"];
    cell.imageView.image = nil;
    cell.textLabel.text = nil;
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    if (!_rows.count) {
        cell.textLabel.text = @"暂无可加入的应用";
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }

    NSDictionary *row = _rows[(NSUInteger)indexPath.row];
    NSString *bundleID = row[@"bundleID"];
    NSString *containerID = row[@"containerID"] ?: @"";
    NSString *appName = TWPrefsAppName(bundleID);
    NSString *containerName = TWCraneContainerName(containerID, bundleID);
    // ScreenCore 同款行：应用图标 + 应用名 - 容器名 + 开关
    cell.imageView.image = TWAppIcon(bundleID);
    cell.textLabel.text = [NSString stringWithFormat:@"%@ - %@", appName, containerName];
    cell.textLabel.textColor = UIColor.labelColor;
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = [row[@"enabled"] boolValue];
    sw.tag = indexPath.row;
    [sw addTarget:self action:@selector(switchToggled:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

@end
