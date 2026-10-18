//  TKVoiceAI.h — 2.2.0 语音与 AI
//  功能来源（独立实现，不引用原插件代码）：
//   · 消息朗读 / 文字转语音：系统 AVSpeechSynthesizer + 可选千问 TTS（qwen3-tts-instruct-flash）
//   · AI 助手：OpenAI / DeepSeek 兼容 /chat/completions，悬浮球入口、人设、记忆轮数、温度
//   · 悬浮球：拖动、菜单（朗读剪贴板 / 文字转语音 / AI 助手 / 设置）
//  限制：不伪造 TIM 语音消息发送链路（silk 编码/录音会话需真机验证），只做朗读与合成播放。
#import <AVFoundation/AVFoundation.h>

static void TKStopSpeaking(void);
static void TKOpenVoiceAISettingsFrom(UIViewController *host);
static void TKUpdateVoiceBallVisibility(void);
static void TKInstallVoiceAI(void);
static void TKVoiceAutoReadRecord(id record);

#pragma mark - 通用
static UIViewController *TKTopViewController(void) {
    UIWindow *key=nil;
    for(UIWindow *w in UIApplication.sharedApplication.windows){if(w.isKeyWindow){key=w;break;}}
    if(!key)key=UIApplication.sharedApplication.windows.firstObject;
    UIViewController *vc=key.rootViewController;
    while(vc.presentedViewController)vc=vc.presentedViewController;
    return vc;
}
static void TKPresentVC(UIViewController *vc) {
    UIViewController *top=TKTopViewController();
    if(!top||top.isBeingPresented||top.isBeingDismissed)return;
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle=UIModalPresentationPageSheet;
    [top presentViewController:nav animated:YES completion:nil];
}
static void TKAlert(NSString *title, NSString *message) {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:title?:@"TIMCleanKit" message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    dispatch_async(dispatch_get_main_queue(),^{UIViewController *top=TKTopViewController();if(top&&!top.isBeingPresented)[top presentViewController:a animated:YES completion:nil];});
}
// 单行文本编辑：字符串配置统一走这里
static void TKEditString(UIViewController *host,NSString *title,NSString *message,NSString *key,NSString *def,UIKeyboardType keyboard,BOOL secure,void(^done)(NSString *value)) {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf){
        tf.text=prefStr(key,def);tf.keyboardType=keyboard;tf.secureTextEntry=secure;
        tf.clearButtonMode=UITextFieldViewModeWhileEditing;tf.autocapitalizationType=UITextAutocapitalizationTypeNone;tf.autocorrectionType=UITextAutocorrectionTypeNo;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
        NSString *v=[a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]?:@"";
        [prefs() setObject:v forKey:key];[prefs() synchronize];
        if(done)done(v);
    }]];
    [host presentViewController:a animated:YES completion:nil];
}

#pragma mark - 文本提取
static NSString *TKVoiceTextOfRecord(id record) {
    NSMutableString *t=[NSMutableString string];
    @try {
        id els=TKObjectCall(record,@"elements");
        if([els isKindOfClass:NSArray.class]) {
            for(id e in els) {
                id te=TKObjectCall(e,@"textElement"),c=te?TKObjectCall(te,@"content"):nil;
                if([c isKindOfClass:NSString.class]&&[c length])[t appendString:c];
            }
        }
    } @catch(NSException *ignored) {}
    return [t copy];
}

#pragma mark - TTS 引擎
static AVSpeechSynthesizer *gTKSpeaker=nil;
static AVAudioPlayer *gTKPlayer=nil;
static NSMutableSet *gTKReadSeen=nil;
static double TKVoiceRate(void) {
    double r=[[prefs() objectForKey:kTKReadRate] doubleValue];
    if(r<=0)r=1.0;
    return MAX(0.5,MIN(2.0,r));
}
static void TKStopSpeaking(void) {
    if(gTKSpeaker)[gTKSpeaker stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    if(gTKPlayer){[gTKPlayer stop];gTKPlayer=nil;}
}
static void TKSpeakText(NSString *text) {
    if(![text isKindOfClass:NSString.class]||!text.length)return;
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{TKSpeakText(text);});return;}
    TKStopSpeaking();
    if(!gTKSpeaker)gTKSpeaker=[AVSpeechSynthesizer new];
    AVSpeechUtterance *u=[AVSpeechUtterance speechUtteranceWithString:text];
    NSString *vid=prefStr(kTKReadVoice,@"");
    AVSpeechSynthesisVoice *v=vid.length?[AVSpeechSynthesisVoice voiceWithIdentifier:vid]:nil;
    if(!v)v=[AVSpeechSynthesisVoice voiceWithLanguage:@"zh-CN"];
    if(v)u.voice=v;
    u.rate=MAX(0.1f,MIN(1.0f,(float)(0.5*TKVoiceRate())));
    u.pitchMultiplier=1.0f;
    [gTKSpeaker speakUtterance:u];
}
// 自动朗读：只处理新收到（onRecvMsg）的文本消息，去重防重复
static void TKVoiceAutoReadRecord(id record) {
    if(!prefBool(kEnabled,YES)||!prefBool(kTKAutoRead,NO))return;
    if(![record isKindOfClass:NSClassFromString(@"OCMsgRecord")])return;
    long long mid=(long long)TKScalar(record,@"msgId","q");
    if(mid) {
        if(!gTKReadSeen)gTKReadSeen=[NSMutableSet new];
        NSString *key=@(mid).stringValue;
        if([gTKReadSeen containsObject:key])return;
        [gTKReadSeen addObject:key];
        if(gTKReadSeen.count>300){NSArray *all=gTKReadSeen.allObjects;for(NSString *old in [all subarrayWithRange:NSMakeRange(0,100)])[gTKReadSeen removeObject:old];}
    }
    NSString *text=TKVoiceTextOfRecord(record);
    if(text.length)TKSpeakText(text);
}

