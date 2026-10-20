// TWArcPanelController.m — 「Arc 面板与手势」子页（四角 / 触发区 / 图标数 /
// 弧半径 / 音效 / 窗口层级优先级）。
//
// 与 TWRootListController 完全同款：同一个 TWStyle + TWCells + TWPrefs 数据面，
// 同样的 specifier 缓存模式（if (!_specifiers) { _specifiers = ...; } return _specifiers;）。
#import "TWArcPanelController.h"
#import "TWCells.h"
#import "TWStyle.h"
#import "TWSpecifiers.h"
#import "TWPath.h"
#import "TWPrefs.h"
#import "TWRuntimeLog.h"

@implementation TWArcPanelController {
    CGFloat _heroWidth;
    BOOL _twAutoPushPicker;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell
forRowAtIndexPath:(NSIndexPath *)indexPath {
    @try {
        PSSpecifier *sp = [self specifierAtIndexPath:indexPath];
        TWStyleSliderCellIfNeeded(cell, sp);
    } @catch (__unused NSException *e) {}
}

// ★ 0.4.2 观测版：同 TWRootListController，异常落盘 + 空白 cell 兜底。
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    @try {
        return [super tableView:tableView cellForRowAtIndexPath:indexPath];
    } @catch (NSException *e) {
        PSSpecifier *sp = [self specifierAtIndexPath:indexPath];
        TWRuntimeLog(@"[panel] cellFor exception sec=%ld row=%ld: %@", (long)indexPath.section, (long)indexPath.row, e.reason ?: e.name);
        TWDiagDumpException(e, [NSString stringWithFormat:@"cellForRow sec=%ld row=%ld",
                                (long)indexPath.section, (long)indexPath.row]);
        TWDiagLog(@"specifier: name=%@ key=%@ cellType=%ld cellClass=%@ detail=%@ bundle=%@",
                  sp.name, [sp propertyForKey:@"key"], (long)[sp cellType],
                  [sp propertyForKey:@"cellClass"], [sp propertyForKey:@"detail"],
                  [sp propertyForKey:@"bundle"]);
        TWDiagLog(@"specifier description: %@", sp);
        return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"TWBlankCell"];
    }
}

- (instancetype)init {
    if ((self = [super init])) {
        self.title = @"图标数量与长按";
    }
    return self;
}

#pragma mark - helpers

#pragma mark - specifiers

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];

        NSInteger priority = [[TWPrefs shared] integerForKey:TWKeyArcWindowPriority defaultValue:TWArcPriorityDefault];
        NSInteger orderCount = (NSInteger)TWArcOrderList().count;

        // 0.9.27：ARC 本体（触发区/菜单/动画/声音）整份改用原版面板
        // （TwinArcPrefs.bundle = ScreenCore 的 TriggerSettings），
        // 这里只保留原版没有、Twin 自己加的项。
        [specs addObject:TWGroupSpecifier(@"图标与长按",
            @"菜单图标数量、长按全屏时长、震动、打开方式、显示哪些应用。")];
        [specs addObject:TWRowSpecifier(self, @"菜单图标数", TWKeyArcItemCount, @6, nil, PSSliderCell,
                                        nil, nil, @{@"twMin": @2, @"twMax": @12, @"twStep": @1, @"twUnit": @" 个"})];
        [specs addObject:TWRowSpecifier(self, @"长按全屏时长", TWKeyArcLongPressDuration, @0.45, nil, PSSliderCell,
                                        nil, nil, @{@"twMin": @0.1, @"twMax": @2.0, @"twStep": @0.05,
                                                    @"twDecimal": @2, @"twUnit": @" 秒"})];
        [specs addObject:TWRowSpecifier(self, @"震动反馈", TWKeyArcHaptic, @YES, nil, PSSwitchCell,
                                        nil, nil, @{})];
        [specs addObject:TWRowSpecifier(self, @"打开方式", TWKeyArcOpenMode, @0, nil, PSSegmentCell,
                                        nil, nil, @{@"twTitles": @[@"分屏", @"全屏"]})];
        [specs addObject:TWRowSpecifier(self, @"显示哪些应用", TWKeyArcIconSource, @0, nil, PSSegmentCell,
                                        nil, nil, @{@"twTitles": @[@"最近应用", @"自选应用"]})];
        [specs addObject:TWLinkRowSpecifier(self, @"自选应用与排序", @"list.number", @"TWArcOrderController", nil, @{})];

        _specifiers = specs;
    }
    return _specifiers;
}

