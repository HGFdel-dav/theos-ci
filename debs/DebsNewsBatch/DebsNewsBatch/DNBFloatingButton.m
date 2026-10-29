//
//  DNBFloatingButton.m
//  DebsNewsBatch
//
//  悬浮按钮：贴在 Debs 的 key window 上，可拖动、位置记忆，点开「新闻批量下载」面板。
//  只做我们自己的 UI，不改任何原生界面。
//

#import "DNBFloatingButton.h"
#import "DNBCommon.h"
#import "DNBPanelViewController.h"

static NSString *const kDNBButtonOffsetXKey = @"buttonOffsetX";
static NSString *const kDNBButtonOffsetYKey = @"buttonOffsetY";

@interface DNBFloatingButton ()
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, assign) BOOL dragging;
@end

@implementation DNBFloatingButton

+ (instancetype)shared
{
    static DNBFloatingButton *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[DNBFloatingButton alloc] init];
    });
    return shared;
}

#pragma mark 启动

- (void)start
{
    if (self.started) {
        return;
    }
    self.started = YES;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(attachIfNeeded)
                   name:UIWindowDidBecomeKeyNotification object:nil];
    [center addObserver:self selector:@selector(attachIfNeeded)
                   name:UIApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:self selector:@selector(attachIfNeeded)
                   name:UIApplicationDidFinishLaunchingNotification object:nil];

    self.timer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                  target:self
                                                selector:@selector(timerTick)
                                                userInfo:nil
                                                 repeats:YES];
    self.timer.tolerance = 0.5;
    [self attachIfNeeded];
    DNBLog(@"悬浮按钮启动完成");
}

- (void)timerTick
{
    [self attachIfNeeded];
}

#pragma mark 窗口

- (UIWindow *)keyWindow
{
    UIWindow *fallback = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow && window.windowLevel == UIWindowLevelNormal) {
                return window;
            }
            if (!fallback && window.windowLevel == UIWindowLevelNormal) {
                fallback = window;
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!fallback) {
        fallback = [UIApplication sharedApplication].windows.firstObject;
    }
#pragma clang diagnostic pop
    return fallback;
}

- (UIButton *)makeButtonIfNeeded
{
    if (self.button) {
        return self.button;
    }

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(0, 0, 96, 34);
    button.backgroundColor = [UIColor colorWithRed:0.09 green:0.11 blue:0.16 alpha:0.92];
    button.layer.cornerRadius = 17.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [UIColor colorWithRed:0.227 green:0.627 blue:1.0 alpha:0.55].CGColor;
    button.tintColor = [UIColor colorWithRed:0.227 green:0.627 blue:1.0 alpha:1.0];
    button.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];

    UIImage *icon = [[UIImage systemImageNamed:@"arrow.down.circle"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    [button setImage:icon forState:UIControlStateNormal];
    [button setTitle:@" 批量下载" forState:UIControlStateNormal];
    [button setTitleColor:[UIColor colorWithWhite:0.95 alpha:1.0] forState:UIControlStateNormal];
    button.contentEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 10);

    [button addTarget:self action:@selector(handleTap) forControlEvents:UIControlEventTouchUpInside];
    [button addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)]];

    UILongPressGestureRecognizer *longPress =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    longPress.minimumPressDuration = 0.6;
    [button addGestureRecognizer:longPress];

    self.button = button;
    return button;
}

- (void)attachIfNeeded
{
    UIWindow *window = [self keyWindow];
    if (!window) {
        return;
    }
    UIButton *button = [self makeButtonIfNeeded];
    if (button.superview != window) {
        [window addSubview:button];
        DNBLog(@"悬浮按钮贴到窗口 %@", NSStringFromClass([window class]));
    }
    if (!self.dragging) {
        [self applyStoredPositionInWindow:window];
    }
    [window bringSubviewToFront:button];
}

#pragma mark 位置

- (NSUserDefaults *)defaults
{
    return [[NSUserDefaults alloc] initWithSuiteName:@"com.niubiprass.debsnewsbatch"];
}

- (void)applyStoredPositionInWindow:(UIWindow *)window
{
    NSUserDefaults *defaults = [self defaults];
    CGFloat offsetX = [defaults objectForKey:kDNBButtonOffsetXKey] ? [defaults doubleForKey:kDNBButtonOffsetXKey] : 68.0;
    CGFloat offsetY = [defaults objectForKey:kDNBButtonOffsetYKey] ? [defaults doubleForKey:kDNBButtonOffsetYKey] : 132.0;

    CGRect bounds = window.bounds;
    CGRect frame = self.button.frame;
    frame.origin.x = bounds.size.width - frame.size.width - (offsetX - frame.size.width / 2.0);
    frame.origin.y = bounds.size.height - frame.size.height - (offsetY - frame.size.height / 2.0);
    [self clampFrameInBounds:bounds];
    self.button.frame = frame;
}

