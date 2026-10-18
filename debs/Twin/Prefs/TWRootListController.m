// TWRootListController.m — Twin 设置面板（0.4.0 改版）。
//
// 五节结构（与用户确认过的设计一致）：
//   1. 插件状态   : 启用 Twin
//   2. 唤醒方式   : 一行二选一 + 「Arc 面板与手势」子页
//   3. 启动       : ARC 打开方式 / 侧边打开方式
//   4. 分身（容器＝图标）: 「分身应用（容器）」「Arc 图标顺序」两个子页
//   5. 记忆       : 记忆大小位置 / 已记忆的窗口 / 重置记忆大小及位置
//
// 硬性约定（避免面板空白或崩溃）：
//   * 真正编译的 PSListController 子类；-specifiers 沿用官方缓存模式
//     （if (!_specifiers) { _specifiers = 动态生成; } return _specifiers;），
//     所有动态 specifier 都加进继承来的 ivar `_specifiers`。
//   * 每个 specifier 的 bundle / detail / label / isController 保持一致
//     （见 Prefs/TWSpecifiers.m 的 TWRowSpecifier）。
//   * 子页一律由 controllerForSpecifier: 直接 new 我们自己的控制器。
//   * 读写一律走 TWPrefs（jbroot 私有 plist），路径统一来自 TWPath.h；
//     KeyWindow / 系统版本等只读信息用 -performSelector/反射，不做硬链接。
#import "TWRootListController.h"
#import "TWCells.h"
#import "TWStyle.h"
#import "TWSpecifiers.h"
#import "TWPath.h"
#import "TWPrefs.h"
#import "TWArcPanelController.h"
#import "TWContainerListController.h"
#import "TWRememberListController.h"

#import <sys/utsname.h>
#import <objc/message.h>

static NSString *const kTWVersion = @"0.4.0";

// 唤醒方式：0 = Arc 角落唤醒（默认），1 = ParallelX 边缘手柄。
typedef NS_ENUM(NSInteger, TWWakeModeValue) {
    TWWakeModeArc       = 0,
    TWWakeModeParallelX = 1,
};

@implementation TWRootListController {
    UIView *_hero;
    CGFloat _heroWidth;
}

- (instancetype)init {
    if ((self = [super init])) {
        self.title = @"Twin";
    }
    return self;
}

#pragma mark - helpers

// 「Arc 面板与手势」的一句摘要（触发角 / 半径 / 图标数 / 音效）。
- (NSString *)twArcSummary {
    TWPrefs *prefs = [TWPrefs shared];
    NSInteger corners = [prefs integerForKey:TWKeyArcCorners defaultValue:3];
    CGFloat cornerSize = [prefs floatForKey:TWKeyArcCornerSize defaultValue:64];
    NSInteger items = [prefs integerForKey:TWKeyArcItemCount defaultValue:6];
    CGFloat radius = [prefs floatForKey:TWKeyArcRadius defaultValue:150];
    BOOL sound = [prefs boolForKey:TWKeyArcSoundEnabled defaultValue:YES];
    NSMutableArray<NSString *> *picked = [NSMutableArray array];
    NSArray<NSString *> *names = @[@"右下", @"左下", @"左上", @"右上"];
    for (NSInteger i = 0; i < (NSInteger)names.count; i++) {
        if (corners & ((NSInteger)1 << i)) [picked addObject:names[(NSUInteger)i]];
    }
    return [NSString stringWithFormat:@"%@ · 触发 %.0fpt · %ld 图标 · 半径 %.0fpt · %@",
            picked.count ? [picked componentsJoinedByString:@"/"] : @"未选角",
            cornerSize, (long)items, radius, sound ? @"音效开" : @"音效关"];
}

// 运行环境（只读状态行）。类名/选择器全部延迟解析，缺符号也不会崩。
- (NSString *)twCraneLabel {
    if (NSClassFromString(@"CraneManager")) return @"就绪";
    return NSClassFromString(@"Crane") ? @"部分可见" : @"未安装";
}

