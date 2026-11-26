static void ADSetFrame(id view,SEL command,CGRect frame) { (void)command; ((UIView *)view).frame=frame; }
static void ADNoLayout(id bridge,SEL command) { (void)bridge;(void)command;ADLayoutCalls++; }
static NSUInteger ADChecks;
#define CHECK(condition) do { ADChecks++; if (!(condition)) { fprintf(stderr,"FAIL %s:%d %s\n",__FILE__,__LINE__,#condition); exit(1); } } while(0)

@interface ADFixture : NSObject
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) ADCard *card;
@property(nonatomic,strong) UIView *canvas;
@property(nonatomic,strong) UIView *host;
@property(nonatomic,strong) ADBridge *bridge;
@property(nonatomic,strong) PXWMContext *context;
@property(nonatomic,strong) UIGestureRecognizer *gesture;
@end
@implementation ADFixture @end

static void ADFitHost(ADBridge *bridge) {
 CGSize source=bridge.sourceSize; CGRect bounds=bridge.canvas.bounds;
 // Independent native-layout stand-in, not a call to PXWMContentFit.
 CGFloat s=MIN(bounds.size.width/source.width,bounds.size.height/source.height);
 bridge.hostView.bounds=CGRectMake(0,0,source.width,source.height);
 bridge.hostView.center=CGPointMake(CGRectGetMidX(bounds),CGRectGetMidY(bounds));
 bridge.hostView.transform=CGAffineTransformMakeScale(s,s);
}
static void ADLayout(id bridge,SEL command) {
 (void)command; ADLayoutCalls++; ADFitHost(bridge);
}
static void ADOriginal(id panel,SEL command,id object) {
 (void)panel; (void)command; ADOriginalCalls++;
 UIGestureRecognizer *gesture=object;
 PXWMGesture *stamp=objc_getAssociatedObject(gesture,PXWMGestureKey);
 ADOriginalSawInteraction=stamp.context.interacting;
 if(ADMutateOriginal && gesture.state==UIGestureRecognizerStateEnded)
  ADOriginalCard.frame=CGRectMake(80,100,260,520);
}
static void ADDrainOne(void) {
 CHECK(ADJobs.count>0);
 dispatch_block_t job=ADJobs.firstObject; [ADJobs removeObjectAtIndex:0]; job();
}
static void ADDrain(void) {
 NSUInteger guard=0;
 while(ADJobs.count) { CHECK(++guard<64); ADDrainOne(); }
}
static ADFixture *ADNew(void) {
 ADJobs=[NSMutableArray array]; ADEvents=[NSMutableArray array]; ADDetails=[NSMutableArray array];
 ADOriginalCalls=ADLayoutCalls=ADProbeCalls=0; ADMutateOriginal=NO;
 ADOriginalSawInteraction=NO;
 PXWindowMemoryStore.shared.snapshot=@{@"enabled":@YES,@"epoch":@7,@"diagnostics":@YES};
 PXWindowMemoryStore.shared.positionSaves=PXWindowMemoryStore.shared.geometrySaves=0;
 PXWMContexts=[NSHashTable weakObjectsHashTable]; PXWMCardClass=ADCard.class;
 PXWMOriginalLayout=ADLayout; PXWMOriginalMove=ADOriginal; PXWMOriginalResize=ADOriginal;
 PXWMOriginalCardSetFrame=ADSetFrame;
 ADFixture *f=[ADFixture new];
 f.window=[UIWindow new]; f.window.frame=CGRectMake(0,0,400,800); f.window.screen=UIScreen.mainScreen;
 f.card=[ADCard new]; f.card.frame=CGRectMake(20,40,200,400); [f.window addSubview:f.card];
 f.canvas=[UIView new]; f.canvas.frame=CGRectMake(0,0,200,400); [f.card addSubview:f.canvas];
 f.host=[UIView new]; [f.canvas addSubview:f.host];
 f.bridge=[ADBridge new]; f.bridge.canvas=f.canvas; f.bridge.hostView=f.host;
 f.bridge.bundleID=@"test.adapter.app"; f.bridge.scene=[NSObject new];
 f.bridge.hasHostedSurface=YES; f.bridge.sourceSize=CGSizeMake(1000,2000); ADFitHost(f.bridge);
 f.context=[PXWMContext new]; f.context.bridge=f.bridge; f.context.canvas=f.canvas;
 f.context.card=f.card; f.context.bundle=f.bridge.bundleID;
 f.context->native=(PXWMNativeLifecycle){1,false,true,false,true};
 objc_setAssociatedObject(f.bridge,PXWMContextKey,f.context,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
 [PXWMContexts addObject:f.context];
 f.gesture=[UIGestureRecognizer new]; f.gesture.view=f.card;
 ADOriginalCard=f.card;
 PXWMGeometry geometry; unsigned key=99;
 CHECK(PXWMNormalGeometry(f.context,&geometry,&key)); CHECK(key==0);
 PXWMArmContinuity(f.context,geometry,key,7,NO);
 CHECK(PXWMContinuityReady(f.context));
 return f;
}
static void ADMismatch(ADFixture *f) { f.host.transform=CGAffineTransformMakeScale(.1,.1); }
static void ADMove(ADFixture *f,UIGestureRecognizerState state) {
 f.gesture.state=state; PXWMMove(f.bridge,NSSelectorFromString(@"moveHost:"),f.gesture);
}
static void ADResize(ADFixture *f,UIGestureRecognizerState state) {
 f.gesture.state=state; PXWMResize(f.bridge,NSSelectorFromString(@"resizeHost:"),f.gesture);
}
static void ADBegin(void) {
 ADFixture *f=ADNew(); ADMove(f,UIGestureRecognizerStateBegan);
 CHECK(ADOriginalCalls==1); CHECK(ADOriginalSawInteraction);
 CHECK(f.context.interacting && f.context.continuityMove);
 CHECK(objc_getAssociatedObject(f.gesture,PXWMGestureKey)!=nil);
 CHECK(PXWindowMemoryStore.shared.positionSaves==0);
 CHECK(PXWindowMemoryStore.shared.geometrySaves==0);
 ADMove(f,UIGestureRecognizerStateChanged); CHECK(ADOriginalCalls==2);
 ADMove(f,UIGestureRecognizerStateCancelled); CHECK(ADOriginalCalls==3);
 f=ADNew(); ADResize(f,UIGestureRecognizerStateBegan);
 CHECK(ADOriginalCalls==1); CHECK(f.context.interacting && !f.context.continuityActive);
 ADMismatch(f); PXWMQueueContentSync(f.context); CHECK(ADJobs.count==0);
 ADResize(f,UIGestureRecognizerStateCancelled);
}
static void ADMoveCancel(void) {
 ADFixture *f=ADNew(); ADMove(f,UIGestureRecognizerStateBegan); ADMutateOriginal=YES;
 ADMove(f,UIGestureRecognizerStateEnded); ADDrain();
 CHECK(ADOriginalCalls==2);
 CHECK(PXWindowMemoryStore.shared.positionSaves==1 && PXWindowMemoryStore.shared.geometrySaves==0);
 CHECK(fabs(f.card.frame.size.width-200)<.001 && fabs(f.card.frame.size.height-400)<.001);
 CHECK(fabs(f.card.frame.origin.x-110)<.001 && fabs(f.card.frame.origin.y-160)<.001);
 CHECK(PXWMRectNear(PXWindowMemoryStore.shared.lastSaved.frame,PXWMFromRect(f.card.frame),.001));
 CHECK(!f.context.interacting && !f.context.savePending);
 CHECK(objc_getAssociatedObject(f.gesture,PXWMGestureKey)==nil);
 for(NSUInteger phase=UIGestureRecognizerStateCancelled;phase<=UIGestureRecognizerStateFailed;phase++) {
  f=ADNew(); ADMove(f,UIGestureRecognizerStateBegan);
  PXWMGesture *old=objc_getAssociatedObject(f.gesture,PXWMGestureKey);
  NSUInteger generation=f.context.generation;
  ADMove(f,(UIGestureRecognizerState)phase);
  // Exercise an already retained late save callback after cancellation.
  PXWMSettleSave(old,0); ADDrain();
  CHECK(ADOriginalCalls==2); CHECK(f.context.generation>generation);
  CHECK(!f.context.interacting && !f.context.savePending && !f.context.pendingGesture);
  CHECK(PXWindowMemoryStore.shared.positionSaves==0 && PXWindowMemoryStore.shared.geometrySaves==0);
  CHECK(objc_getAssociatedObject(f.gesture,PXWMGestureKey)==nil);
  CHECK([ADEvents containsObject:@"gesture_cancel_no_save"]);
 }
}
static void ADQueue(void) {
 ADFixture *f=ADNew(); ADMismatch(f);
 PXWMQueueContentSync(f.context); PXWMQueueContentSync(f.context);
 CHECK(ADJobs.count==1); CHECK(ADLayoutCalls==0); ADDrain();
 CHECK(ADLayoutCalls==1 && ADProbeCalls==1); CHECK(!f.context.continuityScheduled && !f.context.continuitySyncing);
 PXWMQueueContentSync(f.context); CHECK(ADJobs.count==0);
 // Both enqueue-time and execution-time gates are exercised independently.
 for(NSUInteger reason=0;reason<6;reason++) {
  f=ADNew(); ADMismatch(f); PXWMQueueContentSync(f.context); CHECK(ADJobs.count==1);
  if(reason==0) f.context.generation++;
  if(reason==1) PXWindowMemoryStore.shared.snapshot=@{@"enabled":@YES,@"epoch":@8};
  if(reason==2) f.bridge.canvas=[UIView new];
  if(reason==3) f.bridge.bundleID=@"foreign.app";
  if(reason==4) { f.context.interacting=YES; f.context.continuityMove=NO; }
  if(reason==5) PXWindowMemoryStore.shared.snapshot=@{@"enabled":@NO,@"epoch":@7};
  ADDrain(); CHECK(ADLayoutCalls==0); CHECK(!f.context.continuityScheduled);
  PXWMQueueContentSync(f.context); CHECK(ADJobs.count==0);
  if(reason==1 || reason==5) CHECK(!f.context.continuityActive);
 }
 // An old block must not clear a newer generation's coalescing flag.
 f=ADNew(); ADMismatch(f); PXWMQueueContentSync(f.context);
 f.context.generation++;
 PXWMArmContinuity(f.context,f.context.continuityGeometry,0,7,NO);
 PXWMQueueContentSync(f.context); CHECK(ADJobs.count==2);
 ADDrainOne(); CHECK(f.context.continuityScheduled && ADLayoutCalls==0);
 PXWMQueueContentSync(f.context); CHECK(ADJobs.count==1);
 ADDrain(); CHECK(ADLayoutCalls==1 && !f.context.continuityScheduled);
}
static void ADContent(void) {
 ADFixture *f=ADNew(); PXWMRect shown,expected; double scale=0;
 CHECK(PXWMContentGeometry(f.context,&shown,&expected,&scale));
 CHECK(fabs(scale-.2)<1e-9); CHECK(PXWMRectNear(shown,(PXWMRect){0,0,200,400},1e-6));
 CHECK(PXWMRectNear(shown,expected,1e-6));
 CHECK(!PXWMRectNear(PXWMFromRect(f.host.bounds),expected,1));
 PXWMQueueContentSync(f.context); CHECK(ADJobs.count==0 && ADLayoutCalls==0);
 // Non-zero canvas bounds, inset source bounds and a translated intermediary:
 // convertRect must traverse the tree and undo the destination coordinate space.
 f.canvas.bounds=CGRectMake(17,23,300,500);
 UIView *container=[UIView new]; container.frame=CGRectMake(47,63,300,500); [f.canvas addSubview:container];
 [container addSubview:f.host]; f.host.bounds=CGRectMake(11,13,1000,2000);
 f.host.center=CGPointMake(120,210); f.host.transform=CGAffineTransformMakeScale(.25,.25);
 CHECK(PXWMContentGeometry(f.context,&shown,&expected,&scale));
 CHECK(PXWMRectNear(shown,(PXWMRect){42,23,250,500},1e-6));
 CHECK(PXWMRectNear(shown,expected,1e-6)); CHECK(fabs(scale-.25)<1e-9);
 // This case measures content coordinates only; changing canvas independently
 // intentionally no longer represents a synchronized card/canvas layout.
 f.bridge.hostView=f.canvas; CHECK(!PXWMContentGeometry(f.context,&shown,&expected,&scale));
 f.bridge.hostView=[UIView new]; CHECK(!PXWMContentGeometry(f.context,&shown,&expected,&scale));
 f.bridge.hostView=f.host; f.bridge.sourceSize=CGSizeZero;
 CHECK(!PXWMContentGeometry(f.context,&shown,&expected,&scale));
}
static void ADReconcileResize(void) {
 ADFixture *f=ADNew();
 CHECK(!PXWMReconcileRuntimeFrame(f.context));
 f.card.frame=CGRectMake(30,60,260,520);
 CHECK(PXWMReconcileRuntimeFrame(f.context));
 CHECK(PXWMRectNear(PXWMFromRect(f.card.frame),(PXWMRect){20,40,200,400},1e-6));
 CHECK(!f.context.restoring); CHECK(!PXWMReconcileRuntimeFrame(f.context));
 ADResize(f,UIGestureRecognizerStateBegan);
 f.card.frame=CGRectMake(30,60,240,480); f.canvas.frame=CGRectMake(0,0,240,480); ADFitHost(f.bridge);
 CHECK(!PXWMReconcileRuntimeFrame(f.context));
 PXWMQueueContentSync(f.context); CHECK(ADJobs.count==0);
 ADResize(f,UIGestureRecognizerStateEnded); ADDrain();
 CHECK(ADOriginalCalls==2); CHECK(PXWindowMemoryStore.shared.geometrySaves==1 && PXWindowMemoryStore.shared.positionSaves==0);
 CHECK(PXWMRectNear(PXWindowMemoryStore.shared.lastSaved.frame,(PXWMRect){30,60,240,480},1e-6));
 CHECK(!PXWMReconcileRuntimeFrame(f.context));
 PXWMQueueContentSync(f.context); CHECK(ADJobs.count==0 && ADLayoutCalls==0);
 CHECK(PXWMContinuityReady(f.context));
 // Late settle after Settings clear must not recreate a saved frame.
 f=ADNew(); ADResize(f,UIGestureRecognizerStateBegan);
 f.card.frame=CGRectMake(30,60,240,480);
 PXWindowMemoryStore.shared.snapshot=@{@"enabled":@YES,@"epoch":@8};
 ADResize(f,UIGestureRecognizerStateEnded); ADDrain();
 CHECK(PXWindowMemoryStore.shared.positionSaves==0 && PXWindowMemoryStore.shared.geometrySaves==0);
}
static void ADFrameAndFailure(void) {
 ADFixture *f=ADNew();
 PXWMCardSetFrame(f.card,@selector(setFrame:),CGRectMake(30,60,260,520));
 CHECK(PXWMRectNear(PXWMFromRect(f.card.frame),(PXWMRect){20,40,200,400},.001));
 ADMove(f,UIGestureRecognizerStateBegan);
 PXWMCardSetFrame(f.card,@selector(setFrame:),CGRectMake(80,100,260,520));
 CHECK(PXWMRectNear(PXWMFromRect(f.card.frame),(PXWMRect){110,160,200,400},.001));
 CHECK(PXWMRectNear(f.context.continuityGeometry.frame,PXWMFromRect(f.card.frame),.001));
 // Exhaust all thirty geometry-wait retries with a real keyboard transient.
 f.bridge.isHostedKeyboardVisible=YES;ADMove(f,UIGestureRecognizerStateEnded);ADDrain();
 CHECK(!f.context.continuityActive && !f.context.continuityMove);
 CHECK(PXWindowMemoryStore.shared.positionSaves==0);
 f.bridge.isHostedKeyboardVisible=NO;
 CHECK(!PXWMReconcileRuntimeFrame(f.context));
 CHECK(fabs(f.card.frame.origin.x-110)<.001);
 for(NSUInteger reason=0;reason<5;reason++) {
  f=ADNew();
  if(reason==0) f.window.hidden=YES;
  if(reason==1) f.card.alpha=0;
  if(reason==2) f.bridge.scene=nil;
  if(reason==3) f.bridge.hasHostedSurface=NO;
  if(reason==4) f.bridge.fullscreenHandoff=YES;
  CHECK(!PXWMContinuityReady(f.context));
  PXWMCardSetFrame(f.card,@selector(setFrame:),CGRectMake(30,60,260,520));
  CHECK(PXWMRectNear(PXWMFromRect(f.card.frame),(PXWMRect){30,60,260,520},.001));
 }
 f=ADNew();ADMismatch(f);PXWMOriginalLayout=ADNoLayout;
 for(NSUInteger i=0;i<8;i++) { PXWMQueueContentSync(f.context);ADDrain(); }
 CHECK(ADLayoutCalls==2);CHECK(f.context.continuitySyncAttempts==2);
 for(NSUInteger i=0;i<12;i++) {
  f.canvas.bounds=CGRectMake(0,0,200+(i%2),400);
  PXWMQueueContentSync(f.context);ADDrain();
 }
 CHECK(ADLayoutCalls==4);CHECK(f.context.continuityBudgetAttempts==4);
}
static void ADDiagnosticCases(void) {
 ADFixture *f=ADNew();[ADEvents removeAllObjects];[ADDetails removeAllObjects];
 f.bridge.bundleID=@"foreign.app";
 for(unsigned i=0;i<100;i++) CHECK(!PXWMContinuityReady(f.context));
 CHECK(ADEvents.count==1);CHECK([ADDetails[0][@"reason"] unsignedIntValue]==PXWMReasonIdentity);
 CHECK([ADDetails[0][@"diagIncident"] boolValue]);
 f=ADNew();[ADEvents removeAllObjects];[ADDetails removeAllObjects];
 PXWMRect target={40,80,160,320};CGRect original=f.card.frame;
 PXWMFirstFrameSnapshot(f.context,target,1,0);
 CHECK(PXWMRectNear(PXWMFromRect(f.card.frame),PXWMFromRect(original),0));
 CHECK([ADDetails.lastObject[@"visible"] boolValue]);CHECK([ADDetails.lastObject[@"diagIncident"] boolValue]);
 CHECK([ADDetails.lastObject[@"targetX"] doubleValue]==40);
 f.card.frame=PXWMToRect(target);PXWMFirstFrameSnapshot(f.context,target,1,1);
 CHECK([ADDetails.lastObject[@"x"] doubleValue]==40);CHECK(![ADDetails.lastObject[@"diagIncident"] boolValue]);
 NSUInteger count=ADEvents.count;
 PXWindowMemoryStore.shared.snapshot=@{@"enabled":@YES,@"epoch":@7,@"diagnostics":@NO};
 PXWMFirstFrameSnapshot(f.context,target,1,0);
 PXWMDiagnosticReasonLog(f.context,PXWMLaneQueue,PXWMReasonBudget,YES);
 CHECK(ADEvents.count==count);
}
int main(int argc,const char *argv[]) {
 @autoreleasepool {
  if(argc!=2) return 2;
  if(!strcmp(argv[1],"begin")) ADBegin();
  else if(!strcmp(argv[1],"move_cancel")) ADMoveCancel();
  else if(!strcmp(argv[1],"queue")) ADQueue();
  else if(!strcmp(argv[1],"content")) ADContent();
  else if(!strcmp(argv[1],"reconcile_resize")) ADReconcileResize();
  else if(!strcmp(argv[1],"frame_failure")) ADFrameAndFailure();
  else if(!strcmp(argv[1],"diagnostics")) ADDiagnosticCases();
  else return 2;
  printf("PASS %s checks=%lu\n",argv[1],(unsigned long)ADChecks);
 }
 return 0;
}
