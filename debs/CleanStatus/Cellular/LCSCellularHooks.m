#import <UIKit/UIKit.h>
#import <substrate.h>
#import "LCSCellularSettings.h"
#import "LCSCellularRuntime.h"
#import "LCSCellularPanel.h"

// This image is SpringBoard-only. It never replaces buttonTapped: or _toggleState.
static char LCSCellularStateKey,LCSCellularButtonKey;
static Class LCSNativeCellularClass;
static unsigned LCSHookMask;
static NSHashTable *LCSCellularStates;
static __weak LCSCellularSIMController *LCSPresentedSIM;
@class LCSCellularButtonState,LCSCellularPressHandler;
@interface LCSCellularPress : UILongPressGestureRecognizer
@property(nonatomic,weak) LCSCellularButtonState *owner;
@end
@implementation LCSCellularPress
@end
@interface LCSCellularButtonState : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic,weak) UIViewController *controller;
@property(nonatomic,weak) UIControl *button;
@property(nonatomic,weak) UIWindow *window;
@property(nonatomic,strong) LCSCellularPress *directPress;
@property(nonatomic,strong) LCSCellularPress *windowPress;
@property(nonatomic,strong) LCSCellularPressHandler *handler;
- (void)bind;
- (void)unbind;
- (BOOL)allowed;
- (void)pressed:(LCSCellularPress *)gesture;
@end
@interface LCSCellularPressHandler : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic,weak) LCSCellularButtonState *owner;
@end
@implementation LCSCellularPressHandler
- (void)pressed:(LCSCellularPress *)gesture {[self.owner pressed:gesture];}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {return [self.owner gestureRecognizerShouldBegin:g];}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {return [self.owner gestureRecognizer:g shouldReceiveTouch:touch];}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {(void)a;(void)b;return NO;}
@end
static BOOL LCSVisible(UIView *view) {
    if(!view.window)return NO;
    for(UIView *v=view;v;v=v.superview)if(v.hidden||v.alpha<.01)return NO;
    return YES;
}
static BOOL LCSDirectTouch(UIView *view) {
    for(UIView *v=view;v;v=v.superview)if(!v.userInteractionEnabled)return NO;
    return YES;
}
static UIViewController *LCSTop(UIView *anchor) {
    UIViewController *top=anchor.window.rootViewController;
    while(top.presentedViewController&&!top.presentedViewController.isBeingDismissed)top=top.presentedViewController;
    return top.isBeingDismissed?nil:top;
}
static void LCSFindButton(UIView *view,Class cls,NSMutableArray *matches,NSUInteger depth) {
    if(!view||depth>12||matches.count>1)return;
    if([view isKindOfClass:cls]){[matches addObject:view];return;}
    for(UIView *child in view.subviews)LCSFindButton(child,cls,matches,depth+1);
}
static BOOL LCSTapContract(UIControl *button) {
    BOOL primary=NO,early=NO;
    // Do not bind if the stock action happens on TouchDown, before a long press can cancel it.
    for(id target in button.allTargets) {
        id object=target==NSNull.null?nil:target;
        for(NSNumber *event in @[@(UIControlEventTouchUpInside),@(UIControlEventPrimaryActionTriggered)])
            for(NSString *action in [button actionsForTarget:object forControlEvent:event.unsignedIntegerValue])if([action isEqualToString:@"buttonTapped:"])primary=YES;
        early|=[button actionsForTarget:object forControlEvent:UIControlEventTouchDown].count>0;
        early|=[button actionsForTarget:object forControlEvent:UIControlEventTouchDownRepeat].count>0;
    }
    return LCSCellularTapBindingSafe(primary,early,YES,YES);
}
@implementation LCSCellularButtonState
- (BOOL)allowed {
    UIViewController *top=LCSTop(self.button);
    BOOL conflict=LCSPresentedSIM!=nil||[top isKindOfClass:UIAlertController.class]||
        [top isKindOfClass:NSClassFromString(@"LCSCCListViewController")]||
        [top isKindOfClass:LCSCellularSIMController.class];
    return LCSCellularPresentPolicy(LCSCellularSIMManager,LCSCellularFeatureEnabled(LCSCellularSIMManager),
        LCSCellularIsSpringBoard(),(int)NSProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        LCSCellularIsUnlocked(),LCSVisible(self.button),self.controller&&self.button,conflict,
        self.controller.isBeingDismissed||self.controller.isBeingPresented);
}
- (void)unbind {
    if(self.directPress)[self.button removeGestureRecognizer:self.directPress];
    if(self.windowPress)[self.window removeGestureRecognizer:self.windowPress];
    if(objc_getAssociatedObject(self.button,&LCSCellularButtonKey)==self)
        objc_setAssociatedObject(self.button,&LCSCellularButtonKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    self.directPress=nil;self.windowPress=nil;self.button=nil;self.window=nil;
}
- (LCSCellularPress *)newPress {
    if(!self.handler){self.handler=[LCSCellularPressHandler new];self.handler.owner=self;}
    LCSCellularPress *press=[[LCSCellularPress alloc] initWithTarget:self.handler action:@selector(pressed:)];
    press.owner=self;press.delegate=self.handler;press.minimumPressDuration=.45;press.allowableMovement=10;
    press.cancelsTouchesInView=YES;press.delaysTouchesBegan=NO;press.delaysTouchesEnded=NO;
    return press;
}
- (void)bind {
    if(!LCSCellularFeatureEnabled(LCSCellularSIMManager)){[self unbind];return;}
    if(!self.controller.isViewLoaded||![self.controller isKindOfClass:LCSNativeCellularClass]||(LCSHookMask&9U)!=9U)return;
    Class cls=NSClassFromString(@"CCUIRoundButton");if(!cls)return;
    NSMutableArray *buttons=[NSMutableArray array];LCSFindButton(self.controller.view,cls,buttons,0);
    if(buttons.count!=1||![buttons.firstObject isKindOfClass:UIControl.class]) {
        [self unbind];LCSCellularLog(LCSCellularSIMManager,@"binding",@"ambiguous-button",0);return;
    }
    UIControl *button=buttons.firstObject;
    if(!LCSTapContract(button)){[self unbind];LCSCellularLog(LCSCellularSIMManager,@"binding",@"tap-contract-unverified",0);return;}
    if(self.button!=button||!self.directPress) {
        [self unbind];self.button=button;self.directPress=[self newPress];[button addGestureRecognizer:self.directPress];
        objc_setAssociatedObject(button,&LCSCellularButtonKey,self,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LCSCellularLog(LCSCellularSIMManager,@"binding",@"bound",0);
    }
    if(self.window!=button.window) {
        if(self.windowPress)[self.window removeGestureRecognizer:self.windowPress];self.window=button.window;self.windowPress=nil;
        if(self.window){self.windowPress=[self newPress];[self.window addGestureRecognizer:self.windowPress];}
    }
}
- (void)pressed:(LCSCellularPress *)gesture {
    if(gesture.state!=UIGestureRecognizerStateBegan||![self allowed])return;
    UIViewController *top=LCSTop(self.button);if(!top)return;
    LCSCellularSIMController *panel=[LCSCellularSIMController new];LCSPresentedSIM=panel;
    __weak typeof(self) weakSelf=self;__weak LCSCellularSIMController *weakPanel=panel;
    panel.mayContinue=^BOOL{
        LCSCellularButtonState *s=weakSelf;
        return s&&s.controller&&LCSVisible(s.button)&&LCSCellularFeatureEnabled(LCSCellularSIMManager)&&LCSCellularIsUnlocked();
    };
    panel.didClose=^{if(LCSPresentedSIM==weakPanel)LCSPresentedSIM=nil;};
    [top presentViewController:panel animated:YES completion:^{if(!panel.mayContinue||!panel.mayContinue())[panel close];}];
    LCSCellularLog(LCSCellularSIMManager,@"present",@"sim-manager",0);
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if(![self allowed])return NO;
    return gesture==self.directPress?LCSDirectTouch(self.button):!LCSDirectTouch(self.button);
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    if(![self allowed])return NO;
    if(gesture==self.directPress)return YES;
    UIView *hit=touch.view;
    BOOL belongs=hit&&hit!=self.window&&([hit isDescendantOfView:self.controller.view]||[self.button isDescendantOfView:hit]);
    return belongs&&!LCSDirectTouch(self.button)&&CGRectContainsPoint(self.button.bounds,[touch locationInView:self.button]);
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    (void)a;(void)b;return NO;
}
- (void)dealloc {
    if(_directPress)[_button removeGestureRecognizer:_directPress];
    if(_windowPress)[_window removeGestureRecognizer:_windowPress];
}
@end

static void (*LCSOriginalLoad)(id,SEL);
static void (*LCSOriginalAppear)(id,SEL,BOOL);
static void (*LCSOriginalDisappear)(id,SEL,BOOL);
static BOOL (*LCSOriginalRoundBegin)(id,SEL,id);
static void (*LCSOriginalRoundMove)(id,SEL);
static LCSCellularButtonState *LCSState(id object) {
    LCSCellularButtonState *state=objc_getAssociatedObject(object,&LCSCellularStateKey);
    if(!state){state=[LCSCellularButtonState new];state.controller=object;
        objc_setAssociatedObject(object,&LCSCellularStateKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);[LCSCellularStates addObject:state];}
    return state;
}
static void LCSLoaded(id self,SEL sel) {LCSOriginalLoad(self,sel);[LCSState(self) bind];}
static void LCSAppeared(id self,SEL sel,BOOL animated) {LCSOriginalAppear(self,sel,animated);[LCSState(self) bind];}
static void LCSDisappeared(id self,SEL sel,BOOL animated) {
    LCSOriginalDisappear(self,sel,animated);LCSCellularButtonState *s=objc_getAssociatedObject(self,&LCSCellularStateKey);
    if(s&&(!s.button.window||!LCSVisible(s.button)))[LCSPresentedSIM close];
}
static BOOL LCSRoundBegin(id self,SEL sel,id gesture) {
    if([gesture isKindOfClass:LCSCellularPress.class])return [[gesture owner] gestureRecognizerShouldBegin:gesture];
    LCSCellularButtonState *state=objc_getAssociatedObject(self,&LCSCellularButtonKey);
    // Only replace the long-press semantics of this identified cellular button.
    // Ordinary gestures, pans, all other controls and short taps always forward.
    if(state&&[gesture isKindOfClass:UILongPressGestureRecognizer.class]&&[state allowed])return NO;
    return LCSOriginalRoundBegin(self,sel,gesture);
}
static void LCSRoundMoved(id self,SEL sel) {
    LCSOriginalRoundMove(self,sel);LCSCellularButtonState *state=objc_getAssociatedObject(self,&LCSCellularButtonKey);if(state)[state bind];
}
static BOOL LCSInstall(Class cls,const char *name,const char *result,unsigned count,const char *const *args,IMP replacement,IMP *original) {
    SEL sel=sel_registerName(name);if(!LCSCellularMethod(cls,sel,result,count,args))return NO;
    // MSHookMessageEx isolates inherited methods and handles arm64e IMP signing.
    MSHookMessageEx(cls,sel,replacement,original);return *original!=NULL;
}
static void LCSInstallHooks(void) {
    if(!NSThread.isMainThread||!LCSCellularIsSpringBoard()||NSProcessInfo.processInfo.operatingSystemVersion.majorVersion!=15)return;
    Class native=NSClassFromString(@"CCUIConnectivityCellularDataViewController");
    const char *file=native?class_getImageName(native):NULL;
    NSString *image=file?[NSString stringWithUTF8String:file]:nil;
    if(![image hasSuffix:@"/System/Library/ControlCenter/Bundles/ConnectivityModule.bundle/ConnectivityModule"]) {
        LCSCellularLog(LCSCellularSIMManager,@"hook",@"native-image-unverified",0);return;
    }
    LCSNativeCellularClass=native;
    const char *boolean[]={"B"};
    if(!(LCSHookMask&1)&&LCSInstall(native,"viewDidLoad","v",0,NULL,(IMP)LCSLoaded,(IMP *)&LCSOriginalLoad))LCSHookMask|=1;
    if(!(LCSHookMask&2)&&LCSInstall(native,"viewDidAppear:","v",1,boolean,(IMP)LCSAppeared,(IMP *)&LCSOriginalAppear))LCSHookMask|=2;
    if(!(LCSHookMask&4)&&LCSInstall(native,"viewDidDisappear:","v",1,boolean,(IMP)LCSDisappeared,(IMP *)&LCSOriginalDisappear))LCSHookMask|=4;
    Class round=NSClassFromString(@"CCUIRoundButton");
    if(!(LCSHookMask&8)&&LCSInstall(round,"gestureRecognizerShouldBegin:","B",1,(const char *[]){"@"},(IMP)LCSRoundBegin,(IMP *)&LCSOriginalRoundBegin))LCSHookMask|=8;
    if(!(LCSHookMask&16)&&LCSInstall(round,"didMoveToWindow","v",0,NULL,(IMP)LCSRoundMoved,(IMP *)&LCSOriginalRoundMove))LCSHookMask|=16;
}
static void LCSReconcile(void) {
    LCSInstallHooks();
    for(LCSCellularButtonState *state in LCSCellularStates)[state bind];
    if(!LCSCellularFeatureEnabled(LCSCellularSIMManager)||!LCSCellularIsUnlocked())[LCSPresentedSIM close];
}
__attribute__((constructor)) static void LCSCellularInitialize(void) {
    @autoreleasepool {
        if(!LCSCellularIsSpringBoard()||NSProcessInfo.processInfo.operatingSystemVersion.majorVersion!=15)return;
        LCSCellularStartConfiguration();
        dispatch_async(dispatch_get_main_queue(),^{
            LCSCellularStates=[NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory];
            static NSMutableArray *observers;observers=[NSMutableArray new];
            for(NSString *name in @[NSBundleDidLoadNotification,LCSCellularPreferencesDidChange,@"SBDeviceLockStateChangedNotification"])
                [observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){(void)n;LCSReconcile();}]];
            [observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){(void)n;[LCSPresentedSIM close];}]];
            LCSReconcile();
            for(NSNumber *delay in @[@.5,@2,@5,@10,@20])dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay.doubleValue*NSEC_PER_SEC)),dispatch_get_main_queue(),^{LCSInstallHooks();});
        });
    }
}
