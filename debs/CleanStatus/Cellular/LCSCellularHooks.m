#import <UIKit/UIKit.h>
#import <substrate.h>
#import "LCSCellularSettings.h"
#import "LCSCellularRuntime.h"
#import "LCSCellularPanel.h"

// SpringBoard-only. The stock buttonTapped:/_toggleState paths are never replaced.
static char LCSCellularStateKey,LCSCellularButtonKey;
static Class LCSNativeCellularClass;
static unsigned LCSHookMask;
static unsigned const LCSRequiredHookMask=39U;
static unsigned LCSHookFailureMask;
static NSHashTable *LCSCellularStates;
static __weak LCSCellularSIMController *LCSPresentedSIM;
static BOOL LCSPreviewHookReady,LCSCellularForeground=YES;
static BOOL (*LCSOriginalPreviewShouldBegin)(id,SEL,id);
static void (*LCSOriginalExpanded)(id,SEL,BOOL);
static void LCSLogHookFailure(unsigned bit,NSString *reason) {
    if(LCSHookFailureMask&bit)return;LCSHookFailureMask|=bit;
    LCSCellularLog(LCSCellularSIMManager,@"hook",reason,0);
}
@class LCSCellularButtonState;
// Standard recognizer, independent target/delegate. No UIKit subclass, private
// ownership selector or message forwarding.
@interface LCSCellularPressTarget : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic,weak) LCSCellularButtonState *binding;
- (void)lcs_handlePress:(UILongPressGestureRecognizer *)press;
@end
@interface LCSCellularButtonState : NSObject
@property(nonatomic,weak) UIViewController *controller;
@property(nonatomic,weak) UIControl *button;
@property(nonatomic,weak) UIWindow *boundWindow;
@property(nonatomic,weak) LCSCellularSIMController *panel;
@property(nonatomic,strong) UILongPressGestureRecognizer *directPress;
@property(nonatomic,strong) LCSCellularPressTarget *target;
@property(nonatomic,copy) NSString *lastBindingFailure;
@property(nonatomic) BOOL appeared;
@property(nonatomic) BOOL layoutPending;
@property(nonatomic) BOOL expanded;
@property(nonatomic) CFTimeInterval lastLayoutRetry;
- (void)bind;
- (void)unbind;
- (void)pressed:(UILongPressGestureRecognizer *)gesture;
- (BOOL)shouldYieldForGesture:(UIGestureRecognizer *)gesture other:(UIGestureRecognizer *)other;
- (BOOL)ownsPreview:(UIPreviewInteraction *)interaction container:(UIViewController *)container;
@end
@implementation LCSCellularPressTarget
- (void)lcs_handlePress:(UILongPressGestureRecognizer *)press {[self.binding pressed:press];}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    return [self.binding shouldYieldForGesture:gesture other:other];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    (void)gesture;(void)other;return NO;
}
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
    BOOL early=NO;
    for(id target in button.allTargets) {
        id object=target==NSNull.null?nil:target;
        early|=[button actionsForTarget:object forControlEvent:UIControlEventTouchDown].count>0;
        early|=[button actionsForTarget:object forControlEvent:UIControlEventTouchDownRepeat].count>0;
    }
    // A long hold must not intercept a control that already acts on touch-down.
    return !early;
}
@implementation LCSCellularButtonState
- (void)unbind {
    if(self.directPress){self.directPress.enabled=NO;self.directPress.delegate=nil;[self.button removeGestureRecognizer:self.directPress];[self.directPress removeTarget:self.target action:@selector(lcs_handlePress:)];}
    if(objc_getAssociatedObject(self.button,&LCSCellularButtonKey)==self)objc_setAssociatedObject(self.button,&LCSCellularButtonKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    self.directPress=nil;self.target=nil;self.button=nil;self.boundWindow=nil;self.expanded=NO;
}
- (NSString *)bindingFailureForButton:(UIControl *)button {
    if(!self.appeared)return @"controller-not-appeared";
    if((LCSHookMask&LCSRequiredHookMask)!=LCSRequiredHookMask)return @"lifecycle-hooks-incomplete";
    if(!LCSCellularFeatureEnabled(LCSCellularSIMManager))return @"feature-disabled";
    if(!self.controller.isViewLoaded||![self.controller isKindOfClass:LCSNativeCellularClass])return @"controller-mismatch";
    if(!button)return nil;
    if(!button.window||button.window!=self.controller.view.window)return @"button-window-mismatch";
    if(!LCSVisible(button))return @"button-not-visible";
    if(!LCSDirectTouch(button))return @"button-not-direct-touch";
    if(!LCSTapContract(button))return @"tap-contract-unverified";
    id owner=objc_getAssociatedObject(button,&LCSCellularButtonKey);if(owner&&owner!=self)return @"button-owned-elsewhere";
    UIView *view=button;while(view&&view!=self.controller.view)view=view.superview;
    return view==self.controller.view?nil:@"button-outside-controller";
}
- (void)logBindingFailure:(NSString *)reason {
    if(![self.lastBindingFailure isEqualToString:reason])LCSCellularLog(LCSCellularSIMManager,@"binding",reason,0);
    self.lastBindingFailure=reason;
}
- (BOOL)safeDirectButton:(UIControl *)button {
    NSString *reason=[self bindingFailureForButton:button];
    if(reason){[self logBindingFailure:reason];return NO;}
    self.lastBindingFailure=nil;return YES;
}
- (BOOL)shouldYieldForGesture:(UIGestureRecognizer *)gesture other:(UIGestureRecognizer *)other {
    if(!other||gesture!=self.directPress||other==gesture)return NO;
    // Same direction as the working Wi-Fi entry: do not make this long press
    // wait for a pan; ordinary taps still win, preserving the native short tap.
    return ![other isKindOfClass:UIPanGestureRecognizer.class];
}
- (BOOL)ownsPreview:(UIPreviewInteraction *)interaction container:(UIViewController *)container {
    if(self.expanded||LCSPresentedSIM||!self.directPress.enabled||self.directPress.numberOfTouches==0)return NO;
    if(!self.controller.isViewLoaded||![self.controller.view isDescendantOfView:container.view])return NO;
    if(![interaction isKindOfClass:UIPreviewInteraction.class])return NO;
    UIView *view=interaction.view;
    if(view&&!(view==container.view||[view isDescendantOfView:container.view]||[container.view isDescendantOfView:view]))return NO;
    if(self.directPress.state==UIGestureRecognizerStateFailed||
       self.directPress.state==UIGestureRecognizerStateCancelled||
       self.directPress.state==UIGestureRecognizerStateEnded)return NO;
    CGPoint point=[interaction locationInCoordinateSpace:self.button];
    return CGRectContainsPoint(CGRectInset(self.button.bounds,-8,-10),point);
}
- (void)scheduleLayoutRebind {
    if(self.directPress&&self.button.window==self.boundWindow&&LCSVisible(self.button))return;
    CFTimeInterval now=CACurrentMediaTime();
    if(self.layoutPending||now-self.lastLayoutRetry<.25)return;
    self.lastLayoutRetry=now;self.layoutPending=YES;__weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_main_queue(),^{LCSCellularButtonState *state=weakSelf;if(!state)return;state.layoutPending=NO;[state bindAfterLayout];});
}
- (void)bindAfterLayout {
    NSString *gate=[self bindingFailureForButton:nil];if(gate){[self logBindingFailure:gate];[self unbind];return;}
    Class cls=NSClassFromString(@"CCUIRoundButton");NSMutableArray *matches=[NSMutableArray new];if(cls)LCSFindButton(self.controller.view,cls,matches,0);
    if(!cls||matches.count!=1||![matches.firstObject isKindOfClass:UIControl.class]) {
        [self logBindingFailure:!cls?@"button-class-unavailable":(matches.count?@"button-ambiguous":@"button-not-found")];[self unbind];return;
    }
    if(![self safeDirectButton:matches.firstObject]){[self unbind];return;}
    UIControl *button=matches.firstObject;if(button==self.button&&self.directPress)return;
    [self unbind];self.button=button;self.boundWindow=button.window;
    self.target=[LCSCellularPressTarget new];self.target.binding=self;
    self.directPress=[[UILongPressGestureRecognizer alloc] initWithTarget:self.target action:@selector(lcs_handlePress:)];
    self.directPress.delegate=self.target;
    self.directPress.minimumPressDuration=.45;self.directPress.allowableMovement=10;
    self.directPress.cancelsTouchesInView=YES;self.directPress.delaysTouchesBegan=NO;self.directPress.delaysTouchesEnded=NO;
    [button addGestureRecognizer:self.directPress];objc_setAssociatedObject(button,&LCSCellularButtonKey,self,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LCSCellularLog(LCSCellularSIMManager,@"binding",@"bound-wifi-entry",0);
}
- (void)bind {[self scheduleLayoutRebind];}
- (void)pressed:(UILongPressGestureRecognizer *)gesture {
    if(gesture!=self.directPress)return;
    if(gesture.state!=UIGestureRecognizerStateBegan){
        if(gesture.state==UIGestureRecognizerStateEnded||gesture.state==UIGestureRecognizerStateCancelled||gesture.state==UIGestureRecognizerStateFailed)
            dispatch_async(dispatch_get_main_queue(),^{if(self.appeared&&self.button.window&&LCSVisible(self.button))[self bind];});
        return;
    }
    NSString *reason=nil;
    if(!LCSCellularFeatureEnabled(LCSCellularSIMManager))reason=@"feature-disabled";
    else if(!LCSCellularIsSpringBoard())reason=@"wrong-process";
    else if(!LCSCellularIsUnlocked())reason=@"device-locked";
    else if(!self.appeared||!self.controller||self.controller.isBeingDismissed||self.controller.isBeingPresented)reason=@"controller-unavailable";
    else if(!self.button.window||self.button.window!=self.boundWindow||self.button.window!=self.controller.view.window)reason=@"button-window-mismatch";
    else if(!LCSVisible(self.button))reason=@"button-not-visible";
    else if(!LCSDirectTouch(self.button))reason=@"button-not-direct-touch";
    else if(LCSPresentedSIM)reason=@"panel-already-presented";
    if(reason){LCSCellularLog(LCSCellularSIMManager,@"press",reason,0);return;}
    LCSCellularLog(LCSCellularSIMManager,@"entry",@"began-wifi",0);
    UIViewController *top=LCSTop(self.button);
    if(!top||top.isBeingDismissed||top.isBeingPresented){LCSCellularLog(LCSCellularSIMManager,@"press",@"presenter-unavailable",0);return;}
    LCSCellularSIMController *panel=[LCSCellularSIMController new];self.panel=panel;LCSPresentedSIM=panel;
    __weak typeof(self) weakSelf=self;__weak LCSCellularSIMController *weakPanel=panel;
    panel.mayContinue=^BOOL{LCSCellularButtonState *state=weakSelf;return state&&state.appeared&&
      !state.controller.isBeingDismissed&&state.button.window==state.boundWindow&&LCSVisible(state.button)&&
      LCSCellularFeatureEnabled(LCSCellularSIMManager)&&LCSCellularIsUnlocked();};
    panel.didClose=^{LCSCellularButtonState *state=weakSelf;if(state.panel==weakPanel)state.panel=nil;if(LCSPresentedSIM==weakPanel)LCSPresentedSIM=nil;};
    [top presentViewController:panel animated:YES completion:^{
        LCSCellularLog(LCSCellularSIMManager,@"present",panel.presentingViewController?@"sim-manager":@"presentation-missing",0);
        if(!panel.mayContinue||!panel.mayContinue())[panel close];
    }];
}
- (void)dealloc {[self unbind];}
@end

static void (*LCSOriginalLoad)(id,SEL);
static void (*LCSOriginalAppear)(id,SEL,BOOL);
static void (*LCSOriginalDisappear)(id,SEL,BOOL);
static void (*LCSOriginalLayout)(id,SEL);
static LCSCellularButtonState *LCSState(id object) {
    LCSCellularButtonState *state=objc_getAssociatedObject(object,&LCSCellularStateKey);
    if(!state){state=[LCSCellularButtonState new];state.controller=object;
        objc_setAssociatedObject(object,&LCSCellularStateKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);[LCSCellularStates addObject:state];}
    return state;
}
static void LCSLoaded(id self,SEL sel) {LCSOriginalLoad(self,sel);LCSState(self).appeared=YES;[LCSState(self) bind];}
static void LCSAppeared(id self,SEL sel,BOOL animated) {LCSOriginalAppear(self,sel,animated);LCSState(self).appeared=YES;[LCSState(self) bind];}
static void LCSDisappeared(id self,SEL sel,BOOL animated) {
    LCSOriginalDisappear(self,sel,animated);LCSCellularButtonState *s=objc_getAssociatedObject(self,&LCSCellularStateKey);
    if(s&&(!s.button.window||!LCSVisible(s.button))){s.appeared=NO;[s unbind];if(s.panel)[s.panel close];}
}
static void LCSLayoutSubviews(id self,SEL sel) {
    LCSOriginalLayout(self,sel);
    LCSCellularButtonState *state=objc_getAssociatedObject(self,&LCSCellularStateKey);
    if(state&&state.appeared&&LCSCellularFeatureEnabled(LCSCellularSIMManager))[state scheduleLayoutRebind];
}
static void LCSWillExpand(id self,SEL sel,BOOL expanded) {
    LCSCellularButtonState *state=LCSState(self);state.expanded=expanded;
    LCSOriginalExpanded(self,sel,expanded);
    if(expanded&&state.panel)[state.panel close];
    else [state bind];
}
static BOOL LCSPreviewShouldBegin(id self,SEL sel,id interaction) {
    // Shared by all Control Center modules. Only the verified cellular module,
    // with a live touch on its own button, is allowed to change the result.
    if(NSThread.isMainThread&&LCSPreviewHookReady&&LCSCellularForeground&&
       LCSCellularFeatureEnabled(LCSCellularSIMManager)&&LCSCellularIsUnlocked()&&
       [interaction isKindOfClass:UIPreviewInteraction.class]) {
        for(LCSCellularButtonState *state in LCSCellularStates)
            if([state ownsPreview:interaction container:self])return NO;
    }
    return LCSOriginalPreviewShouldBegin(self,sel,interaction);
}
static BOOL LCSInstall(Class cls,const char *name,const char *result,unsigned count,const char *const *args,IMP replacement,IMP *original) {
    SEL sel=sel_registerName(name);if(!LCSCellularMethod(cls,sel,result,count,args))return NO;
    // MSHookMessageEx isolates inherited methods and handles arm64e IMP signing.
    MSHookMessageEx(cls,sel,replacement,original);return *original!=NULL;
}
static void LCSInstallPreviewHook(void) {
    if(LCSPreviewHookReady)return;
    Class cls=NSClassFromString(@"CCUIContentModuleContainerViewController");
    const char *file=cls?class_getImageName(cls):NULL;
    NSString *image=file?[NSString stringWithUTF8String:file]:nil;
    if(!cls||![image hasSuffix:@"/System/Library/PrivateFrameworks/ControlCenterUI.framework/ControlCenterUI"]) {
        LCSLogHookFailure(64U,@"preview-container-unavailable");return;
    }
    const char *object[]={"@"};
    if(!LCSInstall(cls,"previewInteractionShouldBegin:","B",1,object,
       (IMP)LCSPreviewShouldBegin,(IMP *)&LCSOriginalPreviewShouldBegin)) {
        LCSLogHookFailure(128U,@"preview-shouldbegin-unavailable");return;
    }
    LCSPreviewHookReady=YES;
    LCSCellularLog(LCSCellularSIMManager,@"hook",@"preview-shouldbegin-installed",0);
}
static void LCSInstallHooks(void) {
    if(!NSThread.isMainThread||!LCSCellularIsSpringBoard()||NSProcessInfo.processInfo.operatingSystemVersion.majorVersion!=15)return;
    LCSInstallPreviewHook();
    if((LCSHookMask&LCSRequiredHookMask)==LCSRequiredHookMask&&(LCSHookMask&8U))return;
    Class native=NSClassFromString(@"CCUIConnectivityCellularDataViewController");
    if(!native){LCSLogHookFailure(1U,@"native-class-missing");return;}
    const char *file=class_getImageName(native);
    NSString *image=file?[NSString stringWithUTF8String:file]:nil;
    if(![image hasSuffix:@"/System/Library/ControlCenter/Bundles/ConnectivityModule.bundle/ConnectivityModule"]) {
        LCSLogHookFailure(2U,@"native-image-unverified");return;
    }
    LCSNativeCellularClass=native;
    const char *boolean[]={"B"};
    if(!(LCSHookMask&1)) {if(LCSInstall(native,"viewDidLoad","v",0,NULL,(IMP)LCSLoaded,(IMP *)&LCSOriginalLoad))LCSHookMask|=1;else LCSLogHookFailure(4U,@"load-hook-unavailable");}
    if(!(LCSHookMask&2)) {if(LCSInstall(native,"viewDidAppear:","v",1,boolean,(IMP)LCSAppeared,(IMP *)&LCSOriginalAppear))LCSHookMask|=2;else LCSLogHookFailure(8U,@"appear-hook-unavailable");}
    if(!(LCSHookMask&4)) {if(LCSInstall(native,"viewDidDisappear:","v",1,boolean,(IMP)LCSDisappeared,(IMP *)&LCSOriginalDisappear))LCSHookMask|=4;else LCSLogHookFailure(16U,@"disappear-hook-unavailable");}
    if(!(LCSHookMask&8U)) {if(LCSInstall(native,"containerWillTransitionToExpandedContentMode:","v",1,boolean,(IMP)LCSWillExpand,(IMP *)&LCSOriginalExpanded))LCSHookMask|=8U;else LCSLogHookFailure(256U,@"expanded-hook-unavailable");}
    if(!(LCSHookMask&32U)) {if(LCSInstall(native,"viewDidLayoutSubviews","v",0,NULL,(IMP)LCSLayoutSubviews,(IMP *)&LCSOriginalLayout)){LCSHookMask|=32U;LCSCellularLog(LCSCellularSIMManager,@"hook",@"layout-hook-installed",0);}else LCSLogHookFailure(32U,@"layout-hook-unavailable");}
}
static void LCSReconcile(void) {
    LCSInstallHooks();
    for(LCSCellularButtonState *state in LCSCellularStates) {
        if(!LCSCellularForeground||!LCSCellularFeatureEnabled(LCSCellularSIMManager)||!LCSCellularIsUnlocked()){
            [state unbind];if(state.panel)[state.panel close];
        } else [state bind];
    }
    if(!LCSCellularForeground||!LCSCellularFeatureEnabled(LCSCellularSIMManager)||!LCSCellularIsUnlocked())[LCSPresentedSIM close];
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
            [observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){
                (void)n;LCSCellularForeground=NO;
                for(LCSCellularButtonState *state in LCSCellularStates){[state unbind];if(state.panel)[state.panel close];}
                [LCSPresentedSIM close];
            }]];
            [observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){
                (void)n;LCSCellularForeground=YES;LCSReconcile();
            }]];
            LCSReconcile();
            for(NSNumber *delay in @[@.5,@2,@5,@10,@20])dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay.doubleValue*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
                LCSInstallHooks();if((LCSHookMask&LCSRequiredHookMask)==LCSRequiredHookMask)LCSReconcile();
            });
        });
    }
}
