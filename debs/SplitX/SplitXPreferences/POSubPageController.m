#import "POSubPageController.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import "POSplitXLog.h"
#import <objc/message.h>

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
        } else {
            // 自定义 cell 与滑杆：给 PSControlTableCell 作底，再用 cellClass 覆盖。
            spec = [PSSpecifier preferenceSpecifierNamed:label target:self
                                                     set:(hasKey ? @selector(setValue:forSpecifier:) : NULL)
                                                     get:(hasKey ? @selector(getValueForSpecifier:) : NULL)
                                                  detail:nil cell:PSGroupCell edit:nil];   // 只当容器，真实 cell 由 cellClass 决定
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
@end
