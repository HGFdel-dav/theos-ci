#import "POSubPageController.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import "POSplitXLog.h"
#import <objc/message.h>
#import "POCraneBridge.h"
#import "POApplicationHelper.h"
#import "POSliderTableCell.h"
#import <math.h>

@interface PSSpecifier (POSubPageValues)
- (void)setValues:(NSArray *)values titles:(NSArray *)titles;
@end

@implementation POSubPageController {
    NSString *_subPagePlistName;
}

- (instancetype)initWithPlistName:(NSString *)plistName title:(NSString *)title {
    if ((self = [super init])) {
        _subPagePlistName = [plistName copy];
        self.title = title;
        PXLog(@"prefs", @"子页 init plist=%@ title=%@", plistName, title);
    }
    return self;
}

/// 不用 loadSpecifiersFromPlistName：实测它不认传入的名字，永远返回上一页的内容。
/// 这里自己读 plist → 自己造 PSSpecifier，名字改了就是改了。
- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;

    // 动态账号页没有 Clone.plist，必须在读取资源/空 items 判断之前构建。
    if ([_subPagePlistName isEqualToString:@"Clone"]) {
        _specifiers = [[self buildCloneSpecifiers] mutableCopy];
        PXLog(@"prefs", @"分身动态页 count=%lu", (unsigned long)_specifiers.count);
        return _specifiers;
    }

    NSBundle *own = [NSBundle bundleForClass:[POSubPageController class]];
    NSString *path = [own pathForResource:_subPagePlistName ofType:@"plist"];
    NSDictionary *plist = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    NSArray *items = [plist[@"items"] isKindOfClass:[NSArray class]] ? plist[@"items"] : @[];
    PXLog(@"prefs", @"子页自建 plist=%@ path=%@ items=%lu", _subPagePlistName, path ?: @"nil",
          (unsigned long)items.count);
    if (items.count == 0) {
        PSSpecifier *empty = [PSSpecifier groupSpecifierWithName:@"设置资源未加载"];
        [empty setProperty:[NSString stringWithFormat:@"未找到 %@.plist，请提供本页日志。", _subPagePlistName]
                    forKey:@"footerText"];
        _specifiers = [NSMutableArray arrayWithObject:empty];
        return _specifiers;
    }

    NSMutableArray *specifiers = [NSMutableArray array];
    for (NSDictionary *item in items) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *label = item[@"label"];
        NSString *cell = item[@"cell"];
        NSString *cellClass = item[@"cellClass"];

        PSSpecifier *spec = nil;
        if ([cell isEqualToString:@"PSGroupCell"] || (!cell && !cellClass)) {
            spec = [PSSpecifier preferenceSpecifierNamed:label target:nil
                                                     set:NULL get:NULL detail:nil
                                                    cell:PSGroupCell edit:nil];
        } else if ([cell isEqualToString:@"PSSwitchCell"]) {
            spec = [PSSpecifier preferenceSpecifierNamed:label target:self
                                                     set:@selector(setValue:forSpecifier:)
                                                     get:@selector(getValueForSpecifier:)
                                                  detail:nil cell:PSSwitchCell edit:nil];
        } else if ([cell isEqualToString:@"PSLinkListCell"]) {
            Class detailClass = NSClassFromString(@"PSListItemsController");
            NSArray *values = item[@"validValues"];
            NSArray *titles = item[@"validTitles"];
            if (!detailClass || ![values isKindOfClass:NSArray.class] ||
                ![titles isKindOfClass:NSArray.class] || !values.count || values.count != titles.count) {
                PXLogE(@"prefs", @"%@/%@ 动作选项结构无效", _subPagePlistName, item[@"key"]);
                continue;
            }
            spec = [PSSpecifier preferenceSpecifierNamed:label target:self
                                                     set:@selector(setValue:forSpecifier:)
                                                     get:@selector(getValueForSpecifier:)
                                                  detail:detailClass cell:PSLinkListCell edit:nil];
            [spec setValues:values titles:titles];
        } else if ([cell isEqualToString:@"PSLinkCell"]) {
            NSString *detailName = item[@"detail"];
            Class detailClass = [detailName isKindOfClass:NSString.class] ? NSClassFromString(detailName) : Nil;
            spec = [PSSpecifier preferenceSpecifierNamed:label target:self
                                                     set:NULL get:NULL detail:detailClass
                                                    cell:PSLinkCell edit:nil];
        } else if ([cellClass isEqualToString:@"POSliderTableCell"] || [cell isEqualToString:@"PSSliderCell"]) {
            spec = [PSSpecifier preferenceSpecifierNamed:label target:self
                                                     set:@selector(setValue:forSpecifier:)
                                                     get:@selector(getValueForSpecifier:)
                                                  detail:nil cell:PSSliderCell edit:nil];
            // Preferences 的 cellClass 运行时必须是 Class，不是 plist 字符串。
            [spec setProperty:[POSliderTableCell class] forKey:@"cellClass"];
            NSNumber *minimum = item[@"minimumValue"] ?: item[@"min"] ?: @0;
            NSNumber *maximum = item[@"maximumValue"] ?: item[@"max"] ?: @100;
            [spec setProperty:minimum forKey:@"min"];
            [spec setProperty:maximum forKey:@"max"];
            // 自定义单元仍读取原字段；系统 cell 也能读取标准 min/max。
            [spec setProperty:minimum forKey:@"minimumValue"];
            [spec setProperty:maximum forKey:@"maximumValue"];
            [spec setProperty:@YES forKey:@"showValue"];
            [spec setProperty:@NO forKey:@"isContinuous"];
        } else {
            PXLogE(@"prefs", @"%@/%@ unsupported cell=%@ custom=%@", _subPagePlistName, item[@"key"], cell, cellClass);
            continue; // 不认识的交互行不能伪装成 PSGroupCell。
        }
        if (!spec) continue;

        for (NSString *key in item) {
            // plist loader 的结构字段不是可直接复制的运行时对象/SEL。
            if ([@[@"cell", @"cellClass", @"detail", @"get", @"set", @"validValues", @"validTitles"] containsObject:key]) continue;
            id value = item[key];
            if (value) [spec setProperty:value forKey:key];
        }
        [specifiers addObject:spec];
    }

    PXLog(@"prefs", @"子页自建完成 plist=%@ count=%lu", _subPagePlistName, (unsigned long)specifiers.count);
    _specifiers = specifiers;
    return _specifiers;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    @try {
        UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
        PXLog(@"prefs", @"cell page=%@ row=%ld.%ld key=%@ type=%ld actual=%@", _subPagePlistName,
              (long)indexPath.section, (long)indexPath.row, [specifier propertyForKey:@"key"] ?: @"(group)",
              (long)specifier.cellType, NSStringFromClass([cell class]));
        return cell;
    } @catch (NSException *exception) {
        // 记录真实 receiver/selector reason，不用吞异常伪装“修好”。
        PXLogE(@"prefs", @"cell failure page=%@ row=%ld.%ld key=%@ type=%ld exception=%@: %@",
               _subPagePlistName, (long)indexPath.section, (long)indexPath.row,
               [specifier propertyForKey:@"key"], (long)specifier.cellType, exception.name, exception.reason);
        @throw;
    }
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    return [self getValueForSpecifier:specifier];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [self setValue:value forSpecifier:specifier];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    if ([[specifier propertyForKey:@"id"] isEqualToString:@"resetPanelDefaults"]) {
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.niubiprass.splitx"];
        NSDictionary *recommended = @{
            @"iconSize": @56, @"tileSize": @68, @"itemSpacing": @6,
            @"fanRadius": @180, @"fanSpan": @180,
            @"ring1": @12, @"ring2": @0, @"ring3": @0, @"ring4": @0,
            @"ringGap": @0, @"handleSlideDistance": @45,
            @"panelEdgeInset": @0, @"handleOnLeft": @NO,
            @"handleVerticalPosition": @50, @"handleOpacity": @100,
            @"handleHidden": @NO, @"handleAlwaysVisible": @YES,
            @"squareIcons": @NO, @"animationSpeed": @100
        };
        [recommended enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
            [defaults setObject:value forKey:key];
        }];
        [defaults synchronize];
        [POApplicationHelper reloadSettings];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.niubiprass.splitx.settings-changed"), NULL, NULL, YES);
        PXLog(@"prefs", @"恢复推荐菜单布局 keys=%lu", (unsigned long)recommended.count);
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"已恢复推荐布局"
                                                                       message:@"菜单半径、张角、环容量、图标尺寸和手柄位置已恢复。"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [super tableView:tableView didSelectRowAtIndexPath:indexPath];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    PXLog(@"prefs", @"子页 viewDidLoad plist=%@ count=%lu", _subPagePlistName,
          (unsigned long)self.specifiers.count);
}


