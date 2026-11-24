#import <UIKit/UIKit.h>
#import <substrate.h>
#import "LCSCellularSettings.h"
#import "LCSCellularRuntime.h"
#import "LCSCellularPanel.h"
#import "LCSCellularEntryPolicy.h"

// SpringBoard-only. The stock buttonTapped:/_toggleState paths are never replaced.
static char LCSCellularStateKey,LCSCellularButtonKey;
static Class LCSNativeCellularClass;
static unsigned LCSHookMask;
static unsigned const LCSRequiredHookMask=47U;
static unsigned LCSHookFailureMask;
static NSHashTable *LCSCellularStates;
static __weak LCSCellularSIMController *LCSPresentedSIM;
static BOOL LCSPreviewHookReady,LCSCellularForeground=YES;
static BOOL (*LCSOriginalPreviewShouldBegin)(id,SEL,id);
static void (*LCSOriginalExpanded)(id,SEL,BOOL);
static BOOL (*LCSOriginalRoundGestureShouldBegin)(id,SEL,id);
@class LCSCellularButtonState;
static BOOL LCSRoundHookReady,LCSRoundWindowHookReady;
static void (*LCSOriginalRoundDidMoveToWindow)(id,SEL);
static NSString *LCSGestureKind(UIGestureRecognizer *gesture);
static NSString *LCSGestureStateSlug(UIGestureRecognizerState state);
static NSString *LCSExpansionSlug(LCSCellularButtonState *state);
static BOOL LCSVisible(UIView *view);
static BOOL LCSDirectTouch(UIView *view);
static void LCSLogHookFailure(unsigned bit,NSString *reason) {
    if(LCSHookFailureMask&bit)return;LCSHookFailureMask|=bit;
    LCSCellularLog(LCSCellularSIMManager,@"hook",reason,0);
}
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
@property(nonatomic,strong) UILongPressGestureRecognizer *windowPress;
@property(nonatomic,strong) LCSCellularPressTarget *target;
@property(nonatomic,copy) NSString *lastBindingFailure;
@property(nonatomic) BOOL appeared;
@property(nonatomic) BOOL layoutPending;
@property(nonatomic) BOOL expanded;
@property(nonatomic) BOOL expansionKnown;
@property(nonatomic) BOOL expansionOverlayActive;
@property(nonatomic) NSUInteger traceBudget;
@property(nonatomic) NSUInteger traceGeneration;
@property(nonatomic) CFTimeInterval lastTouchTrace;
@property(nonatomic) CFTimeInterval lastLayoutRetry;
- (void)bind;
- (void)unbind;
- (void)bindAfterLayout;
- (void)syncWindowPress;
- (BOOL)entryReady;
- (void)pressed:(UILongPressGestureRecognizer *)gesture;
- (BOOL)shouldYieldForGesture:(UIGestureRecognizer *)gesture other:(UIGestureRecognizer *)other;
- (BOOL)shouldBeginPressedGesture:(UIGestureRecognizer *)gesture;
- (void)receivedTouch:(UIGestureRecognizer *)gesture;
- (void)traceGesture:(UIGestureRecognizer *)gesture phase:(NSString *)phase;
- (void)logGestureInventory;
- (BOOL)ownsPreview:(UIPreviewInteraction *)interaction container:(UIViewController *)container;
@end
@implementation LCSCellularPressTarget
- (void)lcs_handlePress:(UILongPressGestureRecognizer *)press {[self.binding pressed:press];}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    return [self.binding shouldBeginPressedGesture:gesture];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    LCSCellularButtonState *state=self.binding;
    BOOL direct=gesture&&state.directPress&&gesture==state.directPress;
    BOOL fallback=gesture&&state.windowPress&&gesture==state.windowPress;
    if((!direct&&!fallback)||![state entryReady])return NO;
    if(direct&&!LCSDirectTouch(state.button))return NO;
    if(fallback) {
        CGPoint point=[touch locationInView:state.button];
        if(!LCSCellularWindowFallbackAllows(YES,LCSDirectTouch(state.button),YES,
                                            CGRectContainsPoint(CGRectInset(state.button.bounds,-8,-10),point)))return NO;
    }
    [state receivedTouch:gesture];
    // Preparing a hidden button never accepts a touch or synthesizes an action.
    return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    return [self.binding shouldYieldForGesture:gesture other:other];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    if(gesture==self.binding.directPress||gesture==self.binding.windowPress)[self.binding traceGesture:other phase:@"simul-no"];
    return NO;
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
static LCSCellularExpansion LCSExpansionForState(LCSCellularButtonState *state) {
    if(!state||!state.expansionKnown)return LCSCellularExpansionUnknown;
    return state.expanded?LCSCellularExpansionExpanded:LCSCellularExpansionCollapsed;
}
static NSString *LCSGestureKind(UIGestureRecognizer *gesture) {
    if(!gesture)return @"nil";
    if([gesture isKindOfClass:UIScreenEdgePanGestureRecognizer.class])return @"edgepan";
    if([gesture isKindOfClass:UIPanGestureRecognizer.class])return @"pan";
    if([gesture isKindOfClass:UILongPressGestureRecognizer.class])return @"long";
    if([gesture isKindOfClass:UITapGestureRecognizer.class])return @"tap";
    if([gesture isKindOfClass:UISwipeGestureRecognizer.class])return @"swipe";
    if([gesture isKindOfClass:UIPinchGestureRecognizer.class])return @"pinch";
    if([gesture isKindOfClass:UIRotationGestureRecognizer.class])return @"rotate";
    NSString *raw=NSStringFromClass(gesture.class).lowercaseString?:@"unknown";
    NSMutableString *slug=[NSMutableString new];BOOL dash=NO;
    for(NSUInteger i=0;i<raw.length&&slug.length<12;i++) {
        unichar c=[raw characterAtIndex:i];BOOL ascii=(c>='a'&&c<='z');
        if(ascii){[slug appendFormat:@"%C",c];dash=NO;}
        else if(!dash&&slug.length){[slug appendString:@"-"];dash=YES;}
    }
    while([slug hasSuffix:@"-"]) [slug deleteCharactersInRange:NSMakeRange(slug.length-1,1)];
    return slug.length?slug:@"other";
}
static NSString *LCSGestureStateSlug(UIGestureRecognizerState state) {
    switch(state){case UIGestureRecognizerStatePossible:return @"possible";case UIGestureRecognizerStateBegan:return @"began";case UIGestureRecognizerStateChanged:return @"changed";case UIGestureRecognizerStateEnded:return @"ended";case UIGestureRecognizerStateCancelled:return @"cancelled";case UIGestureRecognizerStateFailed:return @"failed";default:return @"unknown";}
}
static NSString *LCSExpansionSlug(LCSCellularButtonState *state) {
    if(!state||!state.expansionKnown)return @"unknown";
    return state.expanded?@"expanded":@"collapsed";
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
    if(self.windowPress){self.windowPress.enabled=NO;self.windowPress.delegate=nil;[self.boundWindow removeGestureRecognizer:self.windowPress];[self.windowPress removeTarget:self.target action:@selector(lcs_handlePress:)];}
    if(objc_getAssociatedObject(self.button,&LCSCellularButtonKey)==self)objc_setAssociatedObject(self.button,&LCSCellularButtonKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    self.traceBudget=0;self.traceGeneration++;
    self.directPress=nil;self.windowPress=nil;self.target=nil;self.button=nil;self.boundWindow=nil;
}
- (NSString *)bindingFailureForButton:(UIControl *)button {
    if(!self.appeared)return @"controller-not-appeared";
    if((LCSHookMask&LCSRequiredHookMask)!=LCSRequiredHookMask)return @"lifecycle-hooks-incomplete";
    if(!LCSCellularFeatureEnabled(LCSCellularSIMManager))return @"feature-disabled";
    if(!LCSCellularForeground)return @"foreground-inactive";
    if(!LCSCellularIsUnlocked())return @"device-locked";
    if(!self.controller.isViewLoaded||![self.controller isKindOfClass:LCSNativeCellularClass])return @"controller-mismatch";
    if(!button)return nil;
    // Registration is passive: visibility/window attachment are checked at use.
    // A detached button can be prepared; a button in another live window cannot.
    if(button.window&&button.window!=self.controller.view.window)return @"button-window-mismatch";
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
- (BOOL)entryReady {
    return self.appeared&&self.controller&&self.controller.isViewLoaded&&self.button&&
        [self.controller isKindOfClass:LCSNativeCellularClass]&&
        [self.button isDescendantOfView:self.controller.view]&&
        objc_getAssociatedObject(self.button,&LCSCellularButtonKey)==self&&
        self.button.window&&self.button.window==self.boundWindow&&
        self.button.window==self.controller.view.window&&LCSVisible(self.button)&&
        LCSTapContract(self.button)&&!LCSPresentedSIM&&LCSCellularFeatureEnabled(LCSCellularSIMManager)&&
        LCSCellularForeground&&LCSCellularIsUnlocked()&&!self.controller.isBeingDismissed&&
        !self.controller.isBeingPresented;
}
- (BOOL)shouldBeginPressedGesture:(UIGestureRecognizer *)gesture {
    BOOL direct=gesture&&self.directPress&&gesture==self.directPress;
    BOOL fallback=gesture&&self.windowPress&&gesture==self.windowPress;
    BOOL owned=direct||fallback;
    LCSCellularExpansion expansion=LCSExpansionForState(self);
    BOOL local=[self entryReady];
    if(direct)local=local&&LCSDirectTouch(self.button);
    if(fallback)local=LCSCellularWindowFallbackAllows(YES,LCSDirectTouch(self.button),LCSVisible(self.button),local);
    bool allowed=LCSCellularMayBeginPress(expansion,owned,local);
    NSString *reason=!owned?@"not-owned":(!self.expansionKnown?@"state-unknown":(self.expanded?@"state-expanded":(allowed?(fallback?@"fallback-eligible":@"entry-eligible"): @"local-gate-failed")));
    NSString *slug=[NSString stringWithFormat:@"begin-%@-g-%@-s-%@",reason,LCSGestureKind(gesture),LCSGestureStateSlug(gesture.state)];
    NSString *limited=slug.length<=48?slug:[slug substringToIndex:48];
    LCSCellularLog(LCSCellularSIMManager,@"entry",limited,0);
    return allowed;
}
- (void)traceGesture:(UIGestureRecognizer *)gesture phase:(NSString *)phase {
    if(!gesture||self.traceBudget<2)return;
    self.traceBudget-=2;
    UIView *view=gesture.view;NSString *scope=@"external";
    if(view&&view==self.button)scope=@"button";
    else if(view&&view==self.boundWindow)scope=@"window";
    else if(view&&[self.button isDescendantOfView:view])scope=@"ancestor";
    NSString *row=[NSString stringWithFormat:@"%@-%@-%@-%@",phase,scope,LCSGestureKind(gesture),LCSGestureStateSlug(gesture.state)];
    LCSCellularLog(LCSCellularSIMManager,@"gesture",row.length<=48?row:[row substringToIndex:48],0);
    NSString *raw=NSStringFromClass(gesture.class).lowercaseString?:@"unknown";
    NSMutableString *slug=[NSMutableString new];
    for(NSUInteger i=0;i<raw.length&&slug.length<48;i++) {
        unichar c=[raw characterAtIndex:i];
        if((c>='a'&&c<='z')||c=='_'||c=='.'||c=='-')[slug appendFormat:@"%C",c];
    }
    LCSCellularLog(LCSCellularSIMManager,@"gesture-class",slug.length?slug:@"unknown",0);
}
- (void)logGestureInventory {
    NSUInteger count=0,depth=0;
    for(UIView *view=self.button;view&&depth<12&&count<4;view=view.superview,depth++) {
        for(UIGestureRecognizer *other in view.gestureRecognizers) {
            if(other==self.directPress||other==self.windowPress)continue;
            [self traceGesture:other phase:@"snapshot"];
            if(++count==4)break;
        }
    }
}
- (void)receivedTouch:(UIGestureRecognizer *)gesture {
    if(gesture!=self.directPress&&gesture!=self.windowPress)return;
    NSUInteger generation=++self.traceGeneration;self.traceBudget=0;
    CFTimeInterval now=CACurrentMediaTime();if(now-self.lastTouchTrace<.75)return;
    self.lastTouchTrace=now;self.traceBudget=36;
    LCSCellularLog(LCSCellularSIMManager,@"touch",LCSExpansionSlug(self),0);
    [self traceGesture:gesture phase:@"own-touch"];[self logGestureInventory];
    __weak typeof(self) weakSelf=self;
    __weak UIGestureRecognizer *weakGesture=gesture;__weak UIControl *weakButton=self.button;
    // Read-only snapshot. UIKit does not send target/action for every Failed state.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.7*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        LCSCellularButtonState *state=weakSelf;
        if(!state||state.traceGeneration!=generation||!weakGesture||
           (state.directPress!=weakGesture&&state.windowPress!=weakGesture)||
           !weakButton||state.button!=weakButton||!LCSCellularForeground||
           !LCSCellularFeatureEnabled(LCSCellularSIMManager)||!LCSCellularIsUnlocked())return;
        NSString *route=state.windowPress==weakGesture?@"window":@"direct";
        LCSCellularLog(LCSCellularSIMManager,@"entry-outcome",
            [NSString stringWithFormat:@"late-%@-%@",route,LCSGestureStateSlug(weakGesture.state)],0);
        [state traceGesture:weakGesture phase:@"own-later"];[state logGestureInventory];
    });
}
- (BOOL)shouldYieldForGesture:(UIGestureRecognizer *)gesture other:(UIGestureRecognizer *)other {
    if(!other||(gesture!=self.directPress&&gesture!=self.windowPress)||other==gesture)return NO;
    [self traceGesture:other phase:[other isKindOfClass:UIPanGestureRecognizer.class]?@"no-require":@"other-waits"];
    // Apple: YES makes the OTHER recognizer wait for OUR recognizer to fail.
    // Preserve 0.3.11 decisions; no competitor identity is proven yet.
    return ![other isKindOfClass:UIPanGestureRecognizer.class];
}
- (BOOL)ownsPreview:(UIPreviewInteraction *)interaction container:(UIViewController *)container {
    UILongPressGestureRecognizer *press=LCSDirectTouch(self.button)?self.directPress:self.windowPress;
    if(!press||LCSPresentedSIM||!press.enabled||press.numberOfTouches==0)return NO;
    if(!self.controller.isViewLoaded||![self.controller.view isDescendantOfView:container.view])return NO;
    if(![interaction isKindOfClass:UIPreviewInteraction.class])return NO;
    UIView *view=interaction.view;
    if(view&&!(view==container.view||[view isDescendantOfView:container.view]||[container.view isDescendantOfView:view]))return NO;
    if(press.state==UIGestureRecognizerStateFailed||
       press.state==UIGestureRecognizerStateCancelled||
       press.state==UIGestureRecognizerStateEnded)return NO;
    CGPoint point=[interaction locationInCoordinateSpace:self.button];
    return CGRectContainsPoint(CGRectInset(self.button.bounds,-8,-10),point);
}
- (void)scheduleLayoutRebind {
    if(self.layoutPending)return;
    CFTimeInterval remaining=.25-(CACurrentMediaTime()-self.lastLayoutRetry);
    if(remaining<0)remaining=0;
    self.layoutPending=YES;__weak typeof(self) weakSelf=self;
    // Coalesce, but keep the trailing layout check instead of dropping it.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(remaining*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        LCSCellularButtonState *state=weakSelf;if(!state)return;
        state.layoutPending=NO;state.lastLayoutRetry=CACurrentMediaTime();[state bindAfterLayout];
    });
}
- (void)syncWindowPress {
    UIWindow *window=self.button.window;
    if(window!=self.controller.view.window)window=nil;
    if(self.boundWindow!=window||(self.windowPress&&self.windowPress.view!=window)) {
        if(self.windowPress) {
            self.windowPress.enabled=NO;self.windowPress.delegate=nil;
            [self.windowPress.view removeGestureRecognizer:self.windowPress];
            [self.windowPress removeTarget:self.target action:@selector(lcs_handlePress:)];
            self.windowPress=nil;self.traceBudget=0;self.traceGeneration++;
        }
        self.boundWindow=window;
    }
    if(!window||self.windowPress)return;
    // Like the existing Wi-Fi route, prepare one passive window recognizer.
    // The receive/begin/action gates permit it only when direct touch cannot work.
    self.windowPress=[[UILongPressGestureRecognizer alloc] initWithTarget:self.target action:@selector(lcs_handlePress:)];
    self.windowPress.delegate=self.target;
    self.windowPress.minimumPressDuration=.45;self.windowPress.allowableMovement=10;
    self.windowPress.cancelsTouchesInView=NO;self.windowPress.delaysTouchesBegan=NO;self.windowPress.delaysTouchesEnded=NO;
    [window addGestureRecognizer:self.windowPress];
    LCSCellularLog(LCSCellularSIMManager,@"binding",@"bound-window-fallback",0);
}
- (void)bindAfterLayout {
    if(!NSThread.isMainThread)return;
    NSString *gate=[self bindingFailureForButton:nil];if(gate){[self logBindingFailure:gate];[self unbind];return;}
    Class cls=NSClassFromString(@"CCUIRoundButton");NSMutableArray *matches=[NSMutableArray new];if(cls)LCSFindButton(self.controller.view,cls,matches,0);
    if(!cls||matches.count!=1||![matches.firstObject isKindOfClass:UIControl.class]) {
        [self logBindingFailure:!cls?@"button-class-unavailable":(matches.count?@"button-ambiguous":@"button-not-found")];[self unbind];return;
    }
    if(![self safeDirectButton:matches.firstObject]){[self unbind];return;}
    UIControl *button=matches.firstObject;
    if(button!=self.button||!self.directPress||self.directPress.view!=button) {
        [self unbind];self.button=button;
        self.target=[LCSCellularPressTarget new];self.target.binding=self;
        self.directPress=[[UILongPressGestureRecognizer alloc] initWithTarget:self.target action:@selector(lcs_handlePress:)];
        self.directPress.delegate=self.target;
        self.directPress.minimumPressDuration=.45;self.directPress.allowableMovement=10;
        self.directPress.cancelsTouchesInView=YES;self.directPress.delaysTouchesBegan=NO;self.directPress.delaysTouchesEnded=NO;
        objc_setAssociatedObject(button,&LCSCellularButtonKey,self,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [button addGestureRecognizer:self.directPress];
        LCSCellularLog(LCSCellularSIMManager,@"binding",@"bound-wifi-entry",0);
        LCSCellularLog(LCSCellularSIMManager,@"binding",LCSVisible(button)?@"prepared-visible":@"prepared-await-visible",0);
    }
    [self syncWindowPress];
}
- (void)bind {[self bindAfterLayout];}
- (void)pressed:(UILongPressGestureRecognizer *)gesture {
    BOOL direct=gesture&&self.directPress&&gesture==self.directPress;
    BOOL fallback=gesture&&self.windowPress&&gesture==self.windowPress;
    if(!direct&&!fallback)return;
    [self traceGesture:gesture phase:@"own-action"];
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
    else if(direct&&!LCSDirectTouch(self.button))reason=@"button-not-direct-touch";
    else if(fallback&&LCSDirectTouch(self.button))reason=@"fallback-not-needed";
    else if(LCSPresentedSIM)reason=@"panel-already-presented";
    else if(![self entryReady])reason=@"entry-became-unavailable";
    if(reason){LCSCellularLog(LCSCellularSIMManager,@"press",reason,0);return;}
    LCSCellularLog(LCSCellularSIMManager,@"entry",fallback?@"route-window":@"route-direct",0);
    LCSCellularLog(LCSCellularSIMManager,@"entry",@"began-wifi",0);
    UIViewController *top=LCSTop(self.button);
    if(!top||top.isBeingDismissed||top.isBeingPresented){LCSCellularLog(LCSCellularSIMManager,@"press",@"presenter-unavailable",0);return;}
    LCSCellularSIMController *panel=[LCSCellularSIMController new];self.panel=panel;LCSPresentedSIM=panel;
    __weak typeof(self) weakSelf=self;__weak LCSCellularSIMController *weakPanel=panel;
    panel.mayContinue=^BOOL{LCSCellularButtonState *state=weakSelf;return state&&state.panel==weakPanel&&state.controller&&
      !state.controller.isBeingDismissed&&(state.expansionOverlayActive||
      (state.appeared&&state.button.window==state.boundWindow&&LCSVisible(state.button)))&&
      LCSCellularFeatureEnabled(LCSCellularSIMManager)&&LCSCellularForeground&&LCSCellularIsUnlocked();};
    panel.didClose=^{LCSCellularButtonState *state=weakSelf;if(state.panel==weakPanel){state.panel=nil;state.expansionOverlayActive=NO;}if(LCSPresentedSIM==weakPanel)LCSPresentedSIM=nil;};
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
static void LCSLoaded(id self,SEL sel) {
    LCSOriginalLoad(self,sel);LCSCellularButtonState *state=LCSState(self);state.appeared=YES;
    if(!state.expansionKnown)LCSCellularLog(LCSCellularSIMManager,@"expansion",@"load-await-transition",0);
    [state bind];
}
static void LCSAppeared(id self,SEL sel,BOOL animated) {
    LCSOriginalAppear(self,sel,animated);LCSCellularButtonState *state=LCSState(self);state.appeared=YES;
    if(!state.expansionKnown)LCSCellularLog(LCSCellularSIMManager,@"expansion",@"appear-await-transition",0);
    [state bind];
}
static void LCSDisappeared(id self,SEL sel,BOOL animated) {
    LCSOriginalDisappear(self,sel,animated);LCSCellularButtonState *s=objc_getAssociatedObject(self,&LCSCellularStateKey);
    if(s&&(!s.button.window||!LCSVisible(s.button))) {
        BOOL transitioningToExpanded=s.expansionOverlayActive&&s.panel!=nil;
        s.appeared=NO;
        if(transitioningToExpanded) {
            s.expansionOverlayActive=YES;
            [s unbind];LCSCellularLog(LCSCellularSIMManager,@"panel",@"keep-during-expansion",0);
        } else {
            [s unbind];if(s.panel)[s.panel close];
        }
    }
}
static void LCSLayoutSubviews(id self,SEL sel) {
    LCSOriginalLayout(self,sel);
    LCSCellularButtonState *state=objc_getAssociatedObject(self,&LCSCellularStateKey);
    if(state&&state.appeared&&LCSCellularFeatureEnabled(LCSCellularSIMManager))[state scheduleLayoutRebind];
}
static void LCSWillExpand(id self,SEL sel,BOOL expanded) {
    LCSCellularButtonState *state=LCSState(self);state.expansionKnown=YES;state.expanded=expanded;
    LCSCellularLog(LCSCellularSIMManager,@"expansion",expanded?@"transition-expanded":@"transition-collapsed",0);
    [state traceGesture:state.directPress phase:@"on-transition"];[state logGestureInventory];
    if(expanded&&state.panel)state.expansionOverlayActive=YES;
    LCSOriginalExpanded(self,sel,expanded);
    [state bind];
}
static void LCSRoundDidMoveToWindow(id self,SEL sel) {
    LCSOriginalRoundDidMoveToWindow(self,sel);
    if(!NSThread.isMainThread)return;
    LCSCellularButtonState *state=objc_getAssociatedObject(self,&LCSCellularButtonKey);
    // Same hook shape as Wi-Fi, but only our already identified cellular button.
    if(state&&state.button==self)[state bind];
}
static BOOL LCSCellularOwnsRoundGesture(id button,id gesture) {
    LCSCellularButtonState *state=objc_getAssociatedObject(button,&LCSCellularButtonKey);
    return gesture&&state&&state.button==button&&state.directPress==gesture&&
        [gesture isKindOfClass:UILongPressGestureRecognizer.class];
}
static BOOL LCSRoundGestureShouldBegin(id self,SEL sel,id gesture) {
    BOOL cellular=LCSCellularOwnsRoundGesture(self,gesture);
    BOOL original=cellular?NO:LCSOriginalRoundGestureShouldBegin(self,sel,gesture);
    LCSCellularButtonState *state=objc_getAssociatedObject(self,&LCSCellularButtonKey);
    BOOL local=cellular&&state&&[state.target gestureRecognizerShouldBegin:gesture];
    BOOL allowed=LCSRoundButtonAllowsGesture(cellular,original,local);
    if(cellular)LCSCellularLog(LCSCellularSIMManager,@"entry",allowed?@"round-button-allowed":@"round-button-refused",0);
    // Observe only this cellular button. Every foreign/native decision is unchanged.
    if(state&&state.button==self)[state traceGesture:gesture phase:cellular?(allowed?@"own-yes":@"own-no"):(original?@"native-yes":@"native-no")];
    return allowed;
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
static void LCSInstallRoundHook(void) {
    if(LCSRoundHookReady&&LCSRoundWindowHookReady)return;
    Class cls=NSClassFromString(@"CCUIRoundButton");
    if(!cls){LCSLogHookFailure(512U,@"round-button-class-unavailable");return;}
    const char *file=class_getImageName(cls);NSString *image=file?[NSString stringWithUTF8String:file]:nil;
    if(![image hasSuffix:@"/System/Library/PrivateFrameworks/ControlCenterUIKit.framework/ControlCenterUIKit"]) {
        LCSLogHookFailure(1024U,@"round-button-image-unverified");return;
    }
    const char *object[]={@encode(id)};
    if(!LCSRoundHookReady) {
        if(LCSInstall(cls,"gestureRecognizerShouldBegin:",@encode(BOOL),1,object,
            (IMP)LCSRoundGestureShouldBegin,(IMP *)&LCSOriginalRoundGestureShouldBegin)) {
            LCSRoundHookReady=YES;LCSCellularLog(LCSCellularSIMManager,@"hook",@"round-local-hook-installed",0);
        } else LCSLogHookFailure(2048U,@"round-shouldbegin-unavailable");
    }
    if(!LCSRoundWindowHookReady) {
        if(LCSInstall(cls,"didMoveToWindow",@encode(void),0,NULL,
            (IMP)LCSRoundDidMoveToWindow,(IMP *)&LCSOriginalRoundDidMoveToWindow)) {
            LCSRoundWindowHookReady=YES;LCSCellularLog(LCSCellularSIMManager,@"hook",@"round-window-readiness-installed",0);
        } else LCSLogHookFailure(4096U,@"round-window-readiness-unavailable");
    }
}
static void LCSInstallHooks(void) {
    if(!NSThread.isMainThread||!LCSCellularIsSpringBoard()||NSProcessInfo.processInfo.operatingSystemVersion.majorVersion!=15)return;
    LCSInstallRoundHook();LCSInstallPreviewHook();
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