- (NSString *)twParallelXLabel {
    return NSClassFromString(@"PXPanelEntry") ? @"就绪" : @"未安装";
}

- (NSString *)twTwinLabel {
    return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: kTWVersion;
}

- (NSString *)twSystemLabel {
    Class deviceClass = NSClassFromString(@"UIDevice");
    SEL sel = NSSelectorFromString(@"currentDevice");
    NSString *system = nil;
    if (deviceClass && [deviceClass respondsToSelector:sel]) {
        id device = ((id (*)(id, SEL))objc_msgSend)(deviceClass, sel);
        if ([device respondsToSelector:NSSelectorFromString(@"systemVersion")]) {
            id version = ((id (*)(id, SEL))objc_msgSend)(device, NSSelectorFromString(@"systemVersion"));
            if ([version isKindOfClass:NSString.class]) system = version;
        }
    }
    struct utsname info;
    NSString *machine = @"iOS";
    if (uname(&info) == 0) machine = [NSString stringWithUTF8String:info.machine] ?: @"iOS";
    return system.length ? [NSString stringWithFormat:@"iOS %@ · %@", system, machine] : machine;
}

#pragma mark - specifiers

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];

        TWPrefs *prefs = [TWPrefs shared];
        BOOL enabled = [prefs boolForKey:TWKeyEnabled defaultValue:NO];
        NSInteger wake = [prefs integerForKey:TWKeyWakeMode defaultValue:TWWakeModeArc];
        if (wake != TWWakeModeArc && wake != TWWakeModeParallelX) wake = TWWakeModeArc;
        NSInteger arcOpen = [prefs integerForKey:TWKeyArcOpenMode defaultValue:0] == 1 ? 1 : 0;
        NSInteger sideOpen = [prefs integerForKey:TWKeySideOpenMode defaultValue:0] == 1 ? 1 : 0;
        NSInteger containerCount = TWCraneContainerCount();
        NSInteger orderCount = (NSInteger)TWArcOrderList().count;
        NSInteger memoryCount = TWRememberSnapshotCount();

        // ---------- 1. 插件状态 ----------
        [specs addObject:TWGroupSpecifier(@"插件状态",
            [NSString stringWithFormat:@"Twin %@ · 独立增强层：不替换、不冲突 ParallelX；关闭总开关即完全恢复系统原状。设置只写越狱环境的私有目录，不会出现在真实 /var/mobile/Library/Preferences。", kTWVersion])];
        [specs addObject:TWRowSpecifier(self, @"启用 Twin", TWKeyEnabled, @NO, @"TWSwitchCell", PSSwitchCell,
                                        @"power", nil, @{@"height": @62, @"twColor": @5})];
        [specs addObject:TWRowSpecifier(self, @"Twin 版本", nil, nil, @"TWStatusCell", PSStaticTextCell,
                                        @"tag", nil,
                                        @{@"height": @50, @"twDetail": [self twTwinLabel], @"twPositive": @YES, @"twColor": @0})];
        [specs addObject:TWRowSpecifier(self, @"Crane 分身", nil, nil, @"TWStatusCell", PSStaticTextCell,
                                        @"square.on.square.dashed", nil,
                                        @{@"height": @50, @"twDetail": [self twCraneLabel], @"twPositive": @NO, @"twColor": @2})];
        [specs addObject:TWRowSpecifier(self, @"ParallelX 分屏", nil, nil, @"TWStatusCell", PSStaticTextCell,
                                        @"rectangle.inset.filled.and.person.filled", nil,
                                        @{@"height": @50, @"twDetail": [self twParallelXLabel], @"twPositive": @NO, @"twColor": @1})];
        [specs addObject:TWRowSpecifier(self, @"运行环境", nil, nil, @"TWStatusCell", PSStaticTextCell,
                                        @"iphone.gen3", nil,
                                        @{@"height": @50, @"twDetail": [self twSystemLabel], @"twPositive": @NO, @"twColor": @9})];

        // ---------- 2. 唤醒方式（二选一） ----------
        [specs addObject:TWGroupSpecifier(@"唤醒方式（二选一）",
            @"选哪个就用哪个唤出菜单：选「Arc 角落唤醒」时 Twin 接管角落手势；选「ParallelX 边缘手柄」时 Twin 完全不接管手势，改用 ParallelX 自己的边缘手柄唤出。")];
        [specs addObject:TWRowSpecifier(self, @"唤醒方式", TWKeyWakeMode, @(TWWakeModeArc), @"TWSegmentCell", PSSegmentCell,
                                        @"hand.draw.fill", nil,
                                        @{@"height": @94, @"twWideSegment": @YES, @"twColor": @7,
                                          @"twTitles": @[@"Arc 角落唤醒", @"ParallelX 边缘手柄"]})];
        [specs addObject:TWLinkRowSpecifier(self, @"Arc 面板与手势", @"circle.grid.cross", @"TWArcPanelController",
                                            [self twArcSummary], @{@"height": @62, @"twColor": @1})];

        // ---------- 3. 启动 ----------
        [specs addObject:TWGroupSpecifier(@"启动",
            @"分别决定 Arc 菜单和侧边（ParallelX 手柄）两条路径打开应用时的窗口形态；选中的那条路径生效。")];
        [specs addObject:TWRowSpecifier(self, @"ARC 打开方式", TWKeyArcOpenMode, @0, @"TWSegmentCell", PSSegmentCell,
                                        @"rectangle.split.2x1", nil,
                                        @{@"height": @58, @"twColor": @0, @"twTitles": @[@"分屏启动", @"全屏启动"]})];
        [specs addObject:TWRowSpecifier(self, @"侧边打开方式", TWKeySideOpenMode, @0, @"TWSegmentCell", PSSegmentCell,
                                        @"rectangle.righthalf.inset.filled", nil,
                                        @{@"height": @58, @"twColor": @6, @"twTitles": @[@"分屏启动", @"全屏启动"]})];
        [specs addObject:TWRowSpecifier(self, @"当前 ARC 打开方式", nil, nil, @"TWStatusCell", PSStaticTextCell,
                                        @"info.circle", nil,
                                        @{@"height": @50, @"twDetail": (arcOpen ? @"全屏启动" : @"分屏启动"), @"twPositive": @NO, @"twColor": @0})];
        [specs addObject:TWRowSpecifier(self, @"当前侧边打开方式", nil, nil, @"TWStatusCell", PSStaticTextCell,
                                        @"info.circle", nil,
                                        @{@"height": @50, @"twDetail": (sideOpen ? @"全屏启动" : @"分屏启动"), @"twPositive": @NO, @"twColor": @6})];

        // ---------- 4. 分身（容器 ＝ 图标） ----------
        [specs addObject:TWGroupSpecifier(@"分身（容器 ＝ 图标）",
            @"一个应用有几个容器，菜单里就有几个图标（角标区分），点哪个就用哪个容器打开。容器 ID 来自 Crane，Twin 只记录要显示哪几个。")];
        [specs addObject:TWLinkRowSpecifier(self, @"分身应用（容器）", @"app.badge", @"TWContainerListController",
                                            (containerCount ? [NSString stringWithFormat:@"%ld 个容器", (long)containerCount] : @"未添加"),
                                            @{@"height": @62, @"twColor": @8})];
        [specs addObject:TWLinkRowSpecifier(self, @"Arc 图标顺序", @"list.number", @"TWArcOrderController",
                                            (orderCount ? [NSString stringWithFormat:@"%ld 个", (long)orderCount] : @"未设置"),
                                            @{@"height": @62, @"twColor": @3})];
        [specs addObject:TWRowSpecifier(self, @"Twin 已启用", nil, nil, @"TWStatusCell", PSStaticTextCell,
                                        @"bolt.fill", nil,
                                        @{@"height": @50, @"twDetail": (enabled ? @"是" : @"否"), @"twPositive": @YES, @"twColor": @5})];

        // ---------- 5. 记忆 ----------
        [specs addObject:TWGroupSpecifier(@"记忆",
            @"按「应用 + 容器」记形态：竖屏/横屏的窗口 frame、是否处于缩小(贴边)态、停在左还是右。下次打开同一个容器就按上次的样子出现。")];
        [specs addObject:TWRowSpecifier(self, @"记忆大小位置", TWKeyRememberSize, @NO, @"TWSwitchCell", PSSwitchCell,
                                        @"arrow.up.left.and.arrow.down.right", nil,
                                        @{@"height": @62, @"twColor": @4})];
        [specs addObject:TWLinkRowSpecifier(self, @"已记忆的窗口", @"clock.arrow.circlepath", @"TWRememberListController",
                                            (memoryCount ? [NSString stringWithFormat:@"%ld 条", (long)memoryCount] : @"暂无"),
                                            @{@"height": @62, @"twColor": @2})];
        [specs addObject:TWButtonRowSpecifier(self, @"重置记忆大小及位置", @"resetMemory", @"arrow.counterclockwise",
                                              YES, @{@"height": @56})];
        [specs addObject:TWRowSpecifier(self, @"记忆条数", nil, nil, @"TWStatusCell", PSStaticTextCell,
                                        @"number", nil,
                                        @{@"height": @50, @"twDetail": [NSString stringWithFormat:@"%ld 条", (long)memoryCount], @"twPositive": @NO, @"twColor": @4})];

        _specifiers = specs;
    }
    return _specifiers;
}

