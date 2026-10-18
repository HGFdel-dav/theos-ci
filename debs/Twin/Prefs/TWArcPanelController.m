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

        // ---- 触发角落 ----
        [specs addObject:TWGroupSpecifier(@"触发角落",
            @"从选中的角落向屏幕内侧拖动即唤出弧形菜单；可同时启用多个角，全部关闭后角落唤醒不触发。")];
        // 0.4.4：恢复四角独立开关——标准 PSSwitchCell + 标准 get/set 选择子（twBit 位掩码，
        // 自定义选择子签名 get:带specifier / set:双参value+specifier，全是标准机制）。
        NSArray<NSArray *> *cornerRows = @[
            @[@"右下", @"arrow.down.right",  @0],
            @[@"左下", @"arrow.down.left",   @1],
            @[@"左上", @"arrow.up.left",     @2],
            @[@"右上", @"arrow.up.right",    @3],
        ];
        for (NSArray *row in cornerRows) {
            [specs addObject:TWRowSpecifier(self, row[0], TWKeyArcCorners, @3, nil, PSSwitchCell,
                                            row[1], nil,
                                            @{@"height": @58, @"twBit": row[2],
                                              @"twGet": @"twCornerEnabled:",
                                              @"twSet": @"twCornerSetEnabled:specifier:"})];
        }

        // ---- 面板 ----
        [specs addObject:TWGroupSpecifier(@"面板",
            @"图标以该角为圆心扇形展开：半径越大越靠屏内，图标数量越少单个图标越大。")];
        [specs addObject:TWRowSpecifier(self, @"触发区大小", TWKeyArcCornerSize, @64, @"TWSliderCell", PSSliderCell,
                                        @"square.dashed", nil,
                                        @{@"height": @78, @"twMin": @40, @"twMax": @120, @"twStep": @2,
                                          @"twUnit": @" pt", @"twColor": @3})];
        [specs addObject:TWRowSpecifier(self, @"图标数量", TWKeyArcItemCount, @6, @"TWSliderCell", PSSliderCell,
                                        @"square.grid.2x2", nil,
                                        @{@"height": @78, @"twMin": @2, @"twMax": @8, @"twStep": @1,
                                          @"twUnit": @" 个", @"twColor": @2})];
        [specs addObject:TWRowSpecifier(self, @"弧半径", TWKeyArcRadius, @150, @"TWSliderCell", PSSliderCell,
                                        @"circle.dashed", nil,
                                        @{@"height": @78, @"twMin": @100, @"twMax": @220, @"twStep": @5,
                                          @"twUnit": @" pt", @"twColor": @1})];
        [specs addObject:TWRowSpecifier(self, @"音效", TWKeyArcSoundEnabled, @YES, @"TWSwitchCell", PSSwitchCell,
                                        @"speaker.wave.2.fill", nil,
                                        @{@"height": @62, @"twColor": @4})];

        // ---- 窗口层级 ----
        [specs addObject:TWGroupSpecifier(@"窗口层级",
            [NSString stringWithFormat:@"生效层级 = 1998 + 视图优先级，当前 %ld。默认 %ld 已高于状态栏(1000)与系统弹窗(2000)；拉到 %ld 为「至高无上」。层级再高也盖不过 iOS 安全界面（密码／支付），也不解除锁屏保护。菜单收起后整窗隐藏，不劫持触摸。",
                                       (long)(1998 + priority), (long)TWArcPriorityDefault, (long)TWArcPriorityMax])];
        [specs addObject:TWRowSpecifier(self, @"窗口层级优先级", TWKeyArcWindowPriority, @(TWArcPriorityDefault),
                                        @"TWSliderCell", PSSliderCell, @"square.stack.3d.up", nil,
                                        @{@"height": @78, @"twMin": @0, @"twMax": @(TWArcPriorityMax), @"twStep": @1,
                                          @"twUnit": @"", @"twDerivedOffset": @1998, @"twColor": @9})];

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