#import "MiniSightChatPanel.h"

static const CGFloat kMSChatCardInset = 8.0;
static const CGFloat kMSChatMaxMessages = 30.0;
static const CGFloat kMSChatCorner = 22.0;

typedef NS_ENUM(NSInteger, MiniSightChatRole) {
    MiniSightChatRoleAssistant = 0,
    MiniSightChatRoleUser,
    MiniSightChatRoleNotice
};

static UIColor *MSChatColor(UIColor *light, UIColor *dark) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
    }];
}

static CGRect MSChatScreenRect(UIWindowScene *scene) {
    CGRect bounds = UIScreen.mainScreen.bounds;
    UIInterfaceOrientation orientation = scene.interfaceOrientation;
    if (orientation == UIInterfaceOrientationUnknown) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        orientation = UIApplication.sharedApplication.statusBarOrientation;
#pragma clang diagnostic pop
    }
    if (UIInterfaceOrientationIsLandscape(orientation)) {
        return CGRectMake(0, 0, MAX(bounds.size.width, bounds.size.height),
                          MIN(bounds.size.width, bounds.size.height));
    }
    return CGRectMake(0, 0, MIN(bounds.size.width, bounds.size.height),
                      MAX(bounds.size.width, bounds.size.height));
}

#pragma mark - Key-capable window

/// Separate from MiniSightWindow on purpose: the pet window must stay non-key
/// so the desktop keeps focus, while the chat needs the keyboard.
@interface MiniSightChatWindow : UIWindow
@end

@implementation MiniSightChatWindow
- (BOOL)canBecomeKeyWindow { return YES; }
@end

#pragma mark - Panel

@interface MiniSightChatPanel () <UITextFieldDelegate>
@property (nonatomic, strong, nullable) MiniSightChatWindow *window;
@property (nonatomic, strong, nullable) UIView *dimView;
@property (nonatomic, strong, nullable) UIView *cardView;
@property (nonatomic, strong, nullable) UIScrollView *scrollView;
@property (nonatomic, strong, nullable) UIStackView *messageStack;
@property (nonatomic, strong, nullable) UITextField *inputField;
@property (nonatomic, strong, nullable) UIButton *sendButton;
@property (nonatomic, strong, nullable) UIButton *cancelButton;
@property (nonatomic, strong, nullable) NSLayoutConstraint *cardBottomConstraint;
@property (nonatomic, strong, nullable) NSLayoutConstraint *cardHeightConstraint;
@property (nonatomic, strong, nullable) NSLayoutConstraint *cancelWidthConstraint;
@property (nonatomic, strong, nullable) NSMutableArray<UIView *> *rows;
@property (nonatomic, strong, nullable) MiniSightAI *ai;
@property (nonatomic, weak, nullable) UIWindow *previousKeyWindow;
@property (nonatomic, assign) BOOL built;
@property (nonatomic, assign) BOOL visible;
@property (nonatomic, assign) BOOL sending;
@property (nonatomic, assign) CGFloat keyboardOverlap;
@end

@implementation MiniSightChatPanel

+ (instancetype)sharedPanel {
    static MiniSightChatPanel *panel;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ panel = [[MiniSightChatPanel alloc] init]; });
    return panel;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _rows = [NSMutableArray array];
    return self;
}

- (BOOL)isVisible { return self.visible; }
- (BOOL)isSending { return self.sending; }

#pragma mark Build

