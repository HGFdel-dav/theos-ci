// SplitXRootListController.m
// 统一入口面板。这里不重画任何功能页：弧形唤醒来自原版弧形引擎，
// 边缘手柄 / 窗口 / 分屏来自原版窗口引擎，两个原版设置 Bundle 随包安装，
// 点进去就是它们自己的页面，参数与行为与原版一致。
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <CoreFoundation/CoreFoundation.h>

static NSString *const kSCDomain = @"com.susudear.screencoreprefs";
static NSString *const kPXDomain = @"com.moxuan.parallelx";

static id SXRead(NSString *domain, NSString *key) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)domain);
    return v ? (__bridge_transfer id)v : nil;
}

static void SXWrite(NSString *domain, NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             value ? (__bridge CFPropertyListRef)value : NULL,
                             (__bridge CFStringRef)domain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.niubiprass.splitx/changed"), NULL, NULL, YES);
}

static PSSpecifier *SXGroup(NSString *title, NSString *footer) {
    PSSpecifier *g = [PSSpecifier groupSpecifierWithName:title ?: @""];
    if (footer.length) [g setProperty:footer forKey:@"footerText"];
    return g;
}

static PSSpecifier *SXLink(id target, NSString *title, NSString *bundle, NSString *detail) {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:title target:target
        set:NULL get:NULL detail:Nil cell:PSLinkCell edit:NULL];
    [s setProperty:bundle forKey:@"bundle"];
    [s setProperty:detail forKey:@"detail"];
    [s setProperty:@YES forKey:@"isController"];
    [s setProperty:@46 forKey:@"height"];
    return s;
}

@interface SplitXRootListController : PSListController
@end

@implementation SplitXRootListController

- (instancetype)init {
    if ((self = [super init])) self.title = @"SplitX";
    return self;
}

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSMutableArray *rows = [NSMutableArray array];

    [rows addObject:SXGroup(@"SplitX", @"总开关只切换两个引擎的启用状态，不改动你的任何配置。")];
    PSSpecifier *master = [PSSpecifier preferenceSpecifierNamed:@"插件总开关" target:self
        set:@selector(setMaster:specifier:) get:@selector(readMaster:) detail:nil cell:PSSwitchCell edit:NULL];
    [master setProperty:@YES forKey:@"default"];
    [master setProperty:@46 forKey:@"height"];
    [rows addObject:master];

    [rows addObject:SXGroup(@"弧形菜单", @"弧形唤醒与手势参数由弧形引擎读取，页面为它自己的设置页。")];
    [rows addObject:SXLink(self, @"弧形菜单与手势", @"ScreenCorePrefs", @"SCRootListController")];

    [rows addObject:SXGroup(@"边缘手柄与窗口", @"手柄、菜单图标、窗口与分屏行为由窗口引擎提供。")];
    [rows addObject:SXLink(self, @"半圆面板与手柄", @"ParallelXPrefs", @"PXRootListController")];

    _specifiers = rows;
    return _specifiers;
}

- (id)readMaster:(PSSpecifier *)sp {
    id sc = SXRead(kSCDomain, @"Enabled");
    id px = SXRead(kPXDomain, @"pluginEnabled");
    if (sc == nil && px == nil) return @YES;
    return @(([sc respondsToSelector:@selector(boolValue)] ? [sc boolValue] : YES) &&
             ([px respondsToSelector:@selector(boolValue)] ? [px boolValue] : YES));
}

- (void)setMaster:(id)value specifier:(PSSpecifier *)sp {
    BOOL on = [value boolValue];
    SXWrite(kSCDomain, @"Enabled", @(on));
    SXWrite(kPXDomain, @"pluginEnabled", @(on));
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.moxuan.parallelx.capture-updated"), NULL, NULL, YES);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.susudear.screencoreprefs/saved"), NULL, NULL, YES);
}

@end
