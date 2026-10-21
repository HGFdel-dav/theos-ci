// TWPXSubpageController.m — ParallelX 透传子页（0.7.0）。
//
// 页面内容逐行照 ParallelX 原版子页 plist 抄：
//   Window.plist   → 竖屏分屏固定居中 / 显示分屏应用图标与名称
//   Keyboard.plist  → 竖屏/横屏外置键盘 / 内置键盘放大倍数 / 横屏外置键盘左右位置 /
//                     双击外部关闭分屏 / 键盘关闭遮罩深度
//   External.plist → 通知横幅跳转分屏 / URL 跳转分屏
//   System.plist   → 锁屏时清理分屏和小窗 / 截图录屏中隐藏手柄和面板 /
//                     允许分屏应用调用相机
//
// footer 注明「由 ParallelX 读取生效」；ParallelX plist 不存在时给出引导提示。
// 值链：所有行直接读写 com.moxuan.parallelx plist（TWPXPrefs），写入后立刻
// postRefresh（com.moxuan.parallelx.capture-updated Darwin 通知）热刷新。
#import "TWPXSubpageController.h"
#import "TWSpecifiers.h"
#import "TWStyle.h"
#import "TWPXPrefs.h"
#import "TWPath.h"
#import <CoreFoundation/CoreFoundation.h>

static NSString *const kPXPassFooter = @"改完立即生效，不需要重启。";

@interface TWPXSubpageController ()
@property (nonatomic, strong) TWPXPrefs *px;
@end

@implementation TWPXSubpageController

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell
forRowAtIndexPath:(NSIndexPath *)indexPath {
    @try {
        PSSpecifier *sp = [self specifierAtIndexPath:indexPath];
        TWStyleSliderCellIfNeeded(cell, sp);
    } @catch (__unused NSException *e) {}
}

// PSListController's inherited initForContentSize: reaches this initializer.
// It must not dispatch back to initForContentSize:.
- (instancetype)init {
    if ((self = [super init])) {
        _px = [[TWPXPrefs alloc] init];
        [self twSyncTitle];
    }
    return self;
}

// 真实键为 launcherSide；launcherSideMode 是 Swift 成员，不是偏好键。
// 原设置 0x37588/0x3759c 和运行时 0x23150/0x23254：0 左、1 右、2 两侧，默认 1。
// 只兼容误写的别名；已有真实键永远优先，写成功才清理别名。
- (void)twMigrateLauncherSideAlias {
    id real = [_px objectForKey:@"launcherSide" defaultValue:nil];
    id alias = [_px objectForKey:@"launcherSideMode" defaultValue:nil];
    if (!real && [alias isKindOfClass:NSNumber.class]) {
        NSInteger mode = MAX(0, MIN(2, [alias integerValue]));
        if ([_px setObject:@(mode) forKey:@"launcherSide"])
            [_px setObject:nil forKey:@"launcherSideMode"];
    }
}

// Preferences 可能在设置 pageType 前已请求过 specifiers。
- (void)setPageType:(TWPXPageType)pageType {
    _pageType = pageType;
    _specifiers = nil;
    [self twSyncTitle];
    if (self.isViewLoaded) [self reloadSpecifiers];
}

- (void)twSyncTitle {
    self.title = [self pageTitle];
}


