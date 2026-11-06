#import "LocalCleanStatusRuntime.h"
#import "LocalCleanStatusConfig.h"
#import "LocalCleanStatusCore.h"
#import "LocalCleanStatusCCPolicy.h"
#import "LocalCleanStatusCCBackend.h"
#import "LocalCleanStatusCCDiagnostics.h"
#import <objc/runtime.h>
#import <objc/message.h>

// iOS 15 only. The two connectivity modules keep their stock tap and their
// expanded menu; we add a long press on the round button and present a list.
// Collapsed state and the lock check gate every presentation.

static char LCSCCTicketKey;
static char LCSCCHandlerKey;

static BOOL LCSCCiOS15(void) {
    static BOOL value; static dispatch_once_t once;
    dispatch_once(&once, ^{ value = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15; });
    return value;
}

static BOOL LCSCCPasscodeLocked(void) {
    Class cls = NSClassFromString(@"SBLockStateAggregator");
    SEL shared = sel_registerName("sharedInstance");
    if (!cls || ![cls respondsToSelector:shared]) return YES; // fail closed
    id aggregator = ((id(*)(id,SEL))objc_msgSend)(cls, shared);
    SEL state = sel_registerName("lockState");
    if (!aggregator || ![aggregator respondsToSelector:state]) return YES;
    return (((NSUInteger(*)(id,SEL))objc_msgSend)(aggregator, state) & 2) != 0;
}

static UIView *LCSCCRoundButton(UIView *view) {
    if (!view) return nil;
    if ([NSStringFromClass(view.class) isEqualToString:@"CCUIRoundButton"]) return view;
    for (UIView *child in view.subviews) {
        UIView *found = LCSCCRoundButton(child);
        if (found) return found;
    }
    return nil;
}

static LocalCleanStatusCCTicket *LCSCCEnsureTicket(id controller) {
    NSValue *boxed = objc_getAssociatedObject(controller, &LCSCCTicketKey);
    LocalCleanStatusCCTicket *ticket = boxed.pointerValue;
    if (!ticket) {
        ticket = calloc(1, sizeof(LocalCleanStatusCCTicket));
        objc_setAssociatedObject(controller, &LCSCCTicketKey, [NSValue valueWithPointer:ticket],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return ticket;
}

#pragma mark - gesture

@interface LCSCCTargetGesture : UILongPressGestureRecognizer
@property(nonatomic) BOOL lcsExpanded;
@end

@implementation LCSCCTargetGesture
- (BOOL)shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    return ![other isKindOfClass:UIPanGestureRecognizer.class];
}
@end

#pragma mark - handler

@interface LCSCCHandler : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, weak) UIViewController *controller;
@property(nonatomic) LCSCCTargetKind kind;
@end

@implementation LCSCCHandler
- (void)lcs_longPress:(LCSCCTargetGesture *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    [self lcs_presentFrom:gesture.view];
}

- (BOOL)lcs_allowed {
    uint32_t flags = local_cleanstatus_currentFlags();
    BOOL ok = local_cleanstatus_ccCanPresent(flags,self.kind,!LCSCCPasscodeLocked(),
        NO, self.controller.view.window != nil,
        self.controller.presentedViewController != nil, NO);
    if (!ok) local_cleanstatus_ccLog(@"cc.blocked",self.kind == LCSCCTargetKindWiFi ? @"wifi" : @"bt");
    return ok;
}

- (void)lcs_presentFrom:(UIView *)anchor {
    if (![self lcs_allowed]) return;
    uint64_t generation = local_cleanstatus_ccBegin(LCSCCEnsureTicket(self.controller));
    (void)generation;
    LCSCCBackend *backend = LCSCCBackend.shared;
    if (self.kind == LCSCCTargetKindWiFi) {
        if (!backend.wiFiAvailable) { [self lcs_alert:@"Wi-Fi 不可用"]; return; }
        [self lcs_showLoading];
        __weak typeof(self) weakSelf = self;
        [backend scanWiFi:^(NSArray<LCSCCTarget *> *targets, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf lcs_presentWiFi:targets error:error anchor:anchor]; });
        }];
    } else {
        if (!backend.bluetoothAvailable) { [self lcs_alert:@"蓝牙不可用"]; return; }
        __weak typeof(self) weakSelf = self;
        [backend listPairedBluetooth:^(NSArray<LCSCCTarget *> *targets, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf lcs_presentBluetooth:targets anchor:anchor]; });
        }];
    }
}