#pragma mark - 千问 TTS
static NSString *const kTKQwenVoiceNames=@"Cherry,Serena,Ethan,Chelsie,Momo,Vivian,Moon,Maia,Kai,Nofish,Bella,Jennifer,Ryan,Katerina,Aiden,Eldric Sage,Mia,Mochi,Bellona,Vincent,Bunny,Neil,Elias,Arthur,Nini,Seren,Pip,Stella,Bodega,Sonrisa,Alek,Dolce,Sohee,Ono Anna,Lenn,Emilien,Andre,Radio Gol,Jada,Dylan,Marcus,Roy,Peter,Sunny,Eric,Rocky,Kiki";
static void TKPlayAudioData(NSData *data) {
    if(!data.length)return;
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{TKPlayAudioData(data);});return;}
    TKStopSpeaking();
    NSError *err=nil;
    gTKPlayer=[[AVAudioPlayer alloc] initWithData:data error:&err];
    if(!gTKPlayer){TKAlert(@"播放失败",err.localizedDescription?:@"音频无法解码");return;}
    AVAudioSession *s=[AVAudioSession sharedInstance];
    [s setCategory:AVAudioSessionCategoryPlayback error:nil];
    [s setActive:YES error:nil];
    [gTKPlayer play];
}
static void TKQwenSynthesize(NSString *text,void(^status)(NSString *),void(^fail)(NSString *)) {
    NSString *key=prefStr(kTKQwenKey,@"");
    if(!key.length){if(fail)fail(@"未配置千问 API Key（设置 → 语音与 AI）");return;}
    NSString *base=prefStr(kTKQwenBase,@"dashscope.aliyuncs.com");
    NSString *model=prefStr(kTKQwenModel,@"qwen3-tts-instruct-flash-2026-01-26");
    NSString *voice=prefStr(kTKQwenVoice,@"Cherry");
    NSString *instr=prefStr(kTKQwenInstr,@"");
    NSMutableDictionary *input=[NSMutableDictionary dictionaryWithDictionary:@{@"text":text,@"voice":voice,@"format":@"wav"}];
    NSMutableDictionary *params=[NSMutableDictionary dictionaryWithDictionary:@{@"speech_rate":@(TKVoiceRate())}];
    if(instr.length)params[@"instruction"]=instr;
    NSDictionary *body=@{@"model":model,@"input":input,@"parameters":params};
    NSURL *url=[NSURL URLWithString:[NSString stringWithFormat:@"https://%@/api/v1/services/aigc/multimodal-generation/generation",base]];
    if(!url){if(fail)fail(@"千问接口地址无效");return;}
    NSMutableURLRequest *req=[NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod=@"POST";req.timeoutInterval=60;
    [req setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody=[NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if(status)status(@"合成中…");
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data,NSURLResponse *resp,NSError *err){
        if(err){if(fail)fail(err.localizedDescription);return;}
        NSDictionary *json=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if(![json isKindOfClass:NSDictionary.class]){if(fail)fail(@"千问返回非 JSON");return;}
        NSString *audioURL=json[@"output"][@"audio"][@"url"];
        if(![audioURL isKindOfClass:NSString.class]||!audioURL.length){
            NSString *msg=json[@"message"]?:json[@"code"];
            if(fail)fail([NSString stringWithFormat:@"千问无音频地址%@",msg?[@"：" stringByAppendingString:msg]:@""]);
            return;
        }
        if(status)status(@"下载音频…");
        [[NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:audioURL] completionHandler:^(NSData *audio,NSURLResponse *r2,NSError *e2){
            if(e2||!audio.length){if(fail)fail(e2.localizedDescription?:@"音频下载失败");return;}
            if(status)status(@"播放中…");
            TKPlayAudioData(audio);
        }] resume];
    }] resume];
}