- (NSInteger)tableView:(UITableView *)tableView indentationLevelForRowAtIndexPath:(NSIndexPath *)indexPath {
    // Icons are drawn in their own column; a system indent only added a blank gutter.
    return 0;
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
    
        @try {
            PSSpecifier *twSliderSpec = [self specifierAtIndexPath:indexPath];
            if ([twSliderSpec cellType] == PSSliderCell) return 58.0;
        } @catch (__unused NSException *e) {}

        return [super tableView:tableView heightForRowAtIndexPath:indexPath];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // 子页是 new 出来的 PSListController：table 没建好时整页是黑的。
    // 这里补背景，至少不会出现"点进去全黑、什么都没有"。
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
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

#pragma mark - 页面配置

- (NSString *)pageTitle {
    switch (_pageType) {
        case TWPXPageWindow:   return @"分屏窗口与角落小窗";
        case TWPXPageKeyboard: return @"键盘";
        case TWPXPageExternal: return @"通知与 URL 跳转";
        case TWPXPageSystem:   return @"锁屏、截图与录屏";
        case TWPXPageLauncher: return @"半圆面板与手柄";
        case TWPXPageGestures: return @"手势区域";
        case TWPXPageBackup:   return @"备份与恢复";
    }
    return @"Twin";
}

#pragma mark - specifiers

- (NSArray *)specifiers {
    if (!_px) _px = [[TWPXPrefs alloc] init]; // 防止父类初始化期间提前取行
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];

        switch (_pageType) {
            case TWPXPageWindow:   [self buildWindowPage:specs];   break;
            case TWPXPageKeyboard: [self buildKeyboardPage:specs]; break;
            case TWPXPageExternal: [self buildExternalPage:specs]; break;
            case TWPXPageSystem:   [self buildSystemPage:specs];   break;
            case TWPXPageLauncher: [self buildLauncherPage:specs]; break;
            case TWPXPageGestures: [self buildGesturesPage:specs]; break;
            case TWPXPageBackup:   [self buildBackupPage:specs];   break;
        }

        _specifiers = specs;
    }
    return _specifiers;
}

// 「分屏窗口与角落小窗」（照 Window.plist）。
- (void)buildWindowPage:(NSMutableArray *)specs {
    [specs addObject:TWGroupSpecifier(@"分屏窗口",
        @"开启竖屏居中后，主屏竖屏时初始和复位锚点固定在屏幕正中央，优先于面板呼出侧和屏幕边距设置；横屏不受影响。不限制手动拖动或键盘避让，下次打开或复位窗口时生效。")];
    [specs addObject:[self pxSlider:@"竖屏初始尺寸" key:@"portraitInitialWidthPercent" def:@85 min:@40 max:@100
                             symbol:@"rectangle.portrait" color:@0]];
    [specs addObject:[self pxSlider:@"竖屏横屏应用尺寸" key:@"portraitLandscapeInitialWidthPercent" def:@90 min:@40 max:@100
                             symbol:@"rectangle" color:@0]];
    [specs addObject:[self pxSlider:@"横屏初始尺寸" key:@"initialWidthPercent" def:@85 min:@40 max:@100
                             symbol:@"rectangle.landscape" color:@0]];
    [specs addObject:[self pxSwitch:@"竖屏分屏固定居中" key:@"portraitCenteredAnchor" def:@NO
                            symbol:@"rectangle.portrait.inset.filled" color:@1]];
    [specs addObject:[self pxSwitch:@"显示分屏应用图标与名称" key:@"showSplitAppIdentity" def:@YES
                            symbol:@"app.badge.checkmark" color:@0]];

    [specs addObject:TWGroupSpecifier(@"角落小窗", kPXPassFooter)];
    [specs addObject:[self pxSlider:@"竖屏小窗宽度" key:@"dockWidth" def:@180 min:@100 max:@300
                             symbol:@"rectangle.portrait" color:@4]];
    [specs addObject:[self pxSlider:@"横屏小窗宽度" key:@"landscapeDockWidth" def:@240 min:@140 max:@380
                             symbol:@"rectangle.landscape" color:@4]];
    [specs addObject:[self pxSlider:@"最多保留小窗数量" key:@"dockCount" def:@3 min:@1 max:@4
                             symbol:@"square.grid.2x2" color:@4]];
    [specs addObject:[self pxSwitch:@"新开分屏时当前窗口变小窗" key:@"autoParkOnNewSplit" def:@YES
                             symbol:@"rectangle.on.rectangle" color:@4]];
}

