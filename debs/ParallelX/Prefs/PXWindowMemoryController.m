#import "PXWindowMemoryController.h"
#import "../Common/PXWindowMemoryStore.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>

@interface PXWindowMemoryController ()
@property(nonatomic, strong) id memoryObserver;
@property(nonatomic, strong) id diagnosticObserver;
@end
@implementation PXWindowMemoryController
- (void)dealloc {
    if (_memoryObserver) [NSNotificationCenter.defaultCenter removeObserver:_memoryObserver];
    if (_diagnosticObserver) [NSNotificationCenter.defaultCenter removeObserver:_diagnosticObserver];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"窗口大小与位置记忆";
    __weak typeof(self) weakSelf = self;
    self.memoryObserver = [NSNotificationCenter.defaultCenter
         addObserverForName:PXWindowMemoryDidLoadNotification object:PXWindowMemoryStore.shared
         queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        (void)note;
        PXWindowMemoryController *controller = weakSelf;
        if (!controller || !controller.isViewLoaded || !controller.view.window) return;
        controller->_specifiers = nil;
        [controller reloadSpecifiers];
    }];
    self.diagnosticObserver=[NSNotificationCenter.defaultCenter
        addObserverForName:PXWindowDiagnosticStatusNotification object:PXWindowMemoryStore.shared
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        (void)note;
        PXWindowMemoryController *controller=weakSelf;
        if (!controller || !controller.isViewLoaded || !controller.view.window) return;
        controller->_specifiers=nil; [controller reloadSpecifiers];
    }];
    [PXWindowMemoryStore.shared reload];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _specifiers = nil;
    [self reloadSpecifiers];
    [PXWindowMemoryStore.shared reload];
}
- (PSSpecifier *)toggle:(NSString *)title key:(NSString *)key {
    PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:title target:self
           set:@selector(writeToggle:specifier:) get:@selector(readToggle:) detail:nil cell:PSSwitchCell edit:nil];
    [row setProperty:key forKey:@"wmKey"];
    [row setProperty:@YES forKey:@"default"];
    return row;
}
- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *items = [NSMutableArray array];
        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"窗口记忆"];
        [group setProperty:@"每个 App 单独记住正常浮窗的大小和位置，同一 App 的分身共用。横竖屏分别保存。拖动或缩放结束时自动保存，下次打开恢复。" forKey:@"footerText"];
        [items addObject:group];
        [items addObject:[self toggle:@"记忆大小和位置" key:@"enabled"]];
        PSSpecifier *reset = [PSSpecifier preferenceSpecifierNamed:@"清空所有窗口记忆" target:self
                             set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
        reset.buttonAction = @selector(confirmClear);
        [items addObject:reset];
        PSSpecifier *explanation = [PSSpecifier groupSpecifierWithName:@"诊断记录"];
        [explanation setProperty:@"记录保存、读回、恢复和跳过原因，普通记录最多256条；另留最近4次异常开窗，每段最多前12条、后12条（后续观察120秒），普通记录不会挤掉异常片段。不记录账号名、聊天、链接或密码。关闭记忆不清空已有尺寸，清空也不移动当前窗口。" forKey:@"footerText"];
        [items addObject:explanation];
        [items addObject:[self toggle:@"记录窗口记忆诊断" key:@"diagnostics"]];
        PSSpecifier *diagnosticStatus=[PSSpecifier groupSpecifierWithName:@"诊断写入状态"];
        [diagnosticStatus setProperty:PXWindowMemoryStore.shared.diagnosticStatusText forKey:@"footerText"];
        [items addObject:diagnosticStatus];
        NSString *error = PXWindowMemoryStore.shared.errorText;
        NSString *status = error.length ? error :
            (PXWindowMemoryStore.shared.isLoaded ?
                [NSString stringWithFormat:@"已读回 %lu 个 App 的窗口记忆。",(unsigned long)[PXWindowMemoryStore.shared.snapshot[@"apps"] count]] :
                @"正在读取窗口记忆；读取前使用原版窗口布局。");
        PSSpecifier *storage = [PSSpecifier groupSpecifierWithName:@"存储状态"];
        [storage setProperty:status forKey:@"footerText"];
        [items addObject:storage];
        _specifiers = items;
    }
    return _specifiers;
}
- (id)readToggle:(PSSpecifier *)specifier {
    return PXWindowMemoryStore.shared.snapshot[[specifier propertyForKey:@"wmKey"]] ?: @YES;
}
- (void)showStorageFailure {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"设置未保存"
           message:PXWindowMemoryStore.shared.errorText preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)writeToggle:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"wmKey"];
    __weak typeof(self) weakSelf = self;
    void (^done)(BOOL) = ^(BOOL ok) {
        PXWindowMemoryController *controller = weakSelf;
        if (!controller) return;
        [controller reloadSpecifiers];
        if (!ok) [controller showStorageFailure];
    };
    if ([key isEqual:@"enabled"])
        [PXWindowMemoryStore.shared setMemoryEnabled:[value boolValue] completion:done];
    else if ([key isEqual:@"diagnostics"])
        [PXWindowMemoryStore.shared setDiagnosticsEnabled:[value boolValue] completion:done];
}
- (void)confirmClear {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清空所有窗口记忆？"
         message:@"只清除各 App 的窗口大小和位置。账号、付款、其他设置及当前窗口都不变，下次新开窗口使用默认布局。"
         preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        [PXWindowMemoryStore.shared clearMemoryWithCompletion:^(BOOL ok) {
            PXWindowMemoryController *controller = weakSelf;
            if (!controller) return;
            [controller reloadSpecifiers];
            if (!ok) [controller showStorageFailure];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