- (void)buildUI {
    NSCAssert([NSThread isMainThread], @"chat panel UI is main-thread owned");
    if (self.built) return;
    self.built = YES;

    CGRect screen = MSChatScreenRect(nil);
    MiniSightChatWindow *window = [[MiniSightChatWindow alloc] initWithFrame:screen];
    window.windowLevel = UIWindowLevelAlert + 2.0;
    window.backgroundColor = UIColor.clearColor;
    window.opaque = NO;
    window.hidden = YES;
    window.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = [self findScene];
        if (scene) window.windowScene = scene;
    }

    UIViewController *controller = [[UIViewController alloc] init];
    UIView *root = [[UIView alloc] initWithFrame:screen];
    root.backgroundColor = UIColor.clearColor;
    controller.view = root;
    window.rootViewController = controller;

    // Dim background: any tap outside the card closes the panel.
    UIView *dim = [[UIView alloc] initWithFrame:screen];
    dim.translatesAutoresizingMaskIntoConstraints = NO;
    dim.backgroundColor = MSChatColor([UIColor colorWithWhite:0.0 alpha:0.28],
                                      [UIColor colorWithWhite:0.0 alpha:0.52]);
    [root addSubview:dim];
    [dim.topAnchor constraintEqualToAnchor:root.topAnchor].active = YES;
    [dim.leadingAnchor constraintEqualToAnchor:root.leadingAnchor].active = YES;
    [dim.trailingAnchor constraintEqualToAnchor:root.trailingAnchor].active = YES;
    [dim.bottomAnchor constraintEqualToAnchor:root.bottomAnchor].active = YES;
    [dim addGestureRecognizer:[[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(backgroundTapped)]];

    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = MSChatColor([UIColor colorWithWhite:0.98 alpha:1.0],
                                       [UIColor colorWithWhite:0.10 alpha:1.0]);
    card.layer.cornerRadius = kMSChatCorner;
    card.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    card.clipsToBounds = YES;
    [root addSubview:card];
    self.cardView = card;

    [card.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:kMSChatCardInset].active = YES;
    [card.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-kMSChatCardInset].active = YES;
    NSLayoutConstraint *topLimit = [card.topAnchor constraintGreaterThanOrEqualToAnchor:
        root.safeAreaLayoutGuide.topAnchor constant:8.0];
    topLimit.priority = UILayoutPriorityRequired;
    topLimit.active = YES;

    NSLayoutConstraint *height = [card.heightAnchor constraintEqualToConstant:420.0];
    height.priority = UILayoutPriorityDefaultHigh;
    height.active = YES;
    self.cardHeightConstraint = height;

    NSLayoutConstraint *bottom = [card.bottomAnchor constraintEqualToAnchor:
        root.safeAreaLayoutGuide.bottomAnchor constant:-16.0];
    bottom.active = YES;
    self.cardBottomConstraint = bottom;

    // Header
    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"MiniSight AI";
    title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    title.textColor = MSChatColor(UIColor.blackColor, UIColor.whiteColor);
    [card addSubview:title];

    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
    clear.translatesAutoresizingMaskIntoConstraints = NO;
    [clear setTitle:@"清空" forState:UIControlStateNormal];
    clear.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [clear addTarget:self action:@selector(clearConversation) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:clear];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [close addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:close];

    [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16].active = YES;
    [title.centerYAnchor constraintEqualToAnchor:close.centerYAnchor].active = YES;
    [title.trailingAnchor constraintLessThanOrEqualToAnchor:clear.leadingAnchor constant:-8].active = YES;
    [clear.centerYAnchor constraintEqualToAnchor:close.centerYAnchor].active = YES;
    [clear.trailingAnchor constraintEqualToAnchor:close.leadingAnchor constant:-6].active = YES;
    [clear.widthAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [close.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12].active = YES;
    [close.topAnchor constraintEqualToAnchor:card.topAnchor constant:8].active = YES;
    [close.widthAnchor constraintEqualToConstant:34].active = YES;
    [close.heightAnchor constraintEqualToConstant:34].active = YES;

    UIView *separator = [[UIView alloc] init];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = MSChatColor([UIColor colorWithWhite:0.0 alpha:0.08],
                                            [UIColor colorWithWhite:1.0 alpha:0.12]);
    [card addSubview:separator];
    [separator.topAnchor constraintEqualToAnchor:close.bottomAnchor constant:6].active = YES;
    [separator.leadingAnchor constraintEqualToAnchor:card.leadingAnchor].active = YES;
    [separator.trailingAnchor constraintEqualToAnchor:card.trailingAnchor].active = YES;
    [separator.heightAnchor constraintEqualToConstant:0.5].active = YES;

    // Messages
    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [card addSubview:scroll];
    self.scrollView = scroll;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8.0;
    stack.alignment = UIStackViewAlignmentFill;
    [scroll addSubview:stack];
    self.messageStack = stack;

    [scroll.topAnchor constraintEqualToAnchor:separator.bottomAnchor constant:8].active = YES;
    [scroll.leadingAnchor constraintEqualToAnchor:card.leadingAnchor].active = YES;
    [scroll.trailingAnchor constraintEqualToAnchor:card.trailingAnchor].active = YES;
    [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:8].active = YES;
    [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:12].active = YES;
    [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-12].active = YES;
    [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-8].active = YES;
    [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-24].active = YES;

    // Composer
    UIView *composer = [[UIView alloc] init];
    composer.translatesAutoresizingMaskIntoConstraints = NO;
    composer.backgroundColor = MSChatColor([UIColor colorWithWhite:1.0 alpha:0.6],
                                           [UIColor colorWithWhite:0.14 alpha:0.9]);
    [card addSubview:composer];

    [composer.topAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:6].active = YES;
    [composer.leadingAnchor constraintEqualToAnchor:card.leadingAnchor].active = YES;
    [composer.trailingAnchor constraintEqualToAnchor:card.trailingAnchor].active = YES;
    [composer.bottomAnchor constraintEqualToAnchor:card.bottomAnchor].active = YES;
    [composer.heightAnchor constraintEqualToConstant:56].active = YES;

    UITextField *field = [[UITextField alloc] init];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.delegate = self;
    field.returnKeyType = UIReturnKeySend;
    field.borderStyle = UITextBorderStyleNone;
    field.font = [UIFont systemFontOfSize:15];
    field.textColor = MSChatColor(UIColor.blackColor, UIColor.whiteColor);
    field.backgroundColor = MSChatColor([UIColor colorWithWhite:0.0 alpha:0.06],
                                        [UIColor colorWithWhite:1.0 alpha:0.10]);
    field.layer.cornerRadius = 10.0;
    field.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
    field.leftViewMode = UITextFieldViewModeAlways;
    field.placeholder = @"和 MiniSight 说点什么";
    field.textContentType = nil;
    field.autocapitalizationType = UITextAutocapitalizationTypeSentences;
    [field addTarget:self action:@selector(inputChanged) forControlEvents:UIControlEventEditingChanged];
    [composer addSubview:field];
    self.inputField = field;

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    cancel.translatesAutoresizingMaskIntoConstraints = NO;
    [cancel setTitle:@"取消" forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [cancel addTarget:self action:@selector(cancelSend) forControlEvents:UIControlEventTouchUpInside];
    cancel.hidden = YES;
    [composer addSubview:cancel];
    self.cancelButton = cancel;

    UIButton *send = [UIButton buttonWithType:UIButtonTypeSystem];
    send.translatesAutoresizingMaskIntoConstraints = NO;
    [send setTitle:@"发送" forState:UIControlStateNormal];
    [send setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    send.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    send.backgroundColor = MSChatColor([UIColor colorWithRed:0.13 green:0.45 blue:0.95 alpha:1.0],
                                       [UIColor colorWithRed:0.30 green:0.58 blue:1.0 alpha:1.0]);
    send.layer.cornerRadius = 10.0;
    send.enabled = NO;
    send.alpha = 0.45;
    [send addTarget:self action:@selector(sendTapped) forControlEvents:UIControlEventTouchUpInside];
    [composer addSubview:send];
    self.sendButton = send;

    [field.leadingAnchor constraintEqualToAnchor:composer.leadingAnchor constant:12].active = YES;
    [field.centerYAnchor constraintEqualToAnchor:composer.centerYAnchor].active = YES;
    [field.heightAnchor constraintEqualToConstant:36].active = YES;

    [cancel.centerYAnchor constraintEqualToAnchor:composer.centerYAnchor].active = YES;
    [cancel.trailingAnchor constraintEqualToAnchor:send.leadingAnchor constant:-8].active = YES;
    NSLayoutConstraint *cancelWidth = [cancel.widthAnchor constraintEqualToConstant:0];
    cancelWidth.active = YES;
    self.cancelWidthConstraint = cancelWidth;

    [send.centerYAnchor constraintEqualToAnchor:composer.centerYAnchor].active = YES;
    [send.trailingAnchor constraintEqualToAnchor:composer.trailingAnchor constant:-12].active = YES;
    [send.widthAnchor constraintEqualToConstant:52].active = YES;
    [send.heightAnchor constraintEqualToConstant:36].active = YES;

    [field.trailingAnchor constraintEqualToAnchor:cancel.leadingAnchor constant:-8].active = YES;

    self.window = window;
    [self appendNotice:@"你好，我是 MiniSight 👋 有什么想聊的？"];
}

#pragma mark Presentation

+ (BOOL)showInWindowScene:(UIWindowScene *)scene {
    return [[self sharedPanel] showInWindowScene:scene];
}

- (BOOL)showInWindowScene:(UIWindowScene *)scene {
    NSCAssert([NSThread isMainThread], @"chat panel is main-thread only");
    if (!self.built) [self buildUI];
    if (!self.window) return NO;
    if (self.visible) {
        [self.window makeKeyWindow];
        [self.inputField becomeFirstResponder];
        return YES;
    }
    UIWindowScene *target = scene ?: [self findScene];
    if (!target) return NO;
    if (self.window.windowScene != target) self.window.windowScene = target;

    for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
        if (candidate != self.window && candidate.isKeyWindow) {
            self.previousKeyWindow = candidate;
            break;
        }
    }
    self.ai.containerPath = self.containerPath;
    self.keyboardOverlap = 0;
    self.visible = YES;
    [self layoutForCurrentScreen];
    self.window.hidden = NO;
    [self.window makeKeyAndVisible];
    [self.window becomeKeyWindow];
    [self observeKeyboard:YES];
    [self.inputField becomeFirstResponder];
    if (self.visibilityHandler) self.visibilityHandler(YES);
    return YES;
}

- (void)close {
    NSCAssert([NSThread isMainThread], @"chat panel is main-thread only");
    if (!self.visible) return;
    self.visible = NO;
    [self endSendingUI];
    [self.ai cancel];                       // synchronous Cancelled reply is ignored (not visible)
    [self.inputField resignFirstResponder];
    [self observeKeyboard:NO];
    [self.window resignKeyWindow];
    self.window.hidden = YES;
    if (self.visibilityHandler) self.visibilityHandler(NO);
    UIWindow *previous = self.previousKeyWindow;
    if (previous && previous.windowScene == self.window.windowScene && previous.canBecomeKeyWindow) {
        [previous makeKeyWindow];
    }
    self.previousKeyWindow = nil;
}

- (void)backgroundTapped {
    [self close];
}

#pragma mark Layout

- (UIWindowScene *)findScene {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class] &&
                scene.activationState == UISceneActivationStateForegroundActive) {
                return (UIWindowScene *)scene;
            }
        }
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)scene;
        }
    }
    return nil;
}

