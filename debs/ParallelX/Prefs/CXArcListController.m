// CXArcListController.m — ARC 设置嵌在 ParallelX 原面板内，无独立首页入口。
// 复用旧触发设置的 native PSListController/PSSpecifier 值链和枚举。
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import "CXPrefs.h"
#import "CXArcSettings.h"
#import "CXLog.h"
#include <math.h>

@interface CXArcListController : PSListController
@end

@implementation CXArcListController
- (instancetype)init {
    if ((self = [super init])) self.title = @"ARC 角落唤醒";
    return self;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSpecifiers];
}

- (PSSpecifier *)row:(NSString *)name key:(NSString *)key cell:(PSCellType)cell {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:name target:self
        set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
        detail:nil cell:cell edit:NULL];
    [spec setProperty:key forKey:@"key"];
    [spec setProperty:@"com.niubiprass.clonex" forKey:@"defaults"];
    [spec setProperty:CXArcDefaultValue(key) forKey:@"default"];
    return spec;
}

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSMutableArray *specs = [NSMutableArray array];
    PSSpecifier *intro = [PSSpecifier groupSpecifierWithName:@"ARC 角落唤醒"];
    [intro setProperty:@"从选定角落向屏幕内拖动，驱动原有面板。菜单、图标、动画和分屏窗口仍由 ParallelX 控制；此页只设置触发手势。"
               forKey:@"footerText"];
    [specs addObject:intro];
    [specs addObject:[self row:@"启用 ARC 角落唤醒" key:@"CXArcEnabled" cell:PSSwitchCell]];
    PSSpecifier *side = [self row:@"触发角落" key:@"CXArcSide" cell:PSLinkCell];
    [side setProperty:@[@0, @1, @2] forKey:@"validValues"];
    [side setProperty:@[@"右下", @"左下", @"左右两侧"] forKey:@"validTitles"];
    [side setProperty:@YES forKey:@"cxArcChoice"];
    [specs addObject:side];
    PSSpecifier *shape = [self row:@"触发区域形状" key:@"CXArcTriggerRegionMode" cell:PSLinkCell];
    [shape setProperty:@[@0, @1] forKey:@"validValues"];
    [shape setProperty:@[@"扇形", @"矩形"] forKey:@"validTitles"];
    [shape setProperty:@YES forKey:@"cxArcChoice"];
    [specs addObject:shape];
    PSSpecifier *region = [PSSpecifier groupSpecifierWithName:@"触发区域"];
    [region setProperty:@"扇形读取半径；矩形读取长度、高度与内侧圆角。调试显示和实际命中使用同一路径。设置立即生效，不创建遮挡点击的覆盖窗口。"
                forKey:@"footerText"];
    [specs addObject:region];
    NSArray *sliders = @[
        @[@"扇形半径", @"CXArcRadius", @1, @300],
        @[@"矩形长度", @"CXArcRectangleLength", @1, @150],
        @[@"矩形高度", @"CXArcRectangleHeight", @1, @150],
        @[@"矩形内侧圆角", @"CXArcRectangleCornerRadius", @0, @150],
        @[@"水平偏移", @"CXArcOffsetX", @0, @100],
        @[@"垂直偏移", @"CXArcOffsetY", @0, @100]
    ];
    for (NSArray *row in sliders) {
        PSSpecifier *spec = [self row:row[0] key:row[1] cell:PSSliderCell];
        [spec setProperty:row[2] forKey:@"min"];
        [spec setProperty:row[3] forKey:@"max"];
        [spec setProperty:@YES forKey:@"showValue"];
        [spec setProperty:@64 forKey:@"height"];
        [specs addObject:spec];
    }
    [specs addObject:[self row:@"显示触发区域（调试）" key:@"CXArcDebug" cell:PSSwitchCell]];
    _specifiers = specs;
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    return [CXPrefs.shared objectForKey:key] ?: CXArcDefaultValue(key) ?: @0;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    if (!CXArcDefaultValue(key) || ![value isKindOfClass:NSNumber.class] || !isfinite([value doubleValue])) return;
    NSArray *choices = [spec propertyForKey:@"validValues"];
    if (choices && ![choices containsObject:value]) return;
    NSNumber *min = [spec propertyForKey:@"min"], *max = [spec propertyForKey:@"max"];
    if (min && max) value = @(round(MIN(MAX([value doubleValue], min.doubleValue), max.doubleValue)));
    [CXPrefs.shared setObject:value forKey:key];
    // 复用旧矩形修复：调整矩形尺寸时切到矩形模式，避免滑杆被非当前模式忽略。
    if ([key hasPrefix:@"CXArcRectangle"]) {
        [CXPrefs.shared setObject:@1 forKey:@"CXArcTriggerRegionMode"];
        for (PSSpecifier *row in self.specifiers)
            if ([[row propertyForKey:@"key"] isEqual:@"CXArcTriggerRegionMode"]) [self reloadSpecifier:row animated:NO];
    }
    CXLog(@"[prefs] arc %@=%@", key, value);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    if ([[spec propertyForKey:@"cxArcChoice"] boolValue]) {
        NSArray *values = [spec propertyForKey:@"validValues"], *titles = [spec propertyForKey:@"validTitles"];
        NSUInteger i = [values indexOfObject:[self readPreferenceValue:spec]];
        cell.detailTextLabel.text = i < titles.count ? titles[i] : @"";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    if ([spec cellType] == PSSliderCell) return 64;
    return [super tableView:tableView heightForRowAtIndexPath:indexPath];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    if (![[spec propertyForKey:@"cxArcChoice"] boolValue]) {
        [super tableView:tableView didSelectRowAtIndexPath:indexPath]; return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray *values = [spec propertyForKey:@"validValues"], *titles = [spec propertyForKey:@"validTitles"];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:spec.name message:nil
        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSUInteger i = 0; i < MIN(values.count, titles.count); i++) {
        id value = values[i];
        [sheet addAction:[UIAlertAction actionWithTitle:titles[i] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self setPreferenceValue:value specifier:spec];
            [self reloadSpecifier:spec animated:NO];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = tableView;
    sheet.popoverPresentationController.sourceRect = [tableView rectForRowAtIndexPath:indexPath];
    [self presentViewController:sheet animated:YES completion:nil];
}
@end
