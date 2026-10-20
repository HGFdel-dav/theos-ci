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
#import "TWStyle.h"
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

#pragma mark - 应用图标（系统私有接口取图，统一尺寸）

static UIImage *TWAppIconRaw(NSString *bundleID) {
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
        SEL proxySel = NSSelectorFromString(@"applicationProxyForIdentifier:");
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyCls, proxySel, bundleID);
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

// 统一画进 44×44pt 画布：私有接口返回的图标尺寸不一致，直接塞进
// UITableViewCell.imageView 会让每行文字左边距不一样——就是"字体和框没对齐"
// 的观感来源。统一尺寸后所有行文字起点一致。
static UIImage *TWAppIcon(NSString *bundleID) {
    UIImage *raw = TWAppIconRaw(bundleID);
    if (!raw || raw.size.width <= 0) return nil;
    if (fabs(raw.size.width - 36.0) < 0.5 && fabs(raw.size.height - 36.0) < 0.5) return raw;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(36.0, 36.0)];
    return [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *rendererContext) {
        [raw drawInRect:CGRectMake(0, 0, 36.0, 36.0)];
    }];
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
            if (root.length) {
                [paths addObject:[root stringByAppendingPathComponent:@"usr/lib/libcrane.dylib"]];
                [paths addObject:[root stringByAppendingPathComponent:@"Library/MobileSubstrate/DynamicLibraries/Crane.dylib"]];
            }
            [paths addObjectsFromArray:@[@"/var/jb/usr/lib/libcrane.dylib",
                                         @"/var/jb/Library/MobileSubstrate/DynamicLibraries/Crane.dylib",
                                         @"/usr/lib/libcrane.dylib",
                                         @"/Library/MobileSubstrate/DynamicLibraries/Crane.dylib"]];
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

static id TWCraneManagerInstance(void) {
    static id mgr;
    static BOOL looked;
    if (!looked) {
        looked = YES;
        Class cls = TWCraneManagerClass();
        if (cls) {
            SEL sel = NSSelectorFromString(@"sharedManager");
            if ([cls respondsToSelector:sel]) {
                mgr = ((id (*)(id, SEL))objc_msgSend)(cls, sel);
            }
        }
    }
    return mgr;
}

static id TWCraneCall(NSString *selectorName, NSArray *arguments) {
    id target = TWCraneManagerInstance();
    if (!target) return nil;
    SEL sel = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:sel]) return nil;
    if (arguments.count == 0) return ((id (*)(id, SEL))objc_msgSend)(target, sel);
    if (arguments.count == 1) return ((id (*)(id, SEL, id))objc_msgSend)(target, sel, arguments[0]);
    return ((id (*)(id, SEL, id, id, BOOL))objc_msgSend)(target, sel, arguments[0], arguments[1], NO);
}

// Crane 的容器显示名（方法名按已解包的 com.wkk.crane 1.3.17 原样使用）。
static NSString *TWCraneContainerName(NSString *containerID, NSString *bundleID) {
    if (!containerID.length || [containerID isEqualToString:@"DEFAULT"]) return @"默认";
    id name = TWCraneCall(@"displayNameForContainerWithIdentifier:ofApplicationWithIdentifier:shouldUseShortVersion:",
                          @[containerID, bundleID]);
    if ([name isKindOfClass:NSString.class] && [name length]) return name;
    return containerID;
}

// 面板侧读 SpringBoard 导出的容器缓存。
// 面板跑在 Settings 进程，CraneManager 只存在于 SpringBoard；直接调用永远是空的。
static NSDictionary *TWCraneContainerCache(void) {
    static NSDictionary *cache;
    static NSTimeInterval stamp;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (cache && now - stamp < 1.0) return cache;
    cache = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Twin/crane-containers.plist"];
    stamp = now;
    return cache;
}

