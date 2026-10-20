// TWOrigArcController.m
// 原版「触发设置」页：直接读 TwinArcPrefs.bundle 里的 TriggerSettings.plist，
// 自己画表格（和 We 其他能正常显示的页同一套做法），读写落在原版设置域。
#import "TWOrigArcController.h"
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
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)kOrigDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kOrigDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.niubiprass.twin/preferences-changed"),
                                         NULL, NULL, YES);
}

#pragma mark - 滑杆单元格

@interface TWOrigSliderCell : UITableViewCell
@property (nonatomic, strong) UILabel *titleLabel2;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) UISlider *slider;
@end

@implementation TWOrigSliderCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        _titleLabel2 = [[UILabel alloc] init];
        _titleLabel2.font = [UIFont systemFontOfSize:17];
        [self.contentView addSubview:_titleLabel2];

        _valueLabel = [[UILabel alloc] init];
        _valueLabel.font = [UIFont systemFontOfSize:15];
        _valueLabel.textColor = [UIColor secondaryLabelColor];
        _valueLabel.textAlignment = NSTextAlignmentRight;
        [self.contentView addSubview:_valueLabel];

        _slider = [[UISlider alloc] init];
        [self.contentView addSubview:_slider];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.contentView.bounds);
    CGFloat h = CGRectGetHeight(self.contentView.bounds);
    _titleLabel2.frame = CGRectMake(16, 6, w - 32 - 70, 21);
    _valueLabel.frame = CGRectMake(w - 16 - 70, 6, 70, 21);
    _slider.frame = CGRectMake(16, h - 30, w - 32, 24);
}
@end

#pragma mark - 页面

@implementation TWOrigArcController {
    NSArray<NSDictionary *> *_sections;
    NSArray *_flatRows;
}

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = @"弧形菜单与手势";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    [self twLoad];
}

- (void)twLoad {
    NSMutableArray *sections = [NSMutableArray array];
    NSString *path = TWOrigBundlePath();
    NSMutableArray *all = [NSMutableArray array];

    NSMutableDictionary *profile = nil;

    if (path) {
        NSString *plistPath = [path stringByAppendingPathComponent:@"TriggerSettings.plist"];
        NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        NSArray *items = [root isKindOfClass:NSDictionary.class] ? root[@"items"] : nil;

        NSDictionary *strings = [NSDictionary dictionaryWithContentsOfFile:
                                 [path stringByAppendingPathComponent:@"zh-Hans.lproj/TriggerSettings.strings"]];

        NSString *(^localize)(NSString *) = ^NSString *(NSString *key) {
            if (![key isKindOfClass:NSString.class] || !key.length) return @"";
            id hit = strings[key];
            return [hit isKindOfClass:NSString.class] ? hit : key;
        };

        for (NSDictionary *it in items) {
            if (![it isKindOfClass:NSDictionary.class]) continue;
            NSString *cell = it[@"cell"] ?: @"";
            NSString *label = localize(it[@"label"]);

            // 原版在滑杆上方放了一条"纯标题"（PSStaticTextCell，无 key、无选项），
            // 我们的滑杆行本身就有标题，照搬会出现"每个都两行"，所以跳过。
            if ([cell isEqualToString:@"PSStaticTextCell"] && !it[@"validValues"] &&
                ![it[@"key"] isKindOfClass:NSString.class]) {
                continue;
            }
            if ([cell isEqualToString:@"PSGroupCell"] || [cell isEqualToString:@"PSButtonCell"]) {
                if (label.length) {
                    profile = [NSMutableDictionary dictionary];
                    profile[@"title"] = label;
                    profile[@"rows"] = [NSMutableArray array];
                    if (it[@"footerText"]) profile[@"footer"] = localize(it[@"footerText"]);
                    [sections addObject:profile];
                }
                continue;
            }
            if (!profile) {
                profile = [NSMutableDictionary dictionary];
                profile[@"title"] = @"";
                profile[@"rows"] = [NSMutableArray array];
                [sections addObject:profile];
            }
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
                for (NSString *t in it[@"validTitles"]) [titles addObject:localize(t)];
                row[@"validTitles"] = titles;
            }
            [profile[@"rows"] addObject:row];
            [all addObject:row];
        }
    }

    if (!sections.count) {
        // 找不到原版文件时给出明确提示，而不是一片空白。
        NSMutableDictionary *fallback = [NSMutableDictionary dictionary];
        fallback[@"title"] = @"触发设置";
        fallback[@"rows"] = [@[@{@"cell": @"PSSwitchCell", @"label": @"未找到原版设置文件", @"key": @"", @"default": @NO}] mutableCopy];
        fallback[@"footer"] = [NSString stringWithFormat:@"查找路径：%@", path ?: @"(都不存在)"];
        [sections addObject:fallback];
    }
    TWRuntimeLog(@"[origarc] bundle=%@ sections=%lu rows=%lu",
                 path ?: @"(nil)", (unsigned long)sections.count, (unsigned long)all.count);
    _sections = sections;
    _flatRows = all;
    [self.tableView reloadData];
}

#pragma mark - 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return (NSInteger)_sections.count; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSArray *rows = _sections[(NSUInteger)section][@"rows"];
    return (NSInteger)rows.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSString *t = _sections[(NSUInteger)section][@"title"];
    return t.length ? t : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return _sections[(NSUInteger)section][@"footer"];
}

