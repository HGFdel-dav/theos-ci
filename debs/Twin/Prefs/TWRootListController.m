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

static NSString *const kTWVersion = @"0.6.0";

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

#pragma mark - 观测轨（0.4.3）：整页行构建轨迹 + 异常原文落盘

static NSString *TWDiagSpecSummary(PSSpecifier *sp) {
    if (!sp) return @"(nil specifier)";
    return [NSString stringWithFormat:@"name=%@ key=%@ type=%ld class=%@ cellClassProp=%@ detail=%@ bundle=%@ validV=%ld validT=%ld height=%@",
            sp.name, [sp propertyForKey:@"key"], (long)[sp cellType], NSStringFromClass([sp class] ?: Nil) ?: @"?",
            [sp propertyForKey:@"cellClass"], [sp propertyForKey:@"detail"], [sp propertyForKey:@"bundle"],
            (long)[[sp propertyForKey:@"validValues"] count], (long)[[sp propertyForKey:@"validTitles"] count],
            [sp propertyForKey:@"height"]];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    CGFloat h = [super tableView:tableView heightForRowAtIndexPath:indexPath];
    PSSpecifier *sp = [self specifierAtIndexPath:indexPath];
    TWDiagLog(@"heightForRow sec=%ld row=%ld -> %.1f | %@", (long)indexPath.section, (long)indexPath.row, h, TWDiagSpecSummary(sp));
    return h;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *sp = [self specifierAtIndexPath:indexPath];
    TWDiagLog(@">> cellFor sec=%ld row=%ld | %@", (long)indexPath.section, (long)indexPath.row, TWDiagSpecSummary(sp));
    @try {
        UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
        NSString *cls = NSStringFromClass([cell class]);
        TWDiagLog(@"<< cellFor sec=%ld row=%ld ok cell=%@", (long)indexPath.section, (long)indexPath.row, cls);
        // 0.4.5：分段控件内部观测——控件在不在/几段/选中哪段，一举定案分段行显示之谜
        if (cls && [cls containsString:@"Segment"]) {
            UISegmentedControl *seg = nil;
            for (UIView *v in cell.subviews) {
                if ([v isKindOfClass:UISegmentedControl.class]) { seg = (UISegmentedControl *)v; break; }
            }
            TWDiagLog(@"  segment内部: control=%@ segCount=%ld selected=%ld subviews=%lu",
                      seg ? @"FOUND" : @"MISSING",
                      seg ? (long)seg.numberOfSegments : -1,
                      seg ? (long)seg.selectedSegmentIndex : -1,
                      (unsigned long)cell.subviews.count);
        }
        return cell;
    } @catch (NSException *e) {
        TWDiagDumpException(e, [NSString stringWithFormat:@"cellForRow sec=%ld row=%ld",
                                (long)indexPath.section, (long)indexPath.row]);
        TWDiagLog(@"specifier detail: %@", TWDiagSpecSummary(sp));
        TWDiagLog(@"specifier description: %@", sp);
        return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"TWBlankCell"];
    }
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];

        TWPrefs *prefs = [TWPrefs shared];
        NSInteger containerCount = TWCraneContainerCount();
        NSInteger memoryCount = TWRememberSnapshotCount();

        // ============ 0.5.0：按设计稿（合并后的面板/根页）重建 ============

        // ---------- 插件状态 ----------
        [specs addObject:TWGroupSpecifier(@"插件状态",
            [NSString stringWithFormat:@"Twin %@ · 独立增强层，不替换、不冲突 ParallelX。关闭总开关即完全恢复系统原状；设置只写越狱环境私有目录。", kTWVersion])];
        [specs addObject:TWRowSpecifier(self, @"启用 Twin", TWKeyEnabled, @NO, nil, PSSwitchCell,
                                        @"power", nil, @{@"height": @62, @"twColor": @0})];

        // ---------- Twin 增强 ----------
        [specs addObject:TWGroupSpecifier(@"Twin 增强", nil)];
        [specs addObject:TWRowSpecifier(self, @"Arc 唤醒", TWKeyArcEnabled, @YES, nil, PSSwitchCell,
                                        @"bolt.horizontal.fill", nil, @{@"height": @62, @"twColor": @1})];
        [specs addObject:TWLinkRowSpecifier(self, @"Arc 面板与手势", @"hand.point.up.left.fill", @"TWArcPanelController",
                                            @"触发边缘、半径、图标与反馈", @{@"height": @62, @"twColor": @0})];
        [specs addObject:TWRowSpecifier(self, @"分身打开", TWKeyCraneEnabled, @YES, nil, PSSwitchCell,
                                        @"square.on.square", nil, @{@"height": @62, @"twColor": @3})];
        [specs addObject:TWLinkRowSpecifier(self, @"分身应用", @"square.grid.2x2", @"TWContainerListController",
                                            (containerCount ? [NSString stringWithFormat:@"%ld 个", (long)containerCount] : @"未添加"),
                                            @{@"height": @62, @"twColor": @4})];
        [specs addObject:TWRowSpecifier(self, @"记忆功能", TWKeyRememberSize, @YES, nil, PSSwitchCell,
                                        @"clock.arrow.circlepath", nil, @{@"height": @62, @"twColor": @2})];
        [specs addObject:TWLinkRowSpecifier(self, @"记忆的窗口", @"macwindow", @"TWRememberListController",
                                            (memoryCount ? [NSString stringWithFormat:@"%ld 个", (long)memoryCount] : @"暂无"),
                                            @{@"height": @62, @"twColor": @5})];

        // ---------- 应用与面板 ----------
        [specs addObject:TWGroupSpecifier(@"应用与面板", nil)];
        [specs addObject:TWLinkRowSpecifier(self, @"应用、快捷操作与排序", @"square.grid.2x2.fill", @"TWStubController",
                                            @"开发中", @{@"height": @62, @"twColor": @0})];
        [specs addObject:TWLinkRowSpecifier(self, @"半圆面板与手柄", @"circle.lefthalf.filled", @"TWStubController",
                                            @"开发中", @{@"height": @62, @"twColor": @1})];

        // ---------- 窗口与交互 ----------
        [specs addObject:TWGroupSpecifier(@"窗口与交互", nil)];
        [specs addObject:TWLinkRowSpecifier(self, @"分屏窗口与角落小窗", @"rectangle.split.3x1", @"TWStubController",
                                            @"开发中", @{@"height": @62, @"twColor": @2})];
        [specs addObject:TWLinkRowSpecifier(self, @"手势区域", @"hand.tap", @"TWStubController",
                                            @"开发中", @{@"height": @62, @"twColor": @0})];
        [specs addObject:TWLinkRowSpecifier(self, @"键盘", @"keyboard", @"TWStubController",
                                            @"开发中", @{@"height": @62, @"twColor": @3})];

        // ---------- 外部打开与系统 ----------
        [specs addObject:TWGroupSpecifier(@"外部打开与系统", nil)];
        [specs addObject:TWLinkRowSpecifier(self, @"通知与 URL 跳转", @"bell.badge", @"TWStubController",
                                            @"开发中", @{@"height": @62, @"twColor": @1})];
        [specs addObject:TWLinkRowSpecifier(self, @"锁屏、截图与录屏", @"lock.shield", @"TWStubController",
                                            @"开发中", @{@"height": @62, @"twColor": @6})];

        // ---------- 配置 ----------
        [specs addObject:TWGroupSpecifier(@"配置",
            [NSString stringWithFormat:@"Twin %@ · 标注「开发中」的入口来自设计稿，页面已就位，功能落地后原地生效。", kTWVersion])];
        [specs addObject:TWLinkRowSpecifier(self, @"备份与恢复", @"arrow.down.doc", @"TWStubController",
                                            @"开发中", @{@"height": @62, @"twColor": @0})];

        _specifiers = specs;
    }
    return _specifiers;
}

#pragma mark - 子页分发（自己 new，避免跨 bundle 类查找）

- (id)controllerForSpecifier:(PSSpecifier *)specifier {
    id controller = TWControllerForSpecifier(self, specifier);
    if (controller) return controller;
    return TWSuperControllerForSpecifier(self, specifier);
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