// Crane 里"有非默认容器"的应用。
static NSArray<NSString *> *TWCraneAppsWithContainers(void) {
    NSDictionary *cache = TWCraneContainerCache();
    if ([cache[@"apps"] isKindOfClass:NSArray.class]) {
        NSMutableArray<NSString *> *apps = [NSMutableArray array];
        for (NSDictionary *app in (NSArray *)cache[@"apps"]) {
            if (![app isKindOfClass:NSDictionary.class]) continue;
            NSString *bundleID = app[@"bundleID"];
            if ([bundleID isKindOfClass:NSString.class] && [bundleID length]) [apps addObject:bundleID];
        }
        return apps;
    }
    // 缓存还没生成（SpringBoard 没跑过 Twin）：回退直接调用，兼容同进程场景。
    id list = TWCraneCall(@"identfiersOfApplicationsThatHaveNonDefaultContainers", @[]);
    NSMutableArray<NSString *> *apps = [NSMutableArray array];
    if ([list isKindOfClass:NSArray.class]) {
        for (id item in list) if ([item isKindOfClass:NSString.class] && [item length]) [apps addObject:item];
    }
    return apps;
}

static NSArray<NSString *> *TWCraneContainerIDsForBundleID(NSString *bundleID) {
    NSDictionary *cache = TWCraneContainerCache();
    if ([cache[@"apps"] isKindOfClass:NSArray.class]) {
        for (NSDictionary *app in (NSArray *)cache[@"apps"]) {
            if (![app isKindOfClass:NSDictionary.class]) continue;
            if (![app[@"bundleID"] isEqual:bundleID]) continue;
            NSMutableArray<NSString *> *ids = [NSMutableArray array];
            for (NSDictionary *c in (NSArray *)app[@"containers"]) {
                NSString *cid = c[@"id"];
                if ([cid isKindOfClass:NSString.class] && [cid length]) [ids addObject:cid];
            }
            return ids;
        }
        return @[];
    }
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
            if (![containerID isKindOfClass:NSString.class]) containerID = @"DEFAULT";
            if (!containerID.length) containerID = @"DEFAULT";   // 0.9.12 及以前的空串＝默认容器
            id enabled = item[@"enabled"];
            BOOL on = [enabled respondsToSelector:@selector(boolValue)] ? [enabled boolValue] : YES;
            enabledMap[[NSString stringWithFormat:@"%@|%@", bundleID, containerID]] = @(on);
        }
    }

    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (NSString *bundleID in TWCraneAppsWithContainers()) {
        NSMutableArray<NSString *> *ids = [NSMutableArray arrayWithObject:@"DEFAULT"];
        for (NSString *cid in TWCraneContainerIDsForBundleID(bundleID)) {
            if (!cid.length || [cid isEqualToString:@"DEFAULT"]) continue;
            [ids addObject:cid];
        }
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
            @"badge": [row[@"containerID"] isEqualToString:@"DEFAULT"] ? @"默" : @"分",
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
        if (![NSFileManager.defaultManager fileExistsAtPath:@"/var/mobile/Library/Twin/crane-containers.plist"]) {
            return @"Twin 后台还没导出容器清单（Crane 未加载或导出失败）。\n请确认 Crane 已安装并运行，然后下拉刷新重试。\n诊断日志：/var/mobile/Library/Twin/export.log";
        }
        return @"没有发现容器。先在 Crane 里给应用建好容器，再回来下拉刷新。";
    }
    return @"「应用名 - 容器名」：开关控制它是否出现在 Twin 的弧形菜单里。\n容器 ID 可在 Crane 设置中查看。\n\n⚠️ 认证取消或容器核验不符时不会打开应用。";
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    

        return 58;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        UITableViewCell *cell = [[TWIconCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"master"];
        cell.textLabel.text = @"分身打开";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [[TWPrefs shared] boolForKey:TWKeyCraneEnabled defaultValue:YES];
        [sw addTarget:self action:@selector(masterSwitchToggled:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"crane"];
    if (!cell) cell = [[TWIconCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"crane"];
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

#pragma mark - Arc 图标顺序（应用、快捷操作与排序）

@implementation TWArcOrderController {
    NSMutableArray<NSString *> *_selected;   // 已选，按顺序
    NSArray<NSString *> *_allApps;           // 全部已安装
    BOOL _editingOrder;
}

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = @"应用、快捷操作与排序";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    // 左侧不设自定义按钮，保留系统返回。
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"排序" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(toggleEditing)];
    [self reloadApps];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadApps];
}

