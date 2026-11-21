#import "LCSCellularPanel.h"
#import "LCSCellularSettings.h"

static CGFloat LCSCardTextScale(void) {
    return (CGFloat)LCSCellularCardScale([[UIFontMetrics defaultMetrics] scaledValueForValue:15.0]/15.0);
}
static UIFont *LCSCardFont(CGFloat size,UIFontWeight weight) {
    return [[UIFontMetrics defaultMetrics] scaledFontForFont:[UIFont systemFontOfSize:size weight:weight] maximumPointSize:size*2.5];
}
static NSString *LCSBadgeText(LCSCellularBadge badge) {
    switch(badge) {
        case LCSCellularBadgeSIMOn:return @"已开启";
        case LCSCellularBadgeSIMOff:return @"已关闭";
        case LCSCellularBadgeDataCurrent:return @"使用中";
        case LCSCellularBadgeDataOther:return @"未选用";
        default:return @"未知";
    }
}
@interface LCSCellularStatusRow : UIControl
@property(nonatomic,strong) UIView *pill;
@property(nonatomic,strong) UILabel *badgeLabel;
@property(nonatomic,strong) UILabel *nameLabel;
- (void)updateLine:(LCSCellularLine *)line kind:(LCSCellularKind)kind busy:(BOOL)busy;
@end
@implementation LCSCellularStatusRow
- (instancetype)initWithFrame:(CGRect)frame {
    if(!(self=[super initWithFrame:frame]))return nil;
    self.isAccessibilityElement=YES;self.accessibilityTraits=UIAccessibilityTraitButton;
    self.pill=[UIView new];self.pill.layer.cornerRadius=11;self.pill.clipsToBounds=YES;
    self.badgeLabel=[UILabel new];self.badgeLabel.textColor=UIColor.whiteColor;self.badgeLabel.textAlignment=NSTextAlignmentCenter;self.badgeLabel.adjustsFontForContentSizeCategory=YES;
    self.badgeLabel.font=LCSCardFont(LCS_CELLULAR_CARD_PILL_FONT,UIFontWeightSemibold);
    self.badgeLabel.translatesAutoresizingMaskIntoConstraints=NO;[self.pill addSubview:self.badgeLabel];
    [NSLayoutConstraint activateConstraints:@[[self.badgeLabel.leadingAnchor constraintEqualToAnchor:self.pill.leadingAnchor constant:12],[self.badgeLabel.trailingAnchor constraintEqualToAnchor:self.pill.trailingAnchor constant:-12],[self.badgeLabel.topAnchor constraintEqualToAnchor:self.pill.topAnchor constant:3],[self.badgeLabel.bottomAnchor constraintEqualToAnchor:self.pill.bottomAnchor constant:-3],[self.pill.heightAnchor constraintGreaterThanOrEqualToConstant:22]]];
    [self.pill setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.pill setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    self.nameLabel=[UILabel new];self.nameLabel.textColor=UIColor.whiteColor;self.nameLabel.font=LCSCardFont(LCS_CELLULAR_CARD_NAME_FONT,UIFontWeightSemibold);self.nameLabel.numberOfLines=2;self.nameLabel.adjustsFontForContentSizeCategory=YES;
    UIStackView *group=[[UIStackView alloc] initWithArrangedSubviews:@[self.pill,self.nameLabel]];group.spacing=12;group.alignment=UIStackViewAlignmentCenter;group.translatesAutoresizingMaskIntoConstraints=NO;group.userInteractionEnabled=NO;
    [self addSubview:group];[NSLayoutConstraint activateConstraints:@[[group.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],[group.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],[group.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:20],[group.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-20]]];
    return self;
}
- (void)layoutSubviews {[super layoutSubviews];self.pill.layer.cornerRadius=MIN(16,CGRectGetHeight(self.pill.bounds)/2);}
- (void)setHighlighted:(BOOL)highlighted {[super setHighlighted:highlighted];self.backgroundColor=highlighted?[UIColor colorWithWhite:1 alpha:.10]:UIColor.clearColor;}
- (void)updateLine:(LCSCellularLine *)line kind:(LCSCellularKind)kind busy:(BOOL)busy {
    BOOL known=kind==LCSCellularSIMManager?line.stateKnown:line.selectionKnown;
    BOOL observed=kind==LCSCellularSIMManager?line.enabled:line.selected;
    LCSCellularBadge badge=LCSCellularCardBadge(kind,known,observed);
    self.badgeLabel.text=LCSBadgeText(badge);self.nameLabel.text=line.name.length?line.name:[NSString stringWithFormat:@"SIM %ld",(long)line.slot];
    self.pill.backgroundColor=LCSCellularCardBadgeGreen(badge)?[UIColor colorWithRed:.19 green:.79 blue:.34 alpha:1]:[UIColor colorWithWhite:1 alpha:.18];
    self.enabled=line.available&&known&&!busy;self.alpha=self.enabled?1:.65;
    self.accessibilityLabel=[NSString stringWithFormat:@"SIM %ld，%@",(long)line.slot,self.nameLabel.text];self.accessibilityValue=self.badgeLabel.text;
    self.accessibilityHint=!known?@"状态未知，暂不可操作":(!line.available?@"此线路当前不可操作":(kind==LCSCellularSIMManager?@"轻点更改线路启停，停用前需要确认":(observed?@"当前上网线路":@"轻点选择此 SIM 上网")));
    self.accessibilityTraits=UIAccessibilityTraitButton|(self.enabled?0:UIAccessibilityTraitNotEnabled);
}
@end

@interface LCSCellularPanelController ()
@property(nonatomic) LCSCellularKind kind;
@property(nonatomic,strong) LCSCellularService *service;
@property(nonatomic,strong) LCSCellularToken *token;
@property(nonatomic,strong) UIView *card;
@property(nonatomic,strong) UIButton *headerButton;
@property(nonatomic,strong) UIImageView *glyph;
@property(nonatomic,strong) UILabel *heading;
@property(nonatomic,strong) NSArray<LCSCellularStatusRow *> *rows;
@property(nonatomic,strong) UIStackView *rowStack;
@property(nonatomic,strong) UIStackView *noticeStack;
@property(nonatomic,strong) UIButton *retryButton;
@property(nonatomic,strong) NSLayoutConstraint *cardHeight;
@property(nonatomic,strong) NSLayoutConstraint *headerHeight;
@property(nonatomic,strong) NSArray<NSLayoutConstraint *> *rowHeights;
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) UIActivityIndicatorView *spinner;
@property(nonatomic,copy) NSArray<LCSCellularLine *> *lines;
@property(nonatomic,strong) NSTimer *guardTimer;
@property(nonatomic,strong) NSMutableArray *observers;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL active;
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL notifiedClose;
@end
@implementation LCSCellularPanelController
- (instancetype)initWithKind:(LCSCellularKind)kind {
    if(!(self=[super initWithNibName:nil bundle:nil]))return nil;
    _kind=kind;_service=[[LCSCellularService alloc] initWithKind:kind];_lines=@[];
    self.modalPresentationStyle=UIModalPresentationOverFullScreen;self.modalTransitionStyle=UIModalTransitionStyleCrossDissolve;
    self.preferredContentSize=CGSizeMake(LCS_CELLULAR_CARD_WIDTH,[[self class] preferredCardHeight]);return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];self.view.backgroundColor=UIColor.clearColor;
    NSString *title=self.kind==LCSCellularSIMManager?@"蜂窝管理":@"数据切换";
    if(self.kind==LCSCellularSIMManager) {
        // Modal only: blur the existing Control Center, not a newly-created window.
        UIVisualEffectView *backdrop=[[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
        backdrop.frame=self.view.bounds;backdrop.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;backdrop.userInteractionEnabled=NO;[self.view addSubview:backdrop];
        UIButton *outside=[UIButton buttonWithType:UIButtonTypeCustom];outside.frame=self.view.bounds;outside.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;outside.accessibilityLabel=@"关闭蜂窝管理";
        [outside addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];[self.view addSubview:outside];self.view.accessibilityViewIsModal=YES;
    }
    self.card=[UIView new];self.card.layer.cornerRadius=LCS_CELLULAR_CARD_RADIUS;self.card.layer.cornerCurve=kCACornerCurveContinuous;self.card.clipsToBounds=YES;self.card.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:self.card];
    if(self.kind==LCSCellularSIMManager) {
        UIVisualEffectView *material=[[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
        material.frame=self.card.bounds;material.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;material.userInteractionEnabled=NO;[self.card addSubview:material];
    }
    // The independent module uses Control Center's own expanded platter/material.
    self.card.backgroundColor=[UIColor colorWithWhite:0 alpha:self.kind==LCSCellularSIMManager?.12:.20];
    UIScrollView *scroll=[UIScrollView new];scroll.translatesAutoresizingMaskIntoConstraints=NO;scroll.alwaysBounceVertical=NO;scroll.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;[self.card addSubview:scroll];
    self.headerButton=[UIButton buttonWithType:UIButtonTypeCustom];self.headerButton.accessibilityLabel=title;self.headerButton.accessibilityHint=@"轻点刷新线路；双指划 Z 可关闭";
    [self.headerButton addTarget:self action:@selector(refresh) forControlEvents:UIControlEventTouchUpInside];
    self.glyph=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:self.kind==LCSCellularSIMManager?@"antenna.radiowaves.left.and.right":@"simcard"]];self.glyph.tintColor=UIColor.whiteColor;self.glyph.contentMode=UIViewContentModeScaleAspectFit;
    if(self.kind==LCSCellularDataSwitch) {
        self.glyph.image=[self.glyph.image imageByApplyingSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightRegular]];self.glyph.contentMode=UIViewContentModeCenter;
        self.glyph.layer.borderWidth=1;self.glyph.layer.borderColor=[UIColor colorWithWhite:1 alpha:.9].CGColor;self.glyph.layer.cornerRadius=LCS_CELLULAR_CARD_GLYPH/2;
    }
    self.heading=[UILabel new];self.heading.text=title;self.heading.font=LCSCardFont(LCS_CELLULAR_CARD_TITLE_FONT,UIFontWeightSemibold);self.heading.textColor=UIColor.whiteColor;self.heading.textAlignment=NSTextAlignmentCenter;self.heading.adjustsFontForContentSizeCategory=YES;self.heading.numberOfLines=2;
    self.spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];self.spinner.color=UIColor.whiteColor;self.spinner.hidesWhenStopped=YES;
    UIView *rule=[UIView new];rule.backgroundColor=[UIColor colorWithWhite:1 alpha:.12];
    for(UIView *v in @[self.glyph,self.heading,self.spinner,rule]){v.translatesAutoresizingMaskIntoConstraints=NO;v.userInteractionEnabled=NO;[self.headerButton addSubview:v];}
    [NSLayoutConstraint activateConstraints:@[[self.glyph.centerXAnchor constraintEqualToAnchor:self.headerButton.centerXAnchor],[self.glyph.topAnchor constraintEqualToAnchor:self.headerButton.topAnchor constant:22],[self.glyph.widthAnchor constraintEqualToConstant:LCS_CELLULAR_CARD_GLYPH],[self.glyph.heightAnchor constraintEqualToConstant:LCS_CELLULAR_CARD_GLYPH],[self.heading.topAnchor constraintEqualToAnchor:self.glyph.bottomAnchor constant:14],[self.heading.leadingAnchor constraintEqualToAnchor:self.headerButton.leadingAnchor constant:18],[self.heading.trailingAnchor constraintEqualToAnchor:self.headerButton.trailingAnchor constant:-18],[self.spinner.leadingAnchor constraintEqualToAnchor:self.glyph.trailingAnchor constant:12],[self.spinner.centerYAnchor constraintEqualToAnchor:self.glyph.centerYAnchor],[rule.bottomAnchor constraintEqualToAnchor:self.headerButton.bottomAnchor],[rule.leadingAnchor constraintEqualToAnchor:self.headerButton.leadingAnchor],[rule.trailingAnchor constraintEqualToAnchor:self.headerButton.trailingAnchor],[rule.heightAnchor constraintEqualToConstant:.5]]];
    NSMutableArray *rows=[NSMutableArray new],*heights=[NSMutableArray new];
    for(NSInteger slot=1;slot<=2;slot++) {
        LCSCellularStatusRow *row=[LCSCellularStatusRow new];row.tag=slot;[row addTarget:self action:@selector(rowPressed:) forControlEvents:UIControlEventTouchUpInside];[rows addObject:row];
        NSLayoutConstraint *height=[row.heightAnchor constraintEqualToConstant:LCSCellularCardRowHeight(LCSCardTextScale())];height.priority=999;height.active=YES;[heights addObject:height];
    }
    self.rows=rows;self.rowHeights=heights;self.rowStack=[[UIStackView alloc] initWithArrangedSubviews:rows];self.rowStack.axis=UILayoutConstraintAxisVertical;
    self.status=[UILabel new];self.status.textColor=UIColor.whiteColor;self.status.font=LCSCardFont(13,UIFontWeightRegular);self.status.adjustsFontForContentSizeCategory=YES;self.status.numberOfLines=0;self.status.textAlignment=NSTextAlignmentCenter;
    self.retryButton=[UIButton buttonWithType:UIButtonTypeSystem];[self.retryButton setTitle:@"重新读取" forState:UIControlStateNormal];[self.retryButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];[self.retryButton addTarget:self action:@selector(refresh) forControlEvents:UIControlEventTouchUpInside];NSLayoutConstraint *retryHit=[self.retryButton.heightAnchor constraintGreaterThanOrEqualToConstant:44];retryHit.priority=999;retryHit.active=YES;
    self.noticeStack=[[UIStackView alloc] initWithArrangedSubviews:@[self.status,self.retryButton]];self.noticeStack.axis=UILayoutConstraintAxisVertical;self.noticeStack.spacing=8;self.noticeStack.layoutMarginsRelativeArrangement=YES;self.noticeStack.directionalLayoutMargins=NSDirectionalEdgeInsetsMake(16,20,16,20);
    UIStackView *content=[[UIStackView alloc] initWithArrangedSubviews:@[self.headerButton,self.rowStack,self.noticeStack]];content.axis=UILayoutConstraintAxisVertical;content.translatesAutoresizingMaskIntoConstraints=NO;[scroll addSubview:content];
    UILayoutGuide *safe=self.view.safeAreaLayoutGuide;CGFloat inset=self.kind==LCSCellularSIMManager?48:0;
    NSLayoutConstraint *width=[self.card.widthAnchor constraintEqualToConstant:LCS_CELLULAR_CARD_WIDTH];width.priority=750;
    self.cardHeight=[self.card.heightAnchor constraintEqualToConstant:[[self class] preferredCardHeight]];self.cardHeight.priority=750;
    self.headerHeight=[self.headerButton.heightAnchor constraintEqualToConstant:LCSCellularCardHeaderHeight(LCSCardTextScale())];
    [NSLayoutConstraint activateConstraints:@[width,self.cardHeight,self.headerHeight,[self.card.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],[self.card.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],[self.card.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-inset],[self.card.heightAnchor constraintLessThanOrEqualToAnchor:safe.heightAnchor constant:-(self.kind==LCSCellularSIMManager?32:0)],[scroll.leadingAnchor constraintEqualToAnchor:self.card.leadingAnchor],[scroll.trailingAnchor constraintEqualToAnchor:self.card.trailingAnchor],[scroll.topAnchor constraintEqualToAnchor:self.card.topAnchor],[scroll.bottomAnchor constraintEqualToAnchor:self.card.bottomAnchor],[content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],[content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],[content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],[content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],[content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]]];
    self.noticeStack.hidden=YES;[self renderLines];
    self.observers=[NSMutableArray new];__weak typeof(self) weakSelf=self;
    for(NSString *name in @[LCSCellularPreferencesDidChange,@"SBDeviceLockStateChangedNotification",UIApplicationWillResignActiveNotification]) {
        [self.observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){
            typeof(self) s=weakSelf;if(!s||!s.active)return;
            if([note.name isEqualToString:UIApplicationWillResignActiveNotification]||![s allowed])[s close];
        }]];
    }
}
+ (CGFloat)preferredCardHeight {return (CGFloat)LCSCellularCardHeight(LCSCardTextScale());}
- (LCSCellularLine *)lineForSlot:(NSInteger)slot {
    LCSCellularLine *found=nil;NSUInteger count=0;
    for(LCSCellularLine *line in self.lines)if(line.slot==slot){found=line;count++;}
    return count==1?found:nil;
}
- (void)renderLines {
    // Badges ONLY read the last observed system model; tapping never edits it.
    for(LCSCellularStatusRow *row in self.rows) {
        LCSCellularLine *line=[self lineForSlot:row.tag];
        if(!line){line=[LCSCellularLine new];line.slot=row.tag;line.name=[NSString stringWithFormat:@"SIM %ld",(long)row.tag];}
        [row updateLine:line kind:self.kind busy:self.busy];
    }
    self.headerButton.enabled=!self.busy;
}
- (void)showNotice:(NSString *)message retry:(BOOL)retry {
    self.status.text=message;self.noticeStack.hidden=!message.length;self.rowStack.hidden=message.length>0;
    self.retryButton.hidden=!retry;self.retryButton.enabled=!self.busy;
}
- (BOOL)accessibilityPerformEscape {[self close];return YES;}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];if(!self.isViewLoaded)return;
    self.cardHeight.constant=[[self class] preferredCardHeight];self.headerHeight.constant=LCSCellularCardHeaderHeight(LCSCardTextScale());
    for(NSLayoutConstraint *height in self.rowHeights)height.constant=LCSCellularCardRowHeight(LCSCardTextScale());
    self.preferredContentSize=CGSizeMake(LCS_CELLULAR_CARD_WIDTH,[[self class] preferredCardHeight]);[self renderLines];
}
- (BOOL)allowed {
    return LCSCellularFeatureEnabled(self.kind)&&LCSCellularIsSpringBoard()&&LCSCellularIsUnlocked()&&
        NSProcessInfo.processInfo.operatingSystemVersion.majorVersion==15&&(!self.mayContinue||self.mayContinue());
}
- (BOOL)current:(NSUInteger)generation {
    return self.active&&self.generation==generation&&!self.token.cancelled&&[self allowed]&&self.isViewLoaded&&self.view.window;
}
- (void)viewDidAppear:(BOOL)animated {[super viewDidAppear:animated];if([self allowed])[self activate];}
- (void)viewDidDisappear:(BOOL)animated {[super viewDidDisappear:animated];[self deactivate];}
- (void)activate {
    if(self.active)return;
    if(![self allowed]){if(self.isViewLoaded)[self showNotice:@"功能已关闭、设备已锁定或系统不受支持。" retry:NO];return;}
    self.active=YES;self.notifiedClose=NO;__weak typeof(self) weakSelf=self;
    self.guardTimer=[NSTimer scheduledTimerWithTimeInterval:.4 repeats:YES block:^(NSTimer *timer){
        (void)timer;typeof(self) s=weakSelf;if(s&&s.active&&(![s allowed]||!s.view.window))[s close];
    }];
    [self refresh];
}
- (void)deactivate {
    self.active=NO;self.generation++;[self.token cancel];self.token=nil;self.busy=NO;
    [self.guardTimer invalidate];self.guardTimer=nil;[self.spinner stopAnimating];[self renderLines];
}
- (void)close {
    [self deactivate];
    if(!self.notifiedClose){self.notifiedClose=YES;void (^callback)(void)=self.didClose;if(callback)callback();}
    if(self.presentingViewController)[self dismissViewControllerAnimated:YES completion:nil];
}
- (void)refresh {
    if(!self.active||self.busy||![self allowed])return;
    [self.token cancel];self.token=[LCSCellularToken new];NSUInteger generation=++self.generation;self.busy=YES;
    if(!self.lines.count)[self showNotice:@"正在读取系统状态…" retry:NO];else [self showNotice:nil retry:NO];
    [self.spinner startAnimating];[self renderLines];
    __weak typeof(self) weakSelf=self;
    [self.service readWithToken:self.token completion:^(NSArray *lines,NSString *error){
        typeof(self) s=weakSelf;if(!s||![s current:generation])return;
        s.busy=NO;s.lines=lines?:@[];[s.spinner stopAnimating];
        [s showNotice:error?:(!lines.count?@"无法读取线路，请重新读取。":nil) retry:YES];
        [s renderLines];
    }];
}
- (void)rowPressed:(LCSCellularStatusRow *)row {
    LCSCellularLine *line=[[self lineForSlot:row.tag] copy];
    if(self.busy||!self.active||![self allowed]||!line.available)return;
    if(self.kind==LCSCellularDataSwitch) {
        if(line.selectionKnown&&!line.selected)[self applyLine:line desired:YES confirmed:YES];return;
    }
    if(!line.stateKnown)return;
    // Use the observed model, not pill color or button state, to choose the target.
    BOOL desired=!line.enabled;
    if(desired){[self applyLine:line desired:YES confirmed:NO];return;}
    NSUInteger generation=self.generation;__weak typeof(self) weakSelf=self;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"停用这条 SIM 线路？" message:@"这可能中断当前通话或移动数据。不会删除 SIM，但重新启用可能需要等待。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"停用线路" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action){
        typeof(self) s=weakSelf;if(s&&[s current:generation])[s applyLine:line desired:NO confirmed:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)applyLine:(LCSCellularLine *)line desired:(BOOL)desired confirmed:(BOOL)confirmed {
    if(self.busy||!self.active||![self allowed])return;
    [self.token cancel];self.token=[LCSCellularToken new];NSUInteger generation=++self.generation;self.busy=YES;
    [self showNotice:nil retry:NO];[self.spinner startAnimating];[self renderLines];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"正在请求系统并等待状态读回");
    __weak typeof(self) weakSelf=self;
    LCSCellularActionCompletion completion=^(BOOL verified,NSArray *lines,NSString *error){
        typeof(self) s=weakSelf;if(!s||![s current:generation])return;
        s.busy=NO;if(lines.count)s.lines=lines;[s.spinner stopAnimating];
        NSString *message=verified?@"系统读回已确认。":(error?:@"尚未确认系统状态，请重新读取。");
        [s showNotice:verified?nil:message retry:!verified];[s renderLines];
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,message);
    };
    if(self.kind==LCSCellularSIMManager)[self.service setSIMLine:line enabled:desired confirmed:confirmed token:self.token completion:completion];
    else [self.service selectDataLine:line token:self.token completion:completion];
}
- (void)dealloc {
    [_token cancel];[_guardTimer invalidate];
    for(id observer in _observers)[NSNotificationCenter.defaultCenter removeObserver:observer];
}
@end
@implementation LCSCellularSIMController
- (instancetype)init {return [super initWithKind:LCSCellularSIMManager];}
@end
@implementation LCSCellularDataController
- (instancetype)init {return [super initWithKind:LCSCellularDataSwitch];}
@end
