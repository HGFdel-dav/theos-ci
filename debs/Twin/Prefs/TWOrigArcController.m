// TWOrigArcController.m
// 原版「触发设置」页：直接读 TwinArcPrefs.bundle 里的 TriggerSettings.plist，
// 使用 PSListController / PSSpecifier 的原生值链，读写落在原版设置域。
#import "TWOrigArcController.h"
#import "TWSpecifiers.h"
#import <CoreFoundation/CoreFoundation.h>
#import "TWRuntimeLog.h"

static NSString *const kOrigDomain = @"com.susudear.screencoreprefs";

#import "TWPath.h"

static NSString *TWOrigBundlePath(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    // ① 最可靠：TwinPrefs 自己就在 PreferenceBundles 里，隔壁就是它
    NSString *selfBundle = [NSBundle mainBundle].bundlePath;
    if (selfBundle.length) {
        [paths addObject:[[selfBundle stringByDeletingLastPathComponent]
                          stringByAppendingPathComponent:@"TwinArcPrefs.bundle"]];
    }
    // ② RootHide / Dopamine 的各种根
    NSArray<NSString *> *roots = TWJBRootCandidates();
    if ([roots isKindOfClass:NSArray.class]) {
        for (NSString *root in roots) {
            if (!root.length) continue;
            [paths addObject:[root stringByAppendingPathComponent:@"Library/PreferenceBundles/TwinArcPrefs.bundle"]];
        }
    }
    // ③ 常规路径兜底
    [paths addObject:@"/Library/PreferenceBundles/TwinArcPrefs.bundle"];
    [paths addObject:@"/var/jb/Library/PreferenceBundles/TwinArcPrefs.bundle"];

    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *p in paths) {
        if ([fm fileExistsAtPath:[p stringByAppendingPathComponent:@"TriggerSettings.plist"]]) {
            TWRuntimeLog(@"[origarc] bundle ← %@", p);
            return p;
        }
    }
    TWRuntimeLog(@"[origarc] 找不到 TwinArcPrefs.bundle，试过：%@", [paths componentsJoinedByString:@" | "]);
    return nil;
}

static id TWOrigRead(NSString *key, id fallback) {
    if (!key.length) return fallback;
    CFPreferencesAppSynchronize((__bridge CFStringRef)kOrigDomain);
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)kOrigDomain);
    return v ? (__bridge_transfer id)v : fallback;
}

static void TWOrigWrite(NSString *key, id value) {
    if (!key.length || !value) return;
    TWRuntimeLog(@"[origarc] write %@=%@", key, value);
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)kOrigDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kOrigDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.niubiprass.twin/preferences-changed"),
                                         NULL, NULL, YES);
}

#import <Preferences/PSSpecifier.h>
#import "TWStyle.h"
#import <math.h>

@implementation TWOrigArcController

