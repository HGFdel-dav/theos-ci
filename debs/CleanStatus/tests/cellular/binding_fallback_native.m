// Foundation-only fake UIKit. No UIKit import/link, no device or SIM service.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

// Prefix value types/functions because macOS Foundation may already expose CG geometry.
// Aliases affect only the extracted code BELOW Foundation imports; no CG runtime calls.
typedef struct { double x,y; } NFPoint;
typedef struct { double width,height; } NFSize;
typedef struct { NFPoint origin; NFSize size; } NFRect;
static NFPoint NFPointMake(double x,double y){return (NFPoint){x,y};}
static NFRect NFRectMake(double x,double y,double w,double h){return (NFRect){{x,y},{w,h}};}
static NFRect NFRectInset(NFRect r,double x,double y){return NFRectMake(r.origin.x+x,r.origin.y+y,r.size.width-2*x,r.size.height-2*y);}
static BOOL NFRectContainsPoint(NFRect r,NFPoint p){return r.size.width>0&&r.size.height>0&&p.x>=r.origin.x&&p.y>=r.origin.y&&p.x<r.origin.x+r.size.width&&p.y<r.origin.y+r.size.height;}
#define CGPoint NFPoint
#define CGSize NFSize
#define CGRect NFRect
#define CGPointMake NFPointMake
#define CGRectMake NFRectMake
#define CGRectInset NFRectInset
#define CGRectContainsPoint NFRectContainsPoint

typedef NS_ENUM(NSInteger,UIGestureRecognizerState){
 UIGestureRecognizerStatePossible=0,UIGestureRecognizerStateBegan,
 UIGestureRecognizerStateChanged,UIGestureRecognizerStateEnded,
 UIGestureRecognizerStateCancelled,UIGestureRecognizerStateFailed};
typedef NSUInteger UIControlEvents;
enum {UIControlEventTouchDown=1,UIControlEventTouchDownRepeat=2,UIControlEventTouchUpInside=64};
@class UIView,UIWindow,UIViewController,UIGestureRecognizer,UITouch;
@protocol UIGestureRecognizerDelegate <NSObject>
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture;
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch;
@end
static NSUInteger NFControllerCreations,NFGestureCreations,NFPanelCreations,NFPresents,NFCompletions,NFCloses,NFCloseCallbacks;
static NSUInteger NFReceived,NFTraces,NFInventories,NFInstallRequests;
static NSMutableArray<NSString *> *NFLogs;
static BOOL NFFeature=YES,NFUnlocked=YES,NFProcess=YES;
static void (^NFDuringPresentation)(void);

@interface UIView : NSObject
@property(nonatomic,weak) UIView *superview;
@property(nonatomic,readonly) UIWindow *window;
@property(nonatomic,strong) NSMutableArray<UIView *> *subviews;
@property(nonatomic,strong) NSMutableArray<UIGestureRecognizer *> *gestureRecognizers;
@property(nonatomic) CGRect bounds;
@property(nonatomic) BOOL hidden,userInteractionEnabled;
@property(nonatomic) double alpha;
@property(nonatomic) NSUInteger addCalls,removeCalls;
- (void)addSubview:(UIView *)view;
- (void)removeFromSuperview;
- (BOOL)isDescendantOfView:(UIView *)view;
- (void)addGestureRecognizer:(UIGestureRecognizer *)gesture;
- (void)removeGestureRecognizer:(UIGestureRecognizer *)gesture;
@end
@interface UIWindow : UIView
@property(nonatomic,strong) UIViewController *rootViewController;
@end
@interface UIControl : UIView
@property(nonatomic,strong) NSMutableSet *targets;
@property(nonatomic,strong) NSMutableDictionary *actionMap;
@property(nonatomic,readonly) NSSet *allTargets;
- (void)addTarget:(id)target action:(SEL)action forControlEvents:(UIControlEvents)events;
- (NSArray *)actionsForTarget:(id)target forControlEvent:(UIControlEvents)event;
@end
@interface CCUIRoundButton : UIControl @end
@interface UIViewController : NSObject
@property(nonatomic,strong) UIView *view;
@property(nonatomic) BOOL isViewLoaded,isBeingDismissed,isBeingPresented;
@property(nonatomic,strong) UIViewController *presentedViewController;
@property(nonatomic,weak) UIViewController *presentingViewController;
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion;
@end
@interface CCUIConnectivityCellularDataViewController : UIViewController @end
@interface UIGestureRecognizer : NSObject
@property(nonatomic,weak) UIView *view;
@property(nonatomic,weak) id<UIGestureRecognizerDelegate> delegate;
@property(nonatomic,weak) id actionTarget;
@property(nonatomic) SEL actionSelector;
@property(nonatomic) BOOL enabled,cancelsTouchesInView,delaysTouchesBegan,delaysTouchesEnded;
@property(nonatomic) UIGestureRecognizerState state;
@property(nonatomic) NSUInteger numberOfTouches;
@property(nonatomic) CGPoint point;
- (instancetype)initWithTarget:(id)target action:(SEL)action;
- (void)removeTarget:(id)target action:(SEL)action;
- (CGPoint)locationInView:(UIView *)view;
- (void)fire;
@end
@interface UILongPressGestureRecognizer : UIGestureRecognizer
@property(nonatomic) double minimumPressDuration,allowableMovement;
@end
@interface UIPanGestureRecognizer : UIGestureRecognizer @end
@interface UIScreenEdgePanGestureRecognizer : UIPanGestureRecognizer @end
@interface UITapGestureRecognizer : UIGestureRecognizer @end
@interface UISwipeGestureRecognizer : UIGestureRecognizer @end
@interface UIPinchGestureRecognizer : UIGestureRecognizer @end
@interface UIRotationGestureRecognizer : UIGestureRecognizer @end
@interface UITouch : NSObject
@property(nonatomic,weak) UIView *view;
@property(nonatomic) CGPoint point;
- (CGPoint)locationInView:(UIView *)view;
@end
@interface UIPreviewInteraction : NSObject
@property(nonatomic,weak) UIView *view;
@property(nonatomic) CGPoint point;
- (CGPoint)locationInCoordinateSpace:(id)space;
@end
@interface LCSCellularSIMController : UIViewController
@property(nonatomic,copy) BOOL (^mayContinue)(void);
@property(nonatomic,copy) void (^didClose)(void);
@property(nonatomic) BOOL closed;
- (void)close;
@end