#pragma mark - 子页分发

- (id)controllerForSpecifier:(PSSpecifier *)specifier {
    id controller = TWControllerForSpecifier(self, specifier);
    if (controller) return controller;
    return TWSuperControllerForSpecifier(self, specifier);
}

#pragma mark - lifecycle


- (NSInteger)tableView:(UITableView *)tableView indentationLevelForRowAtIndexPath:(NSIndexPath *)indexPath {
    @try {
        PSSpecifier *sp = [self specifierAtIndexPath:indexPath];
        return [sp propertyForKey:@"twSymbol"] ? 1 : 0;
    } @catch (__unused NSException *e) { return 0; }
}


- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    @try {
        PSSpecifier *sp = [self specifierAtIndexPath:indexPath];
        id value = [sp propertyForKey:@"height"];
        if ([value isKindOfClass:NSNumber.class]) {
            CGFloat h = [value doubleValue];
            if (h >= 44 && h <= 140) return h;   // 分段/滑杆行需要 58~78pt，46pt 会挤掉控件
        }
    } @catch (__unused NSException *e) {}
    return [super tableView:tableView heightForRowAtIndexPath:indexPath];

        @try {
            PSSpecifier *sl = [self specifierAtIndexPath:indexPath];
            if ([sl cellType] == PSSliderCell) return 58.0;   // 滑杆行：标题+数值一行，轨道一行
        } @catch (__unused NSException *e) {}
}

// 选了「自选应用」却一个都没选时，直接弹出选择页——少点一层子页。
- (void)twAutoPushPicker {
    Class cls = NSClassFromString(@"TWArcOrderController");
    if (!cls || ![cls isSubclassOfClass:UIViewController.class]) return;
    UIViewController *vc = [[cls alloc] init];
    if (vc) [self.navigationController pushViewController:vc animated:YES];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_twAutoPushPicker) return;
    NSInteger src = [[TWPrefs shared] integerForKey:TWKeyArcIconSource defaultValue:0];
    if (src == 1 && TWArcOrderList().count == 0) {
        _twAutoPushPicker = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self twAutoPushPicker];
        });
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // 子页是 new 出来的 PSListController：table 没建好时整页是黑的。
    // 这里补背景，至少不会出现"点进去全黑、什么都没有"。    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    @try {
        UITableView *tbl = [self valueForKey:@"table"];
        if ([tbl isKindOfClass:UITableView.class]) tbl.backgroundColor = UIColor.systemGroupedBackgroundColor;
    } @catch (__unused NSException *e) { }
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSpecifiers];
}

#pragma mark - values

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isKindOfClass:NSString.class] && [key hasPrefix:@"TW"]) {
        id stored = [[TWPrefs shared] objectForKey:key];
        if (stored) return stored;
        id fallback = [specifier propertyForKey:@"default"];
        return fallback ?: @NO;
    }
    return [super readPreferenceValue:specifier];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isKindOfClass:NSString.class] && [key hasPrefix:@"TW"]) {
        [[TWPrefs shared] setObject:value forKey:key];
        [[TWPrefs shared] synchronize];
        return;
    }
    [super setPreferenceValue:value specifier:specifier];
}

#pragma mark - 触发角落位掩码开关（标准 get/set 选择子，0.4.4）

- (id)twCornerEnabled:(PSSpecifier *)specifier {
    NSInteger bit = [[specifier propertyForKey:@"twBit"] integerValue];
    NSInteger mask = [[TWPrefs shared] integerForKey:TWKeyArcCorners defaultValue:3];
    return @((mask & ((NSInteger)1 << bit)) != 0);
}

- (void)twCornerSetEnabled:(id)value specifier:(PSSpecifier *)specifier {
    // 标准的双参 set：PSListController 以 (value, specifier) 调用。
    NSInteger bit = [[specifier propertyForKey:@"twBit"] integerValue];
    NSInteger mask = [[TWPrefs shared] integerForKey:TWKeyArcCorners defaultValue:3];
    if ([value boolValue]) { mask |= ((NSInteger)1 << bit); }
    else { mask &= ~((NSInteger)1 << bit); }
    [[TWPrefs shared] setInteger:mask forKey:TWKeyArcCorners];
    [[TWPrefs shared] synchronize];
}

@end