#import "LocalCleanStatusCCListViewController.h"
#import "LocalCleanStatusCCPolicy.h"
#import "LocalCleanStatusCCEnvironment.h"
#import "LocalCleanStatusCCRuntime.h"
#import "LocalCleanStatusCCDiagnostics.h"
#import "LocalCleanStatusConfig.h"

// The reference is QuickCC2's own table/card, not an Apple picker. Preserve its
// iOS15 constants: over-full-screen + cross-dissolve, thin dark material,
// centered 340pt card, 52pt rows, check/spinner on the left and lock/wifi right.
static UIImage *lcscc_symbol(NSString *name,CGFloat size) {
    UIImageSymbolConfiguration *c=[UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightSemibold];
    UIImage *image=[UIImage systemImageNamed:name withConfiguration:c];
    if(!image && lcscc_method(object_getClass(UIImage.class),sel_registerName("_systemImageNamed:"),@encode(id),1,(const char *[]){@encode(id)}))
        image=((id(*)(id,SEL,id))objc_msgSend)(UIImage.class,sel_registerName("_systemImageNamed:"),name);
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}
@interface LCSCCListCell : UITableViewCell
@property(nonatomic,strong) UILabel *nameLabel;
@property(nonatomic,strong) UILabel *stateLabel;
@property(nonatomic,strong) UIImageView *check;
@property(nonatomic,strong) UIActivityIndicatorView *progress;
@property(nonatomic,strong) UIImageView *lock;
@property(nonatomic,strong) UIImageView *signal;
- (void)configure:(LCSCCTarget *)row kind:(LCSCCTargetKind)kind pending:(BOOL)pending;
@end
@implementation LCSCCListCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    if((self=[super initWithStyle:style reuseIdentifier:identifier])) {
        self.backgroundColor=UIColor.clearColor;
        self.separatorInset=UIEdgeInsetsMake(0,52,0,0);
        UIView *selected=[UIView new];selected.backgroundColor=[UIColor.whiteColor colorWithAlphaComponent:0.12];self.selectedBackgroundView=selected;
        _check=[[UIImageView alloc] initWithImage:lcscc_symbol(@"checkmark",17)];_check.tintColor=UIColor.whiteColor;
        _progress=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];_progress.color=UIColor.whiteColor;
        _nameLabel=[UILabel new];_nameLabel.font=[UIFont systemFontOfSize:17];_nameLabel.textColor=UIColor.whiteColor;
        _stateLabel=[UILabel new];_stateLabel.font=[UIFont systemFontOfSize:15];_stateLabel.textColor=[UIColor.whiteColor colorWithAlphaComponent:0.55];
        _lock=[[UIImageView alloc] initWithImage:lcscc_symbol(@"lock.fill",12)];_lock.tintColor=UIColor.whiteColor;
        _signal=[[UIImageView alloc] initWithImage:lcscc_symbol(@"wifi",15)];_signal.tintColor=UIColor.whiteColor;
        UIStackView *text=[[UIStackView alloc] initWithArrangedSubviews:@[_nameLabel,_stateLabel]];text.axis=UILayoutConstraintAxisVertical;text.spacing=0;
        UIStackView *right=[[UIStackView alloc] initWithArrangedSubviews:@[_lock,_signal]];right.axis=UILayoutConstraintAxisHorizontal;right.spacing=8;right.alignment=UIStackViewAlignmentCenter;
        for(UIView *v in @[_check,_progress,text,right]){v.translatesAutoresizingMaskIntoConstraints=NO;[self.contentView addSubview:v];}
        _check.contentMode=_lock.contentMode=_signal.contentMode=UIViewContentModeScaleAspectFit;
        [right setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [right setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [NSLayoutConstraint activateConstraints:@[
            [_check.centerXAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:26],[_check.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_check.widthAnchor constraintEqualToConstant:19],[_check.heightAnchor constraintEqualToConstant:19],
            [_progress.centerXAnchor constraintEqualToAnchor:_check.centerXAnchor],[_progress.centerYAnchor constraintEqualToAnchor:_check.centerYAnchor],
            [text.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:52],[text.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [text.trailingAnchor constraintLessThanOrEqualToAnchor:right.leadingAnchor constant:-8],
            [right.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],[right.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor]]];
    }return self;
}
- (void)configure:(LCSCCTarget *)row kind:(LCSCCTargetKind)kind pending:(BOOL)pending {
    _nameLabel.text=row.title;
    _stateLabel.text=kind==LCSCCTargetKindBluetooth?(row.connected?@"已连接":@"未连接"):@"";
    _stateLabel.hidden=!_stateLabel.text.length;
    _check.hidden=pending||!row.connected;
    if(pending)[_progress startAnimating];else[_progress stopAnimating];
    _lock.hidden=kind!=LCSCCTargetKindWiFi||!row.secure;
    _signal.hidden=kind!=LCSCCTargetKindWiFi;
    // iOS15 has no variableValue SF Symbol API; the original falls back to the
    // regular wifi glyph, not custom text bars. Preserve that fallback.
    self.accessibilityLabel=[NSString stringWithFormat:@"%@%@%@",row.title?:@"",row.connected?@"，已连接":@"",row.secure?@"，加密网络":@""];
    self.accessibilityValue=pending?@"正在连接":nil;
}
@end

@interface LCSCCListViewController () <UITableViewDataSource,UITableViewDelegate>
@property(nonatomic) LCSCCTargetKind kind;
@property(nonatomic,strong) UIView *card;
@property(nonatomic,strong) UITableView *table;
@property(nonatomic,strong) UILabel *empty;
@property(nonatomic,strong) UIActivityIndicatorView *progress;
@property(nonatomic,strong) UIRefreshControl *refresher;
@property(nonatomic,strong) UILabel *message;
@property(nonatomic,copy) NSArray<LCSCCTarget *> *items;
@property(nonatomic,copy) NSString *pendingIdentifier;
@property(nonatomic) BOOL refreshing;
@property(nonatomic) BOOL refreshFailed;
@property(nonatomic) BOOL active;
@property(nonatomic) uint64_t generation;
@property(nonatomic) NSTimeInterval refreshStart;
@property(nonatomic,strong) NSMutableArray *observers;
- (void)refresh;
@end
@implementation LCSCCListViewController
- (instancetype)initWithKind:(LCSCCTargetKind)kind {
    if((self=[super initWithNibName:nil bundle:nil])) {
        _kind=kind;_items=@[];_observers=[NSMutableArray new];
        self.modalPresentationStyle=UIModalPresentationOverFullScreen;
        self.modalTransitionStyle=UIModalTransitionStyleCrossDissolve;
        self.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    }return self;
}
- (BOOL)allowed {
    BOOL enabled=local_cleanstatus_hasFeature(local_cleanstatus_currentFlags(),
        self.kind==LCSCCTargetKindWiFi?LocalCleanStatusCCWiFi:LocalCleanStatusCCBluetooth);
    return self.active&&enabled&&local_cleanstatus_ccUnlocked()&&(!self.mayContinue||self.mayContinue());
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor=[UIColor.blackColor colorWithAlphaComponent:0.25];
    UIControl *backdrop=[UIControl new];backdrop.translatesAutoresizingMaskIntoConstraints=NO;
    [backdrop addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];[self.view addSubview:backdrop];
    _card=[UIView new];_card.translatesAutoresizingMaskIntoConstraints=NO;_card.layer.cornerRadius=38;_card.layer.cornerCurve=kCACornerCurveContinuous;_card.clipsToBounds=YES;
    [self.view addSubview:_card];
    UIVisualEffectView *material=[[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
    material.translatesAutoresizingMaskIntoConstraints=NO;[_card addSubview:material];
    UIView *content=material.contentView;
    UIImageView *symbol=[[UIImageView alloc] initWithImage:lcscc_symbol(_kind==LCSCCTargetKindWiFi?@"wifi":@"bluetooth",20)];
    if(!symbol.image)symbol.image=lcscc_symbol(@"dot.radiowaves.left.and.right",20);
    symbol.tintColor=UIColor.whiteColor;symbol.contentMode=UIViewContentModeScaleAspectFit;
    UILabel *title=[UILabel new];title.text=_kind==LCSCCTargetKindWiFi?@"无线局域网":@"蓝牙";title.font=[UIFont systemFontOfSize:19 weight:UIFontWeightSemibold];title.textColor=UIColor.whiteColor;
    _progress=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];_progress.color=UIColor.whiteColor;
    UIView *topLine=[UIView new],*bottomLine=[UIView new];
    topLine.backgroundColor=bottomLine.backgroundColor=[UIColor.whiteColor colorWithAlphaComponent:0.18];
    _table=[[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];_table.backgroundColor=UIColor.clearColor;
    _table.rowHeight=52;_table.alwaysBounceVertical=YES;_table.separatorColor=[UIColor.whiteColor colorWithAlphaComponent:0.18];_table.separatorInset=UIEdgeInsetsMake(0,52,0,0);
    _table.dataSource=self;_table.delegate=self;_table.tableFooterView=[UIView new];[_table registerClass:LCSCCListCell.class forCellReuseIdentifier:@"LCSCCRow"];
    _refresher=[UIRefreshControl new];_refresher.tintColor=UIColor.whiteColor;[_refresher addTarget:self action:@selector(refresh) forControlEvents:UIControlEventValueChanged];_table.refreshControl=_refresher;
    _empty=[UILabel new];_empty.text=_kind==LCSCCTargetKindWiFi?@"无网络":@"无已配对设备";_empty.font=[UIFont systemFontOfSize:15];_empty.textColor=[UIColor.whiteColor colorWithAlphaComponent:0.6];_empty.textAlignment=NSTextAlignmentCenter;
    _message=[UILabel new];_message.font=[UIFont systemFontOfSize:12];_message.textColor=[UIColor.whiteColor colorWithAlphaComponent:0.75];_message.textAlignment=NSTextAlignmentCenter;_message.numberOfLines=2;
    UIButton *settings=[UIButton buttonWithType:UIButtonTypeSystem];[settings setTitle:_kind==LCSCCTargetKindWiFi?@"无线局域网设置…":@"蓝牙设置…" forState:UIControlStateNormal];[settings setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];settings.titleLabel.font=[UIFont systemFontOfSize:17];[settings addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
    for(UIView *v in @[symbol,title,_progress,topLine,_table,_empty,_message,bottomLine,settings]){v.translatesAutoresizingMaskIntoConstraints=NO;[content addSubview:v];}
    UILayoutGuide *safe=self.view.safeAreaLayoutGuide;
    CGFloat desiredWidth=UIDevice.currentDevice.userInterfaceIdiom==UIUserInterfaceIdiomPad?420:340;
    NSLayoutConstraint *width=[_card.widthAnchor constraintEqualToConstant:desiredWidth];width.priority=750;
    NSLayoutConstraint *height=[_card.heightAnchor constraintEqualToAnchor:self.view.heightAnchor multiplier:0.51];height.priority=750;
    NSLayoutConstraint *minimum=[_card.heightAnchor constraintGreaterThanOrEqualToConstant:304];minimum.priority=999;
    [NSLayoutConstraint activateConstraints:@[
        [backdrop.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[backdrop.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [backdrop.topAnchor constraintEqualToAnchor:self.view.topAnchor],[backdrop.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_card.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],[_card.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],width,height,minimum,
        [_card.widthAnchor constraintLessThanOrEqualToConstant:desiredWidth],[_card.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:24],
        [_card.heightAnchor constraintLessThanOrEqualToAnchor:safe.heightAnchor constant:-24],
        [material.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor],[material.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor],
        [material.topAnchor constraintEqualToAnchor:_card.topAnchor],[material.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor],
        [symbol.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],[symbol.centerYAnchor constraintEqualToAnchor:content.topAnchor constant:32],
        [title.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],[title.centerYAnchor constraintEqualToAnchor:content.topAnchor constant:68],
        [_progress.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],[_progress.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [topLine.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],[topLine.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [topLine.topAnchor constraintEqualToAnchor:content.topAnchor constant:96],[topLine.heightAnchor constraintEqualToConstant:1/UIScreen.mainScreen.scale],
        [_table.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],[_table.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [_table.topAnchor constraintEqualToAnchor:topLine.bottomAnchor],[_table.bottomAnchor constraintEqualToAnchor:bottomLine.topAnchor],
        [bottomLine.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],[bottomLine.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [bottomLine.bottomAnchor constraintEqualToAnchor:settings.topAnchor],[bottomLine.heightAnchor constraintEqualToConstant:1/UIScreen.mainScreen.scale],
        [settings.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],[settings.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [settings.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],[settings.heightAnchor constraintEqualToConstant:52],
        [_empty.centerXAnchor constraintEqualToAnchor:_table.centerXAnchor],[_empty.centerYAnchor constraintEqualToAnchor:_table.centerYAnchor],
        [_message.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],[_message.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [_message.bottomAnchor constraintEqualToAnchor:bottomLine.topAnchor constant:-6]]];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];self.active=YES;self.generation=local_cleanstatus_ccNextGeneration(self.generation);
    self.card.transform=CGAffineTransformMakeScale(0.9,0.9);
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0 options:0 animations:^{self.card.transform=CGAffineTransformIdentity;} completion:nil];
    __weak typeof(self) weakSelf=self;
    for(NSString *name in @[@"com.local.cleanstatus.preferences-changed",UIApplicationWillResignActiveNotification,@"SBDeviceLockStateChangedNotification"]) {
        id observer=[NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){
            if([note.name isEqualToString:UIApplicationWillResignActiveNotification]||![weakSelf allowed])[weakSelf close];
        }];[self.observers addObject:observer];
    }
    if(self.kind==LCSCCTargetKindBluetooth)[LCSCCBackend.shared startBluetoothUpdates:^{[weakSelf refresh];}];
    [self refresh];[self scheduleRefresh:self.generation];
}
- (void)scheduleRefresh:(uint64_t)generation {
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        typeof(self) strongSelf=weakSelf;
        if(!strongSelf||!strongSelf.active||strongSelf.generation!=generation)return;
        if(![strongSelf allowed]){[strongSelf close];return;}
        // A failing interface is not retried automatically; pull to refresh or
        // flipping the switch retries explicitly.
        if(!strongSelf.refreshing&&!strongSelf.pendingIdentifier.length&&!strongSelf.refreshFailed)[strongSelf refresh];
        [strongSelf scheduleRefresh:generation];
    });
}
- (void)stop {
    if(!self.active)return;
    self.active=NO;self.generation=local_cleanstatus_ccNextGeneration(self.generation);
    [LCSCCBackend.shared cancelRequests];[LCSCCBackend.shared stopBluetoothUpdates];
    for(id o in self.observers)[NSNotificationCenter.defaultCenter removeObserver:o];[self.observers removeAllObjects];
    if(self.didClose)self.didClose();self.didClose=nil;
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];[self stop];
}
- (void)close {
    [self stop];[self dismissViewControllerAnimated:YES completion:nil];
}
- (void)refresh {
    if(![self allowed]){[self close];return;}
    if(self.refreshing)return;
    self.refreshFailed=NO;
    self.refreshing=YES;self.refreshStart=NSProcessInfo.processInfo.systemUptime;[self.progress startAnimating];self.empty.hidden=YES;
    uint64_t generation=self.generation;__weak typeof(self) weakSelf=self;
    LCSCCListHandler loaded=^(NSArray<LCSCCTarget *> *rows,NSError *error){
        typeof(self) s=weakSelf;
        if(!s||!s.active||s.generation!=generation)return;
        if(![s allowed]){[s close];return;}
        s.refreshing=NO;[s.progress stopAnimating];
        if(!error){s.items=[rows copy];[s.table reloadData];}
        s.refreshFailed=error!=nil;
        s.message.text=error.localizedDescription;
        s.empty.hidden=s.items.count!=0||error!=nil;
        NSTimeInterval delay=MAX(0,0.6-(NSProcessInfo.processInfo.systemUptime-s.refreshStart));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            if(weakSelf.active&&weakSelf.generation==generation)[weakSelf.refresher endRefreshing];
        });
    };
    if(self.kind==LCSCCTargetKindWiFi)[LCSCCBackend.shared scanWiFi:loaded];
    else[LCSCCBackend.shared listPairedBluetooth:loaded];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;(void)section;return self.items.count;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    LCSCCListCell *cell=[tableView dequeueReusableCellWithIdentifier:@"LCSCCRow" forIndexPath:indexPath];
    LCSCCTarget *row=self.items[indexPath.row];[cell configure:row kind:self.kind pending:[row.identifier isEqualToString:self.pendingIdentifier]];return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if(![self allowed]){[self close];return;}
    if(self.pendingIdentifier.length||(NSUInteger)indexPath.row>=self.items.count)return;
    LCSCCTarget *target=self.items[indexPath.row];
    if(self.kind==LCSCCTargetKindWiFi&&target.connected)return;
    if(self.kind==LCSCCTargetKindWiFi&&target.secure&&!target.saved){[self openSettings];return;}
    self.pendingIdentifier=target.identifier;self.message.text=nil;[self.table reloadData];
    uint64_t generation=self.generation;__weak typeof(self) weakSelf=self;
    LCSCCActionResult finished=^(BOOL success,NSError *error){
        typeof(self) s=weakSelf;
        if(!s||!s.active||s.generation!=generation)return;
        if(![s allowed]){[s close];return;}
        s.pendingIdentifier=nil;
        if(error.code==LCSCCErrorOpenSettings){[s openSettings];return;}
        s.message.text=success?nil:(error.localizedDescription?:@"连接状态尚未确认");
        [s.table reloadData];[s refresh];
    };
    if(self.kind==LCSCCTargetKindWiFi)[LCSCCBackend.shared joinWiFi:target completion:finished];
    else[LCSCCBackend.shared toggleBluetooth:target completion:finished];
}
- (void)openSettings {
    if(![self allowed]){[self close];return;}
    NSString *url=self.kind==LCSCCTargetKindWiFi?@"prefs:root=WIFI":@"prefs:root=Bluetooth";
    id workspace=lcscc_object(NSClassFromString(@"LSApplicationWorkspace"),"defaultWorkspace");
    SEL sel=sel_registerName("openSensitiveURL:withOptions:");
    const char *args[]={@encode(id),@encode(id)};
    if(!lcscc_method(object_getClass(workspace),sel,@encode(BOOL),2,args)) {
        self.message.text=@"无法打开设置，请从系统设置手动进入";return;
    }
    self.refreshFailed=YES; // no rescan between here and the Settings screen
    [self stop];
    NSTimeInterval t0=CFAbsoluteTimeGetCurrent();
    // Open first, dismiss afterwards. Waiting for the modal dismissal before
    // opening is what made the jump feel stalled.
    ((BOOL(*)(id,SEL,id,id))objc_msgSend)(workspace,sel,[NSURL URLWithString:url],nil);
    NSTimeInterval t1=CFAbsoluteTimeGetCurrent();
    [self dismissViewControllerAnimated:NO completion:^{
        NSTimeInterval t2=CFAbsoluteTimeGetCurrent();
        id cc=lcscc_object(NSClassFromString(@"SBControlCenterController"),"sharedInstance");
        SEL dismiss=sel_registerName("dismissAnimated:");
        if(lcscc_method(object_getClass(cc),dismiss,@encode(void),1,(const char *[]){@encode(BOOL)}))
            ((void(*)(id,SEL,BOOL))objc_msgSend)(cc,dismiss,YES);
        NSTimeInterval t3=CFAbsoluteTimeGetCurrent();
        local_cleanstatus_ccLog(@"settings.timing",[NSString stringWithFormat:@"open=%.0fms dismiss=%.0fms cc=%.0fms url=%@",
            (t1-t0)*1000.0,(t2-t1)*1000.0,(t3-t2)*1000.0,url]);
    }];
}
@end