#pragma mark - 子页分发（自己 new，避免跨 bundle 类查找）

- (id)controllerForSpecifier:(PSSpecifier *)specifier {
    id controller = TWControllerForSpecifier(self, specifier);
    if (controller) return controller;
    return [super controllerForSpecifier:specifier];
}

#pragma mark - hero header

- (void)twRefreshHero {
    if (!self.isViewLoaded) return;
    CGFloat width = self.table.bounds.size.width;
    if (width <= 1.0) width = self.view.bounds.size.width;
    if (width <= 1.0) width = [UIScreen mainScreen].bounds.size.width;
    if (_hero && fabs(_heroWidth - width) < 0.5) return;
    _heroWidth = width;
    BOOL enabled = [[TWPrefs shared] boolForKey:TWKeyEnabled defaultValue:NO];
    _hero = [TWStyle heroHeaderWithTitle:@"Twin"
                               subtitle:@"分屏增强套装 · 独立运行"
                             statusText:(enabled ? @"已启用" : @"已停用")
                                enabled:enabled
                                  width:width];
    self.table.tableHeaderView = _hero;
}

#pragma mark - lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    [self twRefreshHero];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSpecifiers];
    [self twRefreshHero];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.table.bounds.size.width > 1.0 && fabs(self.table.bounds.size.width - _heroWidth) >= 0.5) {
        [self twRefreshHero];
    }
}

- (void)reloadSpecifiers {
    [super reloadSpecifiers];
    if (self.isViewLoaded) [self twRefreshHero];
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

#pragma mark - row actions

- (void)twConfirmResetMemory {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重置记忆大小及位置"
                                                                   message:@"所有应用（含各自容器）的窗口形态记忆都会被清空，下次打开应用将使用默认窗口。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak TWRootListController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"重置" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        TWRememberWipe();
        [weakSelf reloadSpecifiers];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *spec = nil;
    if ([self respondsToSelector:@selector(specifierAtIndexPath:)]) spec = [self specifierAtIndexPath:indexPath];
    NSString *action = [spec propertyForKey:@"twAction"];
    if ([action isKindOfClass:NSString.class] && action.length) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        if ([action isEqualToString:@"resetMemory"]) [self twConfirmResetMemory];
        return;
    }
    [super tableView:tableView didSelectRowAtIndexPath:indexPath];
}

@end