- (void)clampFrameInBounds:(CGRect)bounds
{
    CGRect frame = self.button.frame;
    CGFloat maxX = MAX(0.0, bounds.size.width - frame.size.width - 6.0);
    CGFloat maxY = MAX(0.0, bounds.size.height - frame.size.height - 6.0);
    frame.origin.x = MIN(MAX(6.0, frame.origin.x), maxX);
    frame.origin.y = MIN(MAX(6.0, frame.origin.y), maxY);
    self.button.frame = frame;
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture
{
    UIButton *button = self.button;
    CGPoint translation = [gesture translationInView:button.superview];

    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.dragging = YES;
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        CGPoint center = button.center;
        center.x += translation.x;
        center.y += translation.y;
        button.center = center;
        [gesture setTranslation:CGPointZero inView:button.superview];
        [self clampFrameInBounds:button.superview.bounds];
    } else if (gesture.state == UIGestureRecognizerStateEnded ||
               gesture.state == UIGestureRecognizerStateCancelled) {
        self.dragging = NO;
        CGRect bounds = button.superview.bounds;
        CGFloat offsetX = bounds.size.width - button.center.x;
        CGFloat offsetY = bounds.size.height - button.center.y;
        NSUserDefaults *defaults = [self defaults];
        [defaults setDouble:offsetX forKey:kDNBButtonOffsetXKey];
        [defaults setDouble:offsetY forKey:kDNBButtonOffsetYKey];
        [defaults synchronize];
        DNBLog(@"按钮位置已保存 offset=(%.0f, %.0f)", offsetX, offsetY);
    }
}

#pragma mark 交互

- (UIViewController *)topViewController
{
    UIWindow *window = [self keyWindow];
    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController) {
        controller = controller.presentedViewController;
    }
    return controller;
}

- (void)handleTap
{
    UIViewController *top = [self topViewController];
    if (!top) {
        DNBLog(@"没有可用的根控制器，放弃打开面板");
        return;
    }
    if ([top isKindOfClass:[DNBPanelViewController class]] ||
        ([top isKindOfClass:[UINavigationController class]] &&
         [((UINavigationController *)top).viewControllers.firstObject isKindOfClass:[DNBPanelViewController class]])) {
        return;
    }

    DNBPanelViewController *panel = [[DNBPanelViewController alloc] init];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:panel];
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
        [appearance configureWithOpaqueBackground];
        appearance.backgroundColor = [UIColor colorWithRed:0.06 green:0.07 blue:0.10 alpha:1.0];
        appearance.titleTextAttributes = @{ NSForegroundColorAttributeName : [UIColor whiteColor] };
        navigation.navigationBar.standardAppearance = appearance;
        navigation.navigationBar.scrollEdgeAppearance = appearance;
    }
    if (@available(iOS 15.0, *)) {
        navigation.sheetPresentationController.detents = @[ UISheetPresentationControllerDetent.mediumDetent,
                                                            UISheetPresentationControllerDetent.largeDetent ];
        navigation.sheetPresentationController.prefersGrabberVisible = YES;
    } else {
        navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    }

    __weak typeof(self) weakSelf = self;
    panel.onDismiss = ^{
        weakSelf.button.hidden = NO;
    };

    self.button.hidden = YES;
    DNBLog(@"打开批量下载面板");
    [top presentViewController:navigation animated:YES completion:nil];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture
{
    if (gesture.state != UIGestureRecognizerStateBegan) {
        return;
    }
    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:@"DebsNewsBatch"
                                            message:@"新闻批量下载"
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"重置按钮位置" style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction *action) {
        NSUserDefaults *defaults = [self defaults];
        [defaults removeObjectForKey:kDNBButtonOffsetXKey];
        [defaults removeObjectForKey:kDNBButtonOffsetYKey];
        [defaults synchronize];
        [self attachIfNeeded];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"查看日志路径" style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction *action) {
        DNBLog(@"用户查看日志路径：%@", DNBLogPath());
        UIAlertController *tip =
            [UIAlertController alertControllerWithTitle:@"日志"
                                                message:DNBLogPath()
                                         preferredStyle:UIAlertControllerStyleAlert];
        [tip addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [[self topViewController] presentViewController:tip animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"隐藏按钮（重启 App 恢复）" style:UIAlertActionStyleDestructive
                                           handler:^(__unused UIAlertAction *action) {
        self.timer.fireDate = [NSDate distantFuture];
        self.button.hidden = YES;
        DNBLog(@"用户隐藏了悬浮按钮");
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (@available(iOS 8.0, *)) {
        sheet.popoverPresentationController.sourceView = self.button;
        sheet.popoverPresentationController.sourceRect = self.button.bounds;
    }
    [[self topViewController] presentViewController:sheet animated:YES completion:nil];
}

@end