@implementation UIView
- (instancetype)init {if((self=[super init])){_subviews=[NSMutableArray new];_gestureRecognizers=[NSMutableArray new];_bounds=CGRectMake(0,0,40,40);_alpha=1;_userInteractionEnabled=YES;}return self;}
- (UIWindow *)window {return self.superview.window;}
- (void)addSubview:(UIView *)view {if(view.superview==self)return;[view removeFromSuperview];[self.subviews addObject:view];view.superview=self;}
- (void)removeFromSuperview {[self.superview.subviews removeObjectIdenticalTo:self];self.superview=nil;}
- (BOOL)isDescendantOfView:(UIView *)view {for(UIView *v=self;v;v=v.superview)if(v==view)return YES;return NO;}
- (void)addGestureRecognizer:(UIGestureRecognizer *)gesture {
 self.addCalls++;if(gesture.view&&gesture.view!=self)[gesture.view removeGestureRecognizer:gesture];
 if([self.gestureRecognizers indexOfObjectIdenticalTo:gesture]==NSNotFound)[self.gestureRecognizers addObject:gesture];gesture.view=self;
}
- (void)removeGestureRecognizer:(UIGestureRecognizer *)gesture {self.removeCalls++;[self.gestureRecognizers removeObjectIdenticalTo:gesture];if(gesture.view==self)gesture.view=nil;}
@end
@implementation UIWindow
- (UIWindow *)window {return self;}
@end
@implementation UIControl
- (instancetype)init {if((self=[super init])){_targets=[NSMutableSet new];_actionMap=[NSMutableDictionary new];}return self;}
- (NSSet *)allTargets {return self.targets;}
- (void)addTarget:(id)target action:(SEL)action forControlEvents:(UIControlEvents)events {
 id key=target?:NSNull.null;[self.targets addObject:key];NSValue *identity=[NSValue valueWithNonretainedObject:key];
 NSMutableDictionary *rows=self.actionMap[identity];if(!rows){rows=[NSMutableDictionary new];self.actionMap[identity]=rows;}
 for(NSNumber *bit in @[@1,@2,@64])if(events&bit.unsignedIntegerValue){NSMutableArray *actions=rows[bit];if(!actions){actions=[NSMutableArray new];rows[bit]=actions;}[actions addObject:NSStringFromSelector(action)];}
}
- (NSArray *)actionsForTarget:(id)target forControlEvent:(UIControlEvents)event {return self.actionMap[[NSValue valueWithNonretainedObject:target?:NSNull.null]][@(event)]?:@[];}
@end
@implementation CCUIRoundButton @end
@implementation UIViewController
- (instancetype)init {if((self=[super init])){NFControllerCreations++;_view=[UIView new];_isViewLoaded=YES;}return self;}
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
 (void)animated;NFPresents++;self.presentedViewController=controller;controller.presentingViewController=self;
 if(NFDuringPresentation)NFDuringPresentation();if(completion){NFCompletions++;completion();}
}
@end
@implementation CCUIConnectivityCellularDataViewController @end
@implementation UIGestureRecognizer
- (instancetype)init {if((self=[super init])){NFGestureCreations++;_enabled=YES;_state=UIGestureRecognizerStatePossible;}return self;}
- (instancetype)initWithTarget:(id)target action:(SEL)action {if((self=[self init])){_actionTarget=target;_actionSelector=action;}return self;}
- (void)removeTarget:(id)target action:(SEL)action {if((!target||self.actionTarget==target)&&(!action||self.actionSelector==action)){self.actionTarget=nil;self.actionSelector=NULL;}}
- (CGPoint)locationInView:(UIView *)view {(void)view;return self.point;}
- (void)fire {id target=self.actionTarget;SEL action=self.actionSelector;if(self.enabled&&target&&action){IMP imp=[target methodForSelector:action];((void (*)(id,SEL,id))imp)(target,action,self);}}
@end
@implementation UILongPressGestureRecognizer @end
@implementation UIPanGestureRecognizer @end
@implementation UIScreenEdgePanGestureRecognizer @end
@implementation UITapGestureRecognizer @end
@implementation UISwipeGestureRecognizer @end
@implementation UIPinchGestureRecognizer @end
@implementation UIRotationGestureRecognizer @end
@implementation UITouch
- (CGPoint)locationInView:(UIView *)view {(void)view;return self.point;}
@end
@implementation UIPreviewInteraction
- (CGPoint)locationInCoordinateSpace:(id)space {(void)space;return self.point;}
@end
@implementation LCSCellularSIMController
- (instancetype)init {if((self=[super init]))NFPanelCreations++;return self;}
- (void)close {if(self.closed)return;self.closed=YES;NFCloses++;UIViewController *presenter=self.presentingViewController;if(presenter.presentedViewController==self)presenter.presentedViewController=nil;self.presentingViewController=nil;if(self.didClose){NFCloseCallbacks++;self.didClose();}}
@end

