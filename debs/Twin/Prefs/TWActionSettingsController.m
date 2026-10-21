#import "TWActionSettingsController.h"
#import "TWPXPrefs.h"
#import "TWSpecifiers.h"
#import "TWPath.h"
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>

// Schema evidence (original prefs image, VM addresses):
// 0x81b0 urlShortcuts -> [[String:String]], 0x82d8 customActions -> [[String:Any]],
// 0x8484 shortcutSymbols -> [String:String]; 0xf5c0 URL fields id/title/url.
// 0x138a8 custom ID = px.custom.UUID; copied catalog payload, then id/title updated.
// 0x7f78 applications / searchFavorites are ordered identifier arrays (not dictionaries).
// Catalog exports: PXAvailableWorkflows 0x40b04; PXFetchAllApplicationActions 0x423a4.
// Never execute an action in Settings; only edit original engine data.
static NSString *TWASString(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
static NSArray *TWASArray(id value) { return [value isKindOfClass:NSArray.class] ? value : @[]; }
static NSDictionary *TWASDictionary(id value) { return [value isKindOfClass:NSDictionary.class] ? value : @{}; }
static void TWASRefresh(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.moxuan.parallelx.handle-updated"), NULL, NULL, YES);
}

// Load only the bundled original *preferences catalog*, never the injection dylib.
// Original exports provide real workflow UUIDs / app action type+userInfo payloads.
// Missing bundle/export/permission -> explicit unavailable UI, no fabricated payload.
static void *TWASCatalog(void) {
    static void *handle;
    if (handle) return handle;
    for (NSString *root in TWJBRootCandidates()) {
        NSString *path = [root stringByAppendingPathComponent:@"Library/PreferenceBundles/ParallelXPrefs.bundle/ParallelXPrefs"];
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
            handle = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
            if (handle) break;
        }
    }
    return handle;
}

@interface TWActionSettingsController ()
@property (nonatomic, strong) TWPXPrefs *px;
@property (nonatomic, copy) NSArray *catalog;
@property (nonatomic, copy) NSString *catalogStatus;
@property (nonatomic) BOOL catalogLoading;
- (void)twInvalidate;
- (void)twAlert:(NSString *)message;
- (NSString *)twDataKey;
- (void)twEdit:(PSSpecifier *)specifier;
@end