#pragma mark - 音色列表
@interface TKVoiceListController : UITableViewController
@property(nonatomic,strong) NSArray<AVSpeechSynthesisVoice *> *voices;
@end
@implementation TKVoiceListController
- (instancetype)init {
    if((self=[super initWithStyle:UITableViewStyleInsetGrouped])){
        NSArray *all=[AVSpeechSynthesisVoice speechVoices];
        NSMutableArray *zh=[NSMutableArray new],*other=[NSMutableArray new];
        for(AVSpeechSynthesisVoice *v in all){if([v.language hasPrefix:@"zh"])[zh addObject:v];else [other addObject:v];}
        [zh sortUsingComparator:^NSComparisonResult(AVSpeechSynthesisVoice *a,AVSpeechSynthesisVoice *b){return [a.name compare:b.name];}];
        [other sortUsingComparator:^NSComparisonResult(AVSpeechSynthesisVoice *a,AVSpeechSynthesisVoice *b){return [a.language compare:b.language];}];
        self.voices=[zh arrayByAddingObjectsFromArray:other];
        self.title=@"朗读音色";
    }
    return self;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t{return prefStr(kTKQwenKey,@"").length?2:1;}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s{
    if(s==1)return [[kTKQwenVoiceNames componentsSeparatedByString:@","] count];
    return self.voices.count;
}
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s{return s==0?@"系统音色（离线）":@"千问音色（需 Key，联网）";}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip{
    UITableViewCell *c=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSString *cur=prefStr(kTKReadVoice,@"");
    NSString *backend=prefStr(kTKVoiceBackend,@"system");
    if(ip.section==1){
        NSArray *names=[kTKQwenVoiceNames componentsSeparatedByString:@","];
        c.textLabel.text=names[ip.row];
        c.detailTextLabel.text=@"千问 TTS · 支持语气/语速";
        c.accessoryType=([backend isEqualToString:@"qwen"]&&[cur isEqualToString:names[ip.row]])?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone;
    } else {
        AVSpeechSynthesisVoice *v=self.voices[ip.row];
        c.textLabel.text=v.name;c.detailTextLabel.text=v.language;
        c.accessoryType=([backend isEqualToString:@"system"]&&[cur isEqualToString:v.identifier])?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone;
    }
    return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip{
    [t deselectRowAtIndexPath:ip animated:YES];
    if(ip.section==1){
        NSArray *names=[kTKQwenVoiceNames componentsSeparatedByString:@","];
        [prefs() setObject:@"qwen" forKey:kTKVoiceBackend];[prefs() setObject:names[ip.row] forKey:kTKQwenVoice];
    } else {
        AVSpeechSynthesisVoice *v=self.voices[ip.row];
        [prefs() setObject:@"system" forKey:kTKVoiceBackend];[prefs() setObject:v.identifier forKey:kTKReadVoice];
    }
    [prefs() synchronize];
    [self.navigationController popViewControllerAnimated:YES];
}
@end

#pragma mark - 文字转语音面板
@interface TKVoicePanelController : UIViewController
@property(nonatomic,strong) UITextView *textView;
@property(nonatomic,strong) UILabel *voiceLabel,*statusLabel,*rateCaption;
@property(nonatomic,strong) UISlider *rateSlider;
@property(nonatomic,strong) UITextField *instrField;
@property(nonatomic,strong) UIButton *voicePickButton,*speakButton,*stopButton,*btnCopyText;
@end
@implementation TKVoicePanelController
- (instancetype)init {
    if((self=[super init])){
        self.title=@"文字转语音";
        self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStyleDone target:self action:@selector(close)];
    }
    return self;
}
- (void)close {TKStopSpeaking();[self dismissViewControllerAnimated:YES completion:nil];}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor=UIColor.systemGroupedBackgroundColor;
    self.textView=[UITextView new];self.textView.font=[UIFont systemFontOfSize:16];self.textView.layer.cornerRadius=10;
    self.textView.backgroundColor=UIColor.secondarySystemGroupedBackgroundColor;self.textView.textContainerInset=UIEdgeInsetsMake(12,10,12,10);
    self.textView.text=UIPasteboard.generalPasteboard.string?:@"";
    [self.view addSubview:self.textView];
    self.voiceLabel=[UILabel new];self.voiceLabel.font=[UIFont systemFontOfSize:15];self.voiceLabel.textColor=UIColor.labelColor;
    [self.view addSubview:self.voiceLabel];
    UIButton *pick=[UIButton buttonWithType:UIButtonTypeSystem];[pick setTitle:@"选择音色 ›" forState:UIControlStateNormal];
    [pick addTarget:self action:@selector(pickVoice) forControlEvents:UIControlEventTouchUpInside];[self.view addSubview:pick];self.voicePickButton=pick;
    UILabel *rateCap=[UILabel new];rateCap.text=@"语速";rateCap.font=[UIFont systemFontOfSize:13];rateCap.textColor=UIColor.secondaryLabelColor;[self.view addSubview:rateCap];self.rateCaption=rateCap;
    self.rateSlider=[UISlider new];self.rateSlider.minimumValue=0.5;self.rateSlider.maximumValue=2.0;
    self.rateSlider.value=(float)TKVoiceRate();[self.rateSlider addTarget:self action:@selector(rateChanged) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.rateSlider];
    self.instrField=[UITextField new];self.instrField.placeholder=@"语气（仅千问，如：温柔地、生气地）";
    self.instrField.font=[UIFont systemFontOfSize:14];self.instrField.borderStyle=UITextBorderStyleRoundedRect;
    self.instrField.text=prefStr(kTKQwenInstr,@"");
    [self.instrField addTarget:self action:@selector(instrChanged) forControlEvents:UIControlEventEditingChanged];
    [self.view addSubview:self.instrField];
    UIButton *speak=[UIButton buttonWithType:UIButtonTypeSystem];
    [speak setTitle:@"朗读" forState:UIControlStateNormal];speak.titleLabel.font=[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    speak.backgroundColor=UIColor.systemBlueColor;[speak setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    speak.layer.cornerRadius=12;[speak addTarget:self action:@selector(speakTap) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:speak];self.speakButton=speak;
    UIButton *stop=[UIButton buttonWithType:UIButtonTypeSystem];
    [stop setTitle:@"停止" forState:UIControlStateNormal];stop.layer.cornerRadius=12;
    stop.backgroundColor=UIColor.secondarySystemGroupedBackgroundColor;
    [stop addTarget:self action:@selector(stopTap) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:stop];self.stopButton=stop;
    UIButton *copy=[UIButton buttonWithType:UIButtonTypeSystem];
    [copy setTitle:@"复制文本" forState:UIControlStateNormal];
    [copy addTarget:self action:@selector(copyTap) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:copy];self.btnCopyText=copy;
    self.statusLabel=[UILabel new];self.statusLabel.font=[UIFont systemFontOfSize:12];self.statusLabel.textColor=UIColor.secondaryLabelColor;
    self.statusLabel.textAlignment=NSTextAlignmentCenter;[self.view addSubview:self.statusLabel];
    [self refreshVoiceLabel];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w=self.view.bounds.size.width,h=self.view.bounds.size.height,safe=h;
    if(@available(iOS 11.0,*))safe=h-self.view.safeAreaInsets.bottom;
    CGFloat pad=16,y=12;
    self.textView.frame=CGRectMake(pad,y,w-pad*2,MAX(120,MIN(220,h*0.32)));y=CGRectGetMaxY(self.textView.frame)+12;
    self.voiceLabel.frame=CGRectMake(pad,y,w*0.55,22);
    self.voicePickButton.frame=CGRectMake(w-pad-110,y-4,110,30);y+=30;
    self.rateCaption.frame=CGRectMake(pad,y,w*0.2,20);
    self.rateSlider.frame=CGRectMake(pad+w*0.2,y+2,w-pad*2-w*0.2,30);y+=38;
    self.instrField.frame=CGRectMake(pad,y,w-pad*2,36);y+=46;
    CGFloat btnH=46;
    self.speakButton.frame=CGRectMake(pad,y,(w-pad*2-12)/2,btnH);
    self.stopButton.frame=CGRectMake(CGRectGetMaxX(self.speakButton.frame)+12,y,(w-pad*2-12)/2,btnH);y+=btnH+10;
    self.btnCopyText.frame=CGRectMake(pad,y,w-pad*2,36);y+=40;
    self.statusLabel.frame=CGRectMake(pad,safe-30,w-pad*2,20);
}
- (void)refreshVoiceLabel {
    NSString *backend=prefStr(kTKVoiceBackend,@"system");
    if([backend isEqualToString:@"qwen"])self.voiceLabel.text=[NSString stringWithFormat:@"千问 · %@",prefStr(kTKQwenVoice,@"Cherry")];
    else {
        AVSpeechSynthesisVoice *v=[AVSpeechSynthesisVoice voiceWithIdentifier:prefStr(kTKReadVoice,@"")];
        self.voiceLabel.text=[NSString stringWithFormat:@"系统 · %@",v.name?:@"中文默认"];
    }
}
- (void)pickVoice {[self.navigationController pushViewController:[TKVoiceListController new] animated:YES];}
- (void)viewWillAppear:(BOOL)animated {[super viewWillAppear:animated];[self refreshVoiceLabel];}
- (void)rateChanged {[prefs() setObject:@(self.rateSlider.value) forKey:kTKReadRate];[prefs() synchronize];}
- (void)instrChanged {[prefs() setObject:self.instrField.text?:@"" forKey:kTKQwenInstr];[prefs() synchronize];}
- (void)speakTap {
    NSString *text=[self.textView.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!text.length){TKAlert(@"请输入文字",@"文本框为空。");return;}
    if([prefStr(kTKVoiceBackend,@"system") isEqualToString:@"qwen"]){
        __weak typeof(self) weakSelf=self;
        TKQwenSynthesize(text,^(NSString *s){dispatch_async(dispatch_get_main_queue(),^{weakSelf.statusLabel.text=s;});},
                         ^(NSString *e){dispatch_async(dispatch_get_main_queue(),^{weakSelf.statusLabel.text=[@"失败：" stringByAppendingString:e];});});
    } else {
        TKSpeakText(text);self.statusLabel.text=@"播放中…";
    }
}
- (void)stopTap {TKStopSpeaking();self.statusLabel.text=@"已停止";}
- (void)copyTap {UIPasteboard.generalPasteboard.string=self.textView.text?:@"";self.statusLabel.text=@"已复制";}
@end

#pragma mark - AI 助手聊天
@class TKVoiceAISettingsController;
@interface TKAIChatController : UIViewController <UITableViewDataSource,UITableViewDelegate,UITextFieldDelegate>
@property(nonatomic,strong) UITableView *tableView;
@property(nonatomic,strong) UITextField *inputField;
@property(nonatomic,strong) UIButton *sendButton;
@property(nonatomic,strong) UIView *barView;
@property(nonatomic,strong) UIActivityIndicatorView *spinner;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *messages;
@property(nonatomic,assign) BOOL waiting;
@end
@implementation TKAIChatController
- (instancetype)init {
    if((self=[super init])){
        self.title=@"AI 助手";
        self.messages=[NSMutableArray new];
        self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"设置" style:UIBarButtonItemStylePlain target:self action:@selector(openSettings)];
        self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain target:self action:@selector(clearChat)];
    }
    return self;
}
- (void)openSettings {TKOpenVoiceAISettingsFrom(self);}
- (void)clearChat {[self.messages removeAllObjects];[self.tableView reloadData];}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor=UIColor.systemGroupedBackgroundColor;
    self.tableView=[[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.dataSource=self;self.tableView.delegate=self;
    self.tableView.keyboardDismissMode=UIScrollViewKeyboardDismissModeInteractive;
    self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=64;
    [self.view addSubview:self.tableView];
    UIView *bar=[UIView new];bar.backgroundColor=UIColor.secondarySystemGroupedBackgroundColor;bar.tag=9901;[self.view addSubview:bar];self.barView=bar;
    self.inputField=[UITextField new];self.inputField.placeholder=@"输入问题…";self.inputField.font=[UIFont systemFontOfSize:15];
    self.inputField.borderStyle=UITextBorderStyleRoundedRect;self.inputField.returnKeyType=UIReturnKeySend;
    self.inputField.delegate=self;[bar addSubview:self.inputField];
    self.sendButton=[UIButton buttonWithType:UIButtonTypeSystem];[self.sendButton setTitle:@"发送" forState:UIControlStateNormal];
    self.sendButton.titleLabel.font=[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [self.sendButton addTarget:self action:@selector(sendTap) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:self.sendButton];
    self.spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [bar addSubview:self.spinner];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardChanged:) name:UIKeyboardWillChangeFrameNotification object:nil];
    [self reloadAndScroll];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w=self.view.bounds.size.width,h=self.view.bounds.size.height;
    CGFloat safe=h;
    if(@available(iOS 11.0,*))safe=h-self.view.safeAreaInsets.bottom;
    CGFloat barH=54;
    self.barView.frame=CGRectMake(0,safe-barH,w,barH);
    self.inputField.frame=CGRectMake(12,9,w-12-72-12-26,36);
    self.sendButton.frame=CGRectMake(w-12-64,9,64,36);
    self.spinner.frame=CGRectMake(w-12-64-28,17,20,20);
    self.tableView.frame=CGRectMake(0,0,w,safe-barH);
}
- (void)keyboardChanged:(NSNotification *)n {
    CGRect end=[n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat kb=[self.view convertRect:end fromView:nil].origin.y;
    CGFloat h=self.view.bounds.size.height;
    CGFloat overlap=MAX(0,h-kb);
    UIEdgeInsets in=UIEdgeInsetsMake(0,0,overlap,0);
    self.tableView.contentInset=in;self.tableView.scrollIndicatorInsets=in;
    [UIView animateWithDuration:.22 animations:^{
        CGFloat w=self.view.bounds.size.width;
        CGFloat barH=54;
        CGFloat safe=h-overlap;
        if(@available(iOS 11.0,*))safe=h-overlap-self.view.safeAreaInsets.bottom;
        self.barView.frame=CGRectMake(0,safe-barH,w,barH);
        self.tableView.frame=CGRectMake(0,0,w,safe-barH);
    }];
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s{return self.messages.count;}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid=@"tkai";
    UITableViewCell *c=[t dequeueReusableCellWithIdentifier:cid];
    if(!c){c=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];c.textLabel.numberOfLines=0;c.textLabel.font=[UIFont systemFontOfSize:15];}
    NSDictionary *m=self.messages[ip.row];
    BOOL user=[m[@"role"] isEqualToString:@"user"];
    c.textLabel.text=[NSString stringWithFormat:@"%@%@",user?@"我：":@"AI：",m[@"content"]?:@""];
    c.textLabel.textColor=user?UIColor.labelColor:UIColor.secondaryLabelColor;
    c.backgroundColor=user?UIColor.secondarySystemGroupedBackgroundColor:UIColor.clearColor;
    return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *m=self.messages[ip.row];
    UIPasteboard.generalPasteboard.string=m[@"content"]?:@"";
    TKAlert(@"已复制",nil);
}
- (void)reloadAndScroll {
    [self.tableView reloadData];
    if(self.messages.count)[self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:self.messages.count-1 inSection:0] atScrollPosition:UITableViewScrollPositionBottom animated:YES];
}
- (BOOL)textFieldShouldReturn:(UITextField *)tf {[self sendTap];return YES;}
- (void)sendTap {
    if(self.waiting)return;
    NSString *text=[self.inputField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!text.length)return;
    if(!prefStr(kTKAIKey,@"").length){
        TKAlert(@"未配置 API Key",@"设置 → 语音与 AI → AI 助手，填写接口地址、API Key 和模型。");
        return;
    }
    [self.messages addObject:@{@"role":@"user",@"content":text}];
    self.inputField.text=@"";[self reloadAndScroll];
    self.waiting=YES;[self.spinner startAnimating];self.sendButton.enabled=NO;
    [self requestReply];
}
- (void)requestReply {
    NSString *base=prefStr(kTKAIBase,@"https://api.openai.com/v1");
    while([base hasSuffix:@"/"])base=[base substringToIndex:base.length-1];
    NSString *urlStr=[base stringByAppendingString:@"/chat/completions"];
    NSURL *url=[NSURL URLWithString:urlStr];
    if(!url){[self fail:@"接口地址无效"];return;}
    NSMutableArray *msgs=[NSMutableArray array];
    NSString *persona=prefStr(kTKAIPersona,@"你是 TIM 聊天助手，用简洁中文回答。");
    if(persona.length)[msgs addObject:@{@"role":@"system",@"content":persona}];
    NSInteger memory=MAX(0,MIN(40,prefInt(kTKAIMemory,6)));
    NSInteger start=MAX(0,(NSInteger)self.messages.count-memory*2);
    for(NSInteger i=start;i<(NSInteger)self.messages.count;i++)[msgs addObject:self.messages[i]];
    double temp=[[prefs() objectForKey:kTKAITemp] doubleValue];
    if(temp<=0)temp=0.7;
    temp=MAX(0.0,MIN(2.0,temp));
    NSDictionary *body=@{@"model":prefStr(kTKAIModel,@"gpt-4o-mini"),@"messages":msgs,@"temperature":@(temp)};
    NSMutableURLRequest *req=[NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod=@"POST";req.timeoutInterval=90;
    [req setValue:[@"Bearer " stringByAppendingString:prefStr(kTKAIKey,@"")] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody=[NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data,NSURLResponse *resp,NSError *err){
        dispatch_async(dispatch_get_main_queue(),^{
            self.waiting=NO;[self.spinner stopAnimating];self.sendButton.enabled=YES;
            if(err){[self fail:err.localizedDescription];return;}
            NSDictionary *json=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if(![json isKindOfClass:NSDictionary.class]){[self fail:@"返回非 JSON"];return;}
            NSString *content=json[@"choices"][0][@"message"][@"content"];
            if(![content isKindOfClass:NSString.class]||!content.length){
                NSString *e=json[@"error"][@"message"]?:json[@"message"];
                [self fail:e?:@"接口无回复"];
                return;
            }
            [self.messages addObject:@{@"role":@"assistant",@"content":content}];
            [self reloadAndScroll];
        });
    }] resume];
}
- (void)fail:(NSString *)msg {
    self.waiting=NO;[self.spinner stopAnimating];self.sendButton.enabled=YES;
    TKAlert(@"AI 请求失败",msg?:@"未知错误");
}
@end

