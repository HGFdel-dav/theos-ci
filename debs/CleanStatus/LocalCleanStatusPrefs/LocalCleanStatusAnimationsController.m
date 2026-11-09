#import "LocalCleanStatusAnimationsController.h"
#import "LocalCleanStatusAnimationPreferences.h"
#import "LocalCleanStatusAnimationCapabilities.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>

static NSString * const LCSAnimationPanelChanged = @"LCSAnimationPanelChanged";

// Both pages enqueue reads and writes here; the original panel has its own queue.
static dispatch_queue_t local_cleanstatus_animationPanelQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.local.cleanstatus.animations.preferences", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

// Access these UI-side snapshots only on the main thread. Pending values remain
// visible across pages until their exact revision has been saved successfully.
static NSDictionary *lcsAnimationValues;
static NSMutableDictionary *lcsAnimationPending;
static NSMutableDictionary *lcsAnimationRevisions;
static NSMutableDictionary *lcsAnimationQueuedRevisions;
static NSUInteger lcsAnimationRevision;
static NSUInteger lcsAnimationDebounce;
static NSString *lcsAnimationSaveError;

static void local_cleanstatus_prepareAnimationPanel(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lcsAnimationValues = local_cleanstatus_animationDefaults();
        lcsAnimationPending = [NSMutableDictionary dictionary];
        lcsAnimationRevisions = [NSMutableDictionary dictionary];
        lcsAnimationQueuedRevisions = [NSMutableDictionary dictionary];
    });
}

static void local_cleanstatus_animationPanelChanged(BOOL reloadValues) {
    [[NSNotificationCenter defaultCenter] postNotificationName:LCSAnimationPanelChanged
        object:nil userInfo:@{@"reloadValues": @(reloadValues)}];
}

static void local_cleanstatus_flushAnimationPanel(void) {
    local_cleanstatus_prepareAnimationPanel();
    ++lcsAnimationDebounce;
    NSMutableDictionary *patch = [NSMutableDictionary dictionary];
    NSMutableDictionary *revisions = [NSMutableDictionary dictionary];
    for (NSString *key in lcsAnimationPending) {
        NSNumber *revision = lcsAnimationRevisions[key];
        if ([revision isEqual:lcsAnimationQueuedRevisions[key]]) continue;
        patch[key] = lcsAnimationPending[key];
        revisions[key] = revision;
        lcsAnimationQueuedRevisions[key] = revision;
    }
    if (!patch.count) return;
    NSDictionary *savedPatch = [patch copy];
    NSDictionary *savedRevisions = [revisions copy];
    dispatch_async(local_cleanstatus_animationPanelQueue(), ^{
        // Read-modify-write preserves values changed on the other animation page.
        NSMutableDictionary *latest = [local_cleanstatus_readAnimationPreferences() mutableCopy];
        [latest addEntriesFromDictionary:savedPatch];
        NSDictionary *next = local_cleanstatus_sanitizedAnimationPreferences(latest);
        NSError *error = nil;
        BOOL success = local_cleanstatus_writeAnimationPreferences(next, &error);
        if (success) local_cleanstatus_notifyAnimationsApplied();
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) lcsAnimationValues = next;
            for (NSString *key in savedPatch) {
                NSNumber *revision = savedRevisions[key];
                if ([lcsAnimationQueuedRevisions[key] isEqual:revision])
                    [lcsAnimationQueuedRevisions removeObjectForKey:key];
                if (success && [lcsAnimationRevisions[key] isEqual:revision]) {
                    [lcsAnimationPending removeObjectForKey:key];
                    [lcsAnimationRevisions removeObjectForKey:key];
                }
            }
            if (!success)
                lcsAnimationSaveError = error.localizedDescription ?: @"写入失败，修改尚未保存。请重试。";
            else if (!lcsAnimationPending.count)
                lcsAnimationSaveError = nil;
            local_cleanstatus_animationPanelChanged(NO);
        });
    });
}