@implementation TWActionSettingsController
- (instancetype)init { return [self initForContentSize:CGSizeZero]; }
- (instancetype)initForContentSize:(CGSize)size {
    if ((self = [super initForContentSize:size])) {
        _px = [[TWPXPrefs alloc] init];
        self.title = [self twPageTitle];
    }
    return self;
}
- (NSString *)twPageTitle {
    if ([self isKindOfClass:TWSystemToolsController.class]) return @"系统工具";
    if ([self isKindOfClass:TWURLShortcutsController.class]) return @"URL 快捷项";
    if ([self isKindOfClass:TWWorkflowActionsController.class]) return @"快捷指令";
    if ([self isKindOfClass:TWApplicationActionsController.class]) return @"应用快捷方式";
    if ([self isKindOfClass:TWCustomActionsController.class]) return @"自定义动作";
    return @"系统控制与快捷操作";
}
- (NSString *)twDataKey {
    return [self isKindOfClass:TWURLShortcutsController.class] ? @"urlShortcuts" : @"customActions";
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self twInvalidate]; }
- (void)twInvalidate { _specifiers = nil; if (self.isViewLoaded) [self reloadSpecifiers]; }
- (void)twAlert:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Twin" message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (BOOL)twSave:(id)value key:(NSString *)key {
    BOOL ok = [self.px setObject:value forKey:key];
    if (ok) TWASRefresh();
    else [self twAlert:@"保存失败，请返回重试。没有确认写入成功。"];
    return ok;
}
- (void)twAddButton:(NSMutableArray *)rows title:(NSString *)title action:(NSString *)action data:(NSDictionary *)data {
    PSSpecifier *s = TWButtonRowSpecifier(self, title, action, nil, NO, data);
    if (s) [rows addObject:s];
}
- (void)twAddLink:(NSMutableArray *)rows title:(NSString *)title className:(NSString *)name {
    PSSpecifier *s = TWLinkRowSpecifier(self, title, nil, name, nil, nil);
    if (s) [rows addObject:s];
}
- (NSArray *)twTools {
    // Subset of original picker catalog. No dependency-specific entries, reboot,
    // restart or newly invented destructive commands are exposed here.
    return @[
        @[@"深色模式", @"px.action.dark"], @[@"屏幕录制", @"px.action.record"],
        @[@"旋转锁定", @"px.action.rotation"], @[@"当前应用分屏", @"px.action.window"],
        @[@"截屏", @"px.action.screenshot"], @[@"最近应用", @"px.action.recent"],
        @[@"亮度", @"px.action.brightness"], @[@"应用搜索", @"px.action.search"]
    ];
}
- (NSArray *)specifiers {
    if (!self.px) self.px = [[TWPXPrefs alloc] init];
    if (_specifiers) return _specifiers;
    NSMutableArray *rows = [NSMutableArray array];
    if ([self isKindOfClass:TWSystemToolsController.class]) {
        [rows addObject:TWGroupSpecifier(@"原有工具目录", @"点击条目只编辑是否显示，不在设置内执行。两侧模式手柄跟随最近呼出侧。首次选择将保存显式面板列表，请同时在应用列表中确认原有应用。")];
        NSArray *selected = TWASArray([self.px objectForKey:@"applications" defaultValue:nil]);
        for (NSArray *tool in [self twTools]) {
            NSString *label = [NSString stringWithFormat:@"%@%@", [selected containsObject:tool[1]] ? @"✓ " : @"", tool[0]];
            [self twAddButton:rows title:label action:@"twToggleTool:" data:@{@"twActionID":tool[1]}];
        }
    } else if ([self isKindOfClass:TWWorkflowActionsController.class] || [self isKindOfClass:TWApplicationActionsController.class]) {
        BOOL workflow = [self isKindOfClass:TWWorkflowActionsController.class];
        [rows addObject:TWGroupSpecifier(workflow ? @"系统快捷指令目录" : @"应用提供的快捷方式", @"从原有目录选择后可修改显示名称和图标，保存至自定义动作，并加入半圆面板。此页不会执行动作。目录受系统权限与应用支持情况影响。")];
        [self twAddButton:rows title:@"读取 / 刷新可用目录" action:@"twLoadCatalog:" data:nil];
        [rows addObject:TWGroupSpecifier(nil, self.catalogStatus ?: @"尚未读取目录。不会用输入框伪造快捷指令 UUID 或应用动作 type。")];
        for (id obj in self.catalog) {
            NSDictionary *item = TWASDictionary(obj);
            NSString *title = TWASString(item[@"title"]);
            if (!title.length) continue;
            [self twAddButton:rows title:title action:@"twPickCatalog:" data:@{@"twPayload":item}];
        }
        [self twAddLink:rows title:@"管理已保存的动作" className:@"TWCustomActionsController"];
    } else if ([self isKindOfClass:TWURLShortcutsController.class] || [self isKindOfClass:TWCustomActionsController.class]) {
        BOOL url = [self isKindOfClass:TWURLShortcutsController.class];
        [rows addObject:TWGroupSpecifier(url ? @"URL 快捷项" : @"已保存动作", url ? @"支持完整 URL 或 URL Scheme，最多 10 项。点条目编辑、排序、显示位置或删除。不会在设置内打开链接。" : @"保留原动作的 kind、workflow、bundle、type、userInfo 等全部字段，仅编辑名称和显示位置。新增动作请从快捷指令或应用快捷方式的真实目录选择。")];
        if (url) [self twAddButton:rows title:@"添加 URL 快捷项" action:@"twAddURL:" data:nil];
        NSArray *items = TWASArray([self.px objectForKey:[self twDataKey] defaultValue:nil]);
        for (id obj in items) {
            NSDictionary *item = TWASDictionary(obj);
            NSString *identifier = TWASString(item[@"id"]);
            if (!identifier.length || [item[@"twOwner"] isEqual:@"com.niubiprass.twin.container"]) continue;
            NSString *title = TWASString(item[@"title"]);
            [self twAddButton:rows title:title.length ? title : identifier action:@"twEdit:" data:@{@"twActionID":identifier}];
        }
        if (!items.count) [rows addObject:TWGroupSpecifier(nil, @"暂无已保存的项目。")];
    } else {
        [rows addObject:TWGroupSpecifier(@"系统控制", @"仅配置已有运行时支持的项目，不在设置内执行系统操作。")];
        [self twAddLink:rows title:@"系统工具" className:@"TWSystemToolsController"];
        [self twAddLink:rows title:@"快捷指令" className:@"TWWorkflowActionsController"];
        [self twAddLink:rows title:@"应用快捷方式" className:@"TWApplicationActionsController"];
        [rows addObject:TWGroupSpecifier(@"快捷操作编辑器", @"与半圆面板及搜索收藏共用原始偏好数据。图标使用当前系统支持的 SF Symbols，留空恢复默认。")];
        [self twAddLink:rows title:@"URL 快捷项" className:@"TWURLShortcutsController"];
        [self twAddLink:rows title:@"自定义动作与图标" className:@"TWCustomActionsController"];
        [rows addObject:TWGroupSpecifier(@"顶部与底部手势动作 · 未接线", @"当前已确认可编辑触发区域的尺寸和偏移；尚未确认可配置动作键。顶部角落停靠、底部小窗和退出手势保留运行时原有行为。本页不写入虚构动作键，也不宣称可自定义。")];
    }
    _specifiers = [rows copy];
    return _specifiers;
}
- (id)controllerForSpecifier:(PSSpecifier *)specifier {
    id controller = TWControllerForSpecifier(self, specifier);
    return controller ?: TWSuperControllerForSpecifier(self, specifier);
}