- (void)toggleEditing {
    _editingOrder = !_editingOrder;
    [self setEditing:_editingOrder animated:YES];
    self.navigationItem.rightBarButtonItem.title = _editingOrder ? @"完成" : @"排序";
    [self.tableView reloadData];
}

- (void)reloadApps {
    _selected = [NSMutableArray arrayWithArray:TWArcOrderList() ?: @[]];
    NSMutableArray<NSString *> *all = [NSMutableArray array];
    @try {
        Class ws = NSClassFromString(@"LSApplicationWorkspace");
        SEL sel = NSSelectorFromString(@"defaultWorkspace");
        if (ws && [ws respondsToSelector:sel]) {
            id (*getWS)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            id workspace = getWS(ws, sel);
            SEL allSel = NSSelectorFromString(@"allInstalledApplications");
            if (workspace && [workspace respondsToSelector:allSel]) {
                id (*getAll)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
                NSArray *proxies = getAll(workspace, allSel);
                for (id proxy in proxies) {
                    SEL idSel = NSSelectorFromString(@"applicationIdentifier");
                    if (![proxy respondsToSelector:idSel]) continue;
                    id (*getId)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
                    NSString *bid = getId(proxy, idSel);
                    if ([bid isKindOfClass:NSString.class] && bid.length && ![bid hasPrefix:@"com.apple."]) {
                        [all addObject:bid];
                    }
                }
            }
        }
    } @catch (__unused NSException *e) {}
    _allApps = [all sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    [self.tableView reloadData];
}

// 第二段：未选的剩余应用
- (NSArray<NSString *> *)unselectedApps {
    NSMutableArray *rest = [NSMutableArray array];
    for (NSString *bid in _allApps) if (![_selected containsObject:bid]) [rest addObject:bid];
    return rest;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"已选择（按顺序显示）" : @"更多应用";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? (NSInteger)_selected.count : (NSInteger)self.unselectedApps.count;
}

- (NSString *)bundleIDAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) return _selected[(NSUInteger)indexPath.row];
    return self.unselectedApps[(NSUInteger)indexPath.row];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"TWArcOrderCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) cell = [[TWIconCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellID];
    NSString *bundleID = [self bundleIDAtIndexPath:indexPath];
    cell.imageView.image = TWAppIcon(bundleID);
    cell.textLabel.text = TWPrefsAppName(bundleID);
    cell.textLabel.textColor = UIColor.labelColor;
    cell.showsReorderControl = (indexPath.section == 0);
    cell.accessoryType = UITableViewCellAccessoryNone;
    if (indexPath.section == 0) {
        cell.textLabel.text = [NSString stringWithFormat:@"%ld. %@", (long)indexPath.row + 1, TWPrefsAppName(bundleID)];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *bundleID = [self bundleIDAtIndexPath:indexPath];
    if (indexPath.section == 0) {
        [_selected removeObject:bundleID];
    } else {
        [_selected addObject:bundleID];
    }
    TWSetArcOrderList(_selected);
    [self.tableView reloadData];
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 0;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath
      toIndexPath:(NSIndexPath *)destinationIndexPath {
    if (sourceIndexPath.section != 0 || destinationIndexPath.section != 0) return;
    NSString *item = _selected[(NSUInteger)sourceIndexPath.row];
    [_selected removeObjectAtIndex:(NSUInteger)sourceIndexPath.row];
    [_selected insertObject:item atIndex:(NSUInteger)destinationIndexPath.row];
    TWSetArcOrderList(_selected);
}

@end
