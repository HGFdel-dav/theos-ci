#import "LocalCleanStatusRuntime.h"
#import "LocalCleanStatusCCRuntime.h"
#import "LocalCleanStatusCCEnvironment.h"
#import "LocalCleanStatusCCListViewController.h"
#import "LocalCleanStatusCCPolicy.h"
#import "LocalCleanStatusCCDiagnostics.h"
#import "LocalCleanStatusConfig.h"

static char lcscc_controllerKey,lcscc_buttonKey;
static __weak LCSCCListViewController *lcscc_presentedList;
@interface LCSCCPress : UILongPressGestureRecognizer
@end
@implementation LCSCCPress
@end
@class LCSCCControllerState;
@interface LCSCCPressHandler : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic,weak) LCSCCControllerState *state;
@end
@interface LCSCCControllerState : NSObject
@property(nonatomic,weak) UIViewController *controller;
@property(nonatomic,weak) UIView *button;
@property(nonatomic,weak) UIWindow *fallbackWindow;
@property(nonatomic,strong) LCSCCPress *press;
@property(nonatomic,strong) LCSCCPress *windowPress;
@property(nonatomic,strong) LCSCCPressHandler *handler;
@property(nonatomic) LCSCCTargetKind kind;
@property(nonatomic) BOOL expanded;
- (BOOL)allowed;
- (void)bind;
- (void)presentList;
@end
static BOOL lcscc_viewVisible(UIView *view) {
    if(!view.window)return NO;
    for(UIView *v=view;v;v=v.superview) if(v.hidden||v.alpha<0.01)return NO;
    return YES;
}
static BOOL lcscc_directTouch(UIView *view) {
    for(UIView *v=view;v;v=v.superview) if(!v.userInteractionEnabled)return NO;
    return YES;
}
static void lcscc_findButtons(UIView *view,Class cls,NSMutableArray *matches,NSUInteger depth) {
    if(!view||depth>12||matches.count>1)return;
    if([view isKindOfClass:cls]){[matches addObject:view];return;}
    for(UIView *child in view.subviews)lcscc_findButtons(child,cls,matches,depth+1);
}
static UIViewController *lcscc_top(UIView *anchor) {
    UIViewController *vc=anchor.window.rootViewController;
    while(vc.presentedViewController&&!vc.presentedViewController.isBeingDismissed)vc=vc.presentedViewController;
    return vc.isBeingDismissed?nil:vc;
}
static BOOL lcscc_otherPickerEnabled(LCSCCTargetKind kind) {
    // Read-only interoperability. Do not alter QuickCC2's settings, gestures or
    // hooks. Its presence alone is not a conflict when the feature is off.
    id prefs=lcscc_object(NSClassFromString(@"QC2Prefs"),"shared");
    return lcscc_bool(prefs,"enabled",NO) && lcscc_bool(prefs,kind==LCSCCTargetKindWiFi?"wifiEnabled":"bluetoothEnabled",NO);
}
@implementation LCSCCControllerState
- (BOOL)allowed {
    // Recorded video shows the press landing on the big Wi-Fi tile inside the
    // expanded connectivity module, so both collapsed and expanded anchors are
    // accepted. Lock/visibility/enabled still gate every presentation.
    return local_cleanstatus_ccCanPresent(local_cleanstatus_currentFlags(),(LocalCleanStatusCCKind)self.kind,
        local_cleanstatus_ccUnlocked(),NO,lcscc_viewVisible(self.button),
        lcscc_presentedList!=nil,lcscc_otherPickerEnabled(self.kind));
}
- (void)bind {
    if(!self.controller.isViewLoaded)return;
    Class cls=NSClassFromString(@"CCUIRoundButton");if(!cls)return;
    NSMutableArray *buttons=[NSMutableArray new];lcscc_findButtons(self.controller.view,cls,buttons,0);
    if(buttons.count!=1){local_cleanstatus_ccLog(@"cc.button",buttons.count?@"ambiguous":@"missing");return;}
    UIView *button=buttons.firstObject;
    if(self.button!=button) {
        if(self.press)[self.button removeGestureRecognizer:self.press];
        self.button=button;
        self.handler=[LCSCCPressHandler new];self.handler.state=self;
        self.press=[[LCSCCPress alloc] initWithTarget:self.handler action:@selector(pressed:)];
        self.press.delegate=self.handler;self.press.minimumPressDuration=0.45;
        self.press.cancelsTouchesInView=NO;[button addGestureRecognizer:self.press];
        objc_setAssociatedObject(button,&lcscc_buttonKey,self,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        local_cleanstatus_ccLog(@"cc.button",self.kind==LCSCCTargetKindWiFi?@"wifi.bound":@"bluetooth.bound");
    }
    UIWindow *window=button.window;
    if(self.fallbackWindow!=window) {
        if(self.windowPress)[self.fallbackWindow removeGestureRecognizer:self.windowPress];
        self.fallbackWindow=window;
        if(window){
            self.windowPress=[[LCSCCPress alloc] initWithTarget:self.handler action:@selector(pressed:)];
            self.windowPress.delegate=self.handler;self.windowPress.minimumPressDuration=0.45;
            self.windowPress.cancelsTouchesInView=NO;[window addGestureRecognizer:self.windowPress];
        }
    }
}
- (void)presentList {
    if(![self allowed])return;
    UIViewController *top=lcscc_top(self.button);if(!top||[top isKindOfClass:LCSCCListViewController.class])return;
    if([top isKindOfClass:UIAlertController.class])return;
    LCSCCListViewController *list=[[LCSCCListViewController alloc] initWithKind:self.kind];
    __weak typeof(self) weakSelf=self;
    list.mayContinue=^{
        BOOL ok=weakSelf.controller!=nil&&!weakSelf.expanded&&lcscc_viewVisible(weakSelf.button);
        return ok;
    };
    list.didClose=^{lcscc_presentedList=nil;};
    lcscc_presentedList=list;
    UIImpactFeedbackGenerator *feedback=[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];[feedback impactOccurred];
    [top presentViewController:list animated:YES completion:nil];
    local_cleanstatus_ccLog(@"cc.present",self.kind==LCSCCTargetKindWiFi?@"wifi.card":@"bluetooth.card");
}
- (void)dealloc {
    if(_press)[_button removeGestureRecognizer:_press];
    if(_windowPress)[_fallbackWindow removeGestureRecognizer:_windowPress];
}
@end
@implementation LCSCCPressHandler
- (void)pressed:(UIGestureRecognizer *)recognizer {
    if(recognizer.state==UIGestureRecognizerStateBegan)[self.state presentList];
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if(![self.state allowed])return NO;
    BOOL direct=lcscc_directTouch(self.state.button);
    return recognizer==self.state.press?direct:!direct;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    if(![self.state allowed])return NO;
    if(recognizer!=self.state.windowPress)return YES;
    if(lcscc_directTouch(self.state.button))return NO;
    CGPoint point=[touch locationInView:self.state.button];
    return CGRectContainsPoint(CGRectInset(self.state.button.bounds,-8,-10),point);
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    (void)recognizer;return ![other isKindOfClass:UIPanGestureRecognizer.class];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    (void)recognizer;(void)other;return NO;
}
@end

static LCSCCControllerState *lcscc_state(id controller,LCSCCTargetKind kind) {
    LCSCCControllerState *state=objc_getAssociatedObject(controller,&lcscc_controllerKey);
    if(!state){state=[LCSCCControllerState new];state.controller=controller;state.kind=kind;
        objc_setAssociatedObject(controller,&lcscc_controllerKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
    return state;
}
static void (*lcscc_wifiLoaded)(id,SEL),(*lcscc_bluetoothLoaded)(id,SEL);
static void (*lcscc_wifiAppeared)(id,SEL,BOOL),(*lcscc_bluetoothAppeared)(id,SEL,BOOL);
static void (*lcscc_wifiExpanded)(id,SEL,BOOL),(*lcscc_bluetoothExpanded)(id,SEL,BOOL);
static BOOL (*lcscc_roundShouldBegin)(id,SEL,id);
static void (*lcscc_roundMoved)(id,SEL);
static void lcscc_didLoadWiFi(id self,SEL sel){lcscc_wifiLoaded(self,sel);[lcscc_state(self,LCSCCTargetKindWiFi) bind];}
static void lcscc_didLoadBluetooth(id self,SEL sel){lcscc_bluetoothLoaded(self,sel);[lcscc_state(self,LCSCCTargetKindBluetooth) bind];}
static void lcscc_didAppearWiFi(id self,SEL sel,BOOL animated){lcscc_wifiAppeared(self,sel,animated);[lcscc_state(self,LCSCCTargetKindWiFi) bind];}
static void lcscc_didAppearBluetooth(id self,SEL sel,BOOL animated){lcscc_bluetoothAppeared(self,sel,animated);[lcscc_state(self,LCSCCTargetKindBluetooth) bind];}
static void lcscc_expanded(id self,BOOL expanded,LCSCCTargetKind kind) {
    LCSCCControllerState *state=lcscc_state(self,kind);state.expanded=expanded;
    if(expanded)[lcscc_presentedList close];
    else[state bind];
}
static void lcscc_willExpandWiFi(id self,SEL sel,BOOL expanded){lcscc_wifiExpanded(self,sel,expanded);lcscc_expanded(self,expanded,LCSCCTargetKindWiFi);}
static void lcscc_willExpandBluetooth(id self,SEL sel,BOOL expanded){lcscc_bluetoothExpanded(self,sel,expanded);lcscc_expanded(self,expanded,LCSCCTargetKindBluetooth);}
static BOOL lcscc_roundGesture(id self,SEL sel,id gesture) {
    if([gesture isKindOfClass:LCSCCPress.class]) {
        LCSCCPressHandler *handler=[gesture delegate];return [handler gestureRecognizerShouldBegin:gesture];
    }
    return lcscc_roundShouldBegin(self,sel,gesture);
}
static void lcscc_roundWindow(id self,SEL sel) {
    lcscc_roundMoved(self,sel);
    LCSCCControllerState *state=objc_getAssociatedObject(self,&lcscc_buttonKey);
    if(state)[state bind];
}
static BOOL lcscc_hook(Class cls,const char *name,const char *result,unsigned count,const char * const *args,IMP replacement,IMP *original) {
    SEL sel=sel_registerName(name);
    if(!lcscc_method(cls,sel,result,count,args))return NO;
    // Substrate handles inherited methods and arm64e. Never replace a Method
    // obtained from the superclass, which changed unrelated controllers before.
    MSHookMessageEx(cls,sel,replacement,original);return *original!=NULL;
}
static unsigned lcscc_hookedWifi,lcscc_hookedBluetooth,lcscc_hookedRound;
static void lcscc_installController(Class cls,BOOL wifi,unsigned *mask) {
    if(!cls)return;
    const char *boolArg[]={@encode(BOOL)};
    if(!(*mask&1) && lcscc_hook(cls,"viewDidLoad",@encode(void),0,NULL,
       (IMP)(wifi?lcscc_didLoadWiFi:lcscc_didLoadBluetooth),(IMP *)(wifi?&lcscc_wifiLoaded:&lcscc_bluetoothLoaded)))*mask|=1;
    if(!(*mask&2) && lcscc_hook(cls,"viewDidAppear:",@encode(void),1,boolArg,
       (IMP)(wifi?lcscc_didAppearWiFi:lcscc_didAppearBluetooth),(IMP *)(wifi?&lcscc_wifiAppeared:&lcscc_bluetoothAppeared)))*mask|=2;
    if(!(*mask&4) && lcscc_hook(cls,"containerWillTransitionToExpandedContentMode:",@encode(void),1,boolArg,
       (IMP)(wifi?lcscc_willExpandWiFi:lcscc_willExpandBluetooth),(IMP *)(wifi?&lcscc_wifiExpanded:&lcscc_bluetoothExpanded)))*mask|=4;
}
void local_cleanstatus_installControlCenterHooks(void) {
    if(!NSThread.isMainThread||!local_cleanstatus_ccIsSpringBoard()||NSProcessInfo.processInfo.operatingSystemVersion.majorVersion!=15)return;
    lcscc_installController(NSClassFromString(@"CCUIConnectivityWifiViewController"),YES,&lcscc_hookedWifi);
    lcscc_installController(NSClassFromString(@"CCUIConnectivityBluetoothViewController"),NO,&lcscc_hookedBluetooth);
    Class round=NSClassFromString(@"CCUIRoundButton");
    if(!(lcscc_hookedRound&1) && lcscc_hook(round,"gestureRecognizerShouldBegin:",@encode(BOOL),1,(const char *[]){@encode(id)},(IMP)lcscc_roundGesture,(IMP *)&lcscc_roundShouldBegin))lcscc_hookedRound|=1;
    if(!(lcscc_hookedRound&2) && lcscc_hook(round,"didMoveToWindow",@encode(void),0,NULL,(IMP)lcscc_roundWindow,(IMP *)&lcscc_roundMoved))lcscc_hookedRound|=2;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        local_cleanstatus_ccLog(@"cc.hooks",[NSString stringWithFormat:@"wifi=%u bt=%u round=%u",lcscc_hookedWifi,lcscc_hookedBluetooth,lcscc_hookedRound]);
        [NSNotificationCenter.defaultCenter addObserverForName:NSBundleDidLoadNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){
            (void)note;local_cleanstatus_installControlCenterHooks();
        }];
        for(NSNumber *delay in @[@0.5,@2,@5,@10,@20]) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay.doubleValue*NSEC_PER_SEC)),dispatch_get_main_queue(),^{local_cleanstatus_installControlCenterHooks();});
    });
}
