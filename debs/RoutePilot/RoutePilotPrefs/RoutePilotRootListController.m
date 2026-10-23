#import "RoutePilotRootListController.h"
#import "RoutePilotPreferences.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>


@interface RoutePilotRootListController ()
@end

@implementation RoutePilotRootListController

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *items = [[self loadSpecifiersFromPlistName:@"RoutePilotRoot"
                                                           target:self] mutableCopy];
        [items addObject:[PSSpecifier preferenceSpecifierNamed:@"关于我们" target:self
                     set:nil get:nil detail:nil cell:PSGroupCell edit:nil]];
        [self routepilot_app_addButton:@"Sileo 越狱源" action:@selector(routepilot_app_openRepository:) to:items];
        [self routepilot_app_addButton:@"TG分享频道" action:@selector(routepilot_app_openTelegram:) to:items];
        [self routepilot_app_addButton:@"QQ交流群组" action:@selector(routepilot_app_openQQ:) to:items];
        _specifiers = items;
    }
    return _specifiers;
}

- (void)routepilot_app_addButton:(NSString *)title action:(SEL)action to:(NSMutableArray *)items {
    PSSpecifier *item = [PSSpecifier preferenceSpecifierNamed:title target:self
                          set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
    item.buttonAction = action;
    [items addObject:item];
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key.length == 0) return nil;
    return routepilot_app_readPreferences()[key] ?: [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key.length == 0) return;
    NSError *error = nil;
    if (!routepilot_app_writePreference(key, value, &error)) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"设置未保存"
            message:error.localizedDescription ?: @"请检查配置文件路径和写入权限。"
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        [self reloadSpecifiers];
    }
}

- (void)routepilot_app_openURL:(NSURL *)url fallback:(NSURL *)fallback {
    if (!url) return;
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
        if (success) return;
        if (fallback) {
            [self routepilot_app_openURL:fallback fallback:nil];
        } else {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法打开链接"
                message:@"请确认已安装对应应用。" preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    }];
}

- (void)routepilot_app_openRepository:(id)sender {
    NSString *source = @"https://github.com/Niubiprass/theos-ci";
    // Encode the entire URL as a path component, including its own delimiters.
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                              @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    NSString *encoded = [source stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    NSURL *primary = [NSURL URLWithString:[@"sileo://source/" stringByAppendingString:encoded]];
    [self routepilot_app_openURL:primary fallback:[NSURL URLWithString:source]];
}

- (void)routepilot_app_openTelegram:(id)sender {
    [self routepilot_app_openURL:[NSURL URLWithString:@"https://t.me/"]
                   fallback:[NSURL URLWithString:@"https://t.me/"]];
}

- (void)routepilot_app_openQQ:(id)sender {
    [self routepilot_app_openURL:[NSURL URLWithString:@"mqqapi://"] fallback:nil];
}

- (void)routepilot_app_openAppPicker:(id)sender {
    NSDictionary *prefs = routepilot_app_readPreferences();
    NSArray *apps = [prefs[@"directBundleIDs"] isKindOfClass:[NSArray class]] ? prefs[@"directBundleIDs"] : @[];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"直连应用 Bundle ID"
        message:@"输入一个或多个 Bundle ID，每行一个。此处保存策略名单；实际路由需 VPN 后端适配器支持。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"com.example.app";
        field.keyboardType = UIKeyboardTypeASCIICapable;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.text = [apps componentsJoinedByString:@"\\n"];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存名单" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *raw = alert.textFields.firstObject.text ?: @"";
        NSMutableArray *clean = [NSMutableArray array];
        NSCharacterSet *trim = [NSCharacterSet whitespaceAndNewlineCharacterSet];
        for (NSString *line in [raw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            NSString *bundle = [line stringByTrimmingCharactersInSet:trim];
            if (bundle.length && ![clean containsObject:bundle]) [clean addObject:bundle];
        }
        NSError *error = nil;
        if (!routepilot_app_writePreference(@"directBundleIDs", clean, &error)) {
            UIAlertController *failure = [UIAlertController alertControllerWithTitle:@"保存失败"
                message:error.localizedDescription ?: @"无法写入 RoutePilot 配置。" preferredStyle:UIAlertControllerStyleAlert];
            [failure addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:failure animated:YES completion:nil];
        } else {
            [self reloadSpecifiers];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}


@end
