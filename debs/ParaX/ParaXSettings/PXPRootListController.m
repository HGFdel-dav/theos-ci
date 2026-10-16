// PXPRootListController.m
// ParaX settings root panel, real PSListController subclass with cached
// _specifiers and PXPPrefs-backed values (jbroot plist, never real-var paths).
#import "PXPRootListController.h"
#import <Preferences/PSSpecifier.h>
#import "PXPCraneAppsController.h"
#import "PXPPath.h"
#import "PXPPrefs.h"

@implementation PXPRootListController

- (instancetype)init {
    if ((self = [super init])) {
        self.title = @"ParaX";
    }
    return self;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];

        // ---- Wake-up ----
        PSSpecifier *groupWake = [PSSpecifier groupSpecifierWithName:@"唤醒方式"];
        [specs addObject:groupWake];

        PSSpecifier *enabled = [PSSpecifier preferenceSpecifierNamed:@"启用 ParaX"
                                                               target:self
                                                                  set:NULL
                                                                  get:NULL
                                                                 detail:nil
                                                                   cell:PSSwitchCell
                                                                   edit:nil];
        [enabled setProperty:PXPKeyEnabled forKey:@"key"];
        [enabled setProperty:@NO forKey:@"default"];
        [enabled setProperty:@"总开关：关闭后保持 ParallelX 原本行为，弧形手势与 Crane 均不生效。" forKey:@"footerText"];
        [specs addObject:enabled];

        PSSpecifier *arc = [PSSpecifier preferenceSpecifierNamed:@"Arc 弧形唤醒"
                                                           target:self
                                                              set:NULL
                                                              get:NULL
                                                          detail:nil
                                                             cell:PSSwitchCell
                                                             edit:nil];
        [arc setProperty:PXPKeyArcEnabled forKey:@"key"];
        [arc setProperty:@YES forKey:@"default"];
        [arc setProperty:@"开启后，在屏幕边缘（避开顶部状态栏与底部 Home 条区域）按住并向屏幕内侧拖动，即可唤出弧形应用菜单；松手选中图标打开应用。关闭则完全沿用原来的唤醒方式。" forKey:@"footerText"];
        [specs addObject:arc];

        PSSpecifier *side = [PSSpecifier preferenceSpecifierNamed:@"从右边缘唤醒"
                                                            target:self
                                                               set:NULL
                                                               get:NULL
                                                           detail:nil
                                                              cell:PSSwitchCell
                                                              edit:nil];
        [side setProperty:PXPKeyArcSide forKey:@"key"];
        [side setProperty:@NO forKey:@"default"];
        [side setProperty:@"关闭 = 从左侧边缘触发；开启 = 从右侧边缘触发。菜单图标会从该侧向屏幕内侧展开。" forKey:@"footerText"];
        [specs addObject:side];

        PSSpecifier *width = [PSSpecifier preferenceSpecifierNamed:@"触发区宽度"
                                                            target:self
                                                               set:NULL
                                                               get:NULL
                                                           detail:nil
                                                              cell:PSSliderCell
                                                              edit:nil];
        [width setProperty:PXPKeyArcTriggerWidth forKey:@"key"];
        [width setProperty:@24 forKey:@"default"];
        [width setProperty:@(8) forKey:@"min"];
        [width setProperty:@(60) forKey:@"max"];
        [width setProperty:@YES forKey:@"showValue"];
        [specs addObject:width];

        PSSpecifier *count = [PSSpecifier preferenceSpecifierNamed:@"菜单图标数量"
                                                            target:self
                                                               set:NULL
                                                               get:NULL
                                                           detail:nil
                                                              cell:PSSliderCell
                                                              edit:nil];
        [count setProperty:PXPKeyArcItemCount forKey:@"key"];
        [count setProperty:@6 forKey:@"default"];
        [count setProperty:@(2) forKey:@"min"];
        [count setProperty:@(8) forKey:@"max"];
        [count setProperty:@YES forKey:@"showValue"];
        [count setProperty:@"取最近使用应用（含已安装用户应用兜底）。" forKey:@"footerText"];
        [specs addObject:count];

        PSSpecifier *radius = [PSSpecifier preferenceSpecifierNamed:@"菜单半径"
                                                            target:self
                                                               set:NULL
                                                               get:NULL
                                                           detail:nil
                                                              cell:PSSliderCell
                                                              edit:nil];
        [radius setProperty:PXPKeyArcRadius forKey:@"key"];
        [radius setProperty:@140 forKey:@"default"];
        [radius setProperty:@(90) forKey:@"min"];
        [radius setProperty:@(240) forKey:@"max"];
        [radius setProperty:@YES forKey:@"showValue"];
        [specs addObject:radius];

        PSSpecifier *sound = [PSSpecifier preferenceSpecifierNamed:@"音效与震动"
                                                             target:self
                                                                set:NULL
                                                                get:NULL
                                                            detail:nil
                                                               cell:PSSwitchCell
                                                               edit:nil];
        [sound setProperty:PXPKeyArcSound forKey:@"key"];
        [sound setProperty:@YES forKey:@"default"];
        [specs addObject:sound];

        // ---- Crane ----
        PSSpecifier *groupCrane = [PSSpecifier groupSpecifierWithName:@"Crane 分身"];
        [specs addObject:groupCrane];

        PSSpecifier *craneEnabled = [PSSpecifier preferenceSpecifierNamed:@"Crane 分身支持"
                                                                    target:self
                                                                       set:NULL
                                                                       get:NULL
                                                                   detail:nil
                                                                      cell:PSSwitchCell
                                                                      edit:nil];
        [craneEnabled setProperty:PXPKeyCraneEnabled forKey:@"key"];
        [craneEnabled setProperty:@NO forKey:@"default"];
        [craneEnabled setProperty:@"需要已安装 Crane（libcrane.dylib / CraneManager）。开启后，ParallelX 每打开一个列出的应用，都会先切换到对应分身容器再启动；未安装 Crane 时自动禁用，不影响任何启动。" forKey:@"footerText"];
        [specs addObject:craneEnabled];

        PSSpecifier *apps = [PSSpecifier preferenceSpecifierNamed:@"分身应用列表"
                                                            target:self
                                                               set:NULL
                                                               get:NULL
                                                           detail:NSClassFromString(@"PXPCraneAppsController")
                                                              cell:PSLinkListCell
                                                              edit:nil];
        [apps setProperty:@"为每个应用填写 Crane 容器 ID（在 Crane 的设置里可查看）：ParallelX 打开该应用时会以该分身容器启动。" forKey:@"footerText"];
        [apps setProperty:@YES forKey:@"isController"];
        [specs addObject:apps];

        // ---- About ----
        PSSpecifier *groupAbout = [PSSpecifier groupSpecifierWithName:@"关于"];
        [specs addObject:groupAbout];

        PSSpecifier *version = [PSSpecifier preferenceSpecifierNamed:@"ParaX 0.1.0"
                                                               target:self
                                                                  set:NULL
                                                                  get:NULL
                                                              detail:nil
                                                                 cell:PSStaticTextCell
                                                                 edit:nil];
        [version setProperty:@"Arc 弧形唤醒 + Crane 分身，为 ParallelX 分屏打造。作者：Niubiprass。设置保存在越狱根目录私有的偏好文件，不写入系统真实偏好路径。" forKey:@"footerText"];
        [specs addObject:version];

        _specifiers = specs;
    }
    return _specifiers;
}

#pragma mark - value plumbing (jbroot-backed, not NSUserDefaults)

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    id def = [specifier propertyForKey:@"default"];
    id value = [[PXPPrefs shared] objectForKey:key];
    return value ?: (def ?: nil);
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key) return;
    [[PXPPrefs shared] setObject:value forKey:key];
    [[PXPPrefs shared] synchronize];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [[PXPPrefs shared] synchronize];
}

@end