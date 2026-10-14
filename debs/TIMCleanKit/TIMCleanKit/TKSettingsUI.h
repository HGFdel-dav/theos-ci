// Native UIKit settings, iOS 15+. Included after TKRuntimeSnapshot().
@interface TKSettingsController : UITableViewController
@property(nonatomic,strong) NSArray *sections;
@end
@implementation TKSettingsController
- (instancetype)init {
    if ((self=[super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title=@"TIMCleanKit";
        self.sections=@[
          @[@{@"title":@"启用插件",@"key":kEnabled,@"symbol":@"power",@"default":@YES,@"help":@"总开关立即影响后续操作；关闭后停止自动领取、保存与拦截，已发出的领取请求无法撤销。"},
            @{@"title":@"空白区域唤醒",@"key":kBlankTap,@"symbol":@"hand.tap",@"default":@YES,@"help":@"一指轻点非控件的空白背景打开设置。输入框、按钮、消息气泡、列表单元格与滚动区域会避让；双指长按0.8秒始终保留。"}],
          @[@{@"title":@"防撤回",@"key":kAntiRecall,@"symbol":@"arrow.uturn.backward",@"default":@YES,@"help":@"开启后，用新收到的消息测试对方撤回。监听缓存保留最近200条消息的内容，只在本次进程内有效；不会恢复启动前已丢失的历史消息。"},
            @{@"title":@"消息复读",@"key":kRepeater,@"symbol":@"repeat",@"default":@YES,@"help":@"开启后双击可识别的消息气泡，确认后转发回原会话一次；无法识别气泡时用“选择消息复读”。会真实发送消息，不会自动重复所有消息。"},
            @{@"title":@"选择消息复读",@"action":@"repeat",@"symbol":@"bubble.left.and.bubble.right",@"help":@"只列出本次启动后监听到的最近消息。确认后调用TIM原生转发，结果以会话中的实际发送为准。"},
            @{@"title":@"闪照保存与截图回调",@"key":kFlashPhoto,@"symbol":@"photo.on.rectangle",@"default":@YES,@"help":@"开启后正常预览闪照；原生解密成功并返回图片时保存PNG到TIM沙盒 Documents/TIMCleanKit/FlashPhotos，同时拦截已定位的截图通知入口。不是未读闪照下载器，不能保证所有截图检测都被拦截。"},
            @{@"title":@"导出保存图片",@"action":@"export",@"symbol":@"square.and.arrow.up",@"help":@"选择保存的PNG并通过系统分享导出。只分享你明确选中的图片。"},
            @{@"title":@"查看已保存图片",@"action":@"photos",@"symbol":@"photo.stack",@"help":@"查看本版保存的PNG，点“导出保存图片”可通过系统分享导出。没有原生解密结果或保存失败时不会生成图片。"},
            @{@"title":@"设备名称伪装",@"key":kDeviceSpoof,@"symbol":@"iphone",@"default":@NO,@"help":@"对后续UIDevice.model/localizedModel读取生效。仅改变这两个API的显示字符串，不改变硬件或服务器记录；应用已经缓存的名称可能不刷新。"},
            @{@"title":@"伪装名称",@"action":@"model",@"symbol":@"pencil",@"help":@"输入名称并保存，再开启上方开关；运行状态可核对UIDevice返回值。"}],
          @[@{@"title":@"自动抢红包",@"key":kAutoRed,@"symbol":@"gift",@"default":@YES,@"help":@"总开关与此开关开启时，监听收到的新红包后自动调用原生领取并尝试点击拆包，不需手动点红包。仅处理TIM前台、两分钟内的新消息，串行领取并去重；后台暂停或网络失败不保证领取。"},
            @{@"title":@"启用红包过滤条件",@"key":kRedPacket,@"symbol":@"line.3.horizontal.decrease.circle",@"default":@YES,@"help":@"自动领取和手动点击前使用下方条件过滤。开启自动抢红包需同时开启此项。未知字段放行，不伪造金额或领取结果。"},
            @{@"title":@"跳过测试红包",@"key":kRedSkipTest,@"symbol":@"testtube.2",@"default":@YES,@"help":@"匹配红包标题、内容等字段中的“测试”或“体验”，匹配时不请求领取；属于文本规则，不能识别所有测试红包。"},
            @{@"title":@"跳过口令红包",@"key":kRedSkipCmd,@"symbol":@"text.bubble",@"default":@NO,@"help":@"TIM原生接口判为口令红包时跳过，不自动发送口令；关闭后仍受原生领取流程限制。"},
            @{@"title":@"小额阈值",@"action":@"amount",@"symbol":@"slider.horizontal.3",@"help":@"0为关闭，仅按客户端已知金额判断。随机红包在领取前通常不知道实际金额，所以不能保证“小额不抢”；未知金额仍放行。"}],
          @[@{@"title":@"运行状态",@"action":@"diagnostics",@"symbol":@"waveform.path.ecg",@"help":@"查看监听是否注册、新消息数、领取请求/完成回调/失败、保存图片数和Hook调用。完成回调不等于已到账，请核对红包结果。"},
            @{@"title":@"复制诊断摘要",@"action":@"copy",@"symbol":@"doc.on.doc",@"help":@"复制版本、方法注册状态与计数，便于排查；摘要不含聊天正文、账号、红包账单或凭据。"}]
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
    self.tableView.rowHeight=UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight=112;
}
- (void)closePage {[self dismissViewControllerAnimated:YES completion:nil];}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView{return self.sections.count;}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)section{return [self.sections[section] count];}
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s{return @[@"总开关",@"消息与设备",@"红包过滤",@"诊断"][s];}
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    return @[@"首次注入仍需完全退出TIM再打开；普通开关在下一次操作时生效。",@"消息、图片与发送结果请逐项在真机核对；注册或计数不能证明效果。",@"收到后自动领取是本版新接入流程，尚未真机验证；不会自动补领历史红包。",@"1.0.4 · 实际效果需要真机验证。诊断摘要不包含消息内容。"][s];
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *row=self.sections[ip.section][ip.row];
    UITableViewCell *c=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSString *title=row[@"title"],*help=row[@"help"]?:@"";
    if ([row[@"action"] isEqualToString:@"model"]) title=[title stringByAppendingFormat:@" · %@",prefStr(kSpoofModel,@"iPhone 15 Pro")];
    if ([row[@"action"] isEqualToString:@"amount"]) {NSInteger n=prefInt(kRedMinAmount,100);title=[title stringByAppendingFormat:@" · %@",n>0?[NSString stringWithFormat:@"%.2f 元",n/100.0]:@"关闭"];}
    UIListContentConfiguration *content=[UIListContentConfiguration subtitleCellConfiguration];
    content.text=title;content.textProperties.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];content.textProperties.numberOfLines=0;
    content.secondaryText=help;content.secondaryTextProperties.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];content.secondaryTextProperties.color=UIColor.secondaryLabelColor;content.secondaryTextProperties.numberOfLines=0;
    content.image=[UIImage systemImageNamed:row[@"symbol"]];content.imageProperties.tintColor=UIColor.systemBlueColor;content.textToSecondaryTextVerticalPadding=5;c.contentConfiguration=content;
    NSString *key=row[@"key"];
    if (key) {
        UISwitch *sw=[UISwitch new];sw.on=prefBool(key,[row[@"default"] boolValue]);sw.accessibilityIdentifier=key;
        [sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];c.accessoryView=sw;c.selectionStyle=UITableViewCellSelectionStyleNone;
    } else c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    return c;
}
- (void)showMessage:(NSString *)message {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"TIMCleanKit" message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    dispatch_async(dispatch_get_main_queue(),^{[self presentViewController:a animated:YES completion:nil];});
}
- (void)toggle:(UISwitch *)sender {
    [prefs() setBool:sender.on forKey:sender.accessibilityIdentifier];
    [prefs() synchronize];
    if([sender.accessibilityIdentifier isEqualToString:kAutoRed]){[gTKSeenRedPackets removeAllObjects];[gTKRedQueue removeAllObjects];}
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
    } else if([action isEqualToString:@"repeat"]) {
        if(!prefBool(kRepeater,YES)){[self showMessage:@"请先开启消息复读"];return;}
        UIAlertController *a=[UIAlertController alertControllerWithTitle:@"选择已收到的消息" message:@"确认后转发到原会话。仅列最近10条缓存消息。" preferredStyle:UIAlertControllerStyleAlert];
        NSArray *ids=[[gTKRecentMessages reverseObjectEnumerator] allObjects];
        for(NSUInteger i=0;i<MIN(ids.count,10);i++){
            id record=gTKMessageCache[ids[i]][@"record"];NSString *label=[NSString stringWithFormat:@"最近第%lu条 · 消息类型 %lld",(unsigned long)i+1,TKScalar(record,@"msgType","i")];
            [a addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
                UIAlertController *confirm=[UIAlertController alertControllerWithTitle:@"转发回原会话？" message:@"将真实发送一次。请确认这是你要复读的消息。" preferredStyle:UIAlertControllerStyleAlert];
                [confirm addAction:[UIAlertAction actionWithTitle:@"发送一次" style:UIAlertActionStyleDefault handler:^(UIAlertAction *y){[self showMessage:TKRepeatRecord(record)?@"已请求原生转发，请核对会话":@"发送入口不可用或参数不匹配"];}]];
                [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
                dispatch_async(dispatch_get_main_queue(),^{[self presentViewController:confirm animated:YES completion:nil];});
            }]];
        }
        if(!ids.count){[self showMessage:@"尚未监听到消息，请先接收一条新消息并检查运行状态"];return;}
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:a animated:YES completion:nil];
    } else if([action isEqualToString:@"export"]) {
        NSString *doc=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        NSString *folder=[doc stringByAppendingPathComponent:@"TIMCleanKit/FlashPhotos"];
        NSArray *names=[NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:nil];
        UIAlertController *a=[UIAlertController alertControllerWithTitle:@"选择保存图片" message:@"系统分享会由你确认导出目标。" preferredStyle:UIAlertControllerStyleAlert];NSUInteger added=0;
        for(NSString *name in names){if(![name.pathExtension.lowercaseString isEqualToString:@"png"]||added>=10)continue;added++;
            NSURL *url=[NSURL fileURLWithPath:[folder stringByAppendingPathComponent:name]];
            [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"图片%lu · %@",(unsigned long)added,[name substringToIndex:MIN(name.length,8)]] style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
                UIActivityViewController *share=[[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
                if(share.popoverPresentationController){share.popoverPresentationController.sourceView=self.view;share.popoverPresentationController.sourceRect=CGRectMake(0,0,1,1);}
                dispatch_async(dispatch_get_main_queue(),^{[self presentViewController:share animated:YES completion:nil];});
            }]];
        }
        if(!added){[self showMessage:@"尚未保存图片"];return;}
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:a animated:YES completion:nil];
    } else if([action isEqualToString:@"photos"]) {
        NSString *doc=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        NSString *folder=[doc stringByAppendingPathComponent:@"TIMCleanKit/FlashPhotos"];
        NSArray *names=[NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:nil];NSMutableString *text=[NSMutableString stringWithFormat:@"保存路径：%@\n\n图片预览如下；返回上一页点“导出保存图片”。\n",folder];
        UIViewController *vc=[UIViewController new];vc.title=@"已保存图片";UITextView *view=[UITextView new];view.editable=NO;view.backgroundColor=UIColor.systemBackgroundColor;view.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];view.textColor=UIColor.labelColor;
        NSMutableAttributedString *body=[[NSMutableAttributedString alloc] initWithString:text attributes:@{NSFontAttributeName:view.font,NSForegroundColorAttributeName:UIColor.labelColor}];NSUInteger shown=0;
        for(NSString *name in names){if(![name.pathExtension.lowercaseString isEqualToString:@"png"]||shown>=10)continue;UIImage *image=[UIImage imageWithContentsOfFile:[folder stringByAppendingPathComponent:name]];if(!image)continue;
            NSTextAttachment *attachment=[NSTextAttachment new];attachment.image=image;CGFloat w=280,h=image.size.width>0?w*image.size.height/image.size.width:200;attachment.bounds=CGRectMake(0,0,w,MIN(h,400));
            [body appendAttributedString:[[NSAttributedString alloc] initWithString:[name stringByAppendingString:@"\n"]]];[body appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];[body appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n\n"]];shown++;
        }
        if(!shown)[body appendAttributedString:[[NSAttributedString alloc] initWithString:@"尚未保存图片。先开启功能，再正常预览一张闪照。"]];
        view.attributedText=body;view.textContainerInset=UIEdgeInsetsMake(18,18,24,18);vc.view=view;[self.navigationController pushViewController:vc animated:YES];
    } else {
        NSDictionary *state=TKRuntimeSnapshot();NSMutableString *text=[NSMutableString stringWithFormat:@"TIMCleanKit %@\n%@\n",state[@"version"],state[@"process"]];
        [text appendFormat:@"\n功能引擎：%@\n",state[@"engine"]];
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
