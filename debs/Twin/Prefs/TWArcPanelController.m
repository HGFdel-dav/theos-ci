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

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell
forRowAtIndexPath:(NSIndexPath *)indexPath {
    @try {
        PSSpecifier *sp = [self specifierAtIndexPath:indexPath];
        TWDecorateCellIfNeeded(cell, sp);
        TWStyleSliderCellIfNeeded(cell, sp);
    } @catch (__unused NSException *e) {}
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

        // ---- 唤醒方式（角落 / ParallelX 边缘手柄）----
        [specs addObject:TWGroupSpecifier(@"唤醒方式",
            @"二选一：从屏幕角落起手，或用 ParallelX 原版的边缘手柄。")];
        [specs addObject:TWRowSpecifier(self, @"唤醒方式", TWKeyWakeMode, @0, nil, PSSegmentCell,
                                        @"hand.point.up.left.fill", nil,
                                        @{@"height": @58, @"twColor": @6, @"twTitles": @[@"角落", @"边缘手柄"]})];
        [specs addObject:TWRowSpecifier(self, @"打开方式", TWKeyArcOpenMode, @0, nil, PSSegmentCell,
                                        @"rectangle.split.2x1", nil,
                                        @{@"height": @58, @"twColor": @0, @"twTitles": @[@"分屏", @"全屏"]})];

        // ---- 触发区（照 ScreenCore TriggerSettings）----
        [specs addObject:TWGroupSpecifier(@"从哪些角落唤醒",
            @"勾选后，从该角落往屏内拖即可唤出弧形菜单。至少保留一个。")];
        NSArray *cornerNames = @[@"右下角", @"左下角", @"左上角", @"右上角"];
        NSArray *cornerSymbols = @[@"arrow.down.right", @"arrow.down.left", @"arrow.up.left", @"arrow.up.right"];
        for (NSInteger i = 0; i < 4; i++) {
            [specs addObject:TWRowSpecifier(self, cornerNames[i], TWKeyArcCorners, @YES, nil, PSSwitchCell,
                                            cornerSymbols[i], nil,
                                            @{@"height": @58, @"twColor": @(i % 6), @"twBit": @(i),
                                              @"twGet": @"twCornerEnabled:",
                                              @"twSet": @"twCornerSetEnabled:specifier:"})];
        }

        [specs addObject:TWGroupSpecifier(@"触发区", @"起手的那块区域：扇形按半径算，矩形按长宽算。")];
        [specs addObject:TWRowSpecifier(self, @"触发区形状", TWKeyArcTriggerMode, @0, nil, PSSegmentCell,
                                        @"squareshape.split.2x2", nil,
                                        @{@"height": @58, @"twColor": @0, @"twTitles": @[@"扇形", @"矩形"]})];
        [specs addObject:TWRowSpecifier(self, @"对称镜像", TWKeyArcMirror, @NO, nil, PSSwitchCell,
                                        @"arrow.left.and.right.square", nil,
                                        @{@"height": @58, @"twColor": @1})];
        [specs addObject:TWRowSpecifier(self, @"触发区半径", TWKeyArcCornerSize, @40, nil, PSSliderCell,
                                        @"circle.dashed", nil,
                                        @{@"height": @74, @"twMin": @1, @"twMax": @300, @"twStep": @2, @"twUnit": @" pt", @"twColor": @2})];
        [specs addObject:TWRowSpecifier(self, @"矩形长度", TWKeyArcRectLength, @40, nil, PSSliderCell,
                                        @"rectangle", nil,
                                        @{@"height": @74, @"twMin": @24, @"twMax": @150, @"twStep": @1, @"twUnit": @" pt", @"twColor": @3})];
        [specs addObject:TWRowSpecifier(self, @"矩形高度", TWKeyArcRectHeight, @40, nil, PSSliderCell,
                                        @"rectangle.portrait", nil,
                                        @{@"height": @74, @"twMin": @24, @"twMax": @150, @"twStep": @1, @"twUnit": @" pt", @"twColor": @4})];
        [specs addObject:TWRowSpecifier(self, @"矩形圆角", TWKeyArcRectCorner, @12, nil, PSSliderCell,
                                        @"app", nil,
                                        @{@"height": @74, @"twMin": @0, @"twMax": @150, @"twStep": @1, @"twUnit": @" pt", @"twColor": @5})];
        [specs addObject:TWRowSpecifier(self, @"圆心偏移 X", TWKeyArcOffsetX, @0, nil, PSSliderCell,
                                        @"arrow.right.to.line", nil,
                                        @{@"height": @74, @"twMin": @0, @"twMax": @100, @"twStep": @1, @"twUnit": @" pt", @"twColor": @0})];
        [specs addObject:TWRowSpecifier(self, @"圆心偏移 Y", TWKeyArcOffsetY, @0, nil, PSSliderCell,
                                        @"arrow.down.to.line", nil,
                                        @{@"height": @74, @"twMin": @0, @"twMax": @100, @"twStep": @1, @"twUnit": @" pt", @"twColor": @1})];
        [specs addObject:TWRowSpecifier(self, @"横屏水平偏移", TWKeyArcLandscapeOffset, @0, nil, PSSliderCell,
                                        @"rectangle.landscape", nil,
                                        @{@"height": @74, @"twMin": @0, @"twMax": @200, @"twStep": @2, @"twUnit": @" pt", @"twColor": @2})];

        // ---- 扇形与图标 ----
        [specs addObject:TWGroupSpecifier(@"扇形与图标", nil)];
        [specs addObject:TWRowSpecifier(self, @"弧形半径", TWKeyArcRadius, @140, nil, PSSliderCell,
                                        @"circle.dashed", nil,
                                        @{@"height": @74, @"twMin": @80, @"twMax": @220, @"twStep": @5, @"twUnit": @" pt", @"twColor": @4})];
        [specs addObject:TWRowSpecifier(self, @"偏移距离", TWKeyArcOffsetDistance, @0, nil, PSSliderCell,
                                        @"arrow.up.left.and.arrow.down.right", nil,
                                        @{@"height": @74, @"twMin": @0, @"twMax": @200, @"twStep": @2, @"twUnit": @" pt", @"twColor": @5})];
        [specs addObject:TWRowSpecifier(self, @"菜单整体缩放", TWKeyArcMenuScale, @100, nil, PSSliderCell,
                                        @"arrow.up.left.and.arrow.down.right.circle", nil,
                                        @{@"height": @74, @"twMin": @50, @"twMax": @150, @"twStep": @5, @"twUnit": @" %", @"twColor": @0})];
        [specs addObject:TWRowSpecifier(self, @"横屏菜单缩放", TWKeyArcLandscapeScale, @100, nil, PSSliderCell,
                                        @"rectangle.landscape.rotate", nil,
                                        @{@"height": @74, @"twMin": @50, @"twMax": @400, @"twStep": @5, @"twUnit": @" %", @"twColor": @1})];
        [specs addObject:TWRowSpecifier(self, @"横屏偏移距离", TWKeyArcLandscapeDist, @0, nil, PSSliderCell,
                                        @"arrow.left.and.right.square", nil,
                                        @{@"height": @74, @"twMin": @0, @"twMax": @200, @"twStep": @2, @"twUnit": @" pt", @"twColor": @2})];
        [specs addObject:TWRowSpecifier(self, @"图标形状", TWKeyArcIconShape, @0, nil, PSSegmentCell,
                                        @"square.on.circle", nil,
                                        @{@"height": @58, @"twColor": @3, @"twTitles": @[@"圆角方形", @"圆形"]})];
        [specs addObject:TWRowSpecifier(self, @"图标大小", TWKeyArcIconSize, @28, nil, PSSliderCell,
                                        @"app.badge", nil,
                                        @{@"height": @74, @"twMin": @28, @"twMax": @80, @"twStep": @2, @"twUnit": @" pt", @"twColor": @1})];
        [specs addObject:TWRowSpecifier(self, @"应用图标缩放", TWKeyArcAppIconScale, @70, nil, PSSliderCell,
                                        @"app.dashed", nil,
                                        @{@"height": @74, @"twMin": @10, @"twMax": @100, @"twStep": @5, @"twUnit": @" %", @"twColor": @2})];
        [specs addObject:TWRowSpecifier(self, @"图标底色透明度", TWKeyArcIconBgAlpha, @100, nil, PSSliderCell,
                                        @"circle.lefthalf.filled", nil,
                                        @{@"height": @74, @"twMin": @0, @"twMax": @100, @"twStep": @5, @"twUnit": @" %", @"twColor": @3})];
        [specs addObject:TWRowSpecifier(self, @"菜单图标数", TWKeyArcItemCount, @6, nil, PSSliderCell,
                                        @"square.grid.2x2", nil,
                                        @{@"height": @74, @"twMin": @2, @"twMax": @8, @"twStep": @1, @"twUnit": @" 个", @"twColor": @4})];
        [specs addObject:TWRowSpecifier(self, @"第一环图标数", TWKeyArcFirstRowCount, @5, nil, PSSliderCell,
                                        @"circle.grid.2x2", nil,
                                        @{@"height": @74, @"twMin": @4, @"twMax": @7, @"twStep": @1, @"twUnit": @" 个", @"twColor": @5})];
        [specs addObject:TWRowSpecifier(self, @"环间距", TWKeyArcRingGap, @0, nil, PSSliderCell,
                                        @"arrow.left.and.right", nil,
                                        @{@"height": @74, @"twMin": @0, @"twMax": @40, @"twStep": @1, @"twUnit": @" pt", @"twColor": @0})];

        // ---- 动画 ----
        [specs addObject:TWGroupSpecifier(@"动画", nil)];
        [specs addObject:TWRowSpecifier(self, @"弹性动画", TWKeyArcSpringEnabled, @NO, nil, PSSwitchCell,
                                        @"waveform.path", nil, @{@"height": @58, @"twColor": @1})];
        [specs addObject:TWRowSpecifier(self, @"弹性阻尼", TWKeyArcSpringDamping, @0.68, nil, PSSliderCell,
                                        @"dial.min", nil,
                                        @{@"height": @74, @"twMin": @0.5, @"twMax": @1.0, @"twStep": @0.01, @"twUnit": @"", @"twColor": @2})];
        [specs addObject:TWRowSpecifier(self, @"选中高亮", TWKeyArcSelectedIcon, @YES, nil, PSSwitchCell,
                                        @"circle.dashed.inset.filled", nil, @{@"height": @58, @"twColor": @3})];
        [specs addObject:TWRowSpecifier(self, @"音效", TWKeyArcSound, @YES, nil, PSSwitchCell,
                                        @"speaker.wave.2.fill", nil, @{@"height": @58, @"twColor": @4})];
        [specs addObject:TWRowSpecifier(self, @"震动反馈", TWKeyArcHaptic, @YES, nil, PSSwitchCell,
                                        @"iphone.radiowaves.left.and.right", nil, @{@"height": @58, @"twColor": @2})];

        // ---- 背景 ----
        [specs addObject:TWGroupSpecifier(@"背景", nil)];
        [specs addObject:TWRowSpecifier(self, @"菜单背景", TWKeyArcBgEnabled, @NO, nil, PSSwitchCell,
                                        @"square.fill", nil, @{@"height": @58, @"twColor": @0})];
        [specs addObject:TWRowSpecifier(self, @"背景透明度", TWKeyArcBgAlpha, @0.3, nil, PSSliderCell,
                                        @"circle.lefthalf.filled", nil,
                                        @{@"height": @74, @"twMin": @0.1, @"twMax": @1.0, @"twStep": @0.05, @"twUnit": @"", @"twColor": @1})];

        // ---- 调试 ----
        [specs addObject:TWGroupSpecifier(@"调试", nil)];
        [specs addObject:TWRowSpecifier(self, @"调试模式", TWKeyArcDebug, @NO, nil, PSSwitchCell,
                                        @"ant", nil, @{@"height": @58, @"twColor": @5})];
        [specs addObject:TWRowSpecifier(self, @"截图时隐藏", TWKeyArcHideCapture, @NO, nil, PSSwitchCell,
                                        @"camera.metering.none", nil, @{@"height": @58, @"twColor": @3})];

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
            @"边缘按住向屏内拖动唤出弧形菜单；松手按「打开方式」开窗，长按图标 0.45 秒可强制全屏。")];
        [specs addObject:TWRowSpecifier(self, @"长按图标", TWKeyArcLongPressMode, @0, nil, PSSegmentCell,
                                        @"hand.tap.fill", nil,
                                        @{@"height": @58, @"twColor": @1, @"twTitles": @[@"全屏", @"无"]})];

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