- (CGFloat)preferredCardHeightForSize:(CGSize)size {
    BOOL landscape = size.width > size.height;
    CGFloat height = landscape ? size.height * 0.76 : size.height * 0.58;
    return MIN(MAX(260.0, height), 470.0);
}

- (void)layoutForCurrentScreen {
    if (!self.window) return;
    CGRect screen = MSChatScreenRect(self.window.windowScene);
    self.window.frame = screen;
    self.cardHeightConstraint.constant = [self preferredCardHeightForSize:screen.size];
    [self updateCardBottomAnimated:NO];
}

- (void)updateCardBottomAnimated:(BOOL)animated {
    if (!self.cardBottomConstraint) return;
    CGFloat safe = MAX(self.window.safeAreaInsets.bottom, 8.0);
    CGFloat offset = self.keyboardOverlap > 0 ? self.keyboardOverlap + 8.0 : safe + 8.0;
    self.cardBottomConstraint.constant = -offset;
    if (!animated) {
        [self.window layoutIfNeeded];
        return;
    }
    [UIView animateWithDuration:0.24 delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ [self.window layoutIfNeeded]; } completion:nil];
}

#pragma mark Keyboard

- (void)observeKeyboard:(BOOL)observe {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center removeObserver:self name:UIKeyboardWillChangeFrameNotification object:nil];
    [center removeObserver:self name:UIKeyboardWillHideNotification object:nil];
    [center removeObserver:self name:UIDeviceOrientationDidChangeNotification object:nil];
    [center removeObserver:self name:UIApplicationDidChangeStatusBarOrientationNotification object:nil];
    if (!observe) return;
    [center addObserver:self selector:@selector(keyboardWillChangeFrame:)
                   name:UIKeyboardWillChangeFrameNotification object:nil];
    [center addObserver:self selector:@selector(keyboardWillHide:)
                   name:UIKeyboardWillHideNotification object:nil];
    [center addObserver:self selector:@selector(orientationChanged)
                   name:UIDeviceOrientationDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(orientationChanged)
                   name:UIApplicationDidChangeStatusBarOrientationNotification object:nil];
}