- (id)getValueForSpecifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    NSString *suite = [specifier propertyForKey:@"defaults"];
    if (!key.length || !suite.length) return nil;
    id value = [[[NSUserDefaults alloc] initWithSuiteName:suite] objectForKey:key];
    return value ?: [specifier propertyForKey:@"default"];
}

- (void)setValue:(id)value forSpecifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    NSString *suite = [specifier propertyForKey:@"defaults"];
    if (!key.length || !suite.length) return;
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    id before = [defaults objectForKey:key];
    id storedValue = value;
    if (specifier.cellType == PSSliderCell && [value respondsToSelector:@selector(doubleValue)]) {
        double low = [[specifier propertyForKey:@"min"] doubleValue];
        double high = [[specifier propertyForKey:@"max"] doubleValue];
        double step = [[specifier propertyForKey:@"stepValue"] doubleValue];
        double number = [value doubleValue];
        if (!isfinite(number) || !isfinite(low) || !isfinite(high) || high < low) return;
        // min/max 为边界，步长从 0 对齐；默认值和端点永远可选。
        number = MIN(MAX(number, low), high);
        if (step > 0 && number != low && number != high)
            number = round(number / step) * step;
        storedValue = @(MIN(MAX(number, low), high));
    }
    if (storedValue) [defaults setObject:storedValue forKey:key];
    else [defaults removeObjectForKey:key];
    BOOL synced = [defaults synchronize];
    PXLog(@"prefs", @"子页写 %@ %@ -> %@ input=%@ sync=%d", key, before ?: @"(空)",
          storedValue ?: @"(清空)", value ?: @"(清空)", synced);
    [POApplicationHelper reloadSettings];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.niubiprass.splitx.settings-changed"),
                                         NULL, NULL, YES);
    if (specifier.cellType == PSSliderCell && ![storedValue isEqual:value]) {
        // 步长量化后重读，让显示数值与真正落盘数值一致。
        dispatch_async(dispatch_get_main_queue(), ^{ [self reloadSpecifier:specifier animated:NO]; });
    }
}

