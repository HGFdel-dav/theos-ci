// TWOrigArcController.m
// 原版「触发设置」页：直接读 TwinArcPrefs.bundle 里的 TriggerSettings.plist，
// 用系统原生 specifier 渲染（标签取自原版自己的 zh-Hans 字符串），
// 读写落在原版设置域 com.susudear.screencoreprefs —— 与原版行为一致。
#import "TWOrigArcController.h"
#import "TWStyle.h"
#import <CoreFoundation/CoreFoundation.h>

static NSString *const kOrigDomain = @"com.susudear.screencoreprefs";

static NSString *TWOrigBundlePath(void) {
    NSArray<NSString *> *paths = @[@"/Library/PreferenceBundles/TwinArcPrefs.bundle",
                                   @"/var/jb/Library/PreferenceBundles/TwinArcPrefs.bundle"];
    for (NSString *p in paths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return p;
    }
    return nil;
}

@implementation TWOrigArcController {
    NSArray *_rows;          // 解析后的 plist 行
    NSDictionary *_strings;  // 本地化表
}

- (instancetype)init {
    if ((self = [super init])) {
        self.title = @"弧形菜单与手势";
    }
    return self;
}

#pragma mark - 读写原版域

static id TWOrigRead(NSString *key) {
    if (!key.length) return nil;
    CFPreferencesAppSynchronize((__bridge CFStringRef)kOrigDomain);
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)kOrigDomain);
    return v ? (__bridge_transfer id)v : nil;
}

static void TWOrigWrite(NSString *key, id value) {
    if (!key.length) return;
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)kOrigDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kOrigDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.niubiprass.twin/preferences-changed"),
                                         NULL, NULL, YES);
}

#pragma mark - 载入原版 plist

- (void)twLoadRows {
    if (_rows) return;
    NSString *bundlePath = TWOrigBundlePath();
    if (!bundlePath) { _rows = @[]; return; }
    NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
    NSString *plist = [bundlePath stringByAppendingPathComponent:@"TriggerSettings.plist"];
    NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:plist];
    NSArray *items = root[@"items"];

    // 本地化：优先 bundle 的 zh-Hans 表，读不到就直接用键名。
    NSMutableDictionary *strings = [NSMutableDictionary dictionary];
    NSString *lproj = [bundlePath stringByAppendingPathComponent:@"zh-Hans.lproj/TriggerSettings.strings"];
    NSDictionary *raw = [NSDictionary dictionaryWithContentsOfFile:lproj];
    if ([raw isKindOfClass:NSDictionary.class]) [strings addEntriesFromDictionary:raw];

    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *it in items) {
        if (![it isKindOfClass:NSDictionary.class]) continue;
        NSString *cell = it[@"cell"] ?: @"";
        NSString *labelKey = it[@"label"] ?: @"";
        NSString *label = strings[labelKey] ?: labelKey;
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        row[@"cell"] = cell;
        row[@"label"] = label;
        if (it[@"key"]) row[@"key"] = it[@"key"];
        if (it[@"default"]) row[@"default"] = it[@"default"];
        if (it[@"min"]) row[@"min"] = it[@"min"];
        if (it[@"max"]) row[@"max"] = it[@"max"];
        if (it[@"validValues"]) row[@"validValues"] = it[@"validValues"];
        if (it[@"validTitles"]) {
            NSMutableArray *titles = [NSMutableArray array];
            for (NSString *t in it[@"validTitles"]) [titles addObject:(strings[t] ?: t)];
            row[@"validTitles"] = titles;
        }
        if (it[@"footerText"]) {
            NSString *f = it[@"footerText"];
            row[@"footer"] = strings[f] ?: f;
        }
        [rows addObject:row];
    }
    _rows = rows;
    _strings = strings;
}

#pragma mark - specifiers

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    [self twLoadRows];
    NSMutableArray *specs = [NSMutableArray array];

    for (NSDictionary *row in _rows) {
        NSString *cell = row[@"cell"];
        NSString *label = row[@"label"] ?: @"";
        NSString *key = row[@"key"];

        if ([cell isEqualToString:@"PSGroupCell"]) {
            PSSpecifier *g = [PSSpecifier groupSpecifierWithName:label];
            if (row[@"footer"]) [g setProperty:row[@"footer"] forKey:@"footerText"];
            [specs addObject:g];
            continue;
        }
        // 原版的「ARC 触发区 / ARC 菜单」是可折叠标题，这里直接当分组标题用。
        if ([cell isEqualToString:@"PSButtonCell"]) {
            if (label.length) [specs addObject:[PSSpecifier groupSpecifierWithName:label]];
            continue;
        }
        if ([cell isEqualToString:@"PSSwitchCell"]) {
            PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:label
                                                             target:self
                                                                set:@selector(twSetValue:specifier:)
                                                                get:@selector(twGetValue:)
                                                             detail:nil
                                                               cell:PSSwitchCell
                                                               edit:nil];
            [sp setProperty:key forKey:@"key"];
            if (row[@"default"]) [sp setProperty:row[@"default"] forKey:@"default"];
            [specs addObject:sp];
            continue;
        }
        if ([cell isEqualToString:@"PSSliderCell"]) {
            PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:label
                                                             target:self
                                                                set:@selector(twSetValue:specifier:)
                                                                get:@selector(twGetValue:)
                                                             detail:nil
                                                               cell:PSSliderCell
                                                               edit:nil];
            [sp setProperty:key forKey:@"key"];
            [sp setProperty:row[@"min"] ?: @0 forKey:@"min"];
            [sp setProperty:row[@"max"] ?: @100 forKey:@"max"];
            if (row[@"default"]) [sp setProperty:row[@"default"] forKey:@"default"];
            [specs addObject:sp];
            continue;
        }
        if ([cell isEqualToString:@"PSStaticTextCell"] && row[@"validValues"]) {
            PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:label
                                                             target:self
                                                                set:@selector(twSetValue:specifier:)
                                                                get:@selector(twGetValue:)
                                                             detail:NSClassFromString(@"PSListItemsController")
                                                               cell:PSLinkListCell
                                                               edit:nil];
            [sp setProperty:key forKey:@"key"];
            [sp setProperty:row[@"validValues"] forKey:@"validValues"];
            [sp setProperty:row[@"validTitles"] forKey:@"titles"];
            if (row[@"default"]) [sp setProperty:row[@"default"] forKey:@"default"];
            [specs addObject:sp];
            continue;
        }
    }
    _specifiers = specs;
    return _specifiers;
}

#pragma mark - 值

- (id)twGetValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    id v = TWOrigRead(key);
    if (v) return v;
    return [specifier propertyForKey:@"default"] ?: @0;
}

- (void)twSetValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    TWOrigWrite(key, value);
}
@end
