// Assertions execute the imported production code, not a reimplementation.
static unsigned PXIFakeChecks, PXIFakeOriginalCalls;
static id PXIFakeOriginalSelf, PXIFakeOriginalEvent;
static SEL PXIFakeOriginalCommand;
static NSException *PXIFakeOriginalException;
#define CHECK(expr) do { PXIFakeChecks++; if (!(expr)) { \
    fprintf(stderr,"FAIL %s:%d: %s\n",__FILE__,__LINE__,#expr); exit(2); } } while (0)

@interface PXIFakeRig : NSObject
@property(nonatomic,strong) PXIFakeWindow *window;
@property(nonatomic,strong) PXIFakeView *canvas;
@property(nonatomic,strong) PXIFakeView *host;
@property(nonatomic,strong) PXIFakeView *keyboard;
@property(nonatomic,strong) PXIFakeBridge *bridge;
@end
@implementation PXIFakeRig @end

static void PXIFakeOriginal(id object,SEL command,id event) {
    PXIFakeOriginalCalls++;
    PXIFakeOriginalSelf=object; PXIFakeOriginalCommand=command; PXIFakeOriginalEvent=event;
    if (PXIFakeOriginalException) @throw PXIFakeOriginalException;
}
static void PXIFakeClearLogs(void) { [PXIFakeEvents removeAllObjects]; [PXIFakeDetails removeAllObjects]; }
static void PXIFakeDrain(NSArray<dispatch_block_t> *jobs) {
    for (dispatch_block_t job in jobs) job();
}
static PXIFakeRig *PXIFakeMake(NSString *bundle) {
    PXIFakeRig *r=[PXIFakeRig new];
    r.window=[PXIFakeWindow new]; r.canvas=[PXIFakeView new];
    r.host=[PXIFakeView new]; r.keyboard=[PXIFakeView new];
    [r.window addSubview:r.canvas]; [r.canvas addSubview:r.host]; [r.canvas addSubview:r.keyboard];
    r.bridge=[PXIFakeBridge new]; r.bridge.canvas=r.canvas; r.bridge.hostView=r.host;
    r.bridge.keyboardOverlay=r.keyboard; r.bridge.bundleID=bundle;
    PXIFakeScene *scene=[PXIFakeScene new]; scene.settings=[NSObject new]; scene.clientProcess=[NSObject new];
    r.bridge.scene=scene; return r;
}
static void PXIFakeBind(PXIFakeRig *r,uint64_t serial) {
    PXWindowInputDiagnosticsBind(r.bridge,r.canvas,r.bridge.bundleID,serial,PXIFakeNow-1);
}
static PXIFakeTouch *PXIFakeTouchAt(PXIFakeRig *r,PXIFakeView *view,UITouchPhase phase) {
    PXIFakeTouch *touch=[PXIFakeTouch new]; touch.window=r.window; touch.view=view; touch.phase=phase; return touch;
}
static PXIFakeEvent *PXIFakeEventFor(PXIFakeRig *r,PXIFakeView *view,UITouchPhase phase) {
    PXIFakeEvent *event=[PXIFakeEvent new]; event.type=UIEventTypeTouches;
    event.allTouches=[NSSet setWithObject:PXIFakeTouchAt(r,view,phase)]; return event;
}
static NSException *PXIFakeSend(id window,id event) {
    unsigned before=PXIFakeOriginalCalls;
    SEL command=sel_registerName("fixtureExactSendEvent:"); NSException *caught=nil;
    @try { PXInputSendEvent(window,command,event); }
    @catch (NSException *exception) { caught=exception; }
    CHECK(PXIFakeOriginalCalls==before+1);
    CHECK(PXIFakeOriginalSelf==window); CHECK(PXIFakeOriginalCommand==command);
    CHECK(PXIFakeOriginalEvent==event); return caught;
}
static NSDictionary *PXIFakeLastDispatch(void) {
    CHECK([PXIFakeEvents.lastObject isEqual:@"input_host_dispatch"]);
    return PXIFakeDetails.lastObject;
}
static void PXIFakeValidateLogs(void) {
    NSSet *allowed=[NSSet setWithArray:@[
        @"appHash",@"openSerial",@"inputSchema",@"elapsedMs",@"remoteReceiptKnown",@"appResponsivenessKnown",
        @"scenePresent",@"sceneSerial",@"appPID",@"surface",@"suppressSelection",@"sceneAllowsSelection",
        @"sceneForeground",@"sceneBackgrounded",@"canvasInteractive",@"hostPresent",@"hostInteractive",
        @"hostUnderCanvas",@"hostWindowMatches",@"ignoredAncestors",@"ancestorDepth",@"hierarchyTruncated",
        @"windowHidden",@"windowInteractive",@"windowKey",@"bundleMatch",@"canvasMatch",@"stage",
        @"currentBinding",@"stateSamples",@"stateSuppressed",@"eventsObserved",@"suppressed",@"observerExceptions",@"phaseMask",@"receiverMask",
        @"touchCount",@"touchesTruncated",@"diagIncident",@"dispatchReturned",@"dispatchMs",@"bindingCurrentAfter",
        @"requestedEnabled",@"nativeResult",@"hostDispatch",@"interaction",@"foreground",@"sceneUpdate",
        @"hostPhaseKnown",@"hostGateClosed",@"observationOnly",@"launchToken",@"receiverAfterKnown",@"receiverAfterMask"]];
    CHECK(PXIFakeDetails.count==PXIFakeEvents.count);
    for (NSDictionary *record in PXIFakeDetails) {
        CHECK([record[@"remoteReceiptKnown"] isEqual:@NO]);
        CHECK([record[@"appResponsivenessKnown"] isEqual:@NO]);
        for (NSString *key in record) {
            CHECK([allowed containsObject:key]); CHECK([record[key] isKindOfClass:NSNumber.class]);
        }
    }
    CHECK(PXIFakeForbiddenReads==0);
}

static void PXIFakeCaseScope(void) {
    PXIFakeRig *wx=PXIFakeMake(@"com.tencent.xin");
    PXIFakeRig *qq=PXIFakeMake(@"com.tencent.mqq");
    PXIFakeRig *other=PXIFakeMake(@"com.crossutility.quantumult-x.beta");
    PXIFakeEvent *event=PXIFakeEventFor(wx,wx.host,UITouchPhaseBegan);
    CHECK(PXIFakeSend(wx.window,event)==nil); CHECK(PXIFakeDetails.count==0); CHECK(event.reads==0);
    PXIFakeBind(other,9); CHECK(PXIFakeJobs.count==0); CHECK(PXIFakeDetails.count==0);
    PXIFakeBind(wx,11); PXIFakeBind(qq,12); CHECK(PXIFakeJobs.count==10);
    CHECK(PXIFakeDetails.count==2); PXIFakeValidateLogs(); PXIFakeClearLogs();
    PXIFakeEvent *otherEvent=PXIFakeEventFor(other,other.host,UITouchPhaseBegan);
    CHECK(PXIFakeSend(other.window,otherEvent)==nil);
    CHECK(PXIFakeDetails.count==0); CHECK(otherEvent.reads==0);
    CHECK(PXIFakeSend(wx.window,event)==nil); CHECK(PXIFakeDetails.count==2);
    CHECK([PXIFakeLastDispatch()[@"openSerial"] unsignedLongLongValue]==11);
    CHECK(PXIFakeSend(qq.window,PXIFakeEventFor(qq,qq.host,UITouchPhaseBegan))==nil);
    CHECK(PXIFakeDetails.count==4);
    CHECK([PXIFakeLastDispatch()[@"openSerial"] unsignedLongLongValue]==12);
    PXIFakeValidateLogs(); PXIFakeClearLogs();

    PXIFakeRig *qx=PXIFakeMake(@"com.crossutility.quantumult-x");
    PXIFakeWrites=0;
    PXIFakeBind(qx,13); PXIFakeBind(qx,13);
    CHECK(PXIFakeJobs.count==15); // Five per target; a same-generation rebind adds none.
    CHECK(([PXIFakeEvents isEqual:@[@"input_state"]]));
    CHECK([PXIFakeDetails.lastObject[@"currentBinding"] isEqual:@YES]);
    PXIFakeEvent *qxEvent=PXIFakeEventFor(qx,qx.host,UITouchPhaseBegan);
    PXIFakeStore.shared.snapshot=@{@"diagnostics":@NO};
    CHECK(PXIFakeSend(qx.window,qxEvent)==nil); CHECK(qxEvent.reads==0); CHECK(PXIFakeDetails.count==1);
    PXIFakeStore.shared.snapshot=@{@"diagnostics":@YES};
    CHECK(PXIFakeSend(qx.window,qxEvent)==nil);
    CHECK(([PXIFakeEvents isEqual:@[@"input_state",@"input_host_arrived",@"input_host_dispatch"]]));
    NSDictionary *note=PXIFakeLastDispatch();
    CHECK([note[@"openSerial"] isEqual:@13]); CHECK([note[@"dispatchReturned"] isEqual:@YES]);
    CHECK([note[@"phaseMask"] unsignedIntValue]==(1u<<UITouchPhaseBegan));
    CHECK([note[@"receiverMask"] unsignedIntValue]==2); CHECK([note[@"receiverAfterMask"] unsignedIntValue]==2);
    CHECK(PXIFakeWrites==0); PXIFakeValidateLogs();
}

static void PXIFakeCaseForwardExceptions(void) {
    PXIFakeRig *r=PXIFakeMake(@"com.tencent.xin"); PXIFakeBind(r,21); PXIFakeClearLogs(); PXIFakeWrites=0;
    PXIFakeEvent *event=PXIFakeEventFor(r,r.host,UITouchPhaseBegan);
    CHECK(PXIFakeSend(r.window,event)==nil);
    CHECK([PXIFakeLastDispatch()[@"dispatchReturned"] isEqual:@YES]);
    PXIFakeOriginalException=[NSException exceptionWithName:@"OriginalFailure" reason:@"identity sentinel" userInfo:nil];
    CHECK(PXIFakeSend(r.window,event)==PXIFakeOriginalException);
    CHECK([PXIFakeLastDispatch()[@"dispatchReturned"] isEqual:@NO]);
    PXIFakeValidateLogs(); PXIFakeClearLogs(); PXIFakeOriginalException=nil;
    event.throwReads=YES;
    CHECK(PXIFakeSend(r.window,event)==nil); CHECK(PXIFakeDetails.count==0);
    PXInputContext *context=objc_getAssociatedObject(r.bridge,PXInputContextKey);
    CHECK(context.exceptions==1);
    event.throwReads=NO; PXIFakeTouch *touch=event.allTouches.anyObject; touch.throwReads=YES;
    CHECK(PXIFakeSend(r.window,event)==nil); CHECK(PXIFakeDetails.count==0); CHECK(context.exceptions==2);
    touch.throwReads=NO; r.host.throwReads=YES;
    PXIFakeOriginalException=[NSException exceptionWithName:@"OriginalAndObserverFailure" reason:nil userInfo:nil];
    CHECK(PXIFakeSend(r.window,event)==PXIFakeOriginalException); CHECK(context.exceptions==3);
    r.host.throwReads=NO; PXIFakeStoreThrows=YES;
    CHECK(PXIFakeSend(r.window,event)==PXIFakeOriginalException); CHECK(PXIFakeDetails.count==0);
    PXIFakeOriginalException=nil; CHECK(PXIFakeSend(r.window,event)==nil);
    PXIFakeStoreThrows=NO; CHECK(PXIFakeWrites==0); PXIFakeValidateLogs();
}

static void PXIFakeCasePhasesPrivacy(void) {
    PXIFakeRig *r=PXIFakeMake(@"com.tencent.mqq"); PXIFakeBind(r,31); PXIFakeClearLogs(); PXIFakeWrites=0;
    CHECK(PXIFakeSend(r.window,PXIFakeEventFor(r,r.host,UITouchPhaseMoved))==nil);
    CHECK([PXIFakeLastDispatch()[@"phaseMask"] unsignedIntValue]==(1u<<UITouchPhaseMoved));
    CHECK([PXIFakeLastDispatch()[@"receiverMask"] unsignedIntValue]==2);
    CHECK(PXIFakeSend(r.window,PXIFakeEventFor(r,r.keyboard,UITouchPhaseCancelled))==nil);
    CHECK([PXIFakeLastDispatch()[@"phaseMask"] unsignedIntValue]==(1u<<UITouchPhaseCancelled));
    CHECK([PXIFakeLastDispatch()[@"receiverMask"] unsignedIntValue]==8);
    PXIFakeEvent *mixed=[PXIFakeEvent new]; mixed.type=UIEventTypeTouches;
    mixed.allTouches=[NSSet setWithArray:@[PXIFakeTouchAt(r,r.host,UITouchPhaseBegan),
        PXIFakeTouchAt(r,r.host,UITouchPhaseMoved),PXIFakeTouchAt(r,r.keyboard,UITouchPhaseCancelled),
        PXIFakeTouchAt(r,r.window,UITouchPhaseStationary)]];
    CHECK(PXIFakeSend(r.window,mixed)==nil);
    CHECK([PXIFakeLastDispatch()[@"phaseMask"] unsignedIntValue]==19);
    CHECK([PXIFakeLastDispatch()[@"receiverMask"] unsignedIntValue]==10);
    NSUInteger count=PXIFakeDetails.count;
    CHECK(PXIFakeSend(r.window,PXIFakeEventFor(r,r.host,UITouchPhaseStationary))==nil);
    PXIFakeEvent *motion=PXIFakeEventFor(r,r.host,UITouchPhaseMoved); motion.type=UIEventTypeMotion;
    CHECK(PXIFakeSend(r.window,motion)==nil); CHECK(PXIFakeDetails.count==count);
    PXIFakeRig *other=PXIFakeMake(@"other"); PXIFakeWrites=0;
    CHECK(PXIFakeSend(r.window,PXIFakeEventFor(other,other.host,UITouchPhaseBegan))==nil);
    CHECK(PXIFakeDetails.count==count);
    NSMutableSet *touches=[NSMutableSet new];
    for (unsigned i=0;i<9;i++) [touches addObject:PXIFakeTouchAt(r,r.host,UITouchPhaseMoved)];
    mixed.allTouches=touches; CHECK(PXIFakeSend(r.window,mixed)==nil);
    CHECK([PXIFakeLastDispatch()[@"touchCount"] unsignedIntValue]==8);
    CHECK([PXIFakeLastDispatch()[@"touchesTruncated"] boolValue]);
    CHECK(PXIFakeWrites==0); PXIFakeValidateLogs();
}

static void PXIFakeCaseDisabled(void) {
    PXIFakeRig *r=PXIFakeMake(@"com.tencent.xin"); PXIFakeBind(r,41); PXIFakeValidateLogs(); PXIFakeClearLogs();
    PXIFakeStore.shared.snapshot=@{@"diagnostics":@NO};
    PXIFakeEvent *event=PXIFakeEventFor(r,r.host,UITouchPhaseBegan);
    NSUInteger bridgeReads=r.bridge.reads, windowReads=r.window.reads;
    CHECK(PXIFakeSend(r.window,event)==nil);
    CHECK(event.reads==0); CHECK(r.bridge.reads==bridgeReads); CHECK(r.window.reads==windowReads);
    PXWindowInputDiagnosticsObserve(r.bridge,5);
    PXIFakeDrain([PXIFakeJobs copy]); [PXIFakeJobs removeAllObjects];
    PXWindowInputDiagnosticsClose(r.bridge);
    PXIFakeBind(r,42); PXIFakeDrain([PXIFakeJobs copy]);
    CHECK(PXIFakeSend(r.window,event)==nil); CHECK(PXIFakeDetails.count==0);
    PXIFakeStore.shared.snapshot=@{@"diagnostics":@YES};
    CHECK(PXIFakeSend(r.window,event)==nil); CHECK(PXIFakeDetails.count==2);
    CHECK([PXIFakeLastDispatch()[@"openSerial"] unsignedLongLongValue]==42);
    PXIFakeValidateLogs();
}

static void PXIFakeCaseCloseGeneration(void) {
    PXIFakeRig *r=PXIFakeMake(@"com.tencent.xin"); PXIFakeBind(r,51);
    CHECK(([PXIFakeDelays isEqual:@[@0.25,@1,@3,@8,@15]]));
    CHECK(PXIFakeOriginalCalls==0); CHECK(PXIFakeNow==100);
    PXInputContext *closed __attribute__((objc_precise_lifetime))=objc_getAssociatedObject(r.bridge,PXInputContextKey);
    NSArray *closedJobs=[PXIFakeJobs copy]; [PXIFakeJobs removeAllObjects];
    PXWindowInputDiagnosticsClose(r.bridge); CHECK(!closed.registered);
    PXIFakeValidateLogs(); PXIFakeClearLogs();
    NSUInteger oldReads=r.window.reads, bridgeReads=r.bridge.reads;
    PXIFakeDrain(closedJobs); CHECK(r.window.reads==oldReads); CHECK(r.bridge.reads==bridgeReads);
    CHECK(PXIFakeDetails.count==0);
    CHECK(PXIFakeSend(r.window,PXIFakeEventFor(r,r.host,UITouchPhaseBegan))==nil); CHECK(PXIFakeDetails.count==0);
    // Keep superseded context alive so callbacks exercise generation gates,
    // rather than passing just because their weak reference became nil.
    PXIFakeBind(r,52); PXInputContext *superseded __attribute__((objc_precise_lifetime))=objc_getAssociatedObject(r.bridge,PXInputContextKey);
    NSArray *oldJobs=[PXIFakeJobs copy]; [PXIFakeJobs removeAllObjects];
    PXIFakeRig *next=PXIFakeMake(@"com.tencent.xin");
    next.bridge=r.bridge; next.bridge.canvas=next.canvas;
    next.bridge.hostView=next.host; next.bridge.keyboardOverlay=next.keyboard;
    PXIFakeBind(next,53); CHECK(!superseded.registered); CHECK(superseded.window==r.window);
    CHECK(PXIFakeJobs.count==5); PXIFakeValidateLogs(); PXIFakeClearLogs();
    NSUInteger nextReads=next.window.reads, canvasReads=next.canvas.reads;
    bridgeReads=next.bridge.reads; oldReads=r.window.reads;
    PXIFakeDrain(oldJobs); PXIFakeDrain(closedJobs);
    CHECK(next.window.reads==nextReads); CHECK(next.canvas.reads==canvasReads);
    CHECK(next.bridge.reads==bridgeReads); CHECK(r.window.reads==oldReads); CHECK(PXIFakeDetails.count==0);
    CHECK(PXIFakeSend(r.window,PXIFakeEventFor(r,r.host,UITouchPhaseMoved))==nil); CHECK(PXIFakeDetails.count==0);
    unsigned calls=PXIFakeOriginalCalls; PXIFakeWrites=0;
    PXIFakeDrain([PXIFakeJobs copy]); CHECK(PXIFakeDetails.count==5);
    CHECK(PXIFakeOriginalCalls==calls); CHECK(PXIFakeWrites==0); CHECK(PXIFakeNow==100);
    for (NSDictionary *note in PXIFakeDetails) CHECK([note[@"openSerial"] unsignedLongLongValue]==53);
    CHECK(PXIFakeSend(next.window,PXIFakeEventFor(next,next.host,UITouchPhaseEnded))==nil);
    CHECK([PXIFakeLastDispatch()[@"phaseMask"] unsignedIntValue]==8);
    PXIFakeValidateLogs();
}

static void PXIFakeCaseRateUnknownABI(void) {
    PXIFakeRig *r=PXIFakeMake(@"com.tencent.mqq"); PXIFakeBind(r,61);
    NSDictionary *state=PXIFakeDetails.lastObject;
    for (NSString *key in @[@"appPID",@"surface",@"suppressSelection",@"sceneAllowsSelection",@"sceneForeground",@"sceneBackgrounded"])
        CHECK([state[key] integerValue]==-1);
    CHECK([state[@"hostInteractive"] integerValue]==1); CHECK([state[@"windowHidden"] integerValue]==0);
    PXIFakeValidateLogs(); PXIFakeClearLogs();
    for (unsigned i=0;i<10;i++) CHECK(PXIFakeSend(r.window,PXIFakeEventFor(r,r.host,UITouchPhaseMoved))==nil);
    CHECK(PXIFakeDetails.count==16);
    PXInputContext *context=objc_getAssociatedObject(r.bridge,PXInputContextKey);
    CHECK(context.totalEvents==10); CHECK(context->rate.suppressed==2);
    PXIFakeNow+=10;
    CHECK(PXIFakeSend(r.window,PXIFakeEventFor(r,r.keyboard,UITouchPhaseCancelled))==nil);
    NSDictionary *note=PXIFakeLastDispatch(); CHECK(PXIFakeDetails.count==18);
    CHECK([note[@"suppressed"] unsignedIntValue]==2); CHECK([note[@"eventsObserved"] unsignedIntValue]==11);
    CHECK([note[@"observationOnly"] isEqual:@YES]); CHECK([note[@"hostGateClosed"] isEqual:@NO]);
    CHECK(context->rate.suppressed==0);
    // This observed, closed host gate is not an app-thread/remote receipt proof.
    r.host.userInteractionEnabled=NO; PXIFakeWrites=0;
    CHECK(PXIFakeSend(r.window,PXIFakeEventFor(r,r.host,UITouchPhaseBegan))==nil);
    CHECK([PXIFakeLastDispatch()[@"hostGateClosed"] isEqual:@YES]); CHECK(PXIFakeWrites==0);
    PXIFakeValidateLogs(); PXIFakeClearLogs();
    PXInputOriginalSendEvent=NULL; PXInputOriginalInteraction=NULL;
    PXInputOriginalForeground=NULL; PXInputOriginalSceneUpdate=NULL;
    PXIFakeRejectABI=YES; CHECK(!PXWindowInputDiagnosticsInstall(PXIFakeBridge.class));
    CHECK(PXIFakeHookCalls==0); CHECK(PXInputOriginalSendEvent==NULL);
    CHECK(PXInputOriginalInteraction==NULL); CHECK(PXInputOriginalForeground==NULL); CHECK(PXInputOriginalSceneUpdate==NULL);
    PXIFakeValidateLogs(); PXIFakeClearLogs(); PXIFakeRejectABI=NO;
    CHECK(PXWindowInputDiagnosticsInstall(PXIFakeBridge.class)); CHECK(PXIFakeHookCalls==4);
    CHECK(PXWindowInputDiagnosticsInstall(PXIFakeBridge.class)); CHECK(PXIFakeHookCalls==4);
    PXIFakeValidateLogs();
}

int main(int argc,const char **argv) {
    @autoreleasepool {
        if (argc!=2) { fprintf(stderr,"one case required\n"); return 2; }
        PXIFakeJobs=[NSMutableArray new]; PXIFakeDelays=[NSMutableArray new];
        PXIFakeEvents=[NSMutableArray new]; PXIFakeDetails=[NSMutableArray new];
        PXIFakeStore.shared.snapshot=@{@"diagnostics":@YES};
        PXInputOriginalSendEvent=PXIFakeOriginal;
        CHECK(NSThread.isMainThread);
        if (!strcmp(argv[1],"scope")) PXIFakeCaseScope();
        else if (!strcmp(argv[1],"forward_exceptions")) { PXIFakeCaseForwardExceptions(); }
        else if (!strcmp(argv[1],"phases_privacy")) PXIFakeCasePhasesPrivacy();
        else if (!strcmp(argv[1],"disabled")) PXIFakeCaseDisabled();
        else if (!strcmp(argv[1],"close_generation")) PXIFakeCaseCloseGeneration();
        else if (!strcmp(argv[1],"rate_unknown_abi")) PXIFakeCaseRateUnknownABI();
        else { fprintf(stderr,"unknown case\n"); return 2; }
        printf("PASS %s checks=%u\n",argv[1],PXIFakeChecks); return 0;
    }
}
