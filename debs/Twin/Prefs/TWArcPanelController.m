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

@implementation TWArcPanelController {
    CGFloat _heroWidth;
}

// ★ 0.4.2 观测版：同 TWRootListController，异常落盘 + 空白 cell 兜底。
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    @try {
        return [super tableView:tableView cellForRowAtIndexPath:indexPath];
    } @catch (NSException *e) {
        PSSpecifier *sp = [self specifierAtIndexPath:indexPath];
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
        self.title = @"Arc 面板与手势";
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

        // ============ 0.5.0：按设计稿②（Arc 面板与手势）重建 ============

        // ---- 唤醒 ----
        [specs addObject:TWGroupSpecifier(@"唤醒", nil)];
        [specs addObject:TWRowSpecifier(self, @"触发边缘", TWKeyArcSide, @1, nil, PSSegmentCell,
                                        @"rectangle.portrait.lefthalf.inset.filled", nil,
                                        @{@"height": @58, @"twColor": @0, @"twTitles": @[@"左侧", @"右侧", @"两侧"]})];
        [specs addObject:TWRowSpecifier(self, @"触发区宽度", TWKeyArcTriggerWidth, @24, nil, PSSliderCell,
                                        @"arrow.left.and.right", nil,
                                        @{@"height": @78, @"twMin": @8, @"twMax": @60, @"twStep": @1, @"twUnit": @" pt", @"twColor": @2})];
        [specs addObject:TWRowSpecifier(self, @"菜单图标数", TWKeyArcItemCount, @6, nil, PSSliderCell,
                                        @"square.grid.2x2", nil,
                                        @{@"height": @78, @"twMin": @2, @"twMax": @8, @"twStep": @1, @"twUnit": @" 个", @"twColor": @3})];
        [specs addObject:TWRowSpecifier(self, @"弧形半径", TWKeyArcRadius, @140, nil, PSSliderCell,
                                        @"circle.dashed", nil,
                                        @{@"height": @78, @"twMin": @100, @"twMax": @220, @"twStep": @5, @"twUnit": @" pt", @"twColor": @4})];

        // ---- 窗口层级 ----
        [specs addObject:TWGroupSpecifier(@"窗口层级",
            [NSString stringWithFormat:@"生效层级 = 1998 + 视图优先级，当前 %ld。默认 %ld 已高于状态栏(1000)与系统弹窗(2000)；拉到 %ld 为「至高无上」。层级再高也盖不过 iOS 安全界面（密码／支付），也不解除锁屏保护。",
                                       (long)(1998 + priority), (long)TWArcPriorityDefault, (long)TWArcPriorityMax])];
        [specs addObject:TWRowSpecifier(self, @"视图优先级", TWKeyArcWindowPriority, @(TWArcPriorityDefault), nil, PSSliderCell,
                                        @"square.stack.3d.up", nil,
                                        @{@"height": @78, @"twMin": @0, @"twMax": @(TWArcPriorityMax), @"twStep": @1, @"twUnit": @"", @"twColor": @1})];

        // ---- 图标来源 ----
        [specs addObject:TWGroupSpecifier(@"图标来源", nil)];
        [specs addObject:TWRowSpecifier(self, @"显示哪些应用", TWKeyArcIconSource, @0, nil, PSSegmentCell,
                                        @"person.crop.square", nil,
                                        @{@"height": @58, @"twColor": @5, @"twTitles": @[@"最近应用", @"自选应用"]})];
        [specs addObject:TWLinkRowSpecifier(self, @"自选应用与排序", @"list.number", @"TWArcOrderController",
                                            (orderCount ? [NSString stringWithFormat:@"%ld 个", (long)orderCount] : @"未设置"),
                                            @{@"height": @62, @"twColor": @3})];

        // ---- 反馈与长按 ----
        [specs addObject:TWGroupSpecifier(@"反馈与长按",
            @"边缘按住向屏内拖动唤出弧形菜单；松手打开分屏，长按图标按上面选择的方式打开。")];
        [specs addObject:TWRowSpecifier(self, @"音效", TWKeyArcSound, @YES, nil, PSSwitchCell,
                                        @"speaker.wave.2.fill", nil, @{@"height": @62, @"twColor": @4})];
        [specs addObject:TWRowSpecifier(self, @"震动反馈", TWKeyArcHaptic, @YES, nil, PSSwitchCell,
                                        @"iphone.radiowaves.left.and.right", nil, @{@"height": @62, @"twColor": @2})];
        [specs addObject:TWRowSpecifier(self, @"长按图标", TWKeyArcLongPressMode, @0, nil, PSSegmentCell,
                                        @"hand.tap.fill", nil,
                                        @{@"height": @58, @"twColor": @1, @"twTitles": @[@"分身", @"小窗", @"无"]})];

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

- (void)viewDidLoad {
    [super viewDidLoad];
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