- (void)lcs_alert:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self.controller presentViewController:alert animated:YES completion:nil];
}

- (void)lcs_showLoading {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"扫描 Wi-Fi…" message:nil
        preferredStyle:UIAlertControllerStyleAlert];
    [self.controller presentViewController:alert animated:YES completion:nil];
}

- (void)lcs_presentWiFi:(NSArray<LCSCCTarget *> *)targets error:(NSError *)error anchor:(UIView *)anchor {
    if (self.controller.presentedViewController) [self.controller dismissViewControllerAnimated:NO completion:nil];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择 Wi-Fi"
        message:error ? error.localizedDescription : nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (LCSCCTarget *target in targets) {
        NSString *title = [NSString stringWithFormat:@"%@ %@%@", target.subtitle ?: @"",
                           target.secure ? @"🔒 " : @"", target.title];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) { [weakSelf lcs_joinWiFi:target]; }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"重新扫描" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) { [weakSelf lcs_presentFrom:anchor]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = anchor ?: self.controller.view;
    [self.controller presentViewController:sheet animated:YES completion:nil];
}

- (void)lcs_joinWiFi:(LCSCCTarget *)target {
    uint64_t generation = local_cleanstatus_ccBegin(LCSCCEnsureTicket(self.controller));
    __weak typeof(self) weakSelf = self;
    [LCSCCBackend.shared joinWiFi:target completion:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!local_cleanstatus_ccCurrent(LCSCCEnsureTicket(weakSelf.controller), generation)) return;
            if (success) { local_cleanstatus_ccLog(@"wifi.join",@"ok"); return; }
            if (target.secure) [weakSelf lcs_offerSettingsForSSID:target.title];
            else [weakSelf lcs_alert:error.localizedDescription ?: @"连接失败"];
        });
    }];
}

- (void)lcs_offerSettingsForSSID:(NSString *)ssid {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:ssid
        message:@"需要在设置中输入密码" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"打开设置" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            Class cls = NSClassFromString(@"LSApplicationWorkspace");
            SEL selector = sel_registerName("defaultWorkspace");
            if (!cls || ![cls respondsToSelector:selector]) return;
            id workspace = ((id(*)(id,SEL))objc_msgSend)(cls, selector);
            SEL open = sel_registerName("openSensitiveURL:withOptions:");
            if (![workspace respondsToSelector:open]) return;
            ((BOOL(*)(id,SEL,id,id))objc_msgSend)(workspace, open,
                [NSURL URLWithString:@"prefs:root=WIFI"], nil);
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self.controller presentViewController:alert animated:YES completion:nil];
}

- (void)lcs_presentBluetooth:(NSArray<LCSCCTarget *> *)targets anchor:(UIView *)anchor {
    if (self.controller.presentedViewController) [self.controller dismissViewControllerAnimated:NO completion:nil];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"蓝牙设备"
        message:targets.count ? nil : @"没有已配对设备"
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (LCSCCTarget *target in targets) {
        NSString *title = target.connected ? [@"已连接 · " stringByAppendingString:target.title] : target.title;
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) { [weakSelf lcs_toggle:target]; }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = anchor ?: self.controller.view;
    [self.controller presentViewController:sheet animated:YES completion:nil];
}

- (void)lcs_toggle:(LCSCCTarget *)target {
    __weak typeof(self) weakSelf = self;
    [LCSCCBackend.shared toggleBluetooth:target completion:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!success) [weakSelf lcs_alert:error.localizedDescription ?: @"操作失败"];
        });
    }];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    (void)gesture; (void)other;
    return NO;
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (![self lcs_allowed]) return NO;
    return ((LCSCCTargetGesture *)gesture).lcsExpanded == NO;
}
@end

