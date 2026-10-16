// Included after TKSettingsController. UIKit material only; compatible with iOS 15.
@interface TKGlassPopupController : UIViewController
@property(nonatomic,strong) UIControl *shade;
@property(nonatomic,strong) UIView *card;
@property(nonatomic,strong) UIVisualEffectView *glass;
@property(nonatomic,strong) UINavigationController *navigation;
@property(nonatomic) CGFloat keyboardTop;
@property(nonatomic) BOOL closing;
- (void)closePopup;
@end
@implementation TKGlassPopupController
- (instancetype)init {if((self=[super init])){self.modalPresentationStyle=UIModalPresentationOverFullScreen;self.modalTransitionStyle=UIModalTransitionStyleCrossDissolve;}return self;}
- (void)viewDidLoad {
    [super viewDidLoad];self.view.backgroundColor=UIColor.clearColor;self.view.accessibilityViewIsModal=YES;
    self.shade=[UIControl new];self.shade.backgroundColor=[UIColor.blackColor colorWithAlphaComponent:.38];self.shade.accessibilityLabel=@"关闭设置弹窗";
    [self.shade addTarget:self action:@selector(closePopup) forControlEvents:UIControlEventTouchUpInside];[self.view addSubview:self.shade];
    self.card=[UIView new];self.card.backgroundColor=UIColor.clearColor;self.card.layer.cornerRadius=28;self.card.layer.cornerCurve=kCACornerCurveContinuous;
    self.card.layer.shadowColor=UIColor.blackColor.CGColor;self.card.layer.shadowOpacity=.23;self.card.layer.shadowRadius=26;self.card.layer.shadowOffset=CGSizeMake(0,12);[self.view addSubview:self.card];
    self.glass=[[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    self.glass.layer.cornerRadius=28;self.glass.layer.cornerCurve=kCACornerCurveContinuous;self.glass.clipsToBounds=YES;self.glass.layer.borderWidth=.75;[self.card addSubview:self.glass];
    self.navigation=[[UINavigationController alloc] initWithRootViewController:[TKSettingsController new]];
    self.navigation.view.backgroundColor=UIColor.clearColor;self.navigation.navigationBar.prefersLargeTitles=NO;self.navigation.navigationBar.tintColor=UIColor.systemBlueColor;
    UINavigationBarAppearance *appearance=[UINavigationBarAppearance new];[appearance configureWithTransparentBackground];appearance.shadowColor=UIColor.clearColor;
    appearance.titleTextAttributes=@{NSForegroundColorAttributeName:UIColor.labelColor,NSFontAttributeName:[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]};
    self.navigation.navigationBar.standardAppearance=appearance;self.navigation.navigationBar.scrollEdgeAppearance=appearance;self.navigation.navigationBar.compactAppearance=appearance;
    [self addChildViewController:self.navigation];[self.glass.contentView addSubview:self.navigation.view];[self.navigation didMoveToParentViewController:self];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboardChanged:) name:UIKeyboardWillChangeFrameNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboardHidden:) name:UIKeyboardWillHideNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateAccessibility:) name:UIAccessibilityReduceTransparencyStatusDidChangeNotification object:nil];
    [self updateGlass];
}
- (void)updateGlass {
    BOOL dark=self.traitCollection.userInterfaceStyle==UIUserInterfaceStyleDark;
    self.glass.layer.borderColor=[UIColor colorWithWhite:1 alpha:dark?.15:.55].CGColor;
    // 1.0.6: 卡片内容底色改为近不透明，避免底层 TIM 聊天内容透出与设置文字重叠。
    self.glass.contentView.backgroundColor=UIAccessibilityIsReduceTransparencyEnabled()?UIColor.systemBackgroundColor:[UIColor colorWithWhite:dark?0.07:1 alpha:dark?.94:.96];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {[super traitCollectionDidChange:previous];[self updateGlass];}
- (void)updateAccessibility:(NSNotification *)notification {[self updateGlass];}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];self.shade.frame=self.view.bounds;
    CGRect safe=UIEdgeInsetsInsetRect(self.view.bounds,self.view.safeAreaInsets);
    // 1.0.7: 卡片尺寸固定（只受屏幕约束），键盘只负责上移卡片，不再缩放，避免“变小又变大”。
    CGFloat w=MAX(0,MIN(430,safe.size.width-24));
    CGFloat h=MAX(280,MIN(640,safe.size.height-130));
    CGFloat cx=CGRectGetMidX(safe),cy=CGRectGetMidY(safe);
    CGRect card=CGRectMake(cx-w/2,cy-h/2,w,h);
    if(self.keyboardTop>CGRectGetMinY(card)+40) {
        CGFloat top=MAX(CGRectGetMinY(safe),self.keyboardTop-h-10);
        if(top<CGRectGetMinY(card))card=CGRectMake(cx-w/2,top,w,h);
    }
    self.card.frame=card;
    self.glass.frame=self.card.bounds;self.navigation.view.frame=self.glass.contentView.bounds;
    self.card.layer.shadowPath=[UIBezierPath bezierPathWithRoundedRect:self.card.bounds cornerRadius:28].CGPath;
}
- (void)keyboardChanged:(NSNotification *)n {
    CGRect frame=[n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];frame=[self.view convertRect:frame fromView:nil];
    self.keyboardTop=CGRectIntersectsRect(frame,self.view.bounds)?CGRectGetMinY(frame):0;[self.view setNeedsLayout];
    [UIView animateWithDuration:.24 animations:^{[self.view layoutIfNeeded];}];
}
- (void)keyboardHidden:(NSNotification *)n {self.keyboardTop=0;[self.view setNeedsLayout];[UIView animateWithDuration:.24 animations:^{[self.view layoutIfNeeded];}];}
- (void)viewDidAppear:(BOOL)animated {[super viewDidAppear:animated];UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification,self.navigation.topViewController.view);}
- (void)closePopup {if(self.closing)return;self.closing=YES;[self.view endEditing:YES];[self dismissViewControllerAnimated:YES completion:nil];}
- (BOOL)accessibilityPerformEscape {[self closePopup];return YES;}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];}
@end
static void TKDismissSettings(UIViewController *controller) {
    UIViewController *parent=controller;while(parent && ![parent isKindOfClass:TKGlassPopupController.class])parent=parent.parentViewController;
    if(parent)[(TKGlassPopupController *)parent closePopup];else [controller dismissViewControllerAnimated:YES completion:nil];
}