// 「键盘」（照 Keyboard.plist）。
- (void)buildKeyboardPage:(NSMutableArray *)specs {
    [specs addObject:TWGroupSpecifier(@"键盘模式",
        @"横竖屏分别设置。外置键盘显示在分屏外，不放大窗口；内置键盘保留在分屏内，输入时焦点放大。主屏竖屏时，横屏分屏固定使用内置键盘，竖屏分屏仍按竖屏开关设置。")];
    [specs addObject:[self pxSwitch:@"竖屏使用外置键盘" key:@"portraitExternalKeyboard" def:@YES
                            symbol:@"keyboard" color:@3]];
    [specs addObject:[self pxSwitch:@"横屏使用外置键盘" key:@"landscapeExternalKeyboard" def:@NO
                            symbol:@"globe" color:@3]];

    [specs addObject:TWGroupSpecifier(@"内置键盘",
        @"控制内置键盘输入时的窗口焦点放大。100% 不放大，默认 160%；竖屏主屏中的竖屏分屏放大后居中并底部对齐，横屏分屏围绕原中心放大，不再移动到底部。横屏主屏中的横屏分屏放大后固定在屏幕右下方，位置不随分屏原位置改变。实际倍数受可用安全区域限制，外置键盘不受影响。")];
    [specs addObject:[self pxSlider:@"内置键盘放大倍数" key:@"internalKeyboardZoomPercent"
                                  def:@160 min:@100 max:@200 symbol:@"arrow.up.left.and.arrow.down.right.rectangle" color:@2]];

    [specs addObject:TWGroupSpecifier(@"外置键盘", kPXPassFooter)];
    [specs addObject:[self pxSlider:@"横屏外置键盘左右位置（左→右）" key:@"externalKeyboardHorizontalPercent"
                                  def:@0 min:@0 max:@100 symbol:@"slider.horizontal" color:@5]];
    [specs addObject:[self pxSwitch:@"双击外部关闭分屏" key:@"closeOutsideWithKeyboard" def:@YES
                            symbol:@"hand.tap" color:@0]];
    [specs addObject:[self pxSlider:@"键盘关闭遮罩深度" key:@"keyboardDimOpacity"
                                  def:@0.12 min:@0 max:@0.6 symbol:@"square.slash" color:@6]];
}

// 「通知与 URL 跳转」（照 External.plist）。
- (void)buildExternalPage:(NSMutableArray *)specs {
    [specs addObject:TWGroupSpecifier(@"外部打开",
        @"点击通知横幅或其他应用中的链接时，将目标应用放入分屏；通知中心点击仍按系统原方式全屏打开。")];
    [specs addObject:[self pxSwitch:@"通知横幅跳转分屏" key:@"notificationSplitEnabled" def:@YES
                            symbol:@"bell.badge" color:@1]];
    [specs addObject:[self pxSwitch:@"URL 跳转分屏" key:@"urlSplitEnabled" def:@YES
                            symbol:@"arrow.up.forward.app" color:@2]];
}

// 「锁屏、截图与录屏」（照 System.plist）。
- (void)buildSystemPage:(NSMutableArray *)specs {
    [specs addObject:TWGroupSpecifier(@"锁屏",
        @"开启后，锁屏时关闭主分屏和所有角落小窗；关闭时维持原来的解锁恢复行为。")];
    [specs addObject:[self pxSwitch:@"锁屏时清理分屏和小窗" key:@"clearOnLock" def:@NO
                            symbol:@"lock" color:@6]];

    [specs addObject:TWGroupSpecifier(@"截图与录屏",
        @"截图、录屏时排除手柄和面板，设备上仍可正常操作；不隐藏分屏及键盘。")];
    [specs addObject:[self pxSwitch:@"截图/录屏中隐藏手柄和面板" key:@"hideForScreenshot" def:@NO
                            symbol:@"camera.aperture" color:@5]];

    [specs addObject:TWGroupSpecifier(@"分屏相机",
        @"允许托管中的应用调用相机，不改变系统相机授权。默认关闭；首次安装组件后需重启设备使媒体服务加载，开启后重新进入应用的相机页面。")];
    [specs addObject:[self pxSwitch:@"允许分屏应用调用相机" key:@"hostedCameraEnabled" def:@NO
                            symbol:@"camera" color:@4]];
}