- (void)keyboardWillChangeFrame:(NSNotification *)note {
    CGRect end = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect local = [self.window convertRect:end fromWindow:nil];
    CGFloat overlap = MAX(0.0, CGRectGetMaxY(self.window.bounds) - CGRectGetMinY(local));
    if (CGRectGetMinY(local) >= CGRectGetMaxY(self.window.bounds) - 0.5) overlap = 0.0;
    self.keyboardOverlap = overlap;
    [self updateCardBottomAnimated:YES];
}

- (void)keyboardWillHide:(NSNotification *)note {
    self.keyboardOverlap = 0;
    [self updateCardBottomAnimated:YES];
}

- (void)orientationChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self layoutForCurrentScreen];
    });
}

#pragma mark Messages

- (void)appendMessage:(NSString *)text role:(MiniSightChatRole)role {
    if (!text.length || !self.messageStack) return;
    BOOL isUser = role == MiniSightChatRoleUser;

    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *bubble = [[UIView alloc] init];
    bubble.translatesAutoresizingMaskIntoConstraints = NO;
    bubble.layer.cornerRadius = 14.0;
    bubble.clipsToBounds = YES;
    if (isUser) {
        bubble.backgroundColor = MSChatColor([UIColor colorWithRed:0.13 green:0.45 blue:0.95 alpha:1.0],
                                             [UIColor colorWithRed:0.24 green:0.50 blue:0.96 alpha:1.0]);
    } else if (role == MiniSightChatRoleNotice) {
        bubble.backgroundColor = UIColor.clearColor;
    } else {
        bubble.backgroundColor = MSChatColor([UIColor colorWithWhite:0.0 alpha:0.055],
                                             [UIColor colorWithWhite:1.0 alpha:0.11]);
    }

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.numberOfLines = 0;
    label.font = [UIFont systemFontOfSize:15];
    label.text = text;
    label.textColor = isUser ? UIColor.whiteColor
        : MSChatColor([UIColor colorWithWhite:0.1 alpha:1.0], [UIColor colorWithWhite:0.94 alpha:1.0]);
    if (role == MiniSightChatRoleNotice) {
        label.font = [UIFont systemFontOfSize:13];
        label.textColor = MSChatColor([UIColor colorWithWhite:0.35 alpha:1.0],
                                      [UIColor colorWithWhite:0.65 alpha:1.0]);
        label.textAlignment = NSTextAlignmentCenter;
    }
    [bubble addSubview:label];
    [row addSubview:bubble];
    [self.messageStack addArrangedSubview:row];
    [self.rows addObject:row];

    [row.topAnchor constraintEqualToAnchor:bubble.topAnchor].active = YES;
    [row.bottomAnchor constraintEqualToAnchor:bubble.bottomAnchor].active = YES;
    [bubble.topAnchor constraintEqualToAnchor:row.topAnchor].active = YES;
    [bubble.bottomAnchor constraintEqualToAnchor:row.bottomAnchor].active = YES;
    [label.topAnchor constraintEqualToAnchor:bubble.topAnchor constant:8].active = YES;
    [label.bottomAnchor constraintEqualToAnchor:bubble.bottomAnchor constant:-8].active = YES;
    [label.leadingAnchor constraintEqualToAnchor:bubble.leadingAnchor constant:11].active = YES;
    [label.trailingAnchor constraintEqualToAnchor:bubble.trailingAnchor constant:-11].active = YES;
    [label.widthAnchor constraintLessThanOrEqualToAnchor:self.cardView.widthAnchor multiplier:0.78].active = YES;

    if (isUser) {
        [bubble.trailingAnchor constraintEqualToAnchor:row.trailingAnchor].active = YES;
        [bubble.leadingAnchor constraintGreaterThanOrEqualToAnchor:row.leadingAnchor constant:36].active = YES;
    } else if (role == MiniSightChatRoleNotice) {
        [bubble.centerXAnchor constraintEqualToAnchor:row.centerXAnchor].active = YES;
        [bubble.leadingAnchor constraintGreaterThanOrEqualToAnchor:row.leadingAnchor].active = YES;
        [bubble.trailingAnchor constraintLessThanOrEqualToAnchor:row.trailingAnchor].active = YES;
    } else {
        [bubble.leadingAnchor constraintEqualToAnchor:row.leadingAnchor].active = YES;
        [bubble.trailingAnchor constraintLessThanOrEqualToAnchor:row.trailingAnchor constant:-36].active = YES;
    }

    [self trimMessages];
    [self scrollToBottom];
}