#pragma mark - 语音与 AI 设置页
@interface TKVoiceAISettingsController : UITableViewController
@end
@implementation TKVoiceAISettingsController
- (instancetype)init {if((self=[super initWithStyle:UITableViewStyleInsetGrouped]))self.title=@"语音与 AI";return self;}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t{return 4;}
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s{return @[@"朗读",@"文字转语音",@"AI 助手",@"悬浮球"][s];}
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s{
    if(s==1)return @"系统音色离线可用；千问音色需要 DashScope API Key。";
    if(s==2)return @"兼容 OpenAI / DeepSeek 的 /chat/completions 接口。";
    return nil;
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s{return (NSInteger)[@[@3,@3,@6,@1][s] integerValue];}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    if(ip.section==0){
        if(ip.row==0){c.textLabel.text=@"自动朗读新消息";UISwitch *sw=[UISwitch new];sw.on=prefBool(kTKAutoRead,NO);sw.tag=1001;[sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];c.accessoryView=sw;c.selectionStyle=UITableViewCellSelectionStyleNone;}
        else if(ip.row==1){c.textLabel.text=@"朗读音色";NSString *b=prefStr(kTKVoiceBackend,@"system");c.detailTextLabel.text=[b isEqualToString:@"qwen"]?[@"千问·" stringByAppendingString:prefStr(kTKQwenVoice,@"Cherry")]:@"系统默认";}
        else {c.textLabel.text=@"朗读语速";c.detailTextLabel.text=[NSString stringWithFormat:@"%.2fx",TKVoiceRate()];}
    } else if(ip.section==1){
        if(ip.row==0){c.textLabel.text=@"打开文字转语音";}
        else if(ip.row==1){c.textLabel.text=@"千问 API Key";c.detailTextLabel.text=prefStr(kTKQwenKey,@"").length?@"已配置":@"未配置";}
        else {c.textLabel.text=@"千问模型";c.detailTextLabel.text=prefStr(kTKQwenModel,@"qwen3-tts-instruct-flash-2026-01-26");}
    } else if(ip.section==2){
        if(ip.row==0){c.textLabel.text=@"打开 AI 助手";}
        else if(ip.row==1){c.textLabel.text=@"接口地址";c.detailTextLabel.text=prefStr(kTKAIBase,@"https://api.openai.com/v1");}
        else if(ip.row==2){c.textLabel.text=@"API Key";c.detailTextLabel.text=prefStr(kTKAIKey,@"").length?@"已配置":@"未配置";}
        else if(ip.row==3){c.textLabel.text=@"模型";c.detailTextLabel.text=prefStr(kTKAIModel,@"gpt-4o-mini");}
        else if(ip.row==4){c.textLabel.text=@"人设";c.detailTextLabel.text=prefStr(kTKAIPersona,@"");}
        else {c.textLabel.text=@"记忆轮数";c.detailTextLabel.text=[NSString stringWithFormat:@"%ld",(long)prefInt(kTKAIMemory,6)];}
    } else {
        c.textLabel.text=@"显示悬浮球";UISwitch *sw=[UISwitch new];sw.on=prefBool(kTKFloatBall,YES);sw.tag=1002;[sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];c.accessoryView=sw;c.selectionStyle=UITableViewCellSelectionStyleNone;
    }
    return c;
}
- (void)switchChanged:(UISwitch *)sw {
    if(sw.tag==1001){[prefs() setObject:@(sw.on) forKey:kTKAutoRead];}
    else {[prefs() setObject:@(sw.on) forKey:kTKFloatBall];TKUpdateVoiceBallVisibility();}
    [prefs() synchronize];
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if(ip.section==0){
        if(ip.row==1)[self.navigationController pushViewController:[TKVoiceListController new] animated:YES];
        else if(ip.row==2)TKEditString(self,@"朗读语速",@"0.5 – 2.0，默认 1.0",kTKReadRate,@"1.0",UIKeyboardTypeDecimalPad,NO,^(NSString *v){[t reloadData];});
    } else if(ip.section==1){
        if(ip.row==0)TKPresentVC([TKVoicePanelController new]);
        else if(ip.row==1)TKEditString(self,@"千问 API Key",@"DashScope API Key，仅保存在本机",kTKQwenKey,@"",UIKeyboardTypeDefault,YES,^(NSString *v){[t reloadData];});
        else TKEditString(self,@"千问模型",nil,kTKQwenModel,@"qwen3-tts-instruct-flash-2026-01-26",UIKeyboardTypeDefault,NO,^(NSString *v){[t reloadData];});
    } else if(ip.section==2){
        if(ip.row==0)TKPresentVC([TKAIChatController new]);
        else if(ip.row==1)TKEditString(self,@"接口地址",@"例如 https://api.openai.com/v1 或 https://api.deepseek.com/v1",kTKAIBase,@"https://api.openai.com/v1",UIKeyboardTypeURL,NO,^(NSString *v){[t reloadData];});
        else if(ip.row==2)TKEditString(self,@"API Key",@"仅保存在本机",kTKAIKey,@"",UIKeyboardTypeDefault,YES,^(NSString *v){[t reloadData];});
        else if(ip.row==3)TKEditString(self,@"模型",@"例如 gpt-4o-mini / deepseek-chat",kTKAIModel,@"gpt-4o-mini",UIKeyboardTypeDefault,NO,^(NSString *v){[t reloadData];});
        else if(ip.row==4)TKEditString(self,@"人设",@"系统提示词",kTKAIPersona,@"你是 TIM 聊天助手，用简洁中文回答。",UIKeyboardTypeDefault,NO,^(NSString *v){[t reloadData];});
        else TKEditString(self,@"记忆轮数",@"0 – 40",kTKAIMemory,@"6",UIKeyboardTypeNumberPad,NO,^(NSString *v){[t reloadData];});
    }
}
@end