#pragma mark - 行构造（透传版：twGet/twSet 指向本控制器的 px 值链）

- (PSSpecifier *)pxSwitch:(NSString *)title
                     key:(NSString *)key
                     def:(NSNumber *)def
                  symbol:(NSString *)symbol
                   color:(NSNumber *)color {
    return TWRowSpecifier(self, title, key, def, nil, PSSwitchCell, symbol, nil,
                           @{@"height": @46, @"twColor": color,
                             @"twGet": @"pxReadValue:", @"twSet": @"pxWriteValue:specifier:"});
}

- (PSSpecifier *)pxSlider:(NSString *)title
                     key:(NSString *)key
                     def:(NSNumber *)def
                     min:(NSNumber *)min
                     max:(NSNumber *)max
                  symbol:(NSString *)symbol
                  color:(NSNumber *)color {
    return TWRowSpecifier(self, title, key, def, nil, PSSliderCell, symbol, nil,
                           @{@"height": @58, @"twColor": color,
                             @"twMin": min, @"twMax": max,
                             @"twGet": @"pxReadValue:", @"twSet": @"pxWriteValue:specifier:"});
}

// 「半圆面板与手柄」——原生重画，不再依赖 ParallelX 的 Swift 控制器。
- (void)buildLauncherPage:(NSMutableArray *)specs {
    [self twMigrateLauncherSideAlias];
    [specs addObject:TWGroupSpecifier(@"面板", @"左侧或右侧固定手柄位置；两侧模式允许从左右边缘呼出，手柄跟随最近呼出侧。")];
    [specs addObject:[self pxSegment:@"面板启用侧" key:@"launcherSide"
                                 def:@1 titles:@[@"左侧", @"右侧", @"两侧"]
                              symbol:@"circle.lefthalf.filled" color:@4]];
    [specs addObject:[self pxSlider:@"面板距边缘" key:@"launcherEdgeInset" def:@12 min:@0 max:@60
                             symbol:@"arrow.left.and.right" color:@0]];
    [specs addObject:[self pxSlider:@"图标大小" key:@"launcherIconSize" def:@48 min:@28 max:@80
                             symbol:@"app.badge" color:@2]];
    [specs addObject:[self pxSlider:@"环间距" key:@"launcherRingGap" def:@10 min:@0 max:@40
                             symbol:@"circle.dashed" color:@5]];

    [specs addObject:TWGroupSpecifier(@"每环应用数", @"设为 0 关闭该环，不删除已选应用与排序。")];
    [specs addObject:[self pxSlider:@"第一环" key:@"launcherRing1" def:@5 min:@0 max:@9
                             symbol:@"1.circle" color:@1]];
    [specs addObject:[self pxSlider:@"第二环" key:@"launcherRing2" def:@6 min:@0 max:@12
                             symbol:@"2.circle" color:@1]];
    [specs addObject:[self pxSlider:@"第三环" key:@"launcherRing3" def:@6 min:@0 max:@12
                             symbol:@"3.circle" color:@1]];
    [specs addObject:[self pxSlider:@"第四环" key:@"launcherRing4" def:@0 min:@0 max:@12
                             symbol:@"4.circle" color:@1]];

    [specs addObject:TWGroupSpecifier(@"手柄", kPXPassFooter)];
    [specs addObject:[self pxSlider:@"手柄宽度" key:@"handleWidth" def:@14 min:@6 max:@30
                             symbol:@"arrow.left.and.right" color:@3]];
    [specs addObject:[self pxSlider:@"手柄高度" key:@"handleHeight" def:@90 min:@40 max:@180
                             symbol:@"arrow.up.and.down" color:@3]];
    [specs addObject:[self pxSlider:@"手柄滑动距离" key:@"launcherDragDistance" def:@40 min:@10 max:@120
                             symbol:@"hand.draw" color:@3]];
    [specs addObject:[self pxSlider:@"长按全屏时长" key:@"launcherHoldMilliseconds" def:@800 min:@200 max:@2000
                             symbol:@"clock" color:@6]];
    [specs addObject:[self pxSlider:@"闲置渐隐时间" key:@"handleIdleSeconds" def:@3 min:@0 max:@15
                             symbol:@"eye.slash" color:@6]];
    [specs addObject:[self pxSlider:@"渐隐后不透明度" key:@"handleIdleOpacityPercent" def:@35 min:@0 max:@100
                             symbol:@"circle.lefthalf.filled" color:@6]];

    [specs addObject:TWGroupSpecifier(@"小窗与动画", kPXPassFooter)];
    [specs addObject:[self pxSwitch:@"底部左右滑小窗、上滑退出分屏" key:@"dockSwipeEnabled" def:@YES
                             symbol:@"hand.tap" color:@0]];
    [specs addObject:[self pxSlider:@"全局动画速度" key:@"animationSpeedPercent" def:@100 min:@50 max:@200
                             symbol:@"speedometer" color:@5]];
}

