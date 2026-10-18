// TWRootListController.m — Twin settings panel.
//
// Own look, own data path:
//   * gradient hero header with the Twin mark and a live enable badge
//   * self-drawn cells (TWSwitchCell / TWSliderCell / TWSegmentCell /
//     TWActionCell / TWStatusCell) — no stock specifier rows
//   * every value is read/written through TWPrefs, i.e. the jbroot-private
//     com.niubiprass.twin.plist, never the real /var/mobile/Library/Preferences
#import "TWRootListController.h"
#import "TWCells.h"
#import "TWStyle.h"
#import "TWPath.h"
#import "TWPrefs.h"
#import "TWCraneAppsController.h"
#import "TWRememberAppsController.h"

static NSString *const kTWVersion = @"0.3.0";

static BOOL TWJBRootFileExists(NSString *relative) {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *root in TWJBRootCandidates()) {
        if ([fm fileExistsAtPath:[root stringByAppendingPathComponent:relative]]) return YES;
    }
    return NO;
}

static BOOL TWParallelXInstalled(void) {
    return TWJBRootFileExists(@"Library/MobileSubstrate/DynamicLibraries/ParallelX.dylib");
}

static BOOL TWCraneInstalled(void) {
    return TWJBRootFileExists(@"Library/MobileSubstrate/DynamicLibraries/Crane.dylib") ||
           TWJBRootFileExists(@"usr/lib/libcrane.dylib") ||
           TWJBRootFileExists(@"Library/PreferenceBundles/CranePrefs.bundle");
}

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

- (PSSpecifier *)twGroup:(NSString *)name footer:(NSString *)footer {
    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:name];
    if (footer.length) [group setProperty:footer forKey:@"footerText"];
    return group;
}

- (PSSpecifier *)twRow:(NSString *)title
                   key:(NSString *)key
               default:(id)fallback
              cellName:(NSString *)cellName
              cellType:(PSCellType)cellType
                symbol:(NSString *)symbol
                detail:(NSString *)detail
                  link:(Class)linkClass
                extras:(NSDictionary *)extras {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:title
                                                      target:self
                                                         set:NULL
                                                         get:NULL
                                                      detail:linkClass
                                                        cell:cellType
                                                        edit:nil];
    if (key.length) [spec setProperty:key forKey:@"key"];
    if (fallback) [spec setProperty:fallback forKey:@"default"];
    if (cellName.length) [spec setProperty:cellName forKey:@"cellClass"];
    if (symbol.length) [spec setProperty:symbol forKey:@"twSymbol"];
    if (detail.length) [spec setProperty:detail forKey:@"twDetail"];
    if (linkClass) [spec setProperty:NSStringFromClass(linkClass) forKey:@"detail"];
    for (NSString *extraKey in extras) [spec setProperty:extras[extraKey] forKey:extraKey];
    return spec;
}