#pragma mark - Original catalogs (selection only)
- (void)twLoadCatalog:(PSSpecifier *)unused {
    if (self.catalogLoading) return;
    void *handle = TWASCatalog();
    if (!handle) { self.catalogStatus = @"原有目录组件不可用：未接线。未创建任何动作。"; [self twInvalidate]; return; }
    self.catalogLoading = YES;
    self.catalogStatus = @"正在读取目录…";
    [self twInvalidate];
    __weak typeof(self) weakSelf = self;
    void (^done)(NSArray *) = ^(NSArray *items) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) owner = weakSelf;
            if (!owner) return;
            owner.catalog = TWASArray(items);
            owner.catalogLoading = NO;
            owner.catalogStatus = owner.catalog.count ? @"仅列出原有目录返回的条目。" : @"没有可用项目，或系统权限不允许读取。可先打开相应应用再回来刷新。";
            [owner twInvalidate];
        });
    };
    if ([self isKindOfClass:TWWorkflowActionsController.class]) {
        NSArray *(*fetch)(void) = (NSArray *(*)(void))dlsym(handle, "PXAvailableWorkflows");
        if (!fetch) { self.catalogLoading = NO; self.catalogStatus = @"快捷指令目录接口不可用：未接线。"; [self twInvalidate]; return; }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ done(fetch()); });
    } else {
        void (*fetch)(void (^)(NSArray *)) = (void (*)(void (^)(NSArray *)))dlsym(handle, "PXFetchAllApplicationActions");
        if (!fetch) { self.catalogLoading = NO; self.catalogStatus = @"应用快捷方式目录接口不可用：未接线。"; [self twInvalidate]; return; }
        // Original catalog asserts main-thread invocation, then requests SpringBoard.
        fetch(done);
    }
}
- (void)twPickCatalog:(PSSpecifier *)specifier {
    NSDictionary *payload = TWASDictionary([specifier propertyForKey:@"twPayload"]);
    BOOL workflow = [self isKindOfClass:TWWorkflowActionsController.class];
    BOOL valid = workflow ? [TWASString(payload[@"kind"]) isEqualToString:@"workflow"] && [[NSUUID alloc] initWithUUIDString:TWASString(payload[@"workflow"])] != nil
                          : [TWASString(payload[@"kind"]) isEqualToString:@"quick"] && TWASString(payload[@"app"]).length && TWASString(payload[@"type"]).length;
    if (!valid) { [self twAlert:@"目录返回的数据格式与已确认的动作格式不一致，未保存。请保留现有配置。暂不支持该项目。应提供 kind/workflow 或 kind/app/type。" ]; return; }
    [self twPresentEditor:payload newItem:YES key:@"customActions"];
}

