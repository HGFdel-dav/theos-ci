#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface SCRootListController : PSListController
@end

@implementation SCRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        
        // 总开关
        PSSpecifier *enableSpec = [PSSpecifier preferenceSpecifierNamed:@"Enable ScreenCore"
                                                                 target:self
                                                                    set:@selector(setValue:forKey:)
                                                                    get:@selector(valueForKey:)
                                                                 detail:nil
                                                                   cell:PSSwitchCell
                                                                   edit:nil];
        [enableSpec setProperty:@"enabled" forKey:@"key"];
        [enableSpec setProperty:@YES forKey:@"default"];
        [enableSpec setProperty:@"com.susudear.screencoreprefs" forKey:@"defaults"];
        [specs addObject:enableSpec];
        
        // 分组：手势触发
        PSSpecifier *gestureGroup = [PSSpecifier emptyGroupSpecifier];
        [gestureGroup setProperty:@"Gesture Trigger" forKey:@"label"];
        [specs addObject:gestureGroup];
        
        // 触发角落（多选）
        PSSpecifier *cornerSpec = [PSSpecifier preferenceSpecifierNamed:@"Trigger Corners"
                                                                 target:self
                                                                    set:NULL
                                                                    get:NULL
                                                                 detail:NSClassFromString(@"SCCornerSelectionController")
                                                                   cell:PSLinkListCell
                                                                   edit:nil];
        [specs addObject:cornerSpec];
        
        // 分组：菜单布局
        PSSpecifier *layoutGroup = [PSSpecifier emptyGroupSpecifier];
        [layoutGroup setProperty:@"Menu Layout" forKey:@"label"];
        [specs addObject:layoutGroup];
        
        // 布局模式（分段）
        PSSpecifier *modeSpec = [PSSpecifier preferenceSpecifierNamed:@"Layout Mode"
                                                               target:self
                                                                  set:@selector(setValue:forKey:)
                                                                  get:@selector(valueForKey:)
                                                               detail:nil
                                                                 cell:PSSegmentCell
                                                                 edit:nil];
        [modeSpec setProperty:@"layoutMode" forKey:@"key"];
        [modeSpec setProperty:@0 forKey:@"default"];
        [modeSpec setProperty:@"com.susudear.screencoreprefs" forKey:@"defaults"];
        [modeSpec setProperty:@[@"Fan", @"Rectangle"] forKey:@"validTitles"];
        [modeSpec setProperty:@[@0, @1] forKey:@"validValues"];
        [specs addObject:modeSpec];
        
        // 图标大小滑杆
        PSSpecifier *sizeSpec = [PSSpecifier preferenceSpecifierNamed:@"Icon Size"
                                                               target:self
                                                                  set:@selector(setValue:forKey:)
                                                                  get:@selector(valueForKey:)
                                                               detail:nil
                                                                 cell:PSSliderCell
                                                                 edit:nil];
        [sizeSpec setProperty:@"iconSize" forKey:@"key"];
        [sizeSpec setProperty:@44 forKey:@"default"];
        [sizeSpec setProperty:@"com.susudear.screencoreprefs" forKey:@"defaults"];
        [sizeSpec setProperty:@32 forKey:@"min"];
        [sizeSpec setProperty:@64 forKey:@"max"];
        [specs addObject:sizeSpec];
        
        _specifiers = [specs copy];
    }
    return _specifiers;
}

- (void)setValue:(id)value forKey:(NSString *)key {
    [[SCPreferences sharedInstance] setValue:value forKey:key];
}

- (id)valueForKey:(NSString *)key {
    return [[SCPreferences sharedInstance] valueForKey:key defaultValue:nil];
}

@end
