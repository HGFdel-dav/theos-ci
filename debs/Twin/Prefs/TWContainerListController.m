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
#import "TWAppCatalog.h"
#import "TWContainerActionsPrefs.h"
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
    [[TWPrefs shared] setObject:clean forKey:TWKeyCraneContainers];
    [[TWPrefs shared] synchronize];
    TWPublishContainerActions();
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
    NSArray<NSDictionary *> *_rows;
}
- (instancetype)init {
    if ((self = [super init])) self.title = @"分身应用";
    return self;
}
// Use real group/row specifiers, as in the original container controller.
// Overriding table section counts while returning an empty _specifiers made
// PSListController's inherited header-height lookup index an empty group list.
- (void)twLoadContainerRows {
    id raw = [TWPrefs.shared objectForKey:TWKeyCraneContainers];
    NSMutableDictionary *enabled = [NSMutableDictionary dictionary];
    if ([raw isKindOfClass:NSArray.class]) for (id item in raw) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *bid = item[@"bundleID"], *cid = item[@"containerID"];
        if (![bid isKindOfClass:NSString.class] || !bid.length) continue;
        if (![cid isKindOfClass:NSString.class] || !cid.length) cid = @"DEFAULT";
        enabled[[NSString stringWithFormat:@"%@|%@", bid, cid]] = @(!item[@"enabled"] || [item[@"enabled"] boolValue]);
    }
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *bid in TWCraneAppsWithContainers()) {
        NSMutableOrderedSet *ids = [NSMutableOrderedSet orderedSetWithArray:@[@"DEFAULT"]];
        for (NSString *cid in TWCraneContainerIDsForBundleID(bid)) if (cid.length) [ids addObject:cid];
        for (NSString *cid in ids) {
            NSString *key = [NSString stringWithFormat:@"%@|%@", bid, cid];
            [rows addObject:@{@"bundleID":bid, @"containerID":cid, @"enabled":enabled[key] ?: @YES}];
        }
    }
    _rows = rows;
}
- (NSArray *)specifiers {
    if (!_specifiers) {
        [self twLoadContainerRows];
        NSMutableArray *specs = [NSMutableArray array];
        [specs addObject:TWGroupSpecifier(nil, nil)];
        [specs addObject:TWRowSpecifier(self, @"分身打开", TWKeyCraneEnabled, @YES, nil, PSSwitchCell, nil, nil, @{@"height":@50})];
        NSString *footer = _rows.count ? @"只开启需要显示的容器；普通应用不会进入容器切换。两种唤醒共用相同容器条目。" : @"没有发现分身容器，可下拉刷新。原有配置不会因空扫描结果被删除。";
        [specs addObject:TWGroupSpecifier(@"分身容器", footer)];
        for (NSDictionary *row in _rows) {
            NSString *bid = row[@"bundleID"], *cid = row[@"containerID"];
            NSString *title = [NSString stringWithFormat:@"%@ · %@", TWPrefsAppName(bid), TWCraneContainerName(cid, bid)];
            PSSpecifier *sp = TWRowSpecifier(self, title, nil, row[@"enabled"], nil, PSSwitchCell, nil, nil,
                @{@"height":@58, @"twContainer":row});
            UIImage *icon = TWAppIcon(bid);
            if (icon) [sp setProperty:icon forKey:@"iconImage"];
            [specs addObject:sp];
        }
        if (!_rows.count) [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"暂无可加入的容器" target:self set:NULL get:NULL detail:Nil cell:PSStaticTextCell edit:NULL]];
        _specifiers = specs;
    }
    return _specifiers;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    UIRefreshControl *refresh = [UIRefreshControl new];
    [refresh addTarget:self action:@selector(reloadContainers) forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = refresh;
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadContainers]; }
- (void)reloadContainers {
    _specifiers = nil;
    [self reloadSpecifiers];
    [self.tableView.refreshControl endRefreshing];
}
- (id)readPreferenceValue:(PSSpecifier *)sp {
    NSDictionary *row = [sp propertyForKey:@"twContainer"];
    if (!row) return @([TWPrefs.shared boolForKey:TWKeyCraneEnabled defaultValue:YES]);
    return row[@"enabled"] ?: @YES;
}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)sp {
    NSDictionary *row = [sp propertyForKey:@"twContainer"];
    if (!row) {
        [TWPrefs.shared setBool:[value boolValue] forKey:TWKeyCraneEnabled];
        [TWPrefs.shared synchronize]; TWPublishContainerActions(); return;
    }
    NSMutableArray *updated = [NSMutableArray array];
    for (NSDictionary *old in _rows) {
        NSMutableDictionary *copy = [old mutableCopy];
        if ([old[@"bundleID"] isEqual:row[@"bundleID"]] && [old[@"containerID"] isEqual:row[@"containerID"]]) copy[@"enabled"] = @([value boolValue]);
        copy[@"name"] = TWPrefsAppName(copy[@"bundleID"]);
        [updated addObject:copy];
    }
    _rows = updated;
    TWSaveContainers(updated);
    NSMutableDictionary *copy = [row mutableCopy]; copy[@"enabled"] = @([value boolValue]);
    [sp setProperty:copy forKey:@"twContainer"];
}
@end