#pragma mark - Ordered identifier arrays
- (void)twToggleTool:(PSSpecifier *)specifier {
    NSString *identifier = TWASString([specifier propertyForKey:@"twActionID"]);
    BOOL known = NO;
    for (NSArray *tool in [self twTools]) if ([tool[1] isEqual:identifier]) known = YES;
    if (!known) return;
    NSMutableArray *selected = [TWASArray([self.px objectForKey:@"applications" defaultValue:nil]) mutableCopy];
    if ([selected containsObject:identifier]) [selected removeObject:identifier];
    else [selected addObject:identifier];
    if ([self twSave:selected key:@"applications"]) [self twInvalidate];
}
- (BOOL)twSetMembership:(BOOL)include identifier:(NSString *)identifier key:(NSString *)key {
    if (!identifier.length) return NO;
    NSMutableArray *list = [TWASArray([self.px objectForKey:key defaultValue:nil]) mutableCopy];
    if (include && ![list containsObject:identifier]) [list addObject:identifier];
    if (!include) [list removeObject:identifier];
    return [self twSave:list key:key];
}
- (NSDictionary *)twFind:(NSString *)identifier key:(NSString *)key {
    for (id obj in TWASArray([self.px objectForKey:key defaultValue:nil])) {
        NSDictionary *item = TWASDictionary(obj);
        if ([TWASString(item[@"id"]) isEqual:identifier]) return item;
    }
    return nil;
}
- (BOOL)twReplace:(NSDictionary *)entry key:(NSString *)key isNew:(BOOL)isNew {
    NSString *identifier = TWASString(entry[@"id"]);
    if (!identifier.length) return NO;
    NSMutableArray *items = [TWASArray([self.px objectForKey:key defaultValue:nil]) mutableCopy];
    NSUInteger index = [items indexOfObjectPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) {
        return [TWASString(TWASDictionary(obj)[@"id"]) isEqual:identifier];
    }];
    if (index != NSNotFound) items[index] = entry;
    else if (isNew) {
        if ([key isEqual:@"urlShortcuts"] && items.count >= 10) { [self twAlert:@"URL 快捷项最多 10 项，请先删除已有项目。" ]; return NO; }
        [items addObject:entry];
    } else { [self twAlert:@"该项目已在其他页面删除，请返回刷新。" ]; return NO; }
    return [self twSave:items key:key];
}
- (void)twAddURL:(PSSpecifier *)unused {
    [self twPresentEditor:@{} newItem:YES key:@"urlShortcuts"];
}
- (void)twEdit:(PSSpecifier *)specifier {
    NSString *identifier = TWASString([specifier propertyForKey:@"twActionID"]);
    NSDictionary *item = [self twFind:identifier key:[self twDataKey]];
    if (!item) { [self twInvalidate]; return; }
    [self twPresentEditor:item newItem:NO key:[self twDataKey]];
}
- (void)twPresentEditor:(NSDictionary *)entry newItem:(BOOL)isNew key:(NSString *)key {
    BOOL url = [key isEqual:@"urlShortcuts"];
    NSString *identifier = TWASString(entry[@"id"]);
    NSDictionary *symbols = TWASDictionary([self.px objectForKey:@"shortcutSymbols" defaultValue:nil]);
    UIAlertController *a = [UIAlertController alertControllerWithTitle:isNew ? @"添加快捷操作" : @"编辑快捷操作" message:@"名称与图标保留原动作数据。图标留空恢复默认，不影响其他项目。" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t) { t.placeholder = @"显示名称"; t.text = TWASString(entry[@"title"]); }];
    if (url) [a addTextFieldWithConfigurationHandler:^(UITextField *t) {
        t.placeholder = @"https:// 或 URL Scheme"; t.text = TWASString(entry[@"url"]);
        t.keyboardType = UIKeyboardTypeURL; t.autocapitalizationType = UITextAutocapitalizationTypeNone; t.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t) { t.placeholder = @"SF Symbols 名称（可留空）"; t.text = TWASString(symbols[identifier]); t.autocapitalizationType = UITextAutocapitalizationTypeNone; t.autocorrectionType = UITextAutocorrectionTypeNo; }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        typeof(self) owner = weakSelf;
        if (!owner) return;
        NSCharacterSet *trim = NSCharacterSet.whitespaceAndNewlineCharacterSet;
        NSString *title = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:trim] ?: @"";
        NSString *symbol = [a.textFields.lastObject.text stringByTrimmingCharactersInSet:trim] ?: @"";
        if (!title.length) { [owner twAlert:@"显示名称不能为空，未保存。" ]; return; }
        if (symbol.length && ![UIImage systemImageNamed:symbol]) { [owner twAlert:@"当前系统不支持此 SF Symbols 名称，未保存。" ]; return; }
        NSString *link = url ? [a.textFields[1].text stringByTrimmingCharactersInSet:trim] : nil;
        if (url && (![NSURL URLWithString:link].scheme.length || [link rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound)) {
            [owner twAlert:@"请输入包含 Scheme 的有效 URL，空格请先编码。未保存。" ]; return;
        }
        NSMutableDictionary *updated = [(isNew ? entry : [owner twFind:identifier key:key]) mutableCopy];
        if (!updated) { [owner twAlert:@"项目已删除，请返回刷新。" ]; return; }
        NSString *newID = isNew ? [(url ? @"px.url." : @"px.custom.") stringByAppendingString:NSUUID.UUID.UUIDString] : identifier;
        updated[@"id"] = newID; updated[@"title"] = title;
        if (url) updated[@"url"] = link;
        if (![owner twReplace:updated key:key isNew:isNew]) return;
        NSMutableDictionary *icons = [TWASDictionary([owner.px objectForKey:@"shortcutSymbols" defaultValue:nil]) mutableCopy];
        if (symbol.length) icons[newID] = symbol; else [icons removeObjectForKey:newID];
        if (![owner twSave:icons key:@"shortcutSymbols"]) return;
        if (isNew && ![owner twSetMembership:YES identifier:newID key:@"applications"]) return;
        [owner twInvalidate];
        if (!isNew) [owner twPresentPlacement:newID key:key];
    }]];
    if (!isNew) [a addAction:[UIAlertAction actionWithTitle:@"显示位置 / 排序 / 删除" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [weakSelf twPresentPlacement:identifier key:key]; }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)twPresentPlacement:(NSString *)identifier key:(NSString *)key {
    if (![self twFind:identifier key:key]) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"显示位置与排序" message:@"面板与搜索收藏分别保存原始标识顺序。上移、下移会同时调整此项在两个已加入列表中的位置，不改变其他条目的相对顺序。" preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    for (NSArray *option in @[@[@"半圆面板", @"applications"], @[@"搜索收藏", @"searchFavorites"]]) {
        BOOL included = [TWASArray([self.px objectForKey:option[1] defaultValue:nil]) containsObject:identifier];
        NSString *label = [NSString stringWithFormat:@"%@%@", included ? @"移出" : @"加入", option[0]];
        [a addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [weakSelf twSetMembership:!included identifier:identifier key:option[1]];
            [weakSelf twInvalidate];
        }]];
    }
    for (NSNumber *direction in @[@(-1), @1]) {
        [a addAction:[UIAlertAction actionWithTitle:direction.integerValue < 0 ? @"上移" : @"下移" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            typeof(self) owner = weakSelf;
            if (!owner) return;
            NSMutableArray *entries = [TWASArray([owner.px objectForKey:key defaultValue:nil]) mutableCopy];
            NSUInteger index = [entries indexOfObjectPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) { return [TWASString(TWASDictionary(obj)[@"id"]) isEqual:identifier]; }];
            NSInteger next = (NSInteger)index + direction.integerValue;
            if (index != NSNotFound && next >= 0 && next < (NSInteger)entries.count) {
                [entries exchangeObjectAtIndex:index withObjectAtIndex:(NSUInteger)next];
                if (![owner twSave:entries key:key]) return;
            }
            for (NSString *selection in @[@"applications", @"searchFavorites"]) {
                NSMutableArray *ids = [TWASArray([owner.px objectForKey:selection defaultValue:nil]) mutableCopy];
                NSUInteger current = [ids indexOfObject:identifier];
                NSInteger target = (NSInteger)current + direction.integerValue;
                if (current != NSNotFound && target >= 0 && target < (NSInteger)ids.count) {
                    [ids exchangeObjectAtIndex:current withObjectAtIndex:(NSUInteger)target];
                    if (![owner twSave:ids key:selection]) return;
                }
            }
            [owner twInvalidate];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"删除此快捷操作" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [weakSelf twConfirmDelete:identifier key:key];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)twConfirmDelete:(NSString *)identifier key:(NSString *)key {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"删除快捷操作？" message:@"仅删除此配置及其面板、搜索收藏引用，不删除系统快捷指令或应用数据。" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [a addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        typeof(self) owner = weakSelf;
        if (!owner) return;
        NSMutableArray *items = [TWASArray([owner.px objectForKey:key defaultValue:nil]) mutableCopy];
        NSIndexSet *matches = [items indexesOfObjectsPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) { return [TWASString(TWASDictionary(obj)[@"id"]) isEqual:identifier]; }];
        [items removeObjectsAtIndexes:matches];
        if (![owner twSave:items key:key]) return;
        for (NSString *selection in @[@"applications", @"searchFavorites"]) {
            if (![owner twSetMembership:NO identifier:identifier key:selection]) return;
        }
        for (NSString *iconKey in @[@"shortcutSymbols", @"shortcutImages"]) {
            NSMutableDictionary *icons = [TWASDictionary([owner.px objectForKey:iconKey defaultValue:nil]) mutableCopy];
            [icons removeObjectForKey:identifier];
            if (![owner twSave:icons key:iconKey]) return;
        }
        [owner twInvalidate];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

@implementation TWSystemToolsController @end
@implementation TWURLShortcutsController @end
@implementation TWWorkflowActionsController @end
@implementation TWApplicationActionsController @end
@implementation TWCustomActionsController @end