#pragma mark - hooks

static void LCSCCInstallFor(id controller, LCSCCTargetKind kind) {
    if (!LCSCCiOS15() || !controller) return;
    UIView *button = LCSCCRoundButton(((UIViewController *)controller).view);
    if (!button) { local_cleanstatus_ccLog(@"cc.button",@"missing"); return; }
    if (objc_getAssociatedObject(button, &LCSCCHandlerKey)) return;
    LCSCCHandler *handler = [LCSCCHandler new];
    handler.controller = controller; handler.kind = kind;
    LCSCCTargetGesture *gesture = [[LCSCCTargetGesture alloc] initWithTarget:handler
        action:@selector(lcs_longPress:)];
    gesture.delegate = handler;
    gesture.minimumPressDuration = 0.45;
    gesture.cancelsTouchesInView = NO;
    [button addGestureRecognizer:gesture];
    objc_setAssociatedObject(button, &LCSCCHandlerKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void LCSCCMarkExpanded(UIView *view, BOOL expanded) {
    for (UIGestureRecognizer *gesture in view.gestureRecognizers)
        if ([gesture isKindOfClass:LCSCCTargetGesture.class])
            ((LCSCCTargetGesture *)gesture).lcsExpanded = expanded;
    for (UIView *child in view.subviews) LCSCCMarkExpanded(child, expanded);
}

static BOOL LCSCCInstallClass(NSString *name, LCSCCTargetKind kind) {
    Class cls = NSClassFromString(name);
    if (!cls) return NO;
    SEL viewDidLoad = sel_registerName("viewDidLoad");
    Method method = class_getInstanceMethod(cls, viewDidLoad);
    if (method && method_getImplementation(method) != IMP(LCSCCInstallFor)) {
        IMP original = method_getImplementation(method);
        IMP replacement = imp_implementationWithBlock(^(id self_) {
            ((void(*)(id,SEL))original)(self_, viewDidLoad);
            LCSCCInstallFor(self_, kind);
        });
        method_setImplementation(method, replacement);
    }
    SEL transition = sel_registerName("containerWillTransitionToExpandedContentMode:");
    Method expanded = class_getInstanceMethod(cls, transition);
    if (expanded) {
        IMP original = method_getImplementation(expanded);
        IMP replacement = imp_implementationWithBlock(^(id self_, BOOL expanded_) {
            ((void(*)(id,SEL,BOOL))original)(self_, transition, expanded_);
            LCSCCMarkExpanded(((UIViewController *)self_).view, expanded_);
        });
        method_setImplementation(expanded, replacement);
    }
    return YES;
}

void local_cleanstatus_installControlCenterHooks(void) {
    if (!LCSCCiOS15()) return;
    static BOOL hookedWiFi, hookedBluetooth, scheduled;
    if (!hookedWiFi) hookedWiFi = LCSCCInstallClass(@"CCUIConnectivityWifiViewController", LCSCCTargetKindWiFi);
    if (!hookedBluetooth) hookedBluetooth = LCSCCInstallClass(@"CCUIConnectivityBluetoothViewController", LCSCCTargetKindBluetooth);
    if (hookedWiFi && hookedBluetooth) { local_cleanstatus_ccLog(@"cc.install",@"ok"); return; }
    if (scheduled) return;
    scheduled = YES;
    local_cleanstatus_ccLog(@"cc.install",[NSString stringWithFormat:@"wifi=%d bt=%d",hookedWiFi,hookedBluetooth]);
    // The Control Center bundles can load after SpringBoard starts; retry a few
    // times and on activation instead of failing silently forever.
    for (NSNumber *delay in @[@0.5,@2,@5,@10,@20]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay.doubleValue*NSEC_PER_SEC)),
            dispatch_get_main_queue(),^{ local_cleanstatus_installControlCenterHooks(); });
    }
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note;
            local_cleanstatus_installControlCenterHooks();
        }];
}
