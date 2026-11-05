#import "LocalCleanStatusRootListController.h"
#import "LocalCleanStatusPreferences.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>

static dispatch_queue_t local_cleanstatus_panelQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.local.cleanstatus.panel", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

@interface LocalCleanStatusRootListController ()
@property(nonatomic, strong) NSMutableDictionary *lcsDraft;
@property(nonatomic, copy) NSDictionary *lcsBaseline;
@property(nonatomic) BOOL lcsReady;
@property(nonatomic) BOOL lcsSaving;
@property(nonatomic) NSUInteger lcsGeneration;
@end

@implementation LocalCleanStatusRootListController

- (void)local_cleanstatus_prepareDraft {
    if (!self.lcsDraft) self.lcsDraft = [local_cleanstatus_sanitizedPreferences(@{}) mutableCopy];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self local_cleanstatus_prepareDraft];
    self.title = @"状态栏";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"准备中" style:UIBarButtonItemStyleDone target:self action:@selector(local_cleanstatus_apply:)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.lcsReady = NO;
    NSUInteger generation = ++self.lcsGeneration;
    self.view.userInteractionEnabled = NO;
    self.navigationItem.rightBarButtonItem.enabled = NO;
    __weak typeof(self) weakSelf = self;
    dispatch_async(local_cleanstatus_panelQueue(), ^{
        NSError *error = nil;
        local_cleanstatus_migratePreferences(&error);
        NSDictionary *values = local_cleanstatus_readPreferences();
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.lcsGeneration != generation) return;
            strongSelf.lcsBaseline = values;
            strongSelf.lcsDraft = [values mutableCopy];
            strongSelf.lcsReady = YES;
            strongSelf.view.userInteractionEnabled = YES;
            strongSelf.navigationItem.rightBarButtonItem.enabled = YES;
            strongSelf.navigationItem.rightBarButtonItem.title = @"应用";
            [strongSelf reloadSpecifiers];
            if (error && strongSelf.view.window)
                [strongSelf local_cleanstatus_showTitle:@"偏好路径提示" message:error.localizedDescription];
        });
    });
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (!self.lcsSaving && !self.presentedViewController) {
        self.lcsGeneration++;
        self.lcsDraft = nil; // Leaving without Apply explicitly discards the draft.
        self.lcsReady = NO;
    }
}

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        [self local_cleanstatus_prepareDraft];
        _specifiers = [[self loadSpecifiersFromPlistName:@"LocalCleanStatusRoot" target:self] mutableCopy];
    }
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    [self local_cleanstatus_prepareDraft];
    NSString *key = [specifier propertyForKey:@"key"];
    return self.lcsDraft[key] ?: [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [self local_cleanstatus_prepareDraft];
    NSString *key = [specifier propertyForKey:@"key"];
    if (!self.lcsReady || self.lcsSaving || !key.length || !self.lcsDraft[key]) return;
    self.lcsDraft[key] = @(local_cleanstatus_bool(value));
    self.navigationItem.rightBarButtonItem.title = @"应用 •";
}

- (void)local_cleanstatus_apply:(id)sender {
    (void)sender;
    if (!self.lcsReady || self.lcsSaving) return;
    self.lcsSaving = YES;
    self.view.userInteractionEnabled = NO;
    self.navigationItem.rightBarButtonItem.enabled = NO;
    NSDictionary *draft = [self.lcsDraft copy], *baseline = self.lcsBaseline;
    __weak typeof(self) weakSelf = self;
    dispatch_async(local_cleanstatus_panelQueue(), ^{
        NSError *error = nil;
        BOOL success = NO;
        if (![local_cleanstatus_readPreferences() isEqual:baseline]) {
            error = local_cleanstatus_error(5, @"设置已被其他面板更新。未覆盖；请退出后重新进入，再修改应用。");
        } else {
            success = local_cleanstatus_writePreferences(draft, &error);
            if (success) local_cleanstatus_notifyApplied();
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.lcsSaving = NO;
            strongSelf.view.userInteractionEnabled = YES;
            strongSelf.navigationItem.rightBarButtonItem.enabled = YES;
            if (!success) {
                [strongSelf local_cleanstatus_showTitle:@"设置未保存" message:error.localizedDescription ?: @"写入失败，草稿已保留。"];
                return;
            }
            strongSelf.lcsBaseline = draft;
            strongSelf.navigationItem.rightBarButtonItem.title = @"应用";
            [strongSelf local_cleanstatus_showTitle:@"已保存并发送应用通知"
                message:@"已加载的界面会刷新。新安装后的首次注入需要另行注销；此按钮不会注销或重启设备。图标隐藏不关闭对应服务。"];
        });
    });
}

- (void)local_cleanstatus_showTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