/// 每个有分身的应用一页开关，按账号勾选要不要出现在菜单里。
- (NSArray *)buildCloneSpecifiers {
    @try {
        return [self po_buildCloneSpecifiers];
    } @catch (NSException *e) {
        PXLogE(@"prefs", @"分身页构建异常 %@: %@", e.name, e.reason);
        return @[[PSSpecifier preferenceSpecifierNamed:@"读取分身失败，见日志"
                                                target:nil set:NULL get:NULL detail:nil
                                                  cell:PSGroupCell edit:nil]];
    }
}

- (NSArray *)po_buildCloneSpecifiers {
    PSSpecifier *header = [PSSpecifier groupSpecifierWithName:@"菜单账号选择"];
    [header setProperty:@"开关只控制菜单是否显示，不删除或切换账号。关闭的账号仍会列在这里，可随时重新开启。默认号还受主页“显示默认号”总开关控制。"
                forKey:@"footerText"];
    NSMutableArray *result = [NSMutableArray arrayWithObject:header];
    // 和 SpringBoard 共用 Bridge 的 RootHide 加载、sharedManager 实例及原始枚举。
    if (![POCraneBridge isAvailable]) {
        [header setProperty:@"本进程未能加载 Crane。请确认 Crane 已安装，并查看日志中的动态库路径与错误。" forKey:@"footerText"];
        PXLogW(@"prefs", @"分身页 Crane unavailable");
        return result;
    }
    NSArray<NSString *> *bundles = [POCraneBridge applicationsWithNonDefaultContainers];
    NSUInteger accounts = 0;
    for (NSString *bundle in bundles) {
        @try {
            NSArray<POSplitTarget *> *targets = [POCraneBridge allTargetsForBundleIdentifier:bundle];
            if (targets.count <= 1) continue;
            PSSpecifier *group = [PSSpecifier groupSpecifierWithName:
                [POApplicationHelper displayNameForBundleId:bundle] ?: bundle];
            [result addObject:group];
            for (POSplitTarget *target in targets) {
                NSString *key = [POCraneBridge visibilityKeyForTarget:target];
                NSString *name = target.isDefaultContainer ? @"默认账号" : target.containerDisplayName;
                if (!name.length) name = target.containerIdentifier;
                PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:name target:self
                                                                     set:@selector(setValue:forSpecifier:)
                                                                     get:@selector(getValueForSpecifier:)
                                                                  detail:nil cell:PSSwitchCell edit:nil];
                [row setProperty:key forKey:@"key"];
                [row setProperty:@"com.niubiprass.splitx" forKey:@"defaults"];
                [row setProperty:@YES forKey:@"default"];
                [result addObject:row];
                accounts++;
                PXLog(@"prefs", @"分身行 %@ default=%d show=%@", target.identityKey,
                      target.isDefaultContainer, [self getValueForSpecifier:row]);
            }
        } @catch (NSException *exception) {
            PXLogE(@"prefs", @"%@ 分身行构建异常 %@: %@", bundle, exception.name, exception.reason);
            PSSpecifier *error = [PSSpecifier groupSpecifierWithName:bundle];
            [error setProperty:@"此应用账号读取失败，其他应用不受影响；请提供日志。" forKey:@"footerText"];
            [result addObject:error];
        }
    }
    if (!accounts) {
        PSSpecifier *empty = [PSSpecifier groupSpecifierWithName:@"尚未读到分身账号"];
        [empty setProperty:@"Crane 已加载，但未返回非默认容器。请提供日志中的 raw enumeration 记录。" forKey:@"footerText"];
        [result addObject:empty];
    }
    PXLog(@"prefs", @"分身列表 rawApps=%lu rows=%lu specifiers=%lu", (unsigned long)bundles.count,
          (unsigned long)accounts, (unsigned long)result.count);
    return result;
}
@end
