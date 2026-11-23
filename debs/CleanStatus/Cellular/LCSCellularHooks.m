#import <UIKit/UIKit.h>
#import <substrate.h>
#import "LCSCellularSettings.h"
#import "LCSCellularRuntime.h"
#import "LCSCellularPanel.h"
#import "LCSCellularEntryPolicy.h"

// SpringBoard-only. The stock buttonTapped:/_toggleState paths are never replaced.
static char LCSCellularStateKey,LCSCellularButtonKey;
static Class LCSNativeCellularClass,LCSNativeContainerClass;
static BOOL LCSPreviewHookReady,LCSCellularForeground=YES;
static unsigned LCSHookMask;
static unsigned const LCSRequiredHookMask=39U;
static unsigned LCSHookFailureMask;
static NSHashTable *LCSCellularStates;
static __weak LCSCellularSIMController *LCSPresentedSIM;
static void LCSLogHookFailure(unsigned bit,NSString *reason) {
    if(LCSHookFailureMask&bit)return;LCSHookFailureMask|=bit;
    LCSCellularLog(LCSCellularSIMManager,@"hook",reason,0);
}
@class LCSCellularButtonState;
// Standard recognizer with an independent NSObject target/delegate. No UIKit
// subclass, private owner property or message forwarding is used.
@interface LCSCellularPressTarget : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic,weak) LCSCellularButtonState *binding;
- (void)lcs_handlePress:(UILongPressGestureRecognizer *)press;
@end
@interface LCSCellularButtonState : NSObject
@property(nonatomic,weak) UIViewController *controller;
@property(nonatomic,weak) UIControl *button;
@property(nonatomic,weak) UIWindow *boundWindow;
@property(nonatomic,weak) UIView *localHost;
@property(nonatomic,weak) UIView *moduleContent;
@property(nonatomic,weak) UIViewController *moduleContainer;
@property(nonatomic,weak) LCSCellularSIMController *panel;
@property(nonatomic,strong) UILongPressGestureRecognizer *directPress;
@property(nonatomic,strong) LCSCellularPressTarget *target;
@property(nonatomic,copy) NSString *lastBindingFailure;
@property(nonatomic) BOOL appeared;
@property(nonatomic) BOOL layoutPending;
@property(nonatomic) BOOL expanded,expandedStateKnown;
@property(nonatomic) BOOL priorityLogged;
@property(nonatomic) uint64_t bindingTicket;
@property(nonatomic) LCSEntryAttempt entryAttempt;
@property(nonatomic) CFTimeInterval lastLayoutRetry;
@property(nonatomic) BOOL legacyEntry;
@property(nonatomic,weak) UITouch *activeTouch;
@property(nonatomic) CFTimeInterval entryStartedAt;
- (void)bind;
- (void)unbind;
- (void)pressed:(UILongPressGestureRecognizer *)gesture;
- (BOOL)legacyAllowed;
- (void)resetEntry;
- (BOOL)entryStale;
- (BOOL)receiveGesture:(UIGestureRecognizer *)gesture touch:(UITouch *)touch;
- (BOOL)gestureMayBegin:(UIGestureRecognizer *)gesture;
- (BOOL)prioritiseGesture:(UIGestureRecognizer *)gesture over:(UIGestureRecognizer *)other;
- (BOOL)ownsPreview:(UIPreviewInteraction *)interaction container:(UIViewController *)container;
@end
@implementation LCSCellularPressTarget
- (void)lcs_handlePress:(UILongPressGestureRecognizer *)press {[self.binding pressed:press];}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    return [self.binding receiveGesture:gesture touch:touch];
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    return [self.binding gestureMayBegin:gesture];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    return [self.binding prioritiseGesture:gesture over:other];
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
static BOOL LCSImageEnds(Class cls,NSString *suffix) {
    const char *file=cls?class_getImageName(cls):NULL;
    NSString *image=file?[NSString stringWithUTF8String:file]:nil;
    return image&&[image hasSuffix:suffix];
}
static BOOL LCSConnectivityImage(Class cls) {
    return LCSImageEnds(cls,@"/System/Library/ControlCenter/Bundles/ConnectivityModule.bundle/ConnectivityModule");
}
static UIViewController *LCSLocalModuleContainer(UIViewController *controller) {
    if(!LCSNativeContainerClass||!controller.isViewLoaded)return nil;
    for(UIViewController *vc=controller.parentViewController;vc;vc=vc.parentViewController) {
        if([vc isKindOfClass:LCSNativeContainerClass]) {
            id content=LCSCellularObject(vc,"contentViewController");
            if(![content isKindOfClass:UIViewController.class]||![content isViewLoaded]||
               !LCSConnectivityImage(object_getClass(content)))return nil;
            return [controller.view isDescendantOfView:[content view]]?vc:nil;
        }
    }
    return nil;
}
static BOOL LCSHostImage(UIView *view) {
    Class cls=object_getClass(view);
    return LCSImageEnds(cls,@"/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore")||
        LCSImageEnds(cls,@"/System/Library/Frameworks/UIKit.framework/UIKit")||
        LCSImageEnds(cls,@"/System/Library/PrivateFrameworks/ControlCenterUIKit.framework/ControlCenterUIKit")||
        LCSImageEnds(cls,@"/System/Library/PrivateFrameworks/ControlCenterUI.framework/ControlCenterUI")||
        LCSConnectivityImage(cls);
}
static UIView *LCSLocalTouchHost(UIControl *button,UIView *content) {
    if(!content||!button.window||button.window!=content.window||
       ![button isDescendantOfView:content])return nil;
    // Never climb above this module's content. A recognizer on a local ancestor
    // can receive a disabled child's touches without changing native interaction flags.
    NSUInteger depth=0;
    for(UIView *v=button.superview;v&&depth++<12;v=v.superview) {
        if([v isKindOfClass:UIWindow.class]||![v isDescendantOfView:content])return nil;
        if(![v isKindOfClass:UIControl.class]&&LCSHostImage(v)&&LCSVisible(v)&&LCSDirectTouch(v))return v;
        if(v==content)break;
    }
    return nil;
}
static LCSEntryRect LCSButtonRect(UIView *button) {
    CGRect r=button.bounds;
    return (LCSEntryRect){r.origin.x,r.origin.y,r.size.width,r.size.height};
}
@implementation LCSCellularButtonState
- (void)unbind {
    LCSEntryAttempt attempt=self.entryAttempt;LCSEntryCancel(&attempt);self.entryAttempt=attempt;
    self.bindingTicket=self.bindingTicket==UINT64_MAX?1:self.bindingTicket+1;
    self.priorityLogged=NO;
    if(self.directPress){self.directPress.enabled=NO;self.directPress.delegate=nil;[self.localHost removeGestureRecognizer:self.directPress];[self.directPress removeTarget:self.target action:@selector(lcs_handlePress:)];}
    if(objc_getAssociatedObject(self.button,&LCSCellularButtonKey)==self)objc_setAssociatedObject(self.button,&LCSCellularButtonKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    self.directPress=nil;self.target=nil;self.button=nil;self.boundWindow=nil;
    self.localHost=nil;self.moduleContent=nil;self.moduleContainer=nil;
    self.legacyEntry=NO;self.activeTouch=nil;self.entryStartedAt=0;self.entryAttempt=(LCSEntryAttempt){0};
}
- (NSString *)bindingFailureForButton:(UIControl *)button {
    if(!self.appeared)return @"controller-not-appeared";
    if((LCSHookMask&LCSRequiredHookMask)!=LCSRequiredHookMask)return @"lifecycle-hooks-incomplete";
    if(!LCSCellularFeatureEnabled(LCSCellularSIMManager))return @"feature-disabled";
    if(!LCSCellularForeground)return @"foreground-unavailable";
    if(!self.controller.isViewLoaded||![self.controller isKindOfClass:LCSNativeCellularClass])return @"controller-mismatch";
    if(!button)return nil;
    if(!button.window||button.window!=self.controller.view.window)return @"button-window-mismatch";
    if(!LCSVisible(button))return @"button-not-visible";
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
- (BOOL)entryStale {
    if(self.entryAttempt.phase==LCSEntryIdle)return NO;
    if(self.entryStartedAt<=0||CACurrentMediaTime()-self.entryStartedAt>3.0)return YES;
    UITouch *touch=self.activeTouch;
    return !touch||touch.phase==UITouchPhaseEnded||touch.phase==UITouchPhaseCancelled;
}
- (void)resetEntry {
    LCSEntryAttempt attempt=self.entryAttempt;LCSEntryCancel(&attempt);self.entryAttempt=attempt;
    self.activeTouch=nil;self.entryStartedAt=0;
}
- (BOOL)legacyAllowed {
    return self.legacyEntry&&LCSCellularIsSpringBoard()&&LCSCellularForeground&&
        self.appeared&&self.controller.isViewLoaded&&
        [self.controller isKindOfClass:LCSNativeCellularClass]&&
        (LCSHookMask&LCSRequiredHookMask)==LCSRequiredHookMask&&
        LCSCellularFeatureEnabled(LCSCellularSIMManager)&&LCSCellularIsUnlocked()&&
        self.button.window==self.boundWindow&&LCSVisible(self.button)&&!LCSPresentedSIM;
}
- (BOOL)expandedNow:(BOOL *)known {
    if(self.expandedStateKnown&&self.expanded){if(known)*known=YES;return YES;}
    BOOL valid=NO;BOOL expanded=LCSCellularBool(self.moduleContainer,"isExpanded",&valid);
    if(valid){if(known)*known=YES;return expanded;}
    if(known)*known=self.expandedStateKnown;
    return self.expanded;
}
- (LCSEntryGates)entryGates {
    UIViewController *top=LCSTop(self.button);
    id content=LCSCellularObject(self.moduleContainer,"contentViewController");
    BOOL contentMatches=[content isKindOfClass:UIViewController.class]&&[content isViewLoaded]&&
        LCSConnectivityImage(object_getClass(content))&&[content view]==self.moduleContent;
    LCSEntryGates g={0};
    g.feature=LCSCellularFeatureEnabled(LCSCellularSIMManager);
    g.unlocked=LCSCellularIsUnlocked();g.foreground=LCSCellularForeground;
    g.lifecycle=self.appeared&&LCSPreviewHookReady&&self.controller.isViewLoaded&&
        [self.controller isKindOfClass:LCSNativeCellularClass]&&
        (LCSHookMask&LCSRequiredHookMask)==LCSRequiredHookMask&&
        !self.controller.isBeingDismissed&&!self.controller.isBeingPresented;
    g.visible=LCSVisible(self.button)&&LCSVisible(self.localHost);
    g.local_host=self.localHost&&contentMatches&&![self.localHost isKindOfClass:UIWindow.class]&&
        [self.localHost isDescendantOfView:self.moduleContent]&&LCSHostImage(self.localHost)&&
        LCSDirectTouch(self.localHost)&&[self.button isDescendantOfView:self.localHost];
    g.same_window=self.boundWindow&&self.button.window==self.boundWindow&&
        self.localHost.window==self.boundWindow&&self.moduleContent.window==self.boundWindow;
    g.unique_button=self.button&&objc_getAssociatedObject(self.button,&LCSCellularButtonKey)==self&&
        [self.button isDescendantOfView:self.controller.view];
    g.safe_short_tap=self.button&&LCSTapContract(self.button);
    BOOL ownTop=self.panel&&top==self.panel&&LCSPresentedSIM==self.panel;
    g.no_modal=top&&!top.isBeingDismissed&&(!top.isBeingPresented||ownTop)&&
        ![top isKindOfClass:UIAlertController.class]&&(!LCSPresentedSIM||LCSPresentedSIM==self.panel);
    return g;
}
- (BOOL)receiveGesture:(UIGestureRecognizer *)gesture touch:(UITouch *)touch {
    if(gesture!=self.directPress||!gesture.enabled||LCSPresentedSIM)return NO;
    if([self entryStale])[self resetEntry];
    if(self.legacyEntry) {
        if(gesture.view!=self.button||![self legacyAllowed])return NO;
        UIView *hit=touch.view;
        if(!hit||![hit isDescendantOfView:self.button])return NO;
        CGPoint point=[touch locationInView:self.button];
        if(!LCSEntryContains(LCSButtonRect(self.button),point.x,point.y))return NO;
        self.activeTouch=touch;self.entryStartedAt=CACurrentMediaTime();
        return YES;
    }
    if(gesture.view!=self.localHost)return NO;
    BOOL known=NO,expanded=[self expandedNow:&known];if(!known)return NO;
    UIView *hit=touch.view;
    BOOL related=hit&&([hit isDescendantOfView:self.button]||
        ([self.button isDescendantOfView:hit]&&[hit isDescendantOfView:self.localHost]));
    CGPoint point=[touch locationInView:self.button];LCSEntryAttempt attempt=self.entryAttempt;
    BOOL accepted=LCSEntryReceive(&attempt,[self entryGates],LCSButtonRect(self.button),point.x,point.y,related,expanded);
    if(accepted){self.entryAttempt=attempt;self.activeTouch=touch;self.entryStartedAt=CACurrentMediaTime();
        self.priorityLogged=NO;
        LCSCellularLog(LCSCellularSIMManager,@"entry",expanded?@"touch-expanded":@"touch-collapsed",0);}
    return accepted;
}
- (BOOL)gestureMayBegin:(UIGestureRecognizer *)gesture {
    UIView *expected=self.legacyEntry?self.button:self.localHost;
    if(gesture!=self.directPress||gesture.view!=expected||LCSPresentedSIM)return NO;
    if([self entryStale])[self resetEntry];
    if(self.legacyEntry)return [self legacyAllowed];
    BOOL known=NO,expanded=[self expandedNow:&known];
    LCSEntryAttempt attempt=self.entryAttempt,probe=attempt;
    BOOL allowed=known&&LCSEntryEligible([self entryGates])&&
        LCSEntryBegin(&probe,[self entryGates],LCSButtonRect(self.button),attempt.start_x,attempt.start_y,expanded);
    if(!allowed){LCSEntryCancel(&attempt);self.entryAttempt=attempt;
        LCSCellularLog(LCSCellularSIMManager,@"entry",known?@"begin-refused":@"expanded-state-unavailable",0);}
    return allowed; // Target/action commits the transition only at real Began.
}
- (BOOL)prioritiseGesture:(UIGestureRecognizer *)gesture over:(UIGestureRecognizer *)other {
    if(self.legacyEntry||gesture!=self.directPress||other==gesture)return NO;
    BOOL native=other.delegate==(id)self.button||other.delegate==(id)self.moduleContainer;
    BOOL related=other.view&&[other.view isDescendantOfView:self.moduleContainer.view]&&
        (other.view==self.localHost||[other.view isDescendantOfView:self.localHost]||
         [self.localHost isDescendantOfView:other.view]);
    if(!native||!related)return NO;
    // The six-button module may expand from a native long press or drag. Do not
    // make this cellular long press wait for either. Ordinary taps still wait,
    // preserving the short toggle; gestures in other modules are untouched.
    if([other isKindOfClass:UIPanGestureRecognizer.class]||
       [other isKindOfClass:UILongPressGestureRecognizer.class])return NO;
    return YES;
}
- (BOOL)ownsPreview:(UIPreviewInteraction *)interaction container:(UIViewController *)container {
    if(self.legacyEntry||!LCSPreviewHookReady||container!=self.moduleContainer||!self.directPress.enabled||
       self.directPress.view!=self.localHost||
       ![interaction isKindOfClass:UIPreviewInteraction.class]||
       LCSCellularObject(container,"previewInteraction")!=interaction)return NO;
    BOOL known=NO,expanded=[self expandedNow:&known];LCSEntryAttempt attempt=self.entryAttempt;
    UIView *view=interaction.view;
    BOOL related=view&&[self.localHost isDescendantOfView:view]&&
        [view isDescendantOfView:container.view];
    CGPoint point=[interaction locationInCoordinateSpace:self.button];
    (void)point;
    if(!known||!LCSEntryPreviewWait(&attempt,[self entryGates],expanded,
        container==self.moduleContainer,LCSCellularObject(container,"previewInteraction")==interaction,
        related,LCSButtonRect(self.button),attempt.start_x,attempt.start_y))return NO;
    if(!self.priorityLogged){self.priorityLogged=YES;
        LCSCellularLog(LCSCellularSIMManager,@"entry",@"system-preview-waits",0);}
    return YES;
}
- (void)scheduleLayoutRebind {
    BOOL eligible=self.legacyEntry?[self legacyAllowed]:
        (self.directPress.view==self.localHost&&LCSEntryEligible([self entryGates]));
    if(self.directPress&&eligible)return;
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
    UIControl *button=matches.firstObject;
    UIViewController *container=LCSLocalModuleContainer(self.controller);
    id content=LCSCellularObject(container,"contentViewController");
    UIView *module=[content isKindOfClass:UIViewController.class]&&[content isViewLoaded]?[content view]:nil;
    UIView *host=LCSLocalTouchHost(button,module);
    BOOL legacy=!LCSPreviewHookReady||!container||!module||!host||!LCSEntryRectValid(LCSButtonRect(button));
    if(button==self.button&&self.directPress&&((legacy&&self.legacyEntry)||(!legacy&&host==self.localHost&&container==self.moduleContainer)))return;
    [self unbind];self.button=button;self.boundWindow=button.window;self.legacyEntry=legacy;
    if(legacy) {
        self.localHost=button;self.moduleContainer=nil;self.moduleContent=nil;
    } else {
        self.localHost=host;self.moduleContainer=container;self.moduleContent=module;
    }
    self.target=[LCSCellularPressTarget new];self.target.binding=self;
    self.directPress=[[UILongPressGestureRecognizer alloc] initWithTarget:self.target action:@selector(lcs_handlePress:)];
    self.directPress.delegate=self.target;
    self.directPress.minimumPressDuration=.45;self.directPress.allowableMovement=10;
    self.directPress.numberOfTouchesRequired=1;
    self.directPress.cancelsTouchesInView=YES;self.directPress.delaysTouchesBegan=NO;self.directPress.delaysTouchesEnded=NO;
    UIView *hostView=legacy?button:self.localHost;
    [hostView addGestureRecognizer:self.directPress];objc_setAssociatedObject(button,&LCSCellularButtonKey,self,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LCSCellularLog(LCSCellularSIMManager,@"binding",legacy?@"bound-legacy-fallback":@"bound-local-entry",0);
}
- (void)bind {[self scheduleLayoutRebind];}
- (void)pressed:(UILongPressGestureRecognizer *)gesture {
    if(gesture!=self.directPress)return;
    if(gesture.state!=UIGestureRecognizerStateBegan){
        if(gesture.state==UIGestureRecognizerStateEnded||gesture.state==UIGestureRecognizerStateCancelled||gesture.state==UIGestureRecognizerStateFailed) {
            LCSEntryAttempt attempt=self.entryAttempt;BOOL began=attempt.phase==LCSEntryBegan;
            [self resetEntry];
            LCSCellularLog(LCSCellularSIMManager,@"entry",began?@"hold-finished":@"hold-cancelled",0);
            dispatch_async(dispatch_get_main_queue(),^{if(self.appeared&&self.button.window&&LCSVisible(self.button))[self bind];});
        }
        return;
    }
    NSString *reason=nil;
    if(!LCSCellularFeatureEnabled(LCSCellularSIMManager))reason=@"feature-disabled";
    else if(!LCSCellularIsSpringBoard())reason=@"wrong-process";
    else if(!LCSCellularIsUnlocked())reason=@"device-locked";
    else if(!self.appeared||!self.controller||self.controller.isBeingDismissed||self.controller.isBeingPresented)reason=@"controller-unavailable";
    else if(!self.button.window||self.button.window!=self.boundWindow||self.button.window!=self.controller.view.window)reason=@"button-window-mismatch";
    else if(!LCSVisible(self.button))reason=@"button-not-visible";
    if(self.legacyEntry) {
        if(!LCSDirectTouch(self.button)||gesture.view!=self.button)reason=@"button-not-direct-touch";
        else if(LCSPresentedSIM)reason=@"panel-already-presented";
    } else {
        if(!LCSDirectTouch(self.localHost)||gesture.view!=self.localHost)reason=@"local-host-unavailable";
        else if(LCSPresentedSIM)reason=@"panel-already-presented";
    }
    BOOL known=NO,expanded=NO;
    LCSEntryAttempt attempt=self.entryAttempt;
    if(!reason&&!self.legacyEntry) {
        expanded=[self expandedNow:&known];
        if(!known||!LCSEntryBegin(&attempt,[self entryGates],LCSButtonRect(self.button),attempt.start_x,attempt.start_y,expanded))
            reason=known?@"entry-cycle-refused":@"expanded-state-unavailable";
    }
    if(reason){
        if(!self.legacyEntry){LCSEntryCancel(&attempt);self.entryAttempt=attempt;}
        LCSCellularLog(LCSCellularSIMManager,@"press",reason,0);return;
    }
    if(!self.legacyEntry)self.entryAttempt=attempt;
    LCSCellularLog(LCSCellularSIMManager,@"entry",self.legacyEntry?@"began-legacy":(expanded?@"began-expanded":@"began-collapsed"),0);
    UIViewController *top=LCSTop(self.button);
    if(!top||top.isBeingDismissed||top.isBeingPresented){LCSCellularLog(LCSCellularSIMManager,@"press",@"presenter-unavailable",0);return;}
    LCSCellularSIMController *panel=[LCSCellularSIMController new];self.panel=panel;LCSPresentedSIM=panel;
    uint64_t ticket=self.bindingTicket;
    __weak typeof(self) weakSelf=self;__weak LCSCellularSIMController *weakPanel=panel;
    panel.mayContinue=^BOOL{LCSCellularButtonState *state=weakSelf;return state&&state.appeared&&
      state.bindingTicket==ticket&&LCSCellularForeground&&
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
static void (*LCSOriginalExpanded)(id,SEL,BOOL);
static BOOL (*LCSOriginalPreviewShouldBegin)(id,SEL,id);
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
    LCSCellularButtonState *state=LCSState(self);state.expanded=expanded;state.expandedStateKnown=YES;
    LCSEntryAttempt attempt=state.entryAttempt;
    if(expanded&&!attempt.expanded_at_touch&&attempt.phase!=LCSEntryIdle) {
        LCSEntryCancel(&attempt);state.entryAttempt=attempt;
        LCSCellularLog(LCSCellularSIMManager,@"entry",@"system-expanded-during-hold",0);
    }
    LCSOriginalExpanded(self,sel,expanded);
    if(expanded&&state.panel)[state.panel close];
    else [state bind];
}
static BOOL LCSPreviewShouldBegin(id self,SEL sel,id interaction) {
    // This instance hook is shared by modules, but only this verified module and
    // a touch already accepted by our local cellular recognizer may be changed.
    if(NSThread.isMainThread&&LCSPreviewHookReady&&LCSCellularForeground&&
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
    if(!cls||!LCSImageEnds(cls,@"/System/Library/PrivateFrameworks/ControlCenterUI.framework/ControlCenterUI")) {
        LCSLogHookFailure(64U,@"preview-container-unavailable");return;
    }
    const char *object[]={"@"};
    if(!LCSCellularMethod(cls,sel_registerName("contentViewController"),"@",0,NULL)||
       !LCSCellularMethod(cls,sel_registerName("previewInteraction"),"@",0,NULL)||
       !LCSCellularMethod(cls,sel_registerName("isExpanded"),"B",0,NULL)||
       !LCSInstall(cls,"previewInteractionShouldBegin:","B",1,object,
          (IMP)LCSPreviewShouldBegin,(IMP *)&LCSOriginalPreviewShouldBegin)) {
        LCSLogHookFailure(128U,@"preview-signature-unavailable");return;
    }
    LCSNativeContainerClass=cls;LCSPreviewHookReady=YES;
    LCSCellularLog(LCSCellularSIMManager,@"hook",@"local-preview-hook-installed",0);
}
static void LCSInstallHooks(void) {
    if(!NSThread.isMainThread||!LCSCellularIsSpringBoard()||NSProcessInfo.processInfo.operatingSystemVersion.majorVersion!=15)return;
    LCSInstallPreviewHook();
    if((LCSHookMask&LCSRequiredHookMask)==LCSRequiredHookMask&&LCSPreviewHookReady&&(LCSHookMask&8U))return;
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