@interface LocalCleanStatusAnimationsController ()
@property(nonatomic) BOOL lcsReady;
@property(nonatomic) NSUInteger lcsLoadGeneration;
@property(nonatomic, copy) NSString *lcsShownSaveError;
@property(nonatomic) int lcsCapabilityToken;
@property(nonatomic) BOOL lcsCapabilityRegistered;
- (NSString *)local_cleanstatus_plistName;
- (void)local_cleanstatus_updateAnimationSpecifiers;
- (void)local_cleanstatus_refreshAnimationSpecifiers:(BOOL)reloadValues;
- (void)local_cleanstatus_presentSaveError;
- (void)local_cleanstatus_showError:(NSString *)message;
@end

@implementation LocalCleanStatusAnimationsController
- (NSString *)local_cleanstatus_plistName { return @"LocalCleanStatusAnimations"; }
- (NSMutableArray *)specifiers {
    if (!_specifiers)
        _specifiers = [[self loadSpecifiersFromPlistName:[self local_cleanstatus_plistName] target:self] mutableCopy];
    local_cleanstatus_prepareAnimationPanel();
    [self local_cleanstatus_updateAnimationSpecifiers];
    return _specifiers;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    local_cleanstatus_prepareAnimationPanel();
    self.title = [[self local_cleanstatus_plistName] isEqualToString:@"LocalCleanStatusAnimations"] ? @"动画效果" : @"动画高级设置";
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(local_cleanstatus_animationPanelStateChanged:)
        name:LCSAnimationPanelChanged object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(local_cleanstatus_animationAccessibilityChanged:)
        name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(local_cleanstatus_animationWillResignActive:)
        name:UIApplicationWillResignActiveNotification object:nil];
    __weak typeof(self) weakSelf = self;
    int token = 0;
    if (notify_register_dispatch(LCS_ANIMATION_CAPABILITIES_NAME, &token, dispatch_get_main_queue(), ^(int capabilityToken) {
        (void)capabilityToken;
        [weakSelf local_cleanstatus_refreshAnimationSpecifiers:NO];
    }) == NOTIFY_STATUS_OK) {
        self.lcsCapabilityToken = token;
        self.lcsCapabilityRegistered = YES;
    }
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_lcsCapabilityRegistered) notify_cancel(_lcsCapabilityToken);
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.lcsReady = NO;
    [self local_cleanstatus_refreshAnimationSpecifiers:YES];
    // Flush even if another write is in flight. The child read is queued AFTER
    // all final values, and the shared pending overlay also survives a failure.
    local_cleanstatus_flushAnimationPanel();
    NSUInteger generation = ++self.lcsLoadGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_async(local_cleanstatus_animationPanelQueue(), ^{
        NSError *migrationError = nil;
        local_cleanstatus_migrateAnimationPreferences(&migrationError);
        NSDictionary *values = local_cleanstatus_readAnimationPreferences();
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf.lcsLoadGeneration) return;
            if (migrationError) lcsAnimationSaveError = migrationError.localizedDescription;
            lcsAnimationValues = values;
            strongSelf.lcsReady = YES;
            [strongSelf local_cleanstatus_refreshAnimationSpecifiers:YES];
            [strongSelf local_cleanstatus_presentSaveError];
        });
    });
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self local_cleanstatus_presentSaveError];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    ++self.lcsLoadGeneration;
    local_cleanstatus_flushAnimationPanel();
}
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key) return [specifier propertyForKey:@"default"];
    local_cleanstatus_prepareAnimationPanel();
    return lcsAnimationPending[key] ?: lcsAnimationValues[key] ?: [specifier propertyForKey:@"default"];
}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!self.lcsReady || !key || !local_cleanstatus_animationDefaults()[key]) return;
    [self local_cleanstatus_updateAnimationSpecifiers];
    if (![[specifier propertyForKey:@"enabled"] boolValue]) return;
    NSMutableDictionary *candidate = [lcsAnimationValues mutableCopy];
    [candidate addEntriesFromDictionary:lcsAnimationPending];
    candidate[key] = value ?: local_cleanstatus_animationDefaults()[key];
    // Keep real slider values; the animation API handles booleans and numbers.
    lcsAnimationPending[key] = local_cleanstatus_sanitizedAnimationPreferences(candidate)[key];
    lcsAnimationRevisions[key] = @(++lcsAnimationRevision);
    lcsAnimationSaveError = nil;
    local_cleanstatus_animationPanelChanged(NO);
    NSUInteger generation = ++lcsAnimationDebounce;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation == lcsAnimationDebounce) local_cleanstatus_flushAnimationPanel();
    });
}
- (void)local_cleanstatus_updateAnimationSpecifiers {
    int known = 0;
    uint32_t flags = local_cleanstatus_animationCapabilityFlags(&known);
    NSMutableDictionary *values = [lcsAnimationValues mutableCopy];
    [values addEntriesFromDictionary:lcsAnimationPending];
    BOOL master = [values[@"animationEnabled"] boolValue];
    for (PSSpecifier *specifier in _specifiers) {
        NSString *key = [specifier propertyForKey:@"key"];
        if (![key hasPrefix:@"animation"]) {
            if ([[specifier propertyForKey:@"id"] isEqualToString:@"animationReset"])
                [specifier setProperty:@(self.lcsReady) forKey:@"enabled"];
            continue;
        }
        // Capability state never traps the user with an enabled master switch.
        BOOL enabled = self.lcsReady;
        if (![key isEqualToString:@"animationEnabled"]) {
            NSNumber *capability = [specifier propertyForKey:@"requiresCapability"];
            uint32_t required = capability.unsignedIntValue;
            enabled = enabled && master && known && (required ? (flags & required) == required : flags != 0);
            id dependencies = [specifier propertyForKey:@"animationRequires"];
            if ([dependencies isKindOfClass:[NSString class]]) dependencies = @[dependencies];
            if ([dependencies isKindOfClass:[NSArray class]])
                for (NSString *dependency in dependencies) enabled = enabled && [values[dependency] boolValue];
        }
        [specifier setProperty:@(enabled) forKey:@"enabled"];
    }
    NSString *availability;
    if (!known)
        availability = @"模块状态：未知，尚未收到系统桌面的能力信息。新安装后请注销并重新打开此页；子选项在状态确认前不可调节。总开关仍可关闭。";
    else
        availability = [NSString stringWithFormat:@"应用动画：%@；神灯：%@；通知中心图标：%@。不支持的子选项已停用。",
            flags & LCSAnimationAppSupported ? @"可用" : @"不支持",
            (flags & (LCSAnimationAppSupported | LCSAnimationGenieSupported)) == (LCSAnimationAppSupported | LCSAnimationGenieSupported) ? @"可用" : @"不支持",
            flags & LCSAnimationIconsSupported ? @"可用" : @"不支持"];
    if (known)
        availability = [availability stringByAppendingFormat:@"水滴圆角：%@；透明通知中心面板：%@。",
            (flags & (LCSAnimationAppSupported | LCSAnimationDropletSupported)) == (LCSAnimationAppSupported | LCSAnimationDropletSupported) ? @"可用" : @"不支持",
            (flags & (LCSAnimationIconsSupported | LCSAnimationSheetSupported)) == (LCSAnimationIconsSupported | LCSAnimationSheetSupported) ? @"可用" : @"不支持"];
    if (known && !(flags & LCSAnimationGlobalSlowSupported))
        availability = [availability stringByAppendingString:@"当前系统不支持全局慢放，该选项已停用。"];
    if (known && (flags & LCSAnimationIconsSupported) && !(flags & LCSAnimationBlurSupported))
        availability = [availability stringByAppendingString:@"图标模糊接口不可用，飞入保留原有滤镜。"];
    if (UIAccessibilityIsReduceMotionEnabled())
        availability = [availability stringByAppendingString:@"系统已开启“减弱动态效果”，动画保持系统行为。"];
    NSString *saveState = !self.lcsReady ? @"正在读取动画设置…" :
        lcsAnimationSaveError ? [@"保存失败：" stringByAppendingString:lcsAnimationSaveError] :
        lcsAnimationPending.count ? @"正在自动保存动画设置…" : @"修改自动保存，无需点击“应用”，下一次动画生效。";
    for (PSSpecifier *specifier in _specifiers) {
        if ([[specifier propertyForKey:@"id"] isEqualToString:@"animationAvailability"]) {
            NSString *introduction = [specifier propertyForKey:@"animationIntroduction"] ?: @"";
            [specifier setProperty:[NSString stringWithFormat:@"%@\n%@\n%@", introduction, availability, saveState] forKey:@"footerText"];
        }
    }
}
- (void)local_cleanstatus_refreshAnimationSpecifiers:(BOOL)reloadValues {
    // Do not replace a slider cell during a drag; update only changed enabled
    // states. Initial loads and reset may refresh the displayed values as well.
    for (PSSpecifier *specifier in [self specifiers]) {
        NSNumber *enabled = [specifier propertyForKey:@"enabled"] ?: @YES;
        BOOL enabledChanged = ![[specifier propertyForKey:@"lcsLastEnabled"] isEqual:enabled];
        [specifier setProperty:enabled forKey:@"lcsLastEnabled"];
        BOOL isStatus = [[specifier propertyForKey:@"id"] isEqualToString:@"animationAvailability"];
        BOOL statusChanged = NO;
        if (isStatus) {
            NSString *footer = [specifier propertyForKey:@"footerText"];
            statusChanged = ![[specifier propertyForKey:@"lcsLastFooter"] isEqualToString:footer];
            [specifier setProperty:footer forKey:@"lcsLastFooter"];
        }
        BOOL isControl = [[specifier propertyForKey:@"key"] hasPrefix:@"animation"];
        if (self.isViewLoaded && (statusChanged || (isControl && (reloadValues || enabledChanged)) ||
            ([[specifier propertyForKey:@"id"] isEqualToString:@"animationReset"] && enabledChanged)))
            [self reloadSpecifier:specifier];
    }
}
- (void)local_cleanstatus_animationPanelStateChanged:(NSNotification *)notification {
    [self local_cleanstatus_refreshAnimationSpecifiers:[notification.userInfo[@"reloadValues"] boolValue]];
    if (self.lcsReady) [self local_cleanstatus_presentSaveError];
}
- (void)local_cleanstatus_animationAccessibilityChanged:(NSNotification *)notification {
    (void)notification;
    [self local_cleanstatus_refreshAnimationSpecifiers:NO];
}
- (void)local_cleanstatus_animationWillResignActive:(NSNotification *)notification {
    (void)notification;
    local_cleanstatus_flushAnimationPanel();
}
- (void)local_cleanstatus_resetAnimationSettings {
    if (!self.lcsReady) return;
    NSDictionary *defaults = local_cleanstatus_animationDefaults();
    for (NSString *key in defaults) {
        lcsAnimationPending[key] = defaults[key];
        lcsAnimationRevisions[key] = @(++lcsAnimationRevision);
    }
    lcsAnimationSaveError = nil;
    local_cleanstatus_animationPanelChanged(YES);
    local_cleanstatus_flushAnimationPanel();
}
- (void)local_cleanstatus_presentSaveError {
    if (!lcsAnimationSaveError) { self.lcsShownSaveError = nil; return; }
    if (!self.view.window || self.presentedViewController ||
        self.navigationController.topViewController != self ||
        [self.lcsShownSaveError isEqualToString:lcsAnimationSaveError]) return;
    self.lcsShownSaveError = lcsAnimationSaveError;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"动画设置未保存"
        message:[lcsAnimationSaveError stringByAppendingString:@"\n当前选值已保留，可重试保存。"] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"稍后" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"重试保存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        self.lcsShownSaveError = nil;
        local_cleanstatus_flushAnimationPanel();
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)local_cleanstatus_openAnimationAuthor {
    NSURL *url = [NSURL URLWithString:@"https://t.me/ba31k_tweaks"];
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
        if (!success) dispatch_async(dispatch_get_main_queue(), ^{
            [self local_cleanstatus_showError:@"暂时无法打开作者主页，请稍后重试。"];
        });
    }];
}
- (void)local_cleanstatus_showError:(NSString *)message {
    if (!self.view.window || self.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"动画设置" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

@implementation LocalCleanStatusAnimationAdvancedController
- (NSString *)local_cleanstatus_plistName { return @"LocalCleanStatusAnimationsAdvanced"; }
@end