// Deterministic external dispatch/clock boundary; real method bodies remain intact.
static double NFNow=10;
static NSMutableArray<NSDictionary *> *NFJobs;
static CFTimeInterval NFMediaTime(void){return NFNow;}
static dispatch_queue_t NFMainQueue(void){return NULL;}
static dispatch_time_t NFTime(dispatch_time_t when,int64_t delta){return (when==DISPATCH_TIME_NOW?(uint64_t)(NFNow*NSEC_PER_SEC):when)+(uint64_t)delta;}
static void NFAfter(dispatch_time_t deadline,dispatch_queue_t queue,dispatch_block_t block){(void)queue;if(!NFJobs)NFJobs=[NSMutableArray new];[NFJobs addObject:@{@"deadline":@(deadline),@"block":[block copy]}];}
static void NFAsync(dispatch_queue_t queue,dispatch_block_t block){NFAfter(NFTime(DISPATCH_TIME_NOW,0),queue,block);}
static void NFAdvance(double seconds){
 NFNow+=seconds;NSUInteger iterations=0;
 while(YES){NSDictionary *due=nil;for(NSDictionary *job in NFJobs)if([job[@"deadline"] unsignedLongLongValue]<=(uint64_t)(NFNow*NSEC_PER_SEC)){due=job;break;}
 if(!due)break;if(++iterations>1024){fprintf(stderr,"FAIL fake clock loop\n");exit(2);}[NFJobs removeObjectIdenticalTo:due];dispatch_block_t block=due[@"block"];block();}
}
#define CACurrentMediaTime NFMediaTime
#define dispatch_get_main_queue NFMainQueue
#define dispatch_time NFTime
#define dispatch_after NFAfter
#define dispatch_async NFAsync

enum {LCSCellularSIMManager=1};
static BOOL LCSCellularFeatureEnabled(NSInteger feature){(void)feature;return NFFeature;}
static BOOL LCSCellularIsUnlocked(void){return NFUnlocked;}
static BOOL LCSCellularIsSpringBoard(void){return NFProcess;}
static void LCSCellularLog(NSInteger feature,NSString *event,NSString *reason,NSInteger value){(void)feature;(void)value;if(!NFLogs)NFLogs=[NSMutableArray new];[NFLogs addObject:[NSString stringWithFormat:@"%@|%@",event,reason]];}
static void LCSInstallHooks(void){NFInstallRequests++;} // Hook installation is explicitly mocked.

// NF_PRODUCTION_METHODS_INSERT_HERE

