#import "LocalCleanStatusCellularController.h"
#import "../Cellular/LCSCellularSettings.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>

static dispatch_queue_t LCSCellularPanelQueue(void) {
    static dispatch_queue_t queue;static dispatch_once_t once;
    dispatch_once(&once,^{queue=dispatch_queue_create("com.local.cleanstatus.cellular.panel",DISPATCH_QUEUE_SERIAL);});return queue;
}
@interface LocalCleanStatusCellularController ()
@property(nonatomic,copy) NSDictionary *values;
@property(nonatomic,strong) NSMutableDictionary *pending;
@property(nonatomic,strong) NSMutableDictionary *revisions;
@property(nonatomic) NSUInteger revision;
@property(nonatomic,copy) NSString *saveError;
@end
@implementation LocalCleanStatusCellularController
- (void)prepare {
    if(!self.values)self.values=LCSCellularDefaults();
    if(!self.pending)self.pending=[NSMutableDictionary new];
    if(!self.revisions)self.revisions=[NSMutableDictionary new];
}
- (NSArray *)specifiers {
    [self prepare];
    if(!_specifiers)_specifiers=[self loadSpecifiersFromPlistName:@"LocalCleanStatusCellular" target:self];
    return _specifiers;
}
- (void)viewDidLoad {
    [super viewDidLoad];[self prepare];self.title=@"蜂窝快捷功能";LCSCellularStartConfiguration();
    __weak typeof(self) weakSelf=self;
    dispatch_async(LCSCellularPanelQueue(),^{
        NSError *error=nil;BOOL migrated=LCSCellularMigratePreferences(&error);
        NSDictionary *values=LCSCellularReadPreferences();
        dispatch_async(dispatch_get_main_queue(),^{
            typeof(self) s=weakSelf;if(!s)return;s.values=values;
            if(!migrated)s.saveError=error.localizedDescription?:@"旧设置未能安全迁移，尚未更改。";
            [s reloadSpecifiers];[s displayErrorIfVisible];
        });
    });
}
- (void)viewDidAppear:(BOOL)animated {[super viewDidAppear:animated];[self displayErrorIfVisible];}
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    [self prepare];NSString *key=[specifier propertyForKey:@"key"];
    return self.pending[key]?:self.values[key]?:[specifier propertyForKey:@"default"]?:@NO;
}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [self prepare];NSString *key=[specifier propertyForKey:@"key"];
    if(![@[@"simManager",@"dataSwitch",@"diagnostics"] containsObject:key]||![value isKindOfClass:NSNumber.class])return;
    NSNumber *revision=@(++self.revision);BOOL desired=[value boolValue];self.pending[key]=@(desired);self.revisions[key]=revision;
    __weak typeof(self) weakSelf=self;
    dispatch_async(LCSCellularPanelQueue(),^{
        NSError *error=nil;BOOL ok=LCSCellularSaveSetting(key,desired,&error);
        NSDictionary *actual=LCSCellularReadPreferences();
        dispatch_async(dispatch_get_main_queue(),^{
            typeof(self) s=weakSelf;if(!s)return;s.values=actual;
            if([s.revisions[key] isEqual:revision]){[s.pending removeObjectForKey:key];[s.revisions removeObjectForKey:key];}
            if(!ok)s.saveError=error.localizedDescription?:@"设置未保存，运行中的功能未更新。";
            [s reloadSpecifiers];[s displayErrorIfVisible];
        });
    });
}
- (void)displayErrorIfVisible {
    if(!self.saveError.length||!self.isViewLoaded||!self.view.window||self.presentedViewController)return;
    NSString *message=self.saveError;self.saveError=nil;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"蜂窝设置未完成" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