#pragma mark - specifiers

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];

        BOOL parallelx = TWParallelXInstalled();
        BOOL crane = TWCraneInstalled();
        NSInteger craneCount = (NSInteger)[TWPrefs shared].craneApps.count;
        NSDictionary *frames = [[TWPrefs shared] objectForKey:TWKeyRememberFrames];
        NSInteger frameCount = [frames isKindOfClass:NSDictionary.class] ? (NSInteger)frames.count : 0;

        // ---- 总览 ----
        [specs addObject:[self twGroup:@"总览"
                                footer:[NSString stringWithFormat:@"Twin %@ · 独立增强层：不替换、不冲突 ParallelX；关闭总开关即完全恢复系统原状。", kTWVersion]]];
        [specs addObject:[self twRow:@"启用 Twin" key:TWKeyEnabled default:@NO cellName:@"TWSwitchCell"
                            cellType:PSSwitchCell symbol:@"power" detail:nil link:nil
                              extras:@{@"height": @62}]];
        [specs addObject:[self twRow:@"分屏引擎" key:nil default:nil cellName:@"TWStatusCell"
                            cellType:PSStaticTextCell symbol:@"rectangle.split.2x1"
                              detail:(parallelx ? @"ParallelX 已安装" : @"未安装 · 普通启动")
                                link:nil extras:@{@"height": @52, @"twPositive": @(parallelx)}]];
        [specs addObject:[self twRow:@"分身引擎" key:nil default:nil cellName:@"TWStatusCell"
                            cellType:PSStaticTextCell symbol:@"square.on.square"
                              detail:(crane ? @"Crane 已安装" : @"未安装 · 分身不可用")
                                link:nil extras:@{@"height": @52, @"twPositive": @(crane)}]];

        // ---- Arc ----
        [specs addObject:[self twGroup:@"Arc 弧形唤醒"
                                footer:@"在屏幕边缘按住并向屏幕内侧拖动即可唤出弧形应用菜单，松手选中图标打开应用；关闭后完全不接管手势。"]];
        [specs addObject:[self twRow:@"Arc 弧形唤醒" key:TWKeyArcEnabled default:@YES cellName:@"TWSwitchCell"
                            cellType:PSSwitchCell symbol:@"hand.draw.fill" detail:nil link:nil
                              extras:@{@"height": @62}]];
        [specs addObject:[self twRow:@"触发边缘" key:TWKeyArcSide default:@0 cellName:@"TWSegmentCell"
                            cellType:PSSegmentCell symbol:@"arrow.left.arrow.right" detail:nil link:nil
                              extras:@{@"height": @58, @"twTitles": @[@"左边缘", @"右边缘"]}]];
        [specs addObject:[self twRow:@"触发区宽度" key:TWKeyArcTriggerWidth default:@24 cellName:@"TWSliderCell"
                            cellType:PSSliderCell symbol:@"arrow.left.and.right.square" detail:nil link:nil
                              extras:@{@"height": @78, @"twMin": @12, @"twMax": @60, @"twStep": @1, @"twUnit": @" pt"}]];
        [specs addObject:[self twRow:@"菜单图标数" key:TWKeyArcItemCount default:@6 cellName:@"TWSliderCell"
                            cellType:PSSliderCell symbol:@"square.grid.2x2" detail:nil link:nil
                              extras:@{@"height": @78, @"twMin": @2, @"twMax": @8, @"twStep": @1, @"twUnit": @" 个"}]];
        [specs addObject:[self twRow:@"弧形半径" key:TWKeyArcRadius default:@140 cellName:@"TWSliderCell"
                            cellType:PSSliderCell symbol:@"circle.dashed" detail:nil link:nil
                              extras:@{@"height": @78, @"twMin": @90, @"twMax": @220, @"twStep": @5, @"twUnit": @" pt"}]];
        [specs addObject:[self twRow:@"操作音效" key:TWKeyArcSoundEnabled default:@YES cellName:@"TWSwitchCell"
                            cellType:PSSwitchCell symbol:@"speaker.wave.2.fill" detail:nil link:nil
                              extras:@{@"height": @62}]];

        // ---- Crane ----
        [specs addObject:[self twGroup:@"Crane 分身"
                                footer:@"为指定应用固定 Crane 容器：命中映射时先完成容器切换（含生物认证）再打开，认证取消、切换失败或容器核验不符都不会打开应用。"]];
        [specs addObject:[self twRow:@"Crane 分身" key:TWKeyCraneEnabled default:@NO cellName:@"TWSwitchCell"
                            cellType:PSSwitchCell symbol:@"square.on.square.dashed" detail:nil link:nil
                              extras:@{@"height": @62}]];
        [specs addObject:[self twRow:@"分身应用" key:nil default:nil cellName:@"TWActionCell"
                            cellType:PSLinkCell symbol:@"app.badge"
                              detail:[NSString stringWithFormat:@"%ld 个", (long)craneCount]
                                link:NSClassFromString(@"TWCraneAppsController")
                              extras:@{@"height": @56}]];

        // ---- 窗口记忆 ----
        [specs addObject:[self twGroup:@"窗口记忆"
                                footer:@"记住每个应用分屏窗口的位置与大小，下次打开自动恢复；该功能依赖 ParallelX 提供的分屏窗口。"]];
        [specs addObject:[self twRow:@"记忆窗口尺寸" key:TWKeyRememberSize default:@YES cellName:@"TWSwitchCell"
                            cellType:PSSwitchCell symbol:@"arrow.up.left.and.arrow.down.right" detail:nil link:nil
                              extras:@{@"height": @62}]];
        [specs addObject:[self twRow:@"已记忆的窗口" key:nil default:nil cellName:@"TWActionCell"
                            cellType:PSLinkCell symbol:@"clock.arrow.circlepath"
                              detail:[NSString stringWithFormat:@"%ld 个", (long)frameCount]
                                link:NSClassFromString(@"TWRememberAppsController")
                              extras:@{@"height": @56}]];
        [specs addObject:[self twRow:@"清除全部记忆" key:nil default:nil cellName:@"TWActionCell"
                            cellType:PSButtonCell symbol:@"trash" detail:nil link:nil
                              extras:@{@"height": @56, @"twDestructive": @YES, @"twAction": @"clearFrames"}]];

        // ---- 关于 ----
        [specs addObject:[self twGroup:@"关于"
                                footer:@"设置仅写入越狱环境的私有目录，不会出现在真实 /var/mobile/Library/Preferences，避免被检测与误清理。"]];
        [specs addObject:[self twRow:@"版本" key:nil default:nil cellName:@"TWStatusCell"
                            cellType:PSStaticTextCell symbol:@"tag" detail:kTWVersion link:nil
                              extras:@{@"height": @50, @"twPositive": @YES}]];
        [specs addObject:[self twRow:@"作者" key:nil default:nil cellName:@"TWStatusCell"
                            cellType:PSStaticTextCell symbol:@"person.crop.circle" detail:@"Niubiprass" link:nil
                              extras:@{@"height": @50, @"twPositive": @YES}]];

        _specifiers = specs;
    }
    return _specifiers;
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

- (void)twConfirmClearFrames {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清除全部窗口记忆"
                                                                   message:@"所有已记录的应用分屏窗口位置与大小都会被移除，下次打开应用将使用默认窗口。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak TWRootListController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"清除" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [[TWPrefs shared] clearRememberedFrames];
        [weakSelf reloadSpecifiers];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *spec = nil;
    if ([self respondsToSelector:@selector(specifierAtIndexPath:)]) spec = [self specifierAtIndexPath:indexPath];
    NSString *action = [spec propertyForKey:@"twAction"];
    if ([action isKindOfClass:NSString.class] && [action isEqualToString:@"clearFrames"]) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [self twConfirmClearFrames];
        return;
    }
    [super tableView:tableView didSelectRowAtIndexPath:indexPath];
}

@end