#pragma mark - 悬浮球
@interface TKBallTarget : NSObject
+ (instancetype)shared;
- (void)onBallTap:(UITapGestureRecognizer *)g;
- (void)onBallPan:(UIPanGestureRecognizer *)g;
@end
static UIView *gTKBall=nil;
static void TKShowVoiceMenu(void) {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"TIMCleanKit" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"朗读剪贴板" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
        NSString *s=UIPasteboard.generalPasteboard.string;
        if(!s.length){TKAlert(@"剪贴板为空",nil);return;}
        TKSpeakText(s);
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"文字转语音" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){TKPresentVC([TKVoicePanelController new]);}]];
    [a addAction:[UIAlertAction actionWithTitle:@"AI 助手" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){TKPresentVC([TKAIChatController new]);}]];
    [a addAction:[UIAlertAction actionWithTitle:@"设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){TKPresentSettings(nil);}]];
    [a addAction:[UIAlertAction actionWithTitle:@"隐藏悬浮球" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){
        [prefs() setObject:@NO forKey:kTKFloatBall];[prefs() synchronize];TKUpdateVoiceBallVisibility();
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView=gTKBall;a.popoverPresentationController.sourceRect=gTKBall.bounds;
    UIViewController *top=TKTopViewController();
    if(top&&!top.isBeingPresented)[top presentViewController:a animated:YES completion:nil];
}
static void TKBallMoved(UIPanGestureRecognizer *g) {
    UIView *w=g.view.superview;
    if(!w)return;
    CGPoint p=[g translationInView:w];
    CGPoint c=g.view.center;
    c.x+=p.x;c.y+=p.y;
    CGFloat half=g.view.bounds.size.width/2;
    c.x=MAX(half+8,MIN(w.bounds.size.width-half-8,c.x));
    c.y=MAX(half+8,MIN(w.bounds.size.height-half-8,c.y));
    g.view.center=c;
    [g setTranslation:CGPointZero inView:w];
    if(g.state==UIGestureRecognizerStateEnded){
        [prefs() setObject:[NSString stringWithFormat:@"%.0f,%.0f",c.x,c.y] forKey:kTKFloatPos];
        [prefs() synchronize];
    }
}
static void TKUpdateVoiceBallVisibility(void) {
    dispatch_async(dispatch_get_main_queue(),^{
        BOOL show=prefBool(kEnabled,YES)&&prefBool(kTKFloatBall,YES);
        if(!show){[gTKBall removeFromSuperview];gTKBall=nil;return;}
        if(gTKBall)return;
        UIWindow *w=nil;
        for(UIWindow *win in UIApplication.sharedApplication.windows){if(win.isKeyWindow){w=win;break;}}
        if(!w)w=UIApplication.sharedApplication.windows.firstObject;
        if(!w)return;
        UIView *b=[[UIView alloc] initWithFrame:CGRectMake(0,0,52,52)];
        b.layer.cornerRadius=26;b.layer.masksToBounds=YES;
        b.backgroundColor=[UIColor colorWithRed:0.18 green:0.42 blue:0.90 alpha:0.92];
        UIImageView *icon=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"waveform"]];
        icon.tintColor=UIColor.whiteColor;icon.contentMode=UIViewContentModeScaleAspectFit;icon.frame=CGRectMake(13,13,26,26);
        [b addSubview:icon];b.userInteractionEnabled=YES;
        b.layer.shadowColor=UIColor.blackColor.CGColor;b.layer.shadowOpacity=.25;b.layer.shadowRadius=6;b.layer.shadowOffset=CGSizeMake(0,2);
        NSString *pos=prefStr(kTKFloatPos,@"");
        CGPoint c=CGPointMake(w.bounds.size.width-40,w.bounds.size.height*0.6);
        if(pos.length){NSArray *xy=[pos componentsSeparatedByString:@","];if(xy.count==2)c=CGPointMake([xy[0] doubleValue],[xy[1] doubleValue]);}
        b.center=c;
        UITapGestureRecognizer *tap=[[UITapGestureRecognizer alloc] initWithTarget:[TKBallTarget shared] action:@selector(onBallTap:)];
        UIPanGestureRecognizer *pan=[[UIPanGestureRecognizer alloc] initWithTarget:[TKBallTarget shared] action:@selector(onBallPan:)];
        [b addGestureRecognizer:tap];[b addGestureRecognizer:pan];
        [w addSubview:b];gTKBall=b;
    });
}
@implementation TKBallTarget
+ (instancetype)shared {static TKBallTarget *s;static dispatch_once_t once;dispatch_once(&once,^{s=[TKBallTarget new];});return s;}
- (void)onBallTap:(UITapGestureRecognizer *)g {TKShowVoiceMenu();}
- (void)onBallPan:(UIPanGestureRecognizer *)g {TKBallMoved(g);}
@end

static void TKOpenVoiceAISettingsFrom(UIViewController *host) {
    TKVoiceAISettingsController *c=[TKVoiceAISettingsController new];
    if(host.navigationController)[host.navigationController pushViewController:c animated:YES];
    else TKPresentVC(c);
}
static void TKInstallVoiceAI(void) {
    static BOOL observed=NO;
    if(!observed){observed=YES;
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){TKStopSpeaking();}];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){TKUpdateVoiceBallVisibility();}];
    }
    TKUpdateVoiceBallVisibility();
}
