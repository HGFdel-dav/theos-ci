static void TKDismissSettings(UIViewController *controller);
// Native UIKit settings, iOS 15+. Included after TKRuntimeSnapshot().
// 1.0.5: amounts are stored as integer cents, never converted through floating point.
static NSString *TKUIAmountString(NSInteger cents) {
    cents=MAX((NSInteger)0,cents);
    return [NSString stringWithFormat:@"%ld.%02ld",(long)(cents/100),(long)(cents%100)];
}
static BOOL TKUIParseCents(NSString *input, NSInteger *result, NSString **error) {
    NSString *value=[input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]?:@"";
    if (!value.length) {if(error)*error=@"请输入金额；不设限制请填 0。";return NO;}
    static NSRegularExpression *pattern;
    static dispatch_once_t once;
    dispatch_once(&once,^{pattern=[NSRegularExpression regularExpressionWithPattern:@"^[0-9]+(?:\\.[0-9]{1,2})?$" options:0 error:nil];});
    NSTextCheckingResult *match=[pattern firstMatchInString:value options:0 range:NSMakeRange(0,value.length)];
    if (!match || match.range.length!=value.length) {
        if(error)*error=@"仅接受非负数字，最多两位小数；不要输入符号、逗号或文字。";
        return NO;
    }
    NSArray<NSString *> *parts=[value componentsSeparatedByString:@"."];
    NSString *whole=parts.firstObject;
    NSUInteger start=0;
    while(start+1<whole.length && [whole characterAtIndex:start]=='0')start++;
    whole=[whole substringFromIndex:start];
    if(whole.length>19){if(error)*error=@"金额过大，超出整数分的存储范围。";return NO;}
    NSString *normalized=parts.count==2?[whole stringByAppendingFormat:@".%@",parts[1]]:whole;
    NSDecimalNumber *yuan=[NSDecimalNumber decimalNumberWithString:normalized locale:@{NSLocaleDecimalSeparator:@"."}];
    NSDecimalNumber *cents=[yuan decimalNumberByMultiplyingByPowerOf10:2];
    NSDecimalNumber *limit=[NSDecimalNumber decimalNumberWithString:[NSString stringWithFormat:@"%ld",(long)NSIntegerMax]];
    if([cents isEqualToNumber:NSDecimalNumber.notANumber] || [cents compare:NSDecimalNumber.zero]==NSOrderedAscending || [cents compare:limit]==NSOrderedDescending){
        if(error)*error=@"金额过大，超出整数分的存储范围。";return NO;
    }
    if(result)*result=cents.integerValue;
    return YES;
}
// Read directly: prefStr() treats an empty string as missing, but here empty disables matching.
static NSString *TKUIRedKeywordText(void) {
    id value=[prefs() objectForKey:kRedKeywords];
    return [value isKindOfClass:NSString.class]?value:@"测试\n外挂\n体验";
}
@interface TKRedKeywordsController : UITableViewController
@property(nonatomic,strong) UITextView *editor;
@property(nonatomic,copy) void (^didSave)(void);
@end
@implementation TKRedKeywordsController
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"过滤关键词";self.view.backgroundColor=UIColor.systemGroupedBackgroundColor;self.tableView.backgroundView=nil;
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self action:@selector(saveKeywords)];
    self.tableView.keyboardDismissMode=UIScrollViewKeyboardDismissModeInteractive;
    self.editor=[UITextView new];self.editor.text=TKUIRedKeywordText();self.editor.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.editor.adjustsFontForContentSizeCategory=YES;self.editor.textColor=UIColor.labelColor;self.editor.backgroundColor=UIColor.clearColor;
    self.editor.textContainerInset=UIEdgeInsetsMake(14,12,14,12);self.editor.autocapitalizationType=UITextAutocapitalizationTypeNone;self.editor.autocorrectionType=UITextAutocorrectionTypeNo;
    self.editor.accessibilityLabel=@"红包过滤关键词";self.editor.accessibilityHint=@"支持中文逗号、逗号、空格或换行分隔；删除全部表示不匹配关键词。";
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {return 1;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {return 1;}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {return 220;}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {return @"自定义关键词";}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"用中文逗号、逗号、空格或换行分隔，支持增加与删除。默认：测试、外挂、体验。保存去除首尾空白，空文本表示不匹配关键词。开启“跳过关键词红包”后，标题、内容或名称命中任一关键词即跳过，英文不区分大小写；与金额、口令条件同时生效，不检查账单凭据。返回而不保存会丢弃本次编辑。";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];cell.selectionStyle=UITableViewCellSelectionStyleNone;
    self.editor.translatesAutoresizingMaskIntoConstraints=NO;[cell.contentView addSubview:self.editor];
    [NSLayoutConstraint activateConstraints:@[[self.editor.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor],[self.editor.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor],[self.editor.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor],[self.editor.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor]]];
    return cell;
}
- (void)saveKeywords {
    NSString *value=[self.editor.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]?:@"";
    [prefs() setObject:value forKey:kRedKeywords];[prefs() synchronize];[self.editor resignFirstResponder];
    if(self.didSave)self.didSave();[self.navigationController popViewControllerAnimated:YES];
}
@end
@interface TKSettingsController : UITableViewController
@property(nonatomic,strong) NSArray *sections;
@property(nonatomic,weak) UIAlertController *amountAlert;
@end
@implementation TKSettingsController
- (instancetype)init {
    if ((self=[super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title=@"TIMCleanKit";
        self.sections=@[
          @[@{@"title":@"启用插件",@"key":kEnabled,@"symbol":@"power",@"default":@YES,@"help":@"总开关立即影响后续操作；关闭后停止自动领取、消息复读、撤回拦截与设备伪装，已发出的领取请求无法撤销。TIM 全区域双指长按 0.8 秒可唤醒设置，总开关关闭仍可唤醒。"}],
          @[@{@"title":@"防撤回",@"key":kAntiRecall,@"symbol":@"arrow.uturn.backward",@"default":@YES,@"help":@"开启后，用新收到的消息测试对方撤回。防撤回缓存最近500条收到或显示过的消息，只在本次进程内有效；拦截后在气泡旁显示“拦截撤回”。启动前丢失内容无法恢复，本次实现仍待真机测试。"},
            @{@"title":@"消息复读",@"key":kRepeater,@"symbol":@"repeat",@"default":@YES,@"help":@"总开关与此开关开启时，双击对方可识别的消息气泡，立即向原会话发送一次，无需确认。复读不保存消息、不使用或选择缓存；会真实发送，不会自动重复所有消息。"},
            @{@"title":@"设备机型伪装",@"key":kDeviceSpoof,@"symbol":@"iphone",@"default":@NO,@"help":@"仅影响 TIM 进程内对 UIDevice.model/localizedModel 与已接入机型标识的读取，不改变硬件、系统设置或服务器记录；不能保证覆盖全部检测，应用已缓存的值可能不刷新。"},
            @{@"title":@"伪装机型名称",@"action":@"model",@"symbol":@"pencil",@"help":@"输入机型名称并保存，再开启上方开关；仅作用于 TIM 进程读取，运行状态可核对 UIDevice 返回值。"}],
          @[@{@"title":@"自动抢红包",@"key":kAutoRed,@"symbol":@"gift",@"default":@YES,@"help":@"总开关与此开关开启时，监听收到的新红包后自动调用原生领取并尝试点击拆包，不需手动点红包。仅处理TIM前台、两分钟内的新消息，串行领取并去重；后台暂停或网络失败不保证领取。"},
            @{@"title":@"启用红包过滤条件",@"key":kRedPacket,@"symbol":@"line.3.horizontal.decrease.circle",@"default":@YES,@"help":@"自动领取和手动点击前使用下方关键词、口令与金额条件过滤，这些条件同时生效。开启自动抢红包需同时开启此项；未知金额由“未知金额放行”控制，不伪造金额或领取结果。"},
            @{@"title":@"跳过关键词红包",@"key":kRedSkipTest,@"symbol":@"text.magnifyingglass",@"default":@YES,@"help":@"红包标题、内容或名称命中任一过滤关键词时跳过，英文不区分大小写。默认含“测试”“外挂”“体验”，可在下方增删；与金额和口令条件同时生效，不检查账单凭据。"},
            @{@"title":@"过滤关键词",@"action":@"keywords",@"symbol":@"text.badge.plus",@"help":@"可自定义增加或删除关键词，用中文逗号、逗号、空格或换行分隔；空文本表示不匹配关键词。仅在“跳过关键词红包”开启时生效。"},
            @{@"title":@"跳过口令红包",@"key":kRedSkipCmd,@"symbol":@"text.bubble",@"default":@NO,@"help":@"TIM原生接口判为口令红包时跳过，不自动发送口令；关闭后仍受原生领取流程限制。"},
            @{@"title":@"金额范围",@"action":@"amount",@"symbol":@"slider.horizontal.3",@"help":@"自行输入人民币元最低、最高金额，最多两位小数；包含两端。最低 0 不设下限，最高 0 不设上限。仅按领取前可知金额过滤，不保证等于实际到账。"},
            @{@"title":@"未知金额放行",@"key":kRedUnknownAllow,@"symbol":@"questionmark.circle",@"default":@YES,@"help":@"默认开启：领取前金额未知时放行，仍受关键词与口令条件限制。随机红包领取前通常无法知道实际到账金额；关闭才严格跳过未知金额，但多数随机红包将不抢。"}],
          @[@{@"title":@"运行状态",@"action":@"diagnostics",@"symbol":@"waveform.path.ecg",@"help":@"动态查看功能引擎键值、监听注册、新消息、领取请求/回调/失败与 Hook 调用。完成回调不等于已到账，请核对红包结果。"},
            @{@"title":@"复制诊断摘要",@"action":@"copy",@"symbol":@"doc.on.doc",@"help":@"复制版本、功能引擎键值、方法注册状态与计数，便于排查；摘要不含聊天正文、账号、红包账单或凭据。"}]
        ];
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor=UIColor.systemGroupedBackgroundColor;self.tableView.backgroundView=nil;
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closePage)];
    UIView *header=[[UIView alloc] initWithFrame:CGRectMake(0,0,320,118)];
    UILabel *name=[UILabel new];name.text=@"TIM 增强";name.font=[UIFont systemFontOfSize:30 weight:UIFontWeightBold];name.textColor=UIColor.labelColor;
    UILabel *subtitle=[UILabel new];subtitle.text=@"1.0.6 · 轻触开关 · 双指长按唤醒";subtitle.font=[UIFont systemFontOfSize:14];subtitle.adjustsFontForContentSizeCategory=YES;subtitle.textColor=UIColor.secondaryLabelColor;
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[name,subtitle]];stack.axis=UILayoutConstraintAxisVertical;stack.spacing=7;stack.translatesAutoresizingMaskIntoConstraints=NO;
    [header addSubview:stack];[NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:24],[stack.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-24],[stack.centerYAnchor constraintEqualToAnchor:header.centerYAnchor]]];
    self.tableView.tableHeaderView=header;
    self.tableView.rowHeight=UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight=112;
}
- (void)closePage {TKDismissSettings(self);}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView{return self.sections.count;}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)section{return [self.sections[section] count];}
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s{return @[@"总开关",@"消息与设备",@"红包过滤",@"诊断"][s];}
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    return @[@"TIM 全区域双指长按 0.8 秒唤醒设置，总开关关闭仍可唤醒。首次注入需完全退出TIM再打开；普通开关在下一次操作时生效。",@"消息效果与实际发送结果请逐项真机核对；注册或计数不能证明效果。机型伪装仅作用于 TIM 进程读取，不改变硬件或服务器记录。",@"自动红包已由用户实测 1.0.4 自动领取有效。1.0.6 修复设置面板背景透明度与拦截撤回标签定位；金额范围、未知金额策略与关键词过滤等新修改仍待实测；不会自动补领历史红包。随机红包领取前通常无法知道实际到账金额，关闭未知金额放行后多数随机红包将不抢。",@"1.0.6 · 本次新修改仍待真机实测。诊断摘要不包含消息内容，完成回调不等于到账。"][s];
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *row=self.sections[ip.section][ip.row];
    UITableViewCell *c=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSString *title=row[@"title"],*help=row[@"help"]?:@"";
    if ([row[@"action"] isEqualToString:@"model"]) title=[title stringByAppendingFormat:@" · %@",prefStr(kSpoofModel,@"iPhone 15 Pro")];
    if ([row[@"action"] isEqualToString:@"amount"]) {
        NSInteger minimum=MAX((NSInteger)0,prefInt(kRedMinAmount,100)),maximum=MAX((NSInteger)0,prefInt(kRedMaxAmount,0));
        NSString *lower=minimum>0?[TKUIAmountString(minimum) stringByAppendingString:@" 元"]:@"不设下限";
        NSString *upper=maximum>0?[TKUIAmountString(maximum) stringByAppendingString:@" 元"]:@"不设上限";
        title=[title stringByAppendingFormat:@" · %@ — %@",lower,upper];
    }
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
- (BOOL)validateAmountAlert:(UIAlertController *)alert minimum:(NSInteger *)minimum maximum:(NSInteger *)maximum error:(NSString **)error {
    NSInteger lower=0,upper=0;NSString *detail=nil;
    if(alert.textFields.count!=2){if(error)*error=@"金额输入框不可用，请重新打开。";return NO;}
    if(!TKUIParseCents(alert.textFields[0].text,&lower,&detail)){if(error)*error=[@"最低金额：" stringByAppendingString:detail];return NO;}
    if(!TKUIParseCents(alert.textFields[1].text,&upper,&detail)){if(error)*error=[@"最高金额：" stringByAppendingString:detail];return NO;}
    // Zero upper bound is the explicit no-limit sentinel, not an invalid range.
    if(upper!=0 && upper<lower){if(error)*error=@"最高金额不能低于最低金额；不设上限请填 0。";return NO;}
    if(minimum)*minimum=lower;if(maximum)*maximum=upper;
    return YES;
}
- (void)amountInputChanged:(UITextField *)sender {
    UIAlertController *alert=self.amountAlert;if(!alert)return;
    NSString *error=nil;BOOL valid=[self validateAmountAlert:alert minimum:NULL maximum:NULL error:&error];
    alert.message=valid?@"人民币元，包含两端，最多两位小数。最低 0 不设下限，最高 0 不设上限。仅按领取前可知金额过滤；随机红包通常未知，是否放行由下方开关决定。":error;
    for(UIAlertAction *action in alert.actions)if([action.title isEqualToString:@"保存"])action.enabled=valid;
}
- (void)toggle:(UISwitch *)sender {
    [prefs() setBool:sender.on forKey:sender.accessibilityIdentifier];
    [prefs() synchronize];TKRefreshSpoofProfile();TKRefreshRecallLabels();
    if([sender.accessibilityIdentifier isEqualToString:kAutoRed]){[gTKSeenRedPackets removeAllObjects];[gTKRedQueue removeAllObjects];}
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];NSString *action=self.sections[ip.section][ip.row][@"action"];
    if (!action)return;
    if ([action isEqualToString:@"amount"]) {
        UIAlertController *a=[UIAlertController alertControllerWithTitle:@"金额范围（人民币元）" message:nil preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *f){
            f.text=TKUIAmountString(prefInt(kRedMinAmount,100));f.placeholder=@"最低金额（元），0 不设下限";f.accessibilityLabel=@"最低金额，人民币元";
            UILabel *label=[[UILabel alloc] initWithFrame:CGRectMake(0,0,52,24)];label.text=@"最低";label.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];label.textColor=UIColor.secondaryLabelColor;
            f.leftView=label;f.leftViewMode=UITextFieldViewModeAlways;
            f.keyboardType=UIKeyboardTypeDecimalPad;f.clearButtonMode=UITextFieldViewModeWhileEditing;
            [f addTarget:self action:@selector(amountInputChanged:) forControlEvents:UIControlEventEditingChanged];
        }];
        [a addTextFieldWithConfigurationHandler:^(UITextField *f){
            f.text=TKUIAmountString(prefInt(kRedMaxAmount,0));f.placeholder=@"最高金额（元），0 不设上限";f.accessibilityLabel=@"最高金额，人民币元";
            UILabel *label=[[UILabel alloc] initWithFrame:CGRectMake(0,0,52,24)];label.text=@"最高";label.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];label.textColor=UIColor.secondaryLabelColor;
            f.leftView=label;f.leftViewMode=UITextFieldViewModeAlways;
            f.keyboardType=UIKeyboardTypeDecimalPad;f.clearButtonMode=UITextFieldViewModeWhileEditing;
            [f addTarget:self action:@selector(amountInputChanged:) forControlEvents:UIControlEventEditingChanged];
        }];
        self.amountAlert=a;__weak UIAlertController *weakAlert=a;
        [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
            NSInteger minimum=0,maximum=0;NSString *error=nil;
            if(![self validateAmountAlert:weakAlert minimum:&minimum maximum:&maximum error:&error]){[self showMessage:error];return;}
            [prefs() setInteger:minimum forKey:kRedMinAmount];[prefs() setInteger:maximum forKey:kRedMaxAmount];
            [prefs() synchronize];[self.tableView reloadData];
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [self amountInputChanged:nil];[self presentViewController:a animated:YES completion:nil];
    } else if ([action isEqualToString:@"model"]) {
        UIAlertController *a=[UIAlertController alertControllerWithTitle:@"伪装机型名称" message:@"已内置 iPhone 12–16 系列名称与标识映射，例如 iPhone 15 Pro。自定义未知名称只改变显示文字；不修改硬件或服务器历史。" preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *f){f.text=prefStr(kSpoofModel,@"iPhone 15 Pro");f.clearButtonMode=UITextFieldViewModeWhileEditing;}];
        __weak UIAlertController *weakAlert=a;
        [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){NSString *v=[weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(v.length&&v.length<=80){[prefs() setObject:v forKey:kSpoofModel];[prefs() synchronize];TKRefreshSpoofProfile();[self.tableView reloadData];}}]];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:a animated:YES completion:nil];
    } else if ([action isEqualToString:@"keywords"]) {
        TKRedKeywordsController *editor=[TKRedKeywordsController new];__weak TKSettingsController *weakSelf=self;
        editor.didSave=^{[weakSelf.tableView reloadData];};[self.navigationController pushViewController:editor animated:YES];
    } else if ([action isEqualToString:@"diagnostics"] || [action isEqualToString:@"copy"]) {
        NSDictionary *state=TKRuntimeSnapshot();NSMutableString *text=[NSMutableString stringWithFormat:@"TIMCleanKit %@\n%@\n",state[@"version"]?:@"1.0.6",state[@"process"]?:@"运行状态不可用"];
        [text appendString:@"\n功能引擎：\n"];
        NSDictionary *engine=[state[@"engine"] isKindOfClass:NSDictionary.class]?state[@"engine"]:@{};
        NSArray *keys=[[engine allKeys] sortedArrayUsingSelector:@selector(compare:)];
        for(NSString *key in keys)[text appendFormat:@"%@ = %@\n",key,engine[key]];
        if(!keys.count)[text appendString:@"暂无引擎键值\n"];
        for(NSDictionary *r in state[@"hookRows"])[text appendFormat:@"\n%@\n%@ · 调用 %@ 次\n",r[@"name"],r[@"state"],r[@"hits"]];
        for(NSString *warning in state[@"warnings"])[text appendFormat:@"\n%@\n",warning];
        if([action isEqualToString:@"copy"]) {UIPasteboard.generalPasteboard.string=text;UIAlertController *a=[UIAlertController alertControllerWithTitle:@"已复制" message:@"摘要仅含版本、功能引擎键值、注册状态与计数，不含消息内容。" preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:a animated:YES completion:nil];}
        else {UIViewController *vc=[UIViewController new];vc.title=@"运行状态";UITextView *view=[[UITextView alloc] init];view.editable=NO;view.alwaysBounceVertical=YES;view.backgroundColor=UIColor.clearColor;view.textColor=UIColor.labelColor;view.font=[UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];view.textContainerInset=UIEdgeInsetsMake(18,18,24,18);view.text=text;vc.view=view;[self.navigationController pushViewController:vc animated:YES];}
    }
}
@end
#include "TKGlassPopup.h"
static void TKPresentSettings(UIWindow *window) {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{TKPresentSettings(window);});return;}
    UIViewController *vc=window.rootViewController;
    while(vc) {
        if([vc isKindOfClass:TKGlassPopupController.class])return;
        if(!vc.presentedViewController)break;
        vc=vc.presentedViewController;
    }
    if(!vc||vc.isBeingDismissed||vc.isBeingPresented||[vc isKindOfClass:UIAlertController.class])return;
    [vc presentViewController:[TKGlassPopupController new] animated:YES completion:nil];
}
