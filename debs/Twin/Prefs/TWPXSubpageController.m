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

static NSString *const kPXPassFooter = @"以下开关由 ParallelX 读取生效，修改后立即通知 ParallelX 刷新。";

@interface TWPXSubpageController ()
@property (nonatomic, strong) TWPXPrefs *px;
@end

@implementation TWPXSubpageController

- (instancetype)init {
    if ((self = [super init])) {
        _px = [[TWPXPrefs alloc] init];
        [self twSyncTitle];
    }
    return self;
}

// 页面类型设置后同步标题（controllerForSpecifier: 里 new 完才 setPageType:）。
- (void)setPageType:(TWPXPageType)pageType {
    _pageType = pageType;
    [self twSyncTitle];
}

- (void)twSyncTitle {
    self.title = [self pageTitle];
}

- (void)viewDidLoad {
    [super viewDidLoad];
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
    }
    return @"ParallelX";
}

#pragma mark - specifiers

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];

        // ParallelX 偏好文件定位失败 → 只给提示，不给可改的行（防写出孤儿 plist）。
        if (!_px.available) {
            [specs addObject:TWGroupSpecifier(@"未检测到 ParallelX 偏好",
                @"没有找到 com.moxuan.parallelx.plist。请先打开一次 ParallelX 的设置面板让它生成偏好文件，然后回到这里下拉或重新进入即可生效。")];
            _specifiers = specs;
            return _specifiers;
        }

        switch (_pageType) {
            case TWPXPageWindow:   [self buildWindowPage:specs];   break;
            case TWPXPageKeyboard: [self buildKeyboardPage:specs]; break;
            case TWPXPageExternal: [self buildExternalPage:specs]; break;
            case TWPXPageSystem:   [self buildSystemPage:specs];   break;
        }

        _specifiers = specs;
    }
    return _specifiers;
}

// 「分屏窗口与角落小窗」（照 Window.plist）。
- (void)buildWindowPage:(NSMutableArray *)specs {
    [specs addObject:TWGroupSpecifier(@"分屏窗口",
        @"开启竖屏居中后，主屏竖屏时初始和复位锚点固定在屏幕正中央，优先于面板呼出侧和屏幕边距设置；横屏不受影响。不限制手动拖动或键盘避让，下次打开或复位窗口时生效。")];
    [specs addObject:[self pxSwitch:@"竖屏分屏固定居中" key:@"portraitCenteredAnchor" def:@NO
                            symbol:@"rectangle.portrait.inset.filled" color:@1]];
    [specs addObject:[self pxSwitch:@"显示分屏应用图标与名称" key:@"showSplitAppIdentity" def:@YES
                            symbol:@"app.badge.checkmark" color:@0]];

    [specs addObject:TWGroupSpecifier(@"角落小窗", kPXPassFooter)];
    [specs addObject:TWLinkRowSpecifier(self, @"位置、大小与排列", @"dock.rectangle", @"TWStubController",
                                            @"在 ParallelX 面板中设置", @{@"height": @62, @"twColor": @3})];
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
    [specs addObject:TWLinkRowSpecifier(self, @"URL 分屏黑名单", @"exclamationmark.shield", @"TWStubController",
                                            @"在 ParallelX 面板中维护", @{@"height": @62, @"twColor": @4})];
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
                           @{@"height": @62, @"twColor": color,
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
                           @{@"height": @78, @"twColor": color,
                             @"twMin": min, @"twMax": max,
                             @"twGet": @"pxReadValue:", @"twSet": @"pxWriteValue:specifier:"});
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
    [_px setObject:value forKey:key];
    TWDiagLog(@"PX pass-through write key=%@ value=%@ ok", key, value);
}

#pragma mark - 子页分发

- (id)controllerForSpecifier:(PSSpecifier *)specifier {
    id controller = TWControllerForSpecifier(self, specifier);
    if (controller) return controller;
    return TWSuperControllerForSpecifier(self, specifier);
}

@end