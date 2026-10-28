#import "PXPRoute.h"
#import "PXPAccounts.h"
#import <QuartzCore/QuartzCore.h>

static NSMutableArray<PXPRoute *> *PXPQueue;
static PXPRoute *PXPActive;
static uint64_t PXPNextToken;
static IMP PXPRequestOriginal;
static void PXPDrain(void);
static void PXPClearRoute(PXPRoute *r) {
    PXPClearProvenance(r);
    // Break associated-object cycles only after original system processing has
    // returned. Late native callbacks then cannot complete a newer route.
    for(id obj in @[r.request ?: NSNull.null, r.transitionRequest ?: NSNull.null,
        r.transitionContext ?: NSNull.null,r.workspaceTransaction ?: NSNull.null,
        r.sceneUpdateTransaction ?: NSNull.null])
        if(obj!=NSNull.null && PXPAssociatedRoute(obj)==r) PXPAssociate(obj,nil);
    id options=PXPGet(r.request,@"options");
    if(PXPAssociatedRoute(options)==r) PXPAssociate(options,nil);
    r.nativeDelegate=nil; r.receiver=nil; r.service=nil; r.request=nil;
    r.transitionRequest=nil; r.transitionContext=nil;
    r.workspaceTransaction=nil; r.sceneUpdateTransaction=nil; r.sceneHandle=nil;
    r.completion=nil;
    [PXPQueue removeObjectIdenticalTo:r];
    if(PXPActive==r) PXPActive=nil;
    dispatch_async(dispatch_get_main_queue(),^{ PXPDrain(); });
}
static void PXPFinish(PXPRoute *r,NSError *error) {
    NSCAssert(NSThread.isMainThread,@"Payment route must be serialized on main");
    if(!PXPClaimResult(&r->state)) return;
    PXPSystemCompletion callback=[r.completion copy]; r.completion=nil;
    if(callback && !r.systemCompletionDelivered) {
        r.systemCompletionDelivered=YES;
        @try { callback(error); }
        @catch (__unused NSException *exception) { /* Still tear down native ownership. */ }
    }
    // Never release a borrowed stack block, request or receiver under an active IMP.
    dispatch_async(dispatch_get_main_queue(),^{
        if(error) PXPTeardownNative(r,^(BOOL quiescent){
            if(quiescent) PXPClearRoute(r);
            // Otherwise retain ownership and block the queue; do not invent exit.
        });
        else {
            PXPSetObject(r.sceneUpdateTransaction,@"setSynchronizationDelegate:",nil);
            PXPClearRoute(r);
        }
    });
}
@implementation PXPRoute
- (BOOL)isCurrent {
    return NSThread.isMainThread && PXPActive==self && !PXPTerminal(&state) &&
        CACurrentMediaTime()<self.deadline;
}
- (void)fail:(NSError *)error {
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(),^{ [self fail:error]; }); return;
    }
    if(PXPTerminal(&state)) return;
    BOOL ownsPicker=(PXPActive==self && state.phase==PXPChoosing);
    PXPTransition(&state,error.code==NSUserCancelledError ? PXPCancelled : PXPFailed);
    if(ownsPicker) PXPCancelAccountSelection();
    PXPCancelPaymentHost(self);
    PXPFinish(self,error ?: PXPError(1,@"Payment routing stopped"));
}
- (void)advance {
    if(![self isCurrent]) return;
    if(self.systemError) { [self fail:self.systemError]; return; }
    // Host attachment and the system result are independent obligations. Do not
    // wait for the result before attaching: some system paths complete only
    // after their scene has become hosted. Keep the route until BOTH finish.
    if(state.hostReady) {
        if(self.systemResultReceived && PXPTransition(&state,PXPDone)) PXPFinish(self,nil);
        return;
    }
    if(!PXPCanHost(&state)) return;
    if(!PXPAccountStillMatches(self.bundle,self.container)) {
        [self fail:PXPError(2,@"Selected payment account changed")]; return;
    }
    if(!PXPClaimHost(&state)) return;
    PXPHostScene(self,^(BOOL ready,NSError *error){
        if(![self isCurrent]) return;
        if(!ready) { [self fail:error ?: PXPError(3,@"Payment host not ready")]; return; }
        self->state.hostReady=true;
        [self advance];
    });
}
@end
static id PXPValue(id o,NSString *key) {
    if([o isKindOfClass:NSDictionary.class]) return o[key];
    return PXPGet(o,key);
}
static NSString *PXPTarget(id o,NSUInteger depth) {
    if(!o || depth>4) return nil;
    for(NSString *key in @[@"bundleIdentifier",@"applicationBundleIdentifier",@"targetBundleIdentifier"]){
        NSString *s=PXPString(PXPValue(o,key)); if(s) return s;
    }
    for(NSString *key in @[@"targetApplication",@"target",@"application",@"options",@"dictionary"]){
        id v=PXPValue(o,key); if(v==o) continue;
        NSString *s=PXPString(v);
        if(!s) s=PXPTarget(v,depth+1);
        if(s) return s;
    }
    return nil;
}
static BOOL PXPPayload(id o,NSUInteger depth) {
    if(!o || depth>5) return NO;
    if([o isKindOfClass:NSURL.class]) return YES;
    if([o isKindOfClass:NSDictionary.class]) {
        for(id key in o) {
            if(![key isKindOfClass:NSString.class]) continue;
            NSString *k=[key lowercaseString];
            if([k containsString:@"url"] || [k containsString:@"payload"] ||
               [k containsString:@"options"] || [k containsString:@"link"])
                if(PXPPayload(o[key],depth+1)) return YES;
        }
    } else if([o isKindOfClass:NSArray.class]) {
        for(id v in o) if(PXPPayload(v,depth+1)) return YES;
    } else {
        // Only object getters with checked signatures, never KVC/ivar speculation.
        for(NSString *key in @[@"dictionary",@"options",@"payload",@"URL",@"url"]){
            id v=PXPGet(o,key); if(v!=o && PXPPayload(v,depth+1)) return YES;
        }
    }
    return NO;
}
static void PXPForward(PXPRoute *r) {
    if(![r isCurrent] || !PXPTransition(&r->state,PXPForwarding) || !PXPClaimForward(&r->state)) return;
    PXPTransition(&r->state,PXPActivating);
    PXPAssociate(r.request,r); PXPAssociate(PXPGet(r.request,@"options"),r);
    PXPSystemCompletion result=[^(NSError *error){
        dispatch_async(dispatch_get_main_queue(),^{
            if(![r isCurrent] || r.systemResultReceived) return;
            r.systemResultReceived=YES; r.systemError=error;
            // This callback reports delivery of the original open request, not
            // host visibility or payment success. Preserve its timing/semantics.
            if(!r.systemCompletionDelivered) {
                r.systemCompletionDelivered=YES;
                PXPSystemCompletion original=[r.completion copy]; r.completion=nil;
                @try { if(original) original(error); }
                @catch (__unused NSException *exception) {
                    [r fail:PXPError(11,@"Original result handler raised an exception")]; return;
                }
            }
            if(error) [r fail:error]; else [r advance];
        });
    } copy];
    @try {
        ((void(*)(id,SEL,id,id,PXPSystemCompletion))PXPRequestOriginal)(
            r.receiver,r.selector,r.service,r.request,result);
    } @catch(NSException *e) {
        (void)e; [r fail:PXPError(4,@"Application-open request raised an exception")];
    }
}
static void PXPDrain(void) {
    if(PXPActive || !PXPQueue.count) return;
    PXPRoute *r=PXPQueue.firstObject; PXPActive=r;
    if(CACurrentMediaTime()>=r.deadline) { [r fail:PXPError(5,@"Queued payment request expired")]; return; }
    if(!PXPAccountsAvailable()) { [r fail:PXPError(10,@"Crane account service unavailable")]; return; }
    PXPTransition(&r->state,PXPChoosing);
    PXPChooseAccount(r.bundle,^(NSString *container,NSError *error){
        if(![r isCurrent]) return;
        if(error || !container.length) { [r fail:error ?: PXPError(6,@"No account selected")]; return; }
        r.container=container;
        PXPTransition(&r->state,PXPSwitching);
        PXPClosePaymentHost(r.bundle);
        PXPPrepareAccount(r.bundle,r.container,^BOOL{ return [r isCurrent]; },^(BOOL ready,NSError *failure){
            if(![r isCurrent]) return;
            if(!ready) [r fail:failure ?: PXPError(7,@"Account switch failed")];
            else PXPForward(r);
        });
    });
}
static void PXPRequest(id self,SEL cmd,id service,id request,PXPSystemCompletion completion) {
    NSString *bundle=PXPTarget(request,0);
    // First candidate is deliberately limited to the user's WeChat payment route.
    // No ordinary menu/open request, other app, or background open is intercepted.
    BOOL owns=[bundle isEqual:@"com.tencent.xin"] && PXPPayload(PXPGet(request,@"options"),0);
    if(!owns || !PXPRoutingAvailable()) {
        ((void(*)(id,SEL,id,id,PXPSystemCompletion))PXPRequestOriginal)(self,cmd,service,request,completion);
        return;
    }
    PXPRoute *r=[PXPRoute new];
    r.bundle=bundle; r.receiver=self; r.selector=cmd; r.service=service; r.request=request;
    r.completion=[completion copy]; r.deadline=CACurrentMediaTime()+45;
    dispatch_async(dispatch_get_main_queue(),^{
        if(!PXPQueue) PXPQueue=[NSMutableArray array];
        r->state=(PXPState){.token=++PXPNextToken,.phase=PXPQueued};
        if(PXPQueue.count>=8) { [r fail:PXPError(8,@"Too many pending payment requests")]; return; }
        [PXPQueue addObject:r]; PXPDrain();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,45*NSEC_PER_SEC),dispatch_get_main_queue(),^{
            if(!PXPTerminal(&r->state)) [r fail:PXPError(9,@"Payment routing timed out")];
        });
    });
}
void PXPInstallRequestIntake(void) {
    PXPHook(NSClassFromString(@"SBMainWorkspace"),
        @"systemService:handleOpenApplicationRequest:withCompletion:",(IMP)PXPRequest,
        &PXPRequestOriginal,"v",@[@"@",@"@",@"@?"]);
}