// Inherit the framework's content-size entry; do not redirect -init back to it.
- (instancetype)init {
    if ((self = [super init])) self.title = @"弧形菜单与手势";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
}

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSString *path = TWOrigBundlePath();
    NSDictionary *root = path ? [NSDictionary dictionaryWithContentsOfFile:
        [path stringByAppendingPathComponent:@"TriggerSettings.plist"]] : nil;
    NSDictionary *strings = path ? [NSDictionary dictionaryWithContentsOfFile:
        [path stringByAppendingPathComponent:@"zh-Hans.lproj/TriggerSettings.strings"]] : nil;
    NSString *(^localize)(id) = ^NSString *(id key) {
        if (![key isKindOfClass:NSString.class]) return @"";
        NSString *value = strings[key];
        return [value isKindOfClass:NSString.class] ? value : key;
    };
    NSMutableArray *specs = [NSMutableArray array];
    for (id raw in root[@"items"]) {
        if (![raw isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *row = raw;
        NSString *cell = row[@"cell"], *label = localize(row[@"label"]);
        if ([cell isEqualToString:@"PSStaticTextCell"] && !row[@"validValues"]) continue;
        if ([cell isEqualToString:@"PSGroupCell"] || [cell isEqualToString:@"PSButtonCell"]) {
            PSSpecifier *group = [PSSpecifier groupSpecifierWithName:label];
            if (row[@"footerText"]) [group setProperty:localize(row[@"footerText"]) forKey:@"footerText"];
            [specs addObject:group];
            continue;
        }
        NSString *key = row[@"key"];
        if (![key isKindOfClass:NSString.class] || !key.length) continue;
        // No background layer is drawn anymore; hide its now-dead controls.
        if ([key isEqualToString:@"arcBackgroundEnabled"] || [key isEqualToString:@"arcBackgroundAlpha"]) continue;
        BOOL choice = [row[@"validValues"] isKindOfClass:NSArray.class];
        PSCellType type = choice ? PSLinkCell : [cell isEqualToString:@"PSSwitchCell"] ? PSSwitchCell :
            [cell isEqualToString:@"PSSliderCell"] ? PSSliderCell : PSStaticTextCell;
        PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:label target:self
            set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
            detail:nil cell:type edit:NULL];
        for (NSString *property in @[@"key", @"default", @"min", @"max", @"showValue", @"scLegacyPreferenceKey"])
            if (row[property]) [spec setProperty:row[property] forKey:property];
        [spec setProperty:kOrigDomain forKey:@"defaults"];
        if (type == PSSliderCell) [spec setProperty:@64 forKey:@"height"];
        if (choice) {
            NSMutableArray *titles = [NSMutableArray array];
            for (id title in row[@"validTitles"]) [titles addObject:localize(title)];
            [spec setProperty:titles forKey:@"validTitles"];
            [spec setProperty:row[@"validValues"] forKey:@"validValues"];
            [spec setProperty:@YES forKey:@"twOrigChoice"];
        }
        [specs addObject:spec];
    }
    PSSpecifier *edge = [PSSpecifier preferenceSpecifierNamed:@"菜单贴边距离"
        target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
        detail:nil cell:PSSliderCell edit:NULL];
    [edge setProperty:@"arcMenuEdgeInset" forKey:@"key"];
    [edge setProperty:@0 forKey:@"default"];
    [edge setProperty:@0 forKey:@"min"];
    [edge setProperty:@160 forKey:@"max"];
    [edge setProperty:@YES forKey:@"showValue"];
    [edge setProperty:@64 forKey:@"height"];
    [specs addObject:edge];
    if (!specs.count) {
        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"触发设置"];
        [group setProperty:@"未找到触发设置文件，请检查 Twin 安装。" forKey:@"footerText"];
        [specs addObject:group];
    }
    _specifiers = specs;
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    id value = TWOrigRead(key, nil);
    if (!value) value = TWOrigRead([specifier propertyForKey:@"scLegacyPreferenceKey"], nil);
    return value ?: [specifier propertyForKey:@"default"] ?: @0;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if ([value isKindOfClass:NSNumber.class] && !isfinite([value doubleValue])) return;
    TWOrigWrite(key, value);
    // Keep the previous rectangle-slider fix; only refresh the choice row,
    // not the actively dragged slider (which would interrupt its touch chain).
    if ([key isEqualToString:@"arcRectangleLength"] || [key isEqualToString:@"arcRectangleHeight"] ||
        [key isEqualToString:@"arcRectangleCornerRadius"]) {
        if ([TWOrigRead(@"arcTriggerRegionMode", @0) integerValue] != 1) {
            TWOrigWrite(@"arcTriggerRegionMode", @1);
            for (PSSpecifier *spec in self.specifiers) {
                if ([[spec propertyForKey:@"key"] isEqualToString:@"arcTriggerRegionMode"])
                    [self reloadSpecifier:spec animated:NO];
            }
        }
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    if ([[spec propertyForKey:@"twOrigChoice"] boolValue]) {
        NSArray *values = [spec propertyForKey:@"validValues"], *titles = [spec propertyForKey:@"validTitles"];
        NSUInteger index = [values indexOfObject:[self readPreferenceValue:spec]];
        cell.detailTextLabel.text = index < titles.count ? titles[index] : @"";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    if ([spec cellType] == PSSliderCell) return 64;
    return [super tableView:tableView heightForRowAtIndexPath:indexPath];
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell
forRowAtIndexPath:(NSIndexPath *)indexPath {
    TWStyleSliderCellIfNeeded(cell, [self specifierAtIndexPath:indexPath]);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    if (![[spec propertyForKey:@"twOrigChoice"] boolValue]) {
        [super tableView:tableView didSelectRowAtIndexPath:indexPath];
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray *values = [spec propertyForKey:@"validValues"], *titles = [spec propertyForKey:@"validTitles"];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:spec.name message:nil
        preferredStyle:UIAlertControllerStyleActionSheet];
    id current = [self readPreferenceValue:spec];
    for (NSUInteger i = 0; i < MIN(values.count, titles.count); i++) {
        id value = values[i];
        NSString *title = [current isEqual:value] ? [@"✓ " stringByAppendingString:titles[i]] : titles[i];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self setPreferenceValue:value specifier:spec];
            [self reloadSpecifier:spec animated:NO];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    popover.sourceView = tableView;
    popover.sourceRect = [tableView rectForRowAtIndexPath:indexPath];
    [self presentViewController:sheet animated:YES completion:nil];
}
@end