// 「手势区域」——原生重画。
- (void)buildGesturesPage:(NSMutableArray *)specs {
    [specs addObject:TWGroupSpecifier(@"底部触发区", @"下次打开窗口时生效。")];
    [specs addObject:[self pxSlider:@"底部区域宽度" key:@"gestureWidth" def:@160 min:@40 max:@360
                             symbol:@"arrow.left.and.right" color:@0]];
    [specs addObject:[self pxSlider:@"底部区域高度" key:@"gestureHeight" def:@24 min:@8 max:@80
                             symbol:@"arrow.up.and.down" color:@0]];
    [specs addObject:[self pxSlider:@"底部垂直偏移" key:@"gestureOffset" def:@0 min:@-60 max:@60
                             symbol:@"arrow.up.arrow.down" color:@0]];

    [specs addObject:TWGroupSpecifier(@"顶部触发区", @"顶部左、右角落点击分别停靠为左、右侧小窗。")];
    [specs addObject:[self pxSlider:@"顶部区域宽度" key:@"topGestureWidth" def:@160 min:@40 max:@360
                             symbol:@"arrow.left.and.right" color:@4]];
    [specs addObject:[self pxSlider:@"顶部区域高度" key:@"topGestureHeight" def:@24 min:@8 max:@80
                             symbol:@"arrow.up.and.down" color:@4]];
    [specs addObject:[self pxSlider:@"顶部垂直偏移" key:@"topGestureOffset" def:@0 min:@-60 max:@60
                             symbol:@"arrow.up.arrow.down" color:@4]];

    [specs addObject:TWGroupSpecifier(@"调试", kPXPassFooter)];
    [specs addObject:[self pxSwitch:@"显示手势触发区域" key:@"gestureDebug" def:@NO
                             symbol:@"viewfinder" color:@6]];
}

// 「备份与恢复」——直接读写 ParallelX 的 plist 文件。
- (void)buildBackupPage:(NSMutableArray *)specs {
    [specs addObject:TWGroupSpecifier(@"备份",
        @"导出：把当前全部分屏设置存成一个文件；导入：从同一个文件读回来。导入前建议先导出一次。")];
    PSSpecifier *exportRow = TWButtonRowSpecifier(self, @"导出配置", @"pxExport:", @"square.and.arrow.up", NO, nil);
    PSSpecifier *importRow = TWButtonRowSpecifier(self, @"导入配置", @"pxImport:", @"square.and.arrow.down", NO, nil);
    if (exportRow) [specs addObject:exportRow];
    if (importRow) [specs addObject:importRow];

    [specs addObject:TWGroupSpecifier(@"恢复", @"点「恢复默认设置」会把分屏相关的开关和数值全部还原成出厂值；点完之后逐项重新调即可，不需要重启。")];
    PSSpecifier *reset = TWButtonRowSpecifier(self, @"恢复默认设置", @"pxReset:", @"arrow.counterclockwise", YES, nil);
    if (reset) [specs addObject:reset];
}