- (void)appendNotice:(NSString *)text {
    [self appendMessage:text role:MiniSightChatRoleNotice];
}

- (void)appendError:(NSString *)text {
    [self appendMessage:[@"⚠︎ " stringByAppendingString:text] role:MiniSightChatRoleAssistant];
}

- (void)trimMessages {
    while (self.rows.count > (NSUInteger)kMSChatMaxMessages) {
        UIView *oldest = self.rows.firstObject;
        [self.rows removeObjectAtIndex:0];
        [oldest removeFromSuperview];
    }
}

- (void)scrollToBottom {
    [self.window layoutIfNeeded];
    CGFloat bottom = MAX(0.0, self.scrollView.contentSize.height -
                         self.scrollView.bounds.size.height + self.scrollView.contentInset.bottom);
    [self.scrollView setContentOffset:CGPointMake(0, bottom) animated:YES];
}

#pragma mark Composer

- (void)inputChanged {
    BOOL hasText = [self.inputField.text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]].length > 0;
    self.sendButton.enabled = hasText && !self.sending;
    self.sendButton.alpha = self.sendButton.enabled ? 1.0 : 0.45;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self sendTapped];
    return NO;
}

- (void)sendTapped {
    NSCAssert([NSThread isMainThread], @"chat panel is main-thread only");
    if (self.sending) return;
    NSString *text = [self.inputField.text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length) return;

    [self appendMessage:text role:MiniSightChatRoleUser];
    self.inputField.text = @"";
    [self beginSendingUI];
    self.ai.containerPath = self.containerPath;
    __weak typeof(self) weakSelf = self;
    [self.ai sendUserText:text completion:^(MiniSightAIReply *reply) {
        [weakSelf handleReply:reply];
    }];
}