// Assertion driver: only macOS --native executes these groups.
static void NFFail(const char *expression,int line){fprintf(stderr,"FAIL line %d: %s\n",line,expression);exit(1);}
#define CHECK(x) do {if(!(x))NFFail(#x,__LINE__);} while(0)
static NSUInteger NFOriginalLoads,NFOriginalAppears,NFOriginalDisappears,NFOriginalLayouts,NFOriginalExpands,NFOriginalRounds,NFOriginalRoundBegins,NFOriginalPreviews;
static BOOL NFOriginalDecision=YES;
static void NFLoad(id object,SEL selector){(void)object;(void)selector;NFOriginalLoads++;}
static void NFAppear(id object,SEL selector,BOOL animated){(void)object;(void)selector;(void)animated;NFOriginalAppears++;}
static void NFDisappear(id object,SEL selector,BOOL animated){(void)object;(void)selector;(void)animated;NFOriginalDisappears++;}
static void NFLayout(id object,SEL selector){(void)object;(void)selector;NFOriginalLayouts++;}
static void NFExpand(id object,SEL selector,BOOL expanded){(void)object;(void)selector;(void)expanded;NFOriginalExpands++;}
static void NFRound(id object,SEL selector){(void)object;(void)selector;NFOriginalRounds++;}
static BOOL NFRoundBegin(id object,SEL selector,id gesture){(void)object;(void)selector;(void)gesture;NFOriginalRoundBegins++;return NFOriginalDecision;}
static BOOL NFPreview(id object,SEL selector,id preview){(void)object;(void)selector;(void)preview;NFOriginalPreviews++;return NFOriginalDecision;}
static void NFReset(void){
 [LCSPresentedSIM close];for(LCSCellularButtonState *state in LCSCellularStates)[state unbind];
 LCSCellularStates=[NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory];
 LCSNativeCellularClass=CCUIConnectivityCellularDataViewController.class;LCSHookMask=LCSRequiredHookMask;LCSPreviewHookReady=YES;LCSCellularForeground=YES;
 NFFeature=NFUnlocked=NFProcess=YES;NFOriginalDecision=YES;NFDuringPresentation=nil;NFJobs=[NSMutableArray new];NFNow=10;NFLogs=[NSMutableArray new];
 NFControllerCreations=NFGestureCreations=NFPanelCreations=NFPresents=NFCompletions=NFCloses=NFCloseCallbacks=0;
 NFReceived=NFTraces=NFInventories=NFInstallRequests=0;
 NFOriginalLoads=NFOriginalAppears=NFOriginalDisappears=NFOriginalLayouts=NFOriginalExpands=NFOriginalRounds=NFOriginalRoundBegins=NFOriginalPreviews=0;
 LCSOriginalLoad=NFLoad;LCSOriginalAppear=NFAppear;LCSOriginalDisappear=NFDisappear;LCSOriginalLayout=NFLayout;LCSOriginalExpanded=NFExpand;
 LCSOriginalRoundDidMoveToWindow=NFRound;LCSOriginalRoundGestureShouldBegin=NFRoundBegin;LCSOriginalPreviewShouldBegin=NFPreview;
}
@interface NFScene : NSObject
@property(nonatomic,strong) UIViewController *controller;
@property(nonatomic,strong) CCUIRoundButton *button;
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) LCSCellularButtonState *state;
- (instancetype)initWithClass:(Class)cls;
- (void)load;
- (void)attach:(UIWindow *)window;
@end
static UIWindow *NFWindow(void){UIWindow *window=[UIWindow new];window.rootViewController=[UIViewController new];[window addSubview:window.rootViewController.view];return window;}
@implementation NFScene
- (instancetype)initWithClass:(Class)cls {if((self=[super init])){_controller=[cls new];_button=[CCUIRoundButton new];_button.hidden=YES;[_controller.view addSubview:_button];}return self;}
- (void)load {LCSLoaded(self.controller,@selector(viewDidLoad));self.state=objc_getAssociatedObject(self.controller,&LCSCellularStateKey);}
- (void)attach:(UIWindow *)window {self.window=window;[window.rootViewController.view addSubview:self.controller.view];}
@end
static NFScene *NFDetached(void){NFScene *scene=[[NFScene alloc] initWithClass:CCUIConnectivityCellularDataViewController.class];[scene load];return scene;}
static NFScene *NFLive(BOOL direct){NFScene *scene=NFDetached();scene.controller.view.userInteractionEnabled=direct;[scene attach:NFWindow()];scene.button.hidden=NO;[scene.state bind];return scene;}
static BOOL NFReceive(LCSCellularButtonState *state,UIGestureRecognizer *gesture,double x,double y){UITouch *touch=[UITouch new];touch.view=state.button;touch.point=CGPointMake(x,y);return [state.target gestureRecognizer:gesture shouldReceiveTouch:touch];}
static BOOL NFBegin(LCSCellularButtonState *state,UIGestureRecognizer *gesture){return [state.target gestureRecognizerShouldBegin:gesture];}
static void NFAction(UIGestureRecognizer *gesture,UIGestureRecognizerState phase){gesture.state=phase;[gesture fire];}
static void NFNoBinding(LCSCellularButtonState *state){CHECK(!state.directPress&&!state.windowPress&&!state.button&&!state.boundWindow&&!state.target);}
static void NFCheckPanel(NFScene *scene){CHECK(NFPresents==1&&NFPanelCreations==1&&NFCompletions==1);LCSCellularSIMController *panel=scene.state.panel;CHECK(panel&&panel==LCSPresentedSIM&&panel.presentingViewController);CHECK(panel.mayContinue&&panel.mayContinue());[panel close];CHECK(!scene.state.panel&&!LCSPresentedSIM&&!scene.state.expansionOverlayActive);CHECK(NFCloses==1&&NFCloseCallbacks==1);[panel close];CHECK(NFCloses==1&&NFCloseCallbacks==1);}
static void NFDetachedHidden(void){
 NFScene *scene=NFDetached();LCSCellularButtonState *state=scene.state;
 CHECK(NFOriginalLoads==1&&state.appeared&&!state.expansionKnown);CHECK(state.directPress&&state.directPress.view==scene.button&&!state.windowPress&&!state.boundWindow);
 CHECK(objc_getAssociatedObject(scene.button,&LCSCellularButtonKey)==state);CHECK(NFGestureCreations==1&&scene.button.addCalls==1);
 CHECK(![state entryReady]&&!NFReceive(state,state.directPress,20,20)&&!NFBegin(state,state.directPress));NFAction(state.directPress,UIGestureRecognizerStateBegan);
 CHECK(!NFPresents&&!NFPanelCreations&&!NFReceived);[state bind];CHECK(NFGestureCreations==1&&scene.button.gestureRecognizers.count==1);
 // Attachment alone still does not make a hidden button eligible.
 [scene attach:NFWindow()];LCSRoundDidMoveToWindow(scene.button,@selector(didMoveToWindow));CHECK(NFOriginalRounds==1&&state.windowPress);
 CHECK(!NFReceive(state,state.directPress,20,20)&&!NFReceive(state,state.windowPress,20,20));CHECK(!NFBegin(state,state.directPress)&&!NFBegin(state,state.windowPress));
 NFAction(state.windowPress,UIGestureRecognizerStateBegan);CHECK(!NFPresents);
}
static void NFFirstStart(void){
 for(NSUInteger mode=0;mode<2;mode++){@autoreleasepool{NFReset();BOOL direct=mode==0;NFScene *scene=NFDetached();LCSCellularButtonState *state=scene.state;
 UILongPressGestureRecognizer *prepared=state.directPress;scene.controller.view.userInteractionEnabled=direct;[scene attach:NFWindow()];scene.button.hidden=NO;
 LCSRoundDidMoveToWindow(scene.button,@selector(didMoveToWindow));CHECK(NFOriginalRounds==1&&state.directPress==prepared&&state.windowPress&&state.boundWindow==scene.window);
 CHECK(!state.expansionKnown&&NFOriginalExpands==0&&NFGestureCreations==2);CHECK(scene.button.removeCalls==0&&scene.button.addCalls==1);
 CHECK(state.directPress.cancelsTouchesInView&&!state.windowPress.cancelsTouchesInView);CHECK(!state.directPress.delaysTouchesBegan&&!state.windowPress.delaysTouchesBegan);
 CHECK(state.directPress.minimumPressDuration==.45&&state.windowPress.minimumPressDuration==.45);
 CHECK(NFReceive(state,state.directPress,20,20)==direct&&NFBegin(state,state.directPress)==direct);
 CHECK(NFReceive(state,state.windowPress,20,20)==!direct&&NFBegin(state,state.windowPress)==!direct);
 CHECK(NFReceived==1);NSUInteger received=NFReceived;CHECK(!NFReceive(state,state.windowPress,90,90)&&NFReceived==received);
 NFAction(direct?state.windowPress:state.directPress,UIGestureRecognizerStateBegan);CHECK(!NFPresents);
 NFAction(direct?state.directPress:state.windowPress,UIGestureRecognizerStateBegan);NFCheckPanel(scene);
 }}
}
static void NFRouteFlips(void){
 NFScene *scene=NFLive(YES);LCSCellularButtonState *state=scene.state;UILongPressGestureRecognizer *direct=state.directPress,*fallback=state.windowPress;
 CHECK(NFBegin(state,direct)&&NFReceive(state,direct,20,20));scene.controller.view.userInteractionEnabled=NO;
 NFAction(direct,UIGestureRecognizerStateBegan);CHECK(!NFPresents&&[NFLogs containsObject:@"press|button-not-direct-touch"]);
 [state bind];CHECK(state.directPress==direct&&state.windowPress==fallback&&NFGestureCreations==2&&scene.button.removeCalls==0&&scene.window.removeCalls==0);
 CHECK(!NFBegin(state,direct)&&!NFReceive(state,direct,20,20));CHECK(NFBegin(state,fallback)&&NFReceive(state,fallback,20,20));
 CHECK(NFReceive(state,fallback,-8,-10));CHECK(!NFReceive(state,fallback,48,20)&&!NFReceive(state,fallback,20,50));
 scene.controller.view.userInteractionEnabled=YES;NFAction(fallback,UIGestureRecognizerStateBegan);CHECK(!NFPresents&&[NFLogs containsObject:@"press|fallback-not-needed"]);
 [state bind];CHECK(state.directPress==direct&&state.windowPress==fallback&&NFGestureCreations==2);CHECK(!NFReceive(state,fallback,20,20)&&!NFBegin(state,fallback));
 scene.controller.view.alpha=.001;CHECK(!NFReceive(state,direct,20,20)&&!NFBegin(state,direct));NFAction(direct,UIGestureRecognizerStateBegan);CHECK(!NFPresents);
}
static void NFWindowLifecycle(void){
 NFScene *scene=NFLive(YES);LCSCellularButtonState *state=scene.state;UIWindow *old=scene.window;
 UILongPressGestureRecognizer *direct=state.directPress,*fallback=state.windowPress;
 for(NSUInteger i=0;i<12;i++)[state bind];CHECK(state.directPress==direct&&state.windowPress==fallback&&NFGestureCreations==2);
 CHECK(scene.button.gestureRecognizers.count==1&&old.gestureRecognizers.count==1&&scene.button.addCalls==1&&old.addCalls==1);
 UIWindow *next=NFWindow();[scene attach:next];LCSRoundDidMoveToWindow(scene.button,@selector(didMoveToWindow));
 CHECK(NFOriginalRounds==1&&state.boundWindow==next&&state.windowPress!=fallback&&state.directPress==direct&&NFGestureCreations==3);
 CHECK(!fallback.enabled&&!fallback.delegate&&!fallback.view&&!fallback.actionTarget&&!old.gestureRecognizers.count);
 CHECK(next.gestureRecognizers.count==1&&scene.button.removeCalls==0);[state bind];CHECK(NFGestureCreations==3&&next.addCalls==1);
 // Repair a recognizer that was moved externally, even with the SAME bound window.
 UIWindow *stolen=NFWindow();UILongPressGestureRecognizer *moved=state.windowPress;[stolen addGestureRecognizer:moved];[state syncWindowPress];
 CHECK(!moved.enabled&&!moved.view&&!moved.actionTarget&&!stolen.gestureRecognizers.count);CHECK(state.windowPress!=moved&&state.windowPress.view==next&&next.gestureRecognizers.count==1);
 UILongPressGestureRecognizer *last=state.windowPress;[scene.controller.view removeFromSuperview];LCSRoundDidMoveToWindow(scene.button,@selector(didMoveToWindow));
 CHECK(NFOriginalRounds==2&&!state.boundWindow&&!state.windowPress&&!last.view&&!last.enabled&&!next.gestureRecognizers.count);
 CHECK(state.directPress==direct&&scene.button.gestureRecognizers.count==1&&!NFBegin(state,direct));[state bind];CHECK(state.directPress==direct&&!state.windowPress);
 [scene attach:next];[state bind];CHECK(state.directPress==direct&&state.windowPress&&next.gestureRecognizers.count==1);
 [state unbind];NFNoBinding(state);CHECK(!scene.button.gestureRecognizers.count&&!next.gestureRecognizers.count&&!objc_getAssociatedObject(scene.button,&LCSCellularButtonKey));
 CHECK(!direct.enabled&&!direct.delegate&&!direct.view&&!direct.actionTarget);
}
static void NFBindingGuards(void){
 @autoreleasepool{NFReset();NFScene *scene=NFLive(YES);CCUIRoundButton *second=[CCUIRoundButton new];[scene.controller.view addSubview:second];[scene.state bind];
 NFNoBinding(scene.state);CHECK([scene.state.lastBindingFailure isEqualToString:@"button-ambiguous"]);CHECK(!scene.button.gestureRecognizers.count&&!scene.window.gestureRecognizers.count);CHECK(!objc_getAssociatedObject(second,&LCSCellularButtonKey));}
 @autoreleasepool{NFReset();NFScene *scene=NFLive(YES);UIControl *outside=[UIControl new];[scene.window.rootViewController.view addSubview:outside];
 CHECK(![scene.state safeDirectButton:outside]&&[scene.state.lastBindingFailure isEqualToString:@"button-outside-controller"]);
 UIWindow *other=NFWindow();[other addSubview:outside];CHECK(![scene.state safeDirectButton:outside]&&[scene.state.lastBindingFailure isEqualToString:@"button-window-mismatch"]);
 // Ownership can change after a successful begin; receive/begin/action must recheck.
 LCSCellularButtonState *owner=[LCSCellularButtonState new];CHECK(NFBegin(scene.state,scene.state.directPress));
 objc_setAssociatedObject(scene.button,&LCSCellularButtonKey,owner,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
 CHECK(![scene.state entryReady]&&!NFReceive(scene.state,scene.state.directPress,20,20)&&!NFBegin(scene.state,scene.state.directPress));
 NFAction(scene.state.directPress,UIGestureRecognizerStateBegan);CHECK(!NFPresents);[scene.state bind];NFNoBinding(scene.state);
 CHECK(objc_getAssociatedObject(scene.button,&LCSCellularButtonKey)==owner&&[scene.state.lastBindingFailure isEqualToString:@"button-owned-elsewhere"]);
 NSUInteger logs=NFLogs.count;[scene.state logBindingFailure:@"button-owned-elsewhere"];CHECK(NFLogs.count==logs);
 objc_setAssociatedObject(scene.button,&LCSCellularButtonKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
 @autoreleasepool{NFReset();NFScene *scene=[[NFScene alloc] initWithClass:UIViewController.class];[scene load];NFNoBinding(scene.state);CHECK([scene.state.lastBindingFailure isEqualToString:@"controller-mismatch"]&&!NFGestureCreations);}
 for(NSNumber *event in @[@1,@2]){@autoreleasepool{NFReset();NFScene *scene=[[NFScene alloc] initWithClass:CCUIConnectivityCellularDataViewController.class];
 [scene.button addTarget:event.unsignedIntegerValue==1?scene.controller:nil action:@selector(description) forControlEvents:event.unsignedIntegerValue];[scene load];NFNoBinding(scene.state);
 CHECK([scene.state.lastBindingFailure isEqualToString:@"tap-contract-unverified"]&&!NFGestureCreations&&scene.button.allTargets.count==1);}}
 @autoreleasepool{NFReset();NFScene *scene=[[NFScene alloc] initWithClass:CCUIConnectivityCellularDataViewController.class];[scene.button addTarget:nil action:@selector(description) forControlEvents:UIControlEventTouchUpInside];[scene load];CHECK(scene.state.directPress&&LCSTapContract(scene.button));
 [scene.state unbind];[scene.button removeFromSuperview];[scene.state bind];NFNoBinding(scene.state);CHECK([scene.state.lastBindingFailure isEqualToString:@"button-not-found"]);}
 @autoreleasepool{NFReset();NFScene *scene=NFLive(YES);CHECK(NFBegin(scene.state,scene.state.directPress));[scene.window.rootViewController.view addSubview:scene.button];
 CHECK(![scene.state entryReady]&&!NFBegin(scene.state,scene.state.directPress));NFAction(scene.state.directPress,UIGestureRecognizerStateBegan);CHECK(!NFPresents);}
 @autoreleasepool{NFReset();NFScene *scene=NFDetached();LCSHookMask=0;[scene.state bind];NFNoBinding(scene.state);CHECK([scene.state.lastBindingFailure isEqualToString:@"lifecycle-hooks-incomplete"]);}
}
static void NFSetGate(NSUInteger gate,BOOL enabled){if(gate==0)NFFeature=enabled;else if(gate==1)NFUnlocked=enabled;else LCSCellularForeground=enabled;}
static void NFLateRevocation(void){
 for(NSUInteger gate=0;gate<3;gate++){@autoreleasepool{NFReset();NFScene *scene=NFLive(YES);LCSCellularButtonState *state=scene.state;
 UILongPressGestureRecognizer *saved=state.directPress;LCSCellularPressTarget *target=state.target;[state scheduleLayoutRebind];CHECK(state.layoutPending&&NFJobs.count==1);
 NFSetGate(gate,NO);CHECK(!NFReceive(state,saved,20,20)&&!NFBegin(state,saved));NFAction(saved,UIGestureRecognizerStateBegan);CHECK(!NFPresents);
 LCSReconcile();NFNoBinding(state);CHECK(!scene.button.gestureRecognizers.count&&!scene.window.gestureRecognizers.count);
 NFAdvance(1);CHECK(!state.layoutPending);[state bind];[target lcs_handlePress:saved];NFNoBinding(state);CHECK(!NFPresents&&NFGestureCreations==2&&!saved.enabled&&!saved.actionTarget);
 }}
 for(NSUInteger gate=0;gate<3;gate++){@autoreleasepool{NFReset();NFScene *scene=NFLive(YES);NFAction(scene.state.directPress,UIGestureRecognizerStateBegan);LCSCellularSIMController *panel=scene.state.panel;CHECK(panel&&panel.mayContinue());
 NFSetGate(gate,NO);CHECK(!panel.mayContinue());LCSReconcile();NFNoBinding(scene.state);CHECK(!scene.state.panel&&!LCSPresentedSIM&&NFCloses==1&&NFCloseCallbacks==1);[scene.state bind];NFNoBinding(scene.state);}}
 @autoreleasepool{NFReset();NFScene *scene=NFLive(YES);NFProcess=NO;NFAction(scene.state.directPress,UIGestureRecognizerStateBegan);CHECK(!NFPresents&&[NFLogs containsObject:@"press|wrong-process"]);}
}
static void NFNonBegan(void){
 for(NSUInteger route=0;route<2;route++){@autoreleasepool{NFReset();NFScene *scene=NFLive(route==0);UILongPressGestureRecognizer *press=route==0?scene.state.directPress:scene.state.windowPress;
 for(NSNumber *phase in @[@0,@2,@3,@4,@5]){NFAction(press,phase.integerValue);CHECK(!NFPresents&&!NFPanelCreations);NFAdvance(1);CHECK(NFGestureCreations==2&&scene.button.gestureRecognizers.count==1&&scene.window.gestureRecognizers.count==1);}
 UIGestureRecognizer *foreign=[[UIGestureRecognizer alloc] initWithTarget:scene.state.target action:@selector(lcs_handlePress:)];CHECK(!NFReceive(scene.state,foreign,20,20)&&!NFBegin(scene.state,foreign));NFAction(foreign,UIGestureRecognizerStateBegan);CHECK(!NFPresents);
 }}
}
static void NFExpandedAndPanel(void){
 @autoreleasepool{NFReset();NFScene *scene=NFLive(YES);LCSCellularButtonState *state=scene.state;
 LCSAppeared(scene.controller,@selector(viewDidAppear:),NO);CHECK(NFOriginalAppears==1);
 LCSWillExpand(scene.controller,@selector(containerWillTransitionToExpandedContentMode:),YES);
 CHECK(NFOriginalExpands==1&&state.expansionKnown&&state.expanded&&NFBegin(state,state.directPress));
 state.directPress.numberOfTouches=1;UIPreviewInteraction *preview=[UIPreviewInteraction new];preview.view=scene.window.rootViewController.view;preview.point=CGPointMake(20,20);
 CHECK(!LCSPreviewShouldBegin(scene.window.rootViewController,@selector(previewInteractionShouldBegin:),preview)&&NFOriginalPreviews==0);
 UIView *unrelated=[UIView new];preview.view=unrelated;CHECK(LCSPreviewShouldBegin(scene.window.rootViewController,@selector(previewInteractionShouldBegin:),preview)&&NFOriginalPreviews==1);
 NFAction(state.directPress,UIGestureRecognizerStateBegan);LCSCellularSIMController *panel=state.panel;CHECK(panel&&NFPresents==1&&NFCompletions==1);
 preview.view=scene.window.rootViewController.view;CHECK(LCSPreviewShouldBegin(scene.window.rootViewController,@selector(previewInteractionShouldBegin:),preview)&&NFOriginalPreviews==2);
 LCSWillExpand(scene.controller,@selector(containerWillTransitionToExpandedContentMode:),YES);CHECK(NFOriginalExpands==2&&state.expansionOverlayActive);
 scene.button.hidden=YES;[scene.controller.view removeFromSuperview];LCSDisappeared(scene.controller,@selector(viewDidDisappear:),NO);
 CHECK(NFOriginalDisappears==1&&!state.appeared&&state.expansionOverlayActive&&state.panel==panel);NFNoBinding(state);CHECK(panel.mayContinue()&&!NFCloses);
 [panel close];CHECK(!state.panel&&!state.expansionOverlayActive&&!LCSPresentedSIM&&NFCloses==1&&NFCloseCallbacks==1);
 [state scheduleLayoutRebind];NFAdvance(1);NFNoBinding(state);CHECK(!state.appeared&&NFGestureCreations==2);
 LCSWillExpand(scene.controller,@selector(containerWillTransitionToExpandedContentMode:),NO);CHECK(NFOriginalExpands==3&&!state.expanded&&state.expansionKnown);NFNoBinding(state);
 }
 @autoreleasepool{NFReset();NFScene *scene=NFLive(NO);CHECK(NFBegin(scene.state,scene.state.windowPress));
 LCSWillExpand(scene.controller,@selector(containerWillTransitionToExpandedContentMode:),NO);CHECK(!scene.state.expanded&&scene.state.expansionKnown&&NFBegin(scene.state,scene.state.windowPress));
 NFAction(scene.state.windowPress,UIGestureRecognizerStateBegan);LCSCellularSIMController *panel=scene.state.panel;CHECK(panel);
 // A visible disappearance preserves the old entry, not an unconditional close.
 LCSDisappeared(scene.controller,@selector(viewDidDisappear:),NO);CHECK(scene.state.appeared&&scene.state.panel==panel&&!NFCloses);
 scene.button.hidden=YES;LCSDisappeared(scene.controller,@selector(viewDidDisappear:),NO);CHECK(!scene.state.appeared&&!scene.state.panel&&!LCSPresentedSIM&&NFCloses==1&&NFCloseCallbacks==1);NFNoBinding(scene.state);
 }
 @autoreleasepool{NFReset();NFScene *scene=NFLive(YES);NFDuringPresentation=^{NFFeature=NO;};NFAction(scene.state.directPress,UIGestureRecognizerStateBegan);
 CHECK(NFPresents==1&&NFCompletions==1&&NFCloses==1&&NFCloseCallbacks==1&&!scene.state.panel&&!LCSPresentedSIM);NFDuringPresentation=nil;}
}
static void NFLayoutAndForeign(void){
 NFScene *scene=NFLive(YES);LCSCellularButtonState *state=scene.state;state.lastLayoutRetry=NFNow;
 LCSLayoutSubviews(scene.controller,@selector(viewDidLayoutSubviews));LCSLayoutSubviews(scene.controller,@selector(viewDidLayoutSubviews));
 CHECK(NFOriginalLayouts==2&&state.layoutPending&&NFJobs.count==1);NFAdvance(.1);CHECK(state.layoutPending&&NFJobs.count==1);NFAdvance(.2);CHECK(!state.layoutPending&&!NFJobs.count&&NFGestureCreations==2);
 CHECK(state.lastLayoutRetry==NFNow);LCSRoundDidMoveToWindow(scene.button,@selector(didMoveToWindow));CHECK(NFOriginalRounds==1&&NFGestureCreations==2);
 NSUInteger states=LCSCellularStates.count,controllers=NFControllerCreations;CCUIRoundButton *foreign=[CCUIRoundButton new];LCSRoundDidMoveToWindow(foreign,@selector(didMoveToWindow));
 CHECK(NFOriginalRounds==2&&LCSCellularStates.count==states&&NFControllerCreations==controllers&&!objc_getAssociatedObject(foreign,&LCSCellularStateKey)&&!objc_getAssociatedObject(foreign,&LCSCellularButtonKey));
 CHECK(!foreign.gestureRecognizers.count&&!foreign.addCalls&&NFGestureCreations==2&&!NFPanelCreations);
 for(NSNumber *decision in @[@YES,@NO]){NFOriginalDecision=decision.boolValue;CHECK(LCSRoundGestureShouldBegin(foreign,@selector(gestureRecognizerShouldBegin:),state.directPress)==decision.boolValue);}
 CHECK(NFOriginalRoundBegins==2&&LCSCellularStates.count==states&&NFGestureCreations==2);
 CHECK(LCSRoundGestureShouldBegin(scene.button,@selector(gestureRecognizerShouldBegin:),state.directPress)&&NFOriginalRoundBegins==2);
 scene.controller.view.userInteractionEnabled=NO;CHECK(!LCSRoundGestureShouldBegin(scene.button,@selector(gestureRecognizerShouldBegin:),state.directPress)&&NFOriginalRoundBegins==2);
}
int main(void){
 @autoreleasepool{
  const char *names[]={"detached-hidden-passive-prebind","first-start-direct-and-fallback-no-expanded-callback","same-window-D-flip-rechecks","window-move-detach-and-idempotence","identity-ownership-touchdown-guards","revocation-and-late-layout-callback","non-began-and-foreign-action-no-present","expanded-preview-and-panel-close-preservation","layout-coalescing-and-foreign-original-exact-once"};
  void (*groups[])(void)={NFDetachedHidden,NFFirstStart,NFRouteFlips,NFWindowLifecycle,NFBindingGuards,NFLateRevocation,NFNonBegan,NFExpandedAndPanel,NFLayoutAndForeign};
  for(NSUInteger i=0;i<sizeof(groups)/sizeof(groups[0]);i++){@autoreleasepool{NFReset();groups[i]();printf("PASS %s\n",names[i]);}}
  NFReset();puts("PASS 9 native assertion groups; fake UIKit only, NOT system gesture or device validation.");
 }
 return 0;
}
