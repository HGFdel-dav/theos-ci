#import "TWSplitSettingsController.h"
#import "TWSpecifiers.h"
#import "TWPXPrefs.h"
#import "TWPrefs.h"
#import "TWAppCatalog.h"
#import <math.h>

// Labels/defaults/ranges transcribed from the bundled SplitSettings.plist and
// zh-Hans.lproj/SplitSettings.strings. Feature keys retain the original schema,
// but implemented gesture consumers read Twin's own domain, never an inert domain.
// Native notification taps / URL routing / URL exclusions use the engine domain.
@interface TWSplitSettingsController ()
@property(nonatomic, strong) TWPXPrefs *px;
@end
@implementation TWSplitSettingsController
- (instancetype)init { return [self initForContentSize:CGSizeZero]; }
- (instancetype)initForContentSize:(CGSize)size {
    if ((self = [super initForContentSize:size])) {
        self.title = @"分屏设置"; _px = [TWPXPrefs new];
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [TWPrefs.shared reload];
    [self reloadSpecifiers];
}
- (PSSpecifier *)twSwitch:(NSString *)title key:(NSString *)key native:(BOOL)native fallback:(BOOL)fallback {
    PSSpecifier *s = TWRowSpecifier(self, title, key, @(fallback), nil, PSSwitchCell, nil, nil, nil);
    [s setProperty:@(native) forKey:@"twEngine"];
    return s;
}
- (PSSpecifier *)twSlider:(NSString *)title key:(NSString *)key minimum:(double)minimum maximum:(double)maximum fallback:(double)fallback {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:title target:self
        set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
        detail:Nil cell:PSSliderCell edit:Nil];
    [s setProperty:key forKey:@"key"]; [s setProperty:@(minimum) forKey:@"min"];
    [s setProperty:@(maximum) forKey:@"max"]; [s setProperty:@(fallback) forKey:@"default"];
    [s setProperty:@YES forKey:@"showValue"];
    return s;
}
- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSMutableArray *rows = [NSMutableArray array];
    [rows addObject:TWGroupSpecifier(@"图标手势", @"桌面应用图标上滑、下滑或长按菜单分屏。文件夹与小组件不处理；关闭总开关或锁屏时不触发。")];
    [rows addObject:[self twSwitch:@"图标上滑分屏" key:@"splitIconSwipeUpEnabled" native:NO fallback:NO]];
    [rows addObject:[self twSwitch:@"图标下滑分屏" key:@"splitIconSwipeDownEnabled" native:NO fallback:NO]];
    [rows addObject:[self twSwitch:@"长按图标菜单" key:@"splitIconLongPressMenuEnabled" native:NO fallback:NO]];
    [rows addObject:TWGroupSpecifier(@"通知", @"点击通知由窗口引擎处理。下拉与长按使用独立开关；无法确认通知来源或系统接口不匹配时保持系统原行为。")];
    [rows addObject:[self twSwitch:@"点击通知分屏" key:@"notificationSplitEnabled" native:YES fallback:YES]];
    [rows addObject:[self twSwitch:@"下拉通知分屏" key:@"splitNotificationPullDownEnabled" native:NO fallback:NO]];
    [rows addObject:[self twSwitch:@"长按通知分屏" key:@"splitNotificationLongPressEnabled" native:NO fallback:NO]];
    [rows addObject:TWGroupSpecifier(@"底部上滑关闭", @"快速上滑关闭浮窗。阈值越大，需要越快；从现有窗口底部移动区域开始滑动。触摸区域大小用于限定已有移动手势的起点，不扩展系统触摸范围。")];
    [rows addObject:[self twSwitch:@"底部上滑关闭" key:@"splitBottomSwipeUpCloseEnabled" native:NO fallback:YES]];
    [rows addObject:[self twSlider:@"上滑关闭阈值" key:@"splitBottomSwipeUpCloseThreshold" minimum:1 maximum:100 fallback:37]];
    [rows addObject:[self twSlider:@"底部手势触摸区域" key:@"splitGestureRegionSize" minimum:8 maximum:44 fallback:18]];
    [rows addObject:TWGroupSpecifier(@"链接跳转", @"URL 跳转由窗口引擎直接处理，保留原链接及回调。排除列表保存应用标识，不重新执行打开操作。")];
    [rows addObject:[self twSwitch:@"URL 跳转分屏" key:@"urlSplitEnabled" native:YES fallback:YES]];
    [rows addObject:[self twSwitch:@"系统 URL 分屏" key:@"splitSystemURLRoutingEnabled" native:NO fallback:NO]];
    [rows addObject:[self twSwitch:@"快捷指令浮窗" key:@"splitShortcutFloatingEnabled" native:NO fallback:NO]];
    [rows addObject:[self twSwitch:@"回调自动关闭浮窗" key:@"splitCallbackAutoCloseFloatingEnabled" native:NO fallback:NO]];
    PSSpecifier *exclude = TWLinkRowSpecifier(self, @"URL 分屏排除应用", nil, @"TWURLExcludedAppsController", nil, nil);
    [rows addObject:exclude];
    [rows addObject:TWGroupSpecifier(nil, @"系统跳转和后台快捷指令沿原版请求条件处理；无法确认请求来源时使用系统原行为。")];
    _specifiers = [rows copy];
    return _specifiers;
}
- (id)controllerForSpecifier:(PSSpecifier *)specifier {
    id controller = TWControllerForSpecifier(self, specifier);
    return controller ?: TWSuperControllerForSpecifier(self, specifier);
}
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (![key isKindOfClass:NSString.class] || !key.length) return nil;
    id fallback = [specifier propertyForKey:@"default"] ?: @NO;
    if ([[specifier propertyForKey:@"twEngine"] boolValue]) return [self.px objectForKey:key defaultValue:fallback];
    return [TWPrefs.shared objectForKey:key] ?: fallback;
}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (![key isKindOfClass:NSString.class] || ![value isKindOfClass:NSNumber.class]) return;
    NSNumber *minimum = [specifier propertyForKey:@"min"], *maximum = [specifier propertyForKey:@"max"];
    if (minimum && maximum) {
        double number = [value doubleValue];
        if (!isfinite(number)) return;
        value = @(MIN(maximum.doubleValue, MAX(minimum.doubleValue, number)));
    }
    if ([[specifier propertyForKey:@"twEngine"] boolValue]) [self.px setObject:value forKey:key];
    else { [TWPrefs.shared setObject:value forKey:key]; [TWPrefs.shared synchronize]; }
}
- (void)editURLExclusions:(__unused PSSpecifier *)specifier {
    id raw = [self.px objectForKey:@"urlSplitExcluded" defaultValue:@[]];
    NSMutableArray *valid = [NSMutableArray array];
    if ([raw isKindOfClass:NSArray.class]) for (id item in raw) if ([item isKindOfClass:NSString.class]) [valid addObject:item];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"URL 分屏排除应用"
        message:@"输入应用 Bundle ID，使用逗号、分号、空格或换行分隔。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = [valid componentsJoinedByString:@", "]; field.placeholder = @"com.example.app";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *text = alert.textFields.firstObject.text ?: @"";
        NSMutableCharacterSet *separators = [NSCharacterSet.whitespaceAndNewlineCharacterSet mutableCopy];
        [separators addCharactersInString:@",;，；"];
        NSMutableOrderedSet *identifiers = [NSMutableOrderedSet orderedSet];
        for (NSString *item in [text componentsSeparatedByCharactersInSet:separators]) {
            if (!item.length) continue;
            NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
            if ([item rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound || [item rangeOfString:@"."].location == NSNotFound) {
                UIAlertController *error = [UIAlertController alertControllerWithTitle:@"未保存" message:@"请填写有效的应用 Bundle ID。" preferredStyle:UIAlertControllerStyleAlert];
                [error addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [weakSelf presentViewController:error animated:YES completion:nil]; return;
            }
            [identifiers addObject:item];
        }
        [weakSelf.px setObject:identifiers.array forKey:@"urlSplitExcluded"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    TWStyleSliderCellIfNeeded(cell, specifier);
}
@end

@implementation TWURLExcludedAppsController {
    TWPXPrefs *_px;
}
- (instancetype)init { return [self initForContentSize:UIScreen.mainScreen.bounds.size]; }
- (instancetype)initForContentSize:(CGSize)size {
    if ((self = [super initForContentSize:size])) { self.title = @"URL 分屏排除应用"; _px = [TWPXPrefs new]; }
    return self;
}
- (NSArray *)specifiers {
    if (!_px) _px = [TWPXPrefs new];
    if (!_specifiers) {
        NSMutableArray *rows = [NSMutableArray arrayWithObject:TWGroupSpecifier(@"排除应用", @"开启的应用不通过 URL 自动分屏；应用选择和主清单共用完整扫描结果。")];
        for (NSString *bid in TWInstalledAppIdentifiers()) {
            PSSpecifier *s = TWRowSpecifier(self, TWPrefsAppName(bid), bid, @NO, nil, PSSwitchCell, nil, nil, nil);
            [rows addObject:s];
        }
        _specifiers = rows;
    }
    return _specifiers;
}
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    id raw = [_px objectForKey:@"urlSplitExcluded" defaultValue:@[]];
    return @([raw isKindOfClass:NSArray.class] && [raw containsObject:[specifier propertyForKey:@"key"]]);
}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *bid = [specifier propertyForKey:@"key"];
    if (![bid isKindOfClass:NSString.class] || !bid.length) return;
    id raw = [_px objectForKey:@"urlSplitExcluded" defaultValue:@[]];
    NSMutableArray *list = [raw isKindOfClass:NSArray.class] ? [raw mutableCopy] : [NSMutableArray array];
    if ([value boolValue] && ![list containsObject:bid]) [list addObject:bid];
    if (![value boolValue]) [list removeObject:bid];
    [_px setObject:list forKey:@"urlSplitExcluded"];
}
@end
