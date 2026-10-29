#import "POSubPageController.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import "POSplitXLog.h"
#import <objc/message.h>
#import "POCraneBridge.h"
#import "POApplicationHelper.h"

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

    NSBundle *own = [NSBundle bundleForClass:[POSubPageController class]];
    NSString *path = [own pathForResource:_subPagePlistName ofType:@"plist"];
    NSDictionary *plist = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    NSArray *items = [plist[@"items"] isKindOfClass:[NSArray class]] ? plist[@"items"] : @[];
    PXLog(@"prefs", @"子页自建 plist=%@ path=%@ items=%lu", _subPagePlistName, path ?: @"nil",
          (unsigned long)items.count);
    if (items.count == 0) {
        _specifiers = @[];
        return _specifiers;
    }

    if ([_subPagePlistName isEqualToString:@"Clone"]) {
        _specifiers = [self buildCloneSpecifiers];
        return _specifiers;
    }

    NSMutableArray *specifiers = [NSMutableArray array];
    for (NSDictionary *item in items) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *label = item[@"label"];
        NSString *cell = item[@"cell"];
        NSString *cellClass = item[@"cellClass"];
        BOOL hasKey = [item[@"key"] isKindOfClass:[NSString class]] && [item[@"key"] length] > 0;

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
        } else if ([cell isEqualToString:@"PSLinkCell"]) {
            spec = [PSSpecifier preferenceSpecifierNamed:label target:self
                                                     set:NULL get:NULL detail:nil
                                                    cell:PSLinkCell edit:nil];
        } else if ([cellClass isEqualToString:@"POSliderTableCell"]) {
            // 系统滑杆，cellClass 在这里不可靠。
            spec = [PSSpecifier preferenceSpecifierNamed:label target:self
                                                     set:@selector(setValue:forSpecifier:)
                                                     get:@selector(getValueForSpecifier:)
                                                  detail:nil cell:PSSliderCell edit:nil];
        } else {
            spec = [PSSpecifier preferenceSpecifierNamed:label target:self
                                                     set:(hasKey ? @selector(setValue:forSpecifier:) : NULL)
                                                     get:(hasKey ? @selector(getValueForSpecifier:) : NULL)
                                                  detail:nil cell:PSGroupCell edit:nil];
        }
        if (!spec) continue;

        for (NSString *key in item) {
            if ([key isEqualToString:@"cell"]) continue;
            id value = item[key];
            if (value) [spec setProperty:value forKey:key];
        }
        if (cellClass.length) [spec setProperty:cellClass forKey:@"cellClass"];
        [specifiers addObject:spec];
    }

    PXLog(@"prefs", @"子页自建完成 plist=%@ count=%lu", _subPagePlistName, (unsigned long)specifiers.count);
    _specifiers = specifiers;
    return _specifiers;
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
    if (value) [defaults setObject:value forKey:key];
    else [defaults removeObjectForKey:key];
    [defaults synchronize];
    PXLog(@"prefs", @"子页写 %@=%@", key, value ?: @"(清空)");
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.niubiprass.splitx.settings-changed"),
                                         NULL, NULL, YES);
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
    NSMutableArray *result = [NSMutableArray array];
    id manager = NSClassFromString(@"CraneManager");
    SEL listSel = NSSelectorFromString(@"identfiersOfApplicationsThatHaveNonDefaultContainers");
    if (!manager || ![manager respondsToSelector:listSel]) {
        PXLogW(@"prefs", @"分身列表：CraneManager=%@ selector=%d", manager ? @"有" : @"无",
               [manager respondsToSelector:listSel]);
        PSSpecifier *empty = [PSSpecifier preferenceSpecifierNamed:@"没有可列的分身（Crane 未加载或不支持）"
                                                            target:nil set:NULL get:NULL detail:nil
                                                              cell:PSGroupCell edit:nil];
        return @[empty];
    }
    NSArray *bundles = ((id (*)(id, SEL))objc_msgSend)(manager, listSel);
    PXLog(@"prefs", @"分身列表 apps=%lu", (unsigned long)bundles.count);
    for (NSString *bundle in bundles) {
        if (![bundle isKindOfClass:NSString.class]) continue;
        PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:
            [POApplicationHelper displayNameForBundleId:bundle] ?: bundle
            target:nil set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil];
        [result addObject:group];
        NSArray *targets = [POCraneBridge targetsForBundleIdentifier:bundle];
        @try {
        for (POSplitTarget *target in targets) {
            if (target.isDefaultContainer) continue;
            NSString *key = [NSString stringWithFormat:@"cloneShow.%@.%@", bundle, target.containerIdentifier];
            PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:target.containerDisplayName
                                                              target:self
                                                                 set:@selector(setValue:forSpecifier:)
                                                                 get:@selector(getValueForSpecifier:)
                                                              detail:nil cell:PSSwitchCell edit:nil];
            [row setProperty:key forKey:@"key"];
            [row setProperty:@"com.niubiprass.splitx" forKey:@"defaults"];
            [row setProperty:@YES forKey:@"default"];
            [result addObject:row];
        }
        } @catch (NSException *e) {
            PXLogW(@"prefs", @"%@ 分身行构建失败 %@", bundle, e.reason);
        }
    }
    return result;
}
@end
