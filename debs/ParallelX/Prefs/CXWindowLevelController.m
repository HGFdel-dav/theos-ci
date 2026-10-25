// CXWindowLevelController.m - ParallelX 窗口层级设置面板
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "CXPrefs.h"
#import "CXLog.h"

@interface CXWindowLevelController : PSListController
@end

@implementation CXWindowLevelController

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        
        // 说明
        PSSpecifier *group1 = [PSSpecifier preferenceSpecifierNamed:@"窗口层级设置"
                                                              target:self set:NULL get:NULL
                                                              detail:Nil cell:PSGroupCell edit:Nil];
        [group1 setProperty:@"控制 ParallelX 菜单窗口的显示层级。高层级可以盖过 Dock、控制中心。" forKey:@"footerText"];
        [specs addObject:group1];
        
        // 层级模式
        PSSpecifier *mode = [PSSpecifier preferenceSpecifierNamed:@"层级模式"
                                                           target:self
                                                              set:@selector(setPreferenceValue:specifier:)
                                                              get:@selector(readPreferenceValue:)
                                                           detail:NSClassFromString(@"PSListItemsController")
                                                             cell:PSLinkListCell edit:Nil];
        [mode setProperty:@"CXWindowLevelMode" forKey:@"key"];
        [mode setProperty:@"com.niubiprass.clonex" forKey:@"defaults"];
        [mode setProperty:@0 forKey:@"default"];
        [mode setProperty:@[@0, @1, @2] forKey:@"validValues"];
        [mode setProperty:@[@"普通 (0)", @"高层级 (2046)", @"自定义"] forKey:@"validTitles"];
        [mode setProperty:@"com.niubiprass.clonex/changed" forKey:@"PostNotification"];
        [specs addObject:mode];
        
        // 自定义层级组
        PSSpecifier *group2 = [PSSpecifier preferenceSpecifierNamed:@"自定义层级"
                                                              target:self set:NULL get:NULL
                                                              detail:Nil cell:PSGroupCell edit:Nil];
        [group2 setProperty:@"仅“自定义”模式生效。常见层级：0=普通窗口 1040=Dock 1060=控制中心 2046=至高无上"
                     forKey:@"footerText"];
        [specs addObject:group2];
        
        // 自定义滑块
        PSSpecifier *slider = [PSSpecifier preferenceSpecifierNamed:@""
                                                             target:self
                                                                set:@selector(setPreferenceValue:specifier:)
                                                                get:@selector(readPreferenceValue:)
                                                             detail:Nil cell:PSSliderCell edit:Nil];
        [slider setProperty:@"CXCustomWindowLevel" forKey:@"key"];
        [slider setProperty:@"com.niubiprass.clonex" forKey:@"defaults"];
        [slider setProperty:@46.0 forKey:@"default"];
        [slider setProperty:@0.0 forKey:@"min"];
        [slider setProperty:@2200.0 forKey:@"max"];
        [slider setProperty:@YES forKey:@"showValue"];
        [slider setProperty:@"com.niubiprass.clonex/changed" forKey:@"PostNotification"];
        [specs addObject:slider];
        
        // 测试组
        PSSpecifier *group3 = [PSSpecifier preferenceSpecifierNamed:@"测试"
                                                              target:self set:NULL get:NULL
                                                              detail:Nil cell:PSGroupCell edit:Nil];
        [group3 setProperty:@"修改后触发 PX 菜单并打开控制中心测试效果。" forKey:@"footerText"];
        [specs addObject:group3];
        
        
        _specifiers = [specs copy];
    }
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    NSString *defaults = [specifier propertyForKey:@"defaults"];
    id defaultValue = [specifier propertyForKey:@"default"];
    return [CXPrefs.shared objectForKey:key] ?: defaultValue;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    [CXPrefs.shared setObject:value forKey:key];
    
    // 发送通知
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.niubiprass.clonex/changed"),
                                         NULL, NULL, YES);
}

@end
