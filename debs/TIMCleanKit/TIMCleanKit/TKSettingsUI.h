// Native UIKit settings, iOS 15+. Included after TKRuntimeSnapshot().
@interface TKSettingsController : UITableViewController
@property(nonatomic,strong) NSArray *sections;
@end
@implementation TKSettingsController
- (instancetype)init {
    if ((self=[super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title=@"TIMCleanKit";
        self.sections=@[
          @[@{@"title":@"启用插件",@"key":kEnabled,@"symbol":@"power",@"default":@YES}],
          @[@{@"title":@"防撤回",@"key":kAntiRecall,@"symbol":@"arrow.uturn.backward",@"default":@YES},
            @{@"title":@"设备名称伪装",@"key":kDeviceSpoof,@"symbol":@"iphone",@"default":@NO},
            @{@"title":@"伪装名称",@"action":@"model",@"symbol":@"pencil"}],
          @[@{@"title":@"红包入口过滤",@"key":kRedPacket,@"symbol":@"line.3.horizontal.decrease.circle",@"default":@YES},
            @{@"title":@"跳过测试红包",@"key":kRedSkipTest,@"symbol":@"testtube.2",@"default":@YES},
            @{@"title":@"跳过口令红包",@"key":kRedSkipCmd,@"symbol":@"text.bubble",@"default":@NO},
            @{@"title":@"小额阈值",@"action":@"amount",@"symbol":@"slider.horizontal.3"}],
          @[@{@"title":@"运行状态",@"action":@"diagnostics",@"symbol":@"waveform.path.ecg"},
            @{@"title":@"复制诊断摘要",@"action":@"copy",@"symbol":@"doc.on.doc"}]
        ];
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor=UIColor.systemGroupedBackgroundColor;
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closePage)];
    UIView *header=[[UIView alloc] initWithFrame:CGRectMake(0,0,320,118)];
    UILabel *name=[UILabel new];name.text=@"TIM 增强";name.font=[UIFont systemFontOfSize:30 weight:UIFontWeightBold];name.textColor=UIColor.labelColor;
    UILabel *subtitle=[UILabel new];subtitle.text=@"更清晰的设置 · 可核验的状态";subtitle.font=[UIFont systemFontOfSize:14];subtitle.textColor=UIColor.secondaryLabelColor;
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[name,subtitle]];stack.axis=UILayoutConstraintAxisVertical;stack.spacing=7;stack.translatesAutoresizingMaskIntoConstraints=NO;
    [header addSubview:stack];[NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:24],[stack.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-24],[stack.centerYAnchor constraintEqualToAnchor:header.centerYAnchor]]];
    self.tableView.tableHeaderView=header;
}
- (void)closePage {[self dismissViewControllerAnimated:YES completion:nil];}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView{return self.sections.count;}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)section{return [self.sections[section] count];}
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s{return @[@"总开关",@"消息与设备",@"红包过滤",@"诊断"][s];}
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    return @[@"开关只表示配置。请在运行状态页确认注册与触发记录。",@"防撤回补充读取与查询入口，效果仍需实测。设备伪装仅修改 UIDevice 名称，不改变硬件型号。",@"这是手动打开入口的过滤，未实现自动领取。随机红包的实际金额在领取前通常未知，不能保证小额过滤。",@"1.0.3 · 复读与闪照保存尚未实现，未提供无效开关。诊断不包含聊天内容和账号信息。"][s];
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *row=self.sections[ip.section][ip.row];
    UITableViewCell *c=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    c.textLabel.text=row[@"title"];c.textLabel.font=[UIFont systemFontOfSize:16];
    c.imageView.image=[UIImage systemImageNamed:row[@"symbol"]];c.imageView.tintColor=UIColor.systemBlueColor;
    NSString *key=row[@"key"];
    if (key) {
        UISwitch *sw=[UISwitch new];sw.on=prefBool(key,[row[@"default"] boolValue]);sw.accessibilityIdentifier=key;
        [sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];c.accessoryView=sw;c.selectionStyle=UITableViewCellSelectionStyleNone;
    } else {
        c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
        if ([row[@"action"] isEqualToString:@"model"]) c.detailTextLabel.text=prefStr(kSpoofModel,@"iPhone 15 Pro");
        if ([row[@"action"] isEqualToString:@"amount"]) {NSInteger n=prefInt(kRedMinAmount,100);c.detailTextLabel.text=n>0?[NSString stringWithFormat:@"%.2f 元",n/100.0]:@"关闭";}
    }
    return c;
}
- (void)toggle:(UISwitch *)sender {
    [prefs() setBool:sender.on forKey:sender.accessibilityIdentifier];
    [prefs() synchronize];
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];NSString *action=self.sections[ip.section][ip.row][@"action"];
    if (!action)return;
    if ([action isEqualToString:@"amount"]) {
        UIAlertController *a=[UIAlertController alertControllerWithTitle:@"小额阈值" message:@"仅按客户端已知金额判断；未知金额放行。" preferredStyle:UIAlertControllerStyleAlert];
        for (NSNumber *n in @[@0,@1,@5,@10,@20,@100]) {
            NSString *label=n.integerValue?[NSString stringWithFormat:@"%.2f 元",n.doubleValue/100]:@"关闭";
            [a addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[prefs() setInteger:n.integerValue forKey:kRedMinAmount];[prefs() synchronize];[self.tableView reloadData];}]];
        }
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:a animated:YES completion:nil];
    } else if ([action isEqualToString:@"model"]) {
        UIAlertController *a=[UIAlertController alertControllerWithTitle:@"设备显示名称" message:@"仅改变 UIDevice 返回字符串。" preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *f){f.text=prefStr(kSpoofModel,@"iPhone 15 Pro");f.clearButtonMode=UITextFieldViewModeWhileEditing;}];
        __weak UIAlertController *weakAlert=a;
        [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){NSString *v=[weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(v.length&&v.length<=80){[prefs() setObject:v forKey:kSpoofModel];[prefs() synchronize];[self.tableView reloadData];}}]];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:a animated:YES completion:nil];
    } else {
        NSDictionary *state=TKRuntimeSnapshot();NSMutableString *text=[NSMutableString stringWithFormat:@"TIMCleanKit %@\n%@\n",state[@"version"],state[@"process"]];
        for(NSDictionary *r in state[@"hookRows"])[text appendFormat:@"\n%@\n%@ · 调用 %@ 次\n",r[@"name"],r[@"state"],r[@"hits"]];
        for(NSString *warning in state[@"warnings"])[text appendFormat:@"\n%@\n",warning];
        if([action isEqualToString:@"copy"]) {UIPasteboard.generalPasteboard.string=text;UIAlertController *a=[UIAlertController alertControllerWithTitle:@"已复制" message:@"摘要仅含版本、注册状态和调用次数。" preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:a animated:YES completion:nil];}
        else {UIViewController *vc=[UIViewController new];vc.title=@"运行状态";UITextView *view=[[UITextView alloc] init];view.editable=NO;view.alwaysBounceVertical=YES;view.backgroundColor=UIColor.systemBackgroundColor;view.textColor=UIColor.labelColor;view.font=[UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];view.textContainerInset=UIEdgeInsetsMake(18,18,24,18);view.text=text;vc.view=view;[self.navigationController pushViewController:vc animated:YES];}
    }
}
@end
static void TKPresentSettings(UIWindow *window) {
    if (![NSThread isMainThread]) {dispatch_async(dispatch_get_main_queue(),^{TKPresentSettings(window);});return;}
    UIViewController *vc=window.rootViewController;
    while(vc.presentedViewController&&!vc.presentedViewController.isBeingDismissed)vc=vc.presentedViewController;
    if(!vc||vc.isBeingDismissed||[vc isKindOfClass:[UIAlertController class]])return;
    if([vc isKindOfClass:[UINavigationController class]]&&[((UINavigationController *)vc).topViewController isKindOfClass:[TKSettingsController class]])return;
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:[TKSettingsController new]];nav.modalPresentationStyle=UIModalPresentationPageSheet;
    nav.navigationBar.prefersLargeTitles=NO;
    if(nav.sheetPresentationController){nav.sheetPresentationController.detents=@[UISheetPresentationControllerDetent.largeDetent];nav.sheetPresentationController.prefersGrabberVisible=YES;}
    [vc presentViewController:nav animated:YES completion:nil];
}