- (void)beginSendingUI {
    self.sending = YES;
    self.sendButton.enabled = NO;
    self.sendButton.alpha = 0.45;
    self.cancelButton.hidden = NO;
    self.cancelWidthConstraint.constant = 46.0;
}

- (void)endSendingUI {
    self.sending = NO;
    self.cancelButton.hidden = YES;
    self.cancelWidthConstraint.constant = 0.0;
    [self inputChanged];
}

- (void)cancelSend {
    if (!self.sending) return;
    [self endSendingUI];
    [self.ai cancel];
    [self appendNotice:@"已取消"];
}

- (void)handleReply:(MiniSightAIReply *)reply {
    if (!self.visible || !self.sending) return;   // closed or cancelled meanwhile
    [self endSendingUI];
    if (reply.isSuccess) {
        [self appendMessage:reply.text role:MiniSightChatRoleAssistant];
        if (self.replyHandler) self.replyHandler(reply.text);
        return;
    }
    if (reply.issue == MiniSightAIIssueCancelled) return;
    [self appendError:reply.displayText];
    if (self.errorHandler) self.errorHandler(reply.displayText, reply.issue);
}

#pragma mark Clear

- (void)clearConversation {
    if (self.sending) {
        [self endSendingUI];
        [self.ai cancel];
    }
    [self.ai resetConversation];
    for (UIView *row in self.rows) [row removeFromSuperview];
    [self.rows removeAllObjects];
    [self appendNotice:@"对话已清空，重新开始吧"];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

@end