- (NSDictionary *)rowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray *rows = _sections[(NSUInteger)indexPath.section][@"rows"];
    if (indexPath.row >= (NSInteger)rows.count) return nil;
    return rows[(NSUInteger)indexPath.row];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = [self rowAtIndexPath:indexPath];
    return [row[@"cell"] isEqualToString:@"PSSliderCell"] ? 58.0 : 44.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = [self rowAtIndexPath:indexPath];
    NSString *cell = row[@"cell"] ?: @"";
    NSString *key = row[@"key"];
    NSString *label = row[@"label"] ?: @"";

    if ([cell isEqualToString:@"PSSliderCell"]) {
        TWOrigSliderCell *c = [tableView dequeueReusableCellWithIdentifier:@"slider"];
        if (!c) c = [[TWOrigSliderCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"slider"];
        c.titleLabel2.text = label;
        CGFloat min = [row[@"min"] doubleValue];
        CGFloat max = [row[@"max"] doubleValue];
        if (max <= min) max = min + 100;
        c.slider.minimumValue = min;
        c.slider.maximumValue = max;
        c.slider.value = [TWOrigRead(key, row[@"default"] ?: @(min)) doubleValue];
        double v = c.slider.value;
        c.valueLabel.text = (fabs(v - round(v)) < 0.01)
            ? [NSString stringWithFormat:@"%.0f", v]
            : [NSString stringWithFormat:@"%.2f", v];
        c.slider.tag = indexPath.section * 1000 + indexPath.row;
        [c.slider removeTarget:self action:@selector(twSliderChanged:) forControlEvents:UIControlEventValueChanged];
        [c.slider addTarget:self action:@selector(twSliderChanged:) forControlEvents:UIControlEventValueChanged];
        [c.slider addTarget:self action:@selector(twSliderEnded:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
        return c;
    }

    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"plain"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"plain"];
    c.textLabel.text = label;
    c.detailTextLabel.text = nil;
    c.accessoryView = nil;
    c.accessoryType = UITableViewCellAccessoryNone;
    c.selectionStyle = UITableViewCellSelectionStyleNone;

    if ([cell isEqualToString:@"PSSwitchCell"]) {
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [TWOrigRead(key, row[@"default"] ?: @NO) boolValue];
        sw.tag = indexPath.section * 1000 + indexPath.row;
        [sw addTarget:self action:@selector(twSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        return c;
    }

    if (row[@"validValues"]) {
        NSArray *values = row[@"validValues"];
        NSArray *titles = row[@"validTitles"];
        id current = TWOrigRead(key, row[@"default"] ?: @0);
        NSInteger idx = [values indexOfObject:current];
        if (idx == NSNotFound && values.count) {
            for (NSUInteger i = 0; i < values.count; i++) {
                if ([values[i] integerValue] == [current integerValue]) { idx = (NSInteger)i; break; }
            }
        }
        NSString *title = (idx != NSNotFound && idx < (NSInteger)titles.count) ? titles[(NSUInteger)idx] : @"";
        c.detailTextLabel.text = title;
        c.textLabel.text = label;
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
        return c;
    }

    c.detailTextLabel.text = @"";
    return c;
}

- (void)twSwitchChanged:(UISwitch *)sw {
    NSInteger rowIndex = sw.tag;
    NSIndexPath *ip = [NSIndexPath indexPathForRow:rowIndex % 1000 inSection:rowIndex / 1000];
    NSDictionary *row = [self rowAtIndexPath:ip];
    TWOrigWrite(row[@"key"], @(sw.isOn));
}

- (void)twSliderChanged:(UISlider *)slider {
    NSInteger rowIndex = slider.tag;
    NSIndexPath *ip = [NSIndexPath indexPathForRow:rowIndex % 1000 inSection:rowIndex / 1000];
    NSDictionary *row = [self rowAtIndexPath:ip];
    TWOrigWrite(row[@"key"], @(slider.value));
    TWOrigSliderCell *cell = (TWOrigSliderCell *)[self.tableView cellForRowAtIndexPath:ip];
    if ([cell isKindOfClass:TWOrigSliderCell.class]) {
        double sv = slider.value;
        cell.valueLabel.text = (fabs(sv - round(sv)) < 0.01)
            ? [NSString stringWithFormat:@"%.0f", sv]
            : [NSString stringWithFormat:@"%.2f", sv];
    }
}

- (void)twSliderEnded:(UISlider *)slider {
    [self twSliderChanged:slider];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = [self rowAtIndexPath:indexPath];
    NSArray *values = row[@"validValues"];
    NSArray *titles = row[@"validTitles"];
    if (!values.count || !titles.count) return;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:row[@"label"]
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    id current = TWOrigRead(row[@"key"], row[@"default"] ?: @0);
    for (NSUInteger i = 0; i < values.count && i < titles.count; i++) {
        id value = values[i];
        BOOL selected = ([value integerValue] == [current integerValue]);
        NSString *title = selected ? [NSString stringWithFormat:@"✓ %@", titles[i]] : titles[i];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            TWOrigWrite(row[@"key"], value);
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}
@end
