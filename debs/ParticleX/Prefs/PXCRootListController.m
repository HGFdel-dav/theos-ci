#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import "../Sources/PXCPaths.h"

@interface PXCRootListController : PSListController
@end
@implementation PXCRootListController
- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    id value = PXCReadPreferences()[[specifier propertyForKey:@"key"]];
    return value ?: [specifier propertyForKey:@"default"];
}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (![key isKindOfClass:NSString.class] || !key.length || !value) return;
    NSMutableDictionary *p = [PXCReadPreferences() mutableCopy];
    p[key] = value;
    NSString *path = PXCPreferencePath();
    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:&error];
    struct stat st;
    if (!error && lstat(path.fileSystemRepresentation,&st)==0 && (!S_ISREG(st.st_mode) || st.st_nlink!=1)) {
        error = [NSError errorWithDomain:@"ParticleX" code:1 userInfo:@{NSLocalizedDescriptionKey:@"配置文件不是安全的普通文件，已停止写入。"}];
    }
    NSData *data = error ? nil : [NSPropertyListSerialization dataWithPropertyList:p format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    BOOL saved = data && [data writeToFile:path options:NSDataWritingAtomic error:&error];
    if (saved) {
        chmod(path.fileSystemRepresentation,0600);
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), PXC_CHANGED_CF, NULL, NULL, true);
    } else {
        [self reloadSpecifiers];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"保存失败" message:error.localizedDescription ?: @"无法写入当前越狱根。" preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
}
- (void)showDiagnostics {
    NSData *data = [NSData dataWithContentsOfFile:PXCLogPath() options:NSDataReadingMappedIfSafe error:nil];
    NSString *text = data.length <= 300*1024 ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if (text.length > 7000) text = [text substringFromIndex:text.length-7000];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"ParticleX 诊断" message:text.length ? text : @"暂无日志。安装后需要重新载入 SpringBoard 插件。日志不包含通知内容和截图。" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { UIPasteboard.generalPasteboard.string = text ?: @"暂无日志"; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
@end