- (PSSpecifier *)pxSegment:(NSString *)title
                       key:(NSString *)key
                       def:(NSNumber *)def
                    titles:(NSArray *)titles
                    symbol:(NSString *)symbol
                     color:(NSNumber *)color {
    return TWRowSpecifier(self, title, key, def, nil, PSSegmentCell, symbol, nil,
                          @{@"height": @58, @"twColor": color, @"twTitles": titles,
                            @"twGet": @"pxReadValue:", @"twSet": @"pxWriteValue:specifier:"});
}

- (void)pxExport:(PSSpecifier *)specifier {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [dir stringByAppendingPathComponent:@"Twin-Backup.plist"];
    NSDictionary *all = [_px allValues];
    BOOL ok = [(all ?: @{}) writeToFile:path atomically:YES];
    [self twToast:ok ? [@"已导出到 " stringByAppendingString:path] : @"导出失败"];
}

- (void)pxImport:(PSSpecifier *)specifier {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [dir stringByAppendingPathComponent:@"Twin-Backup.plist"];
    NSDictionary *all = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![all isKindOfClass:NSDictionary.class]) { [self twToast:@"没有找到备份文件"]; return; }
    for (NSString *k in all) [_px setObject:all[k] forKey:k];
    [_px synchronize];
    [self reloadSpecifiers];
    [self twToast:@"已导入"];
}

- (void)pxReset:(PSSpecifier *)specifier {
    [_px removeAll];
    [self reloadSpecifiers];
    [self twToast:@"已恢复默认"];
}

- (void)twToast:(NSString *)text {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:text
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}

#pragma mark - 值链（读写 ParallelX 真实 plist）

- (id)pxReadValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (![key isKindOfClass:NSString.class] || !key.length) return @NO;
    id def = [specifier propertyForKey:@"default"] ?: @NO;
    id stored = [_px objectForKey:key defaultValue:def];
    // PSSliderCell 的值链要 NSNumber：滑杆原版用 float/integer 混存，这里按需归一。
    if ([specifier cellType] == PSSliderCell) {
        if (![stored isKindOfClass:NSNumber.class]) stored = def;
        return stored;
    }
    return stored ?: def;
}

// 系统设置行走的是标准值链；原来只挂了 twSet/twGet 属性，
// 而本机 Preferences 不认自定义 cellClass → 改了半天其实什么都没写。
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [self pxWriteValue:value specifier:specifier];
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    return [self pxReadValue:specifier];
}

- (void)pxWriteValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (![key isKindOfClass:NSString.class] || !key.length) return;
    // 滑杆按需取整（百分比值都是整数步进），遮罩深度保持浮点。
    if ([specifier cellType] == PSSliderCell && [value respondsToSelector:@selector(doubleValue)]) {
        double v = [value doubleValue];
        BOOL isFloat = [[specifier propertyForKey:@"twMin"] isKindOfClass:NSNumber.class] &&
                       [[specifier propertyForKey:@"twMax"] isKindOfClass:NSNumber.class] &&
                       ([[specifier propertyForKey:@"twMin"] doubleValue] != floor([[specifier propertyForKey:@"twMin"] doubleValue]) ||
                        [[specifier propertyForKey:@"twMax"] doubleValue] != floor([[specifier propertyForKey:@"twMax"] doubleValue]));
        value = isFloat ? @(v) : @((NSInteger)llround(v));
    }
    BOOL ok = [_px setObject:value forKey:key];
    if (ok) {
        NSString *notification = nil;
        if ([key hasPrefix:@"launcher"] || [key hasPrefix:@"handle"])
            notification = @"com.moxuan.parallelx.handle-updated";
        else if ([key hasPrefix:@"dock"])
            notification = @"com.moxuan.parallelx.dock-updated";
        if (notification) CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)notification, NULL, NULL, YES);
    }
    TWDiagLog(@"PX pass-through write key=%@ value=%@ sync=%d", key, value, ok);
}

#pragma mark - 子页分发

- (id)controllerForSpecifier:(PSSpecifier *)specifier {
    id controller = TWControllerForSpecifier(self, specifier);
    if (controller) return controller;
    return TWSuperControllerForSpecifier(self, specifier);
}

@end