#import <UIKit/UIKit.h>
#import <substrate.h>
#import "LCSCellularSettings.h"
#import "LCSCellularRuntime.h"
#import "LCSCellularPanel.h"

// SpringBoard-only. The stock buttonTapped:/_toggleState paths are never replaced.
static char LCSCellularStateKey,LCSCellularButtonKey;
static Class LCSNativeCellularClass;
static unsigned LCSHookMask;
static unsigned const LCSRequiredHookMask=7U;
static NSHashTable *LCSCellularStates;
static __weak LCSCellularSIMController *LCSPresentedSIM;
@class LCSCellularButtonState;
// Action-only target. No UIKit subclass, gesture delegate or private ownership selector.
@interface LCSCellularPressTarget : NSObject
@property(nonatomic,weak) LCSCellularButtonState *binding;
- (void)lcs_handlePress:(UILongPressGestureRecognizer *)press;
@end
@interface LCSCellularButtonState : NSObject {
    BOOL _handledBeginning;
}
@property(nonatomic,weak) UIViewController *controller;
@property(nonatomic,weak) UIControl *button;
@property(nonatomic,weak) UIWindow *boundWindow;
@property(nonatomic,weak) LCSCellularSIMController *panel;
@property(nonatomic,strong) UILongPressGestureRecognizer *directPress;
@property(nonatomic,strong) LCSCellularPressTarget *target;
@property(nonatomic) BOOL conflictLogged;
@property(nonatomic) BOOL appeared;
@property(nonatomic) BOOL layoutPending;
- (void)bind;
- (void)unbind;
- (void)pressed:(UILongPressGestureRecognizer *)gesture;
@end
@implementation LCSCellularPressTarget
- (void)lcs_handlePress:(UILongPressGestureRecognizer *)press {[self.binding pressed:press];}
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
static BOOL LCSHasAnyGesture(UIView *view,NSUInteger depth) {
    if(!view||depth>16)return YES;
    if(view.gestureRecognizers.count)return YES;
    for(UIView *child in view.subviews)if(LCSHasAnyGesture(child,depth+1))return YES;
    return NO;
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
    for(id target in button.allTargets) {
        id object=target==NSNull.null?nil:target;
        for(NSNumber *event in @[@(UIControlEventTouchUpInside),@(UIControlEventPrimaryActionTriggered)])
            for(NSString *action in [button actionsForTarget:object forControlEvent:event.unsignedIntegerValue])if([action isEqualToString:@"buttonTapped:"])primary=YES;
        early|=[button actionsForTarget:object forControlEvent:UIControlEventTouchDown].count>0;
        early|=[button actionsForTarget:object forControlEvent:UIControlEventTouchDownRepeat].count>0;
    }
    // Unknown target/action arrangements are not proof the stock short tap is safe.
    return primary&&!early;
}
@implementation LCSCellularButtonState
- (void)unbind {
    if(self.directPress){[self.button removeGestureRecognizer:self.directPress];[self.directPress removeTarget:self.target action:@selector(lcs_handlePress:)];}
    if(objc_getAssociatedObject(self.button,&LCSCellularButtonKey)==self)objc_setAssociatedObject(self.button,&LCSCellularButtonKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    self.directPress=nil;self.target=nil;self.button=nil;self.boundWindow=nil;self->_handledBeginning=NO;
}
- (BOOL)safeDirectButton:(UIControl *)button {
    if(!button.window||button.window!=self.controller.view.window||!LCSVisible(button)||!LCSDirectTouch(button)||!LCSTapContract(button))return NO;
    if(objc_getAssociatedObject(button,&LCSCellularButtonKey)!=nil&&objc_getAssociatedObject(button,&LCSCellularButtonKey)!=self)return NO;
    UIView *v=button;while(v&&v!=self.controller.view)v=v.superview;if(v!=self.controller.view)return NO;
    // Existing native gesture arbitration is opaque; do not add another recognizer.
    if(LCSHasAnyGesture(button,0)){
        if(!self.conflictLogged){self.conflictLogged=YES;LCSCellularLog(LCSCellularSIMManager,@"binding",@"recognizer-conflict",0);}
        return NO;
    }
    self.conflictLogged=NO;
    return YES;
}
- (void)scheduleBind {
    if(self.layoutPending)return;self.layoutPending=YES;__weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_main_queue(),^{LCSCellularButtonState *state=weakSelf;if(!state)return;state.layoutPending=NO;[state bindAfterLayout];});
}
- (void)bindAfterLayout {
    if(!self.appeared||(LCSHookMask&LCSRequiredHookMask)!=LCSRequiredHookMask||!LCSCellularFeatureEnabled(LCSCellularSIMManager)||
       !self.controller.isViewLoaded||![self.controller isKindOfClass:LCSNativeCellularClass]){[self unbind];return;}
    Class cls=NSClassFromString(@"CCUIRoundButton");NSMutableArray *matches=[NSMutableArray new];if(cls)LCSFindButton(self.controller.view,cls,matches,0);
    if(matches.count!=1||![matches.firstObject isKindOfClass:UIControl.class]||![self safeDirectButton:matches.firstObject]){[self unbind];return;}
    UIControl *button=matches.firstObject;if(button==self.button&&self.directPress)return;
    [self unbind];self.button=button;self.boundWindow=button.window;
    self.target=[LCSCellularPressTarget new];self.target.binding=self;
    self.directPress=[[UILongPressGestureRecognizer alloc] initWithTarget:self.target action:@selector(lcs_handlePress:)];
    self.directPress.minimumPressDuration=.45;self.directPress.allowableMovement=10;
    self.directPress.cancelsTouchesInView=YES;self.directPress.delaysTouchesBegan=NO;self.directPress.delaysTouchesEnded=NO;
    [button addGestureRecognizer:self.directPress];objc_setAssociatedObject(button,&LCSCellularButtonKey,self,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LCSCellularLog(LCSCellularSIMManager,@"binding",@"bound-direct-only",0);
}
- (void)bind {[self scheduleBind];}
- (void)pressed:(UILongPressGestureRecognizer *)gesture {
    if(gesture!=self.directPress||gesture.state!=UIGestureRecognizerStateBegan||self->_handledBeginning)return;
    if(!LCSCellularFeatureEnabled(LCSCellularSIMManager)||!LCSCellularIsSpringBoard()||
       !LCSCellularIsUnlocked()||!self.appeared||self.controller.isBeingDismissed||self.controller.isBeingPresented||
       !self.button.window||self.button.window!=self.boundWindow||self.button.window!=self.controller.view.window||
       !LCSVisible(self.button)||!LCSDirectTouch(self.button)||LCSTop(self.button)!=self.controller)return;
    UIViewController *top=LCSTop(self.button);if(!top)return;
    LCSCellularSIMController *panel=[LCSCellularSIMController new];self.panel=panel;LCSPresentedSIM=panel;
    __weak typeof(self) weakSelf=self;__weak LCSCellularSIMController *weakPanel=panel;
    panel.mayContinue=^BOOL{LCSCellularButtonState *state=weakSelf;return state&&state.appeared&&
      !state.controller.isBeingDismissed&&state.button.window==state.boundWindow&&LCSVisible(state.button)&&
      LCSCellularFeatureEnabled(LCSCellularSIMManager)&&LCSCellularIsUnlocked();};
    panel.didClose=^{LCSCellularButtonState *state=weakSelf;if(state.panel==weakPanel)state.panel=nil;if(LCSPresentedSIM==weakPanel)LCSPresentedSIM=nil;};
    [top presentViewController:panel animated:YES completion:^{if(!panel.mayContinue||!panel.mayContinue())[panel close];}];
    LCSCellularLog(LCSCellularSIMManager,@"present",@"sim-manager",0);
}
- (void)dealloc {[self unbind];}
@end

static void (*LCSOriginalLoad)(id,SEL);
static void (*LCSOriginalAppear)(id,SEL,BOOL);
static void (*LCSOriginalDisappear)(id,SEL,BOOL);
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
static BOOL LCSInstall(Class cls,const char *name,const char *result,unsigned count,const char *const *args,IMP replacement,IMP *original) {
    SEL sel=sel_registerName(name);if(!LCSCellularMethod(cls,sel,result,count,args))return NO;
    // MSHookMessageEx isolates inherited methods and handles arm64e IMP signing.
    MSHookMessageEx(cls,sel,replacement,original);return *original!=NULL;
}
static void LCSInstallHooks(void) {
    if(!NSThread.isMainThread||!LCSCellularIsSpringBoard()||NSProcessInfo.processInfo.operatingSystemVersion.majorVersion!=15)return;
    if((LCSHookMask&LCSRequiredHookMask)==LCSRequiredHookMask)return;
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
}
static void LCSReconcile(void) {
    LCSInstallHooks();
    for(LCSCellularButtonState *state in LCSCellularStates) {
        if(!LCSCellularFeatureEnabled(LCSCellularSIMManager)||!LCSCellularIsUnlocked()){
            [state unbind];if(state.panel)[state.panel close];
        } else [state bind];
    }
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
            for(NSNumber *delay in @[@.5,@2,@5,@10,@20])dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay.doubleValue*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
                LCSInstallHooks();if((LCSHookMask&LCSRequiredHookMask)==LCSRequiredHookMask)LCSReconcile();
            });
        });
    }
}
