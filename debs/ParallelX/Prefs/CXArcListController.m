// CXArcListController.m — ARC 设置嵌在 ParallelX 原面板内，无独立首页入口。
// 复用旧触发设置的 native PSListController/PSSpecifier 值链和枚举。
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import "CXPrefs.h"
#import "CXArcSettings.h"
#import "CXLog.h"
#import "CXArcWake.h"
#include <math.h>

@interface CXArcListController : PSListController {
    NSArray<NSString *> *_sliderKeys;
}
@end

// 自绘滑杆行：左侧功能名、右侧固定宽度数值（右对齐，不再被裁）。
@interface CXArcSliderCell : UITableViewCell
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) UISlider *slider;
@end

@implementation CXArcSliderCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _nameLabel = [[UILabel alloc] init];
        _nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _valueLabel = [[UILabel alloc] init];
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
        _valueLabel.textColor = UIColor.secondaryLabelColor;
        _valueLabel.textAlignment = NSTextAlignmentRight;
        _slider = [[UISlider alloc] init];
        for (UIView *v in @[_nameLabel, _valueLabel, _slider]) [self.contentView addSubview:v];
        for (UIView *v in @[_nameLabel, _valueLabel, _slider]) v.translatesAutoresizingMaskIntoConstraints = NO;
        [_nameLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16].active = YES;
        [_nameLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10].active = YES;
        [_valueLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16].active = YES;
        [_valueLabel.lastBaselineAnchor constraintEqualToAnchor:_nameLabel.lastBaselineAnchor].active = YES;
        [_valueLabel.widthAnchor constraintEqualToConstant:64].active = YES;
        [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_valueLabel.leadingAnchor constant:-8].active = YES;
        [_slider.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16].active = YES;
        [_slider.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16].active = YES;
        [_slider.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2].active = YES;
        [_slider.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-8].active = YES;
    }
    return self;
}
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
    NSMutableArray<NSString *> *sliderKeys = [NSMutableArray array];
    for (NSArray *row in sliders) {
        [sliderKeys addObject:row[1]];
        PSSpecifier *spec = [self row:row[0] key:row[1] cell:PSSliderCell];
        [spec setProperty:row[2] forKey:@"min"];
        [spec setProperty:row[3] forKey:@"max"];
        [spec setProperty:@YES forKey:@"showValue"];
        [spec setProperty:@64 forKey:@"height"];
        [specs addObject:spec];
    }
    _sliderKeys = sliderKeys;
    [specs addObject:[self row:@"显示触发区域（调试）" key:@"CXArcDebug" cell:PSSwitchCell]];
    PSSpecifier *channel = [PSSpecifier groupSpecifierWithName:@"系统手势通道"];
    [channel setProperty:@"系统通道让 ARC 在应用内也能响应。连续两次启动异常会自动停用它、只保留窗口手势；刚出过安全模式或应用内按不出来时，点下面重置一次。"
                forKey:@"footerText"];
    [specs addObject:channel];
    PSSpecifier *reset = [PSSpecifier preferenceSpecifierNamed:@"重置系统手势通道" target:self
        set:NULL get:NULL detail:nil cell:PSButtonCell edit:NULL];
    [reset setButtonAction:@selector(resetSystemChannel:)];
    [specs addObject:reset];
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
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    if ([spec cellType] == PSSliderCell) {
        CXArcSliderCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cxArcSlider"];
        if (!cell) cell = [[CXArcSliderCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"cxArcSlider"];
        cell.nameLabel.text = spec.name;
        CGFloat min = [[spec propertyForKey:@"min"] doubleValue];
        CGFloat max = [[spec propertyForKey:@"max"] doubleValue];
        cell.slider.minimumValue = min;
        cell.slider.maximumValue = max;
        cell.slider.continuous = NO; // 松手才写，避免拖动中反复刷新
        cell.slider.value = [[self readPreferenceValue:spec] doubleValue];
        cell.valueLabel.text = [NSString stringWithFormat:@"%.0f", cell.slider.value];
        cell.slider.tag = (NSInteger)[_sliderKeys indexOfObject:[spec propertyForKey:@"key"]];
        [cell.slider removeTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [cell.slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        return cell;
    }
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    if ([[spec propertyForKey:@"cxArcChoice"] boolValue]) {
        NSArray *values = [spec propertyForKey:@"validValues"], *titles = [spec propertyForKey:@"validTitles"];
        NSUInteger i = [values indexOfObject:[self readPreferenceValue:spec]];
        cell.detailTextLabel.text = i < titles.count ? titles[i] : @"";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        cell.detailTextLabel.text = @"";
    }
    return cell;
}

- (void)sliderChanged:(UISlider *)sender {
    @try {
        NSInteger index = sender.tag;
        if (index < 0 || index >= (NSInteger)_sliderKeys.count) return;
        NSString *key = _sliderKeys[index];
        id spec = sender.superview.superview; // 只用于回显；不依赖 PS 查询
        NSInteger v = (NSInteger)llround(sender.value);
        [CXPrefs.shared setObject:@(v) forKey:key];
        if ([key hasPrefix:@"CXArcRectangle"])
            [CXPrefs.shared setObject:@1 forKey:@"CXArcTriggerRegionMode"];
        UIView *cell = sender.superview.superview;
        if ([cell isKindOfClass:CXArcSliderCell.class])
            ((CXArcSliderCell *)cell).valueLabel.text = [NSString stringWithFormat:@"%ld", (long)v];
        CXLog(@"[prefs] arc %@=%ld", key, (long)v);
        (void)spec;
    } @catch (NSException *e) { CXLog(@"[prefs] slider 异常 %@", e.reason); }
}

- (void)resetSystemChannel:(PSSpecifier *)spec {
    [CXPrefs.shared setObject:@NO forKey:@"CXArcChannelBlocked"];
    [CXPrefs.shared setObject:@0 forKey:@"CXArcChannelFailures"];
    [CXPrefs.shared setObject:@NO forKey:@"CXArcChannelPending"];
    // CXPrefs synchronize 会发布 com.niubiprass.clonex/changed，SpringBoard 据此重试注册。
    CXLog(@"[prefs] 系统手势通道已重置");
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    if ([spec cellType] == PSSliderCell) return 68;
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