@implementation TWArcOrderController {
    NSMutableArray<NSString *> *_selected;
    NSArray<NSString *> *_allApps;
    BOOL _editingOrder;
}
- (instancetype)init {
    if ((self = [super init])) self.title = @"应用、快捷操作与排序";
    return self;
}
- (NSArray *)specifiers {
    if (!_specifiers) {
        if (!_selected) _selected = [NSMutableArray arrayWithArray:TWArcOrderList() ?: @[]];
        if (!_allApps) _allApps = TWInstalledAppIdentifiers();
        NSMutableArray *rows = [NSMutableArray array];
        [rows addObject:TWGroupSpecifier(@"已选择（按顺序显示）", @"点应用移除，进入排序后拖动右侧手柄。不卸载应用；扇形与半圆菜单共用清单。")];
        for (NSString *bid in _selected) {
            PSSpecifier *sp = TWButtonRowSpecifier(self, TWPrefsAppName(bid), @"toggleApplication:", nil, NO,
                @{@"twBundleID":bid, @"twSelected":@YES, @"height":@50});
            UIImage *icon = TWAppIcon(bid); if (icon) [sp setProperty:icon forKey:@"iconImage"];
            [rows addObject:sp];
        }
        [rows addObject:TWGroupSpecifier(@"更多应用", nil)];
        for (NSString *bid in _allApps) {
            if ([_selected containsObject:bid]) continue;
            PSSpecifier *sp = TWButtonRowSpecifier(self, TWPrefsAppName(bid), @"toggleApplication:", nil, NO,
                @{@"twBundleID":bid, @"twSelected":@NO, @"height":@50});
            UIImage *icon = TWAppIcon(bid); if (icon) [sp setProperty:icon forKey:@"iconImage"];
            [rows addObject:sp];
        }
        _specifiers = rows;
    }
    return _specifiers;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.allowsSelectionDuringEditing = YES;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"排序" style:UIBarButtonItemStylePlain target:self action:@selector(toggleEditing)];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadApps]; }
- (void)reloadApps {
    _selected = [NSMutableArray arrayWithArray:TWArcOrderList() ?: @[]];
    _allApps = TWInstalledAppIdentifiers(); _specifiers = nil;
    [self reloadSpecifiers];
}
- (void)toggleEditing {
    _editingOrder = !_editingOrder;
    [self.tableView setEditing:_editingOrder animated:YES];
    self.navigationItem.rightBarButtonItem.title = _editingOrder ? @"完成" : @"排序";
}
- (void)toggleApplication:(PSSpecifier *)sp {
    NSString *bid = [sp propertyForKey:@"twBundleID"];
    if (![bid isKindOfClass:NSString.class] || !bid.length) return;
    if ([_selected containsObject:bid]) [_selected removeObject:bid]; else [_selected addObject:bid];
    TWSetArcOrderList(_selected); _specifiers = nil; [self reloadSpecifiers];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    PSSpecifier *sp = [self specifierAtIndexPath:indexPath];
    if ([sp propertyForKey:@"twBundleID"]) [self toggleApplication:sp];
    else [super tableView:tableView didSelectRowAtIndexPath:indexPath];
}
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return [[[self specifierAtIndexPath:indexPath] propertyForKey:@"twSelected"] boolValue];
}
- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return [[[self specifierAtIndexPath:indexPath] propertyForKey:@"twSelected"] boolValue];
}
- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath { return UITableViewCellEditingStyleNone; }
- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath { return NO; }
- (NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)source toProposedIndexPath:(NSIndexPath *)destination {
    if (destination.section != 0) return [NSIndexPath indexPathForRow:MAX(0, (NSInteger)_selected.count - 1) inSection:0];
    return destination;
}
- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)source toIndexPath:(NSIndexPath *)destination {
    if (source.section != 0 || destination.section != 0 || source.row < 0 || destination.row < 0 || source.row >= (NSInteger)_selected.count || destination.row >= (NSInteger)_selected.count) return;
    NSString *bid = _selected[(NSUInteger)source.row];
    [_selected removeObjectAtIndex:(NSUInteger)source.row]; [_selected insertObject:bid atIndex:(NSUInteger)destination.row];
    TWSetArcOrderList(_selected);
    // Rebuild the specifier order too: the next inherited header or row lookup
    // must see the same ordering as UITableView's committed move.
    _specifiers = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ [self reloadSpecifiers]; });
}
@end
