#import "PXPRoute.h"
#import "PXPAccounts.h"
#import <QuartzCore/QuartzCore.h>
#import "PXPHostState.h"

static IMP PXPOpenOriginal,PXPLookupOriginal,PXPCloseOriginal;
static const char PXPHostKey;
static BOOL PXPHostReady;
@interface PXPHostLease : NSObject {
@public PXPHostState lifecycle;
}
@property(nonatomic,weak) PXPRoute *route;
@property(nonatomic,weak) id bridge;
@property(nonatomic,strong) id scene;
@property(nonatomic,strong) id handle;
@property(nonatomic,copy) NSString *bundle;
@property(nonatomic,copy) NSString *identifier;
@property(nonatomic) uint64_t generation;
@property(nonatomic) BOOL initializing;
@property(nonatomic) BOOL opened;
@property(nonatomic) BOOL completed;
@property(nonatomic,copy) void (^completion)(BOOL,NSError *);
@end
@implementation PXPHostLease
@end
static PXPHostLease *PXPStartingLease;
static NSHashTable *PXPBridges;
static NSMapTable<PXPRoute *,PXPHostLease *> *PXPPendingHosts;
static uint64_t PXPGeneration(id bridge,BOOL *valid) {
    SEL sel=NSSelectorFromString(@"generation");
    *valid=PXPSignature(bridge,sel,"Q",@[]);
    return *valid ? ((uint64_t(*)(id,SEL))objc_msgSend)(bridge,sel) : 0;
}
static id PXPExactScene(PXPHostLease *lease) {
    id scene=PXPGet(lease.handle,@"sceneIfExists");
    Class fb=NSClassFromString(@"FBScene");
    NSString *sid=PXPString(PXPGet(scene,@"identifier"));
    NSString *handleID=PXPString(PXPGet(lease.handle,@"sceneIdentifier"));
    NSString *bundle=PXPString(PXPGet(PXPGet(lease.handle,@"application"),@"bundleIdentifier"));
    if(!fb || ![scene isKindOfClass:fb] || ![sid isEqual:lease.identifier] ||
       ![handleID isEqual:lease.identifier] || ![bundle isEqual:lease.bundle]) return nil;
    return scene;
}
static BOOL PXPLeaseGeneration(PXPHostLease *lease,id bridge) {
    BOOL known=NO; uint64_t gen=PXPGeneration(bridge,&known);
    return known && lease.bridge==bridge && gen==lease.generation && PXPHostLive(&lease->lifecycle,gen);
}
static void PXPHostFinish(PXPHostLease *lease,BOOL ready,NSError *error) {
    if(lease.completed) return;
    lease.completed=YES;
    void (^callback)(BOOL,NSError *)=[lease.completion copy]; lease.completion=nil;
    if(!ready && lease.bridge) {
        id bridge=lease.bridge;
        if(objc_getAssociatedObject(bridge,&PXPHostKey)==lease) {
            objc_setAssociatedObject(bridge,&PXPHostKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            // Only close the bridge initialized for this request; never arbitrary PX hosts.
            if(PXPLeaseGeneration(lease,bridge))
                ((void(*)(id,SEL))PXPCloseOriginal)(bridge,NSSelectorFromString(@"close"));
        }
    }
    if(!ready) PXPHostStop(&lease->lifecycle);
    else lease->lifecycle.visible=true;
    // Retain the route identity on a successful lease until this route finishes;
    // a later system error must still be able to close the exact visible host.
    if(!ready) {
        [PXPPendingHosts removeObjectForKey:lease.route];
        lease.route=nil;
    }
    if(callback) callback(ready,error);
}
static BOOL PXPViewUsable(id value) {
    if(![value isKindOfClass:UIView.class]) return NO;
    UIView *v=value;
    return v.window && !v.hidden && v.alpha>0 && !CGRectIsEmpty(v.bounds);
}
static id PXPLookup(id self,SEL cmd,NSString *bundle) {
    PXPHostLease *lease=objc_getAssociatedObject(self,&PXPHostKey);
    if(lease && [bundle isEqual:lease.bundle]) {
        if(!PXPLeaseGeneration(lease,self)) return nil;
        // Exact lease survives successful route cleanup until this bridge closes.
        // Missing exact scene NEVER permits a same-bundle fallback or new launch.
        id scene=PXPExactScene(lease);
        return scene==lease.scene ? scene : nil;
    }
    return ((id(*)(id,SEL,id))PXPLookupOriginal)(self,cmd,bundle);
}
static void PXPClose(id self,SEL cmd) {
    PXPHostLease *lease=objc_getAssociatedObject(self,&PXPHostKey);
    if(lease && !lease.initializing) {
        objc_setAssociatedObject(self,&PXPHostKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        PXPHostStop(&lease->lifecycle);
        if(!lease.completed) PXPHostFinish(lease,NO,PXPError(61,@"Payment host closed before ready"));
        else if([lease.route isCurrent]) [lease.route fail:PXPError(61,@"Payment host closed before system request completed")];
    }
    ((void(*)(id,SEL))PXPCloseOriginal)(self,cmd);
}
static void PXPOpen(id self,SEL cmd,NSString *bundle,UIView *canvas,UIView *keyboard,void (^completion)(BOOL)) {
    PXPHostLease *lease=PXPStartingLease;
    if(!lease || ![bundle isEqual:lease.bundle]) {
        PXPHostLease *old=objc_getAssociatedObject(self,&PXPHostKey);
        if(old && !old.completed) PXPHostFinish(old,NO,PXPError(72,@"Payment host replaced by another open"));
        ((void(*)(id,SEL,id,id,id,void(^)(BOOL)))PXPOpenOriginal)(self,cmd,bundle,canvas,keyboard,completion);
        return;
    }
    BOOL known=NO; uint64_t before=PXPGeneration(self,&known);
    if(lease.opened || ![lease.route isCurrent] || !known || before==UINT64_MAX ||
       !PXPViewUsable(canvas) || PXPExactScene(lease)!=lease.scene) {
        if(completion) completion(NO);
        PXPHostFinish(lease,NO,PXPError(62,@"Exact payment host preflight failed")); return;
    }
    if(!PXPHostStart(&lease->lifecycle,before)) {
        if(completion) completion(NO);
        PXPHostFinish(lease,NO,PXPError(73,@"Payment host lifecycle rejected initialization")); return;
    }
    lease.opened=YES; lease.bridge=self; lease.generation=before+1;
    lease.initializing=YES;
    objc_setAssociatedObject(self,&PXPHostKey,lease,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [PXPBridges addObject:self];
    void (^wrapped)(BOOL)=[^(BOOL ok){
        // Serialize BEFORE touching UIKit, lease state or external callbacks.
        dispatch_async(dispatch_get_main_queue(),^{
            if(!PXPHostClaimCallback(&lease->lifecycle)) return;
            BOOL valid=ok && !lease.completed && [lease.route isCurrent] &&
                PXPLeaseGeneration(lease,self) && PXPExactScene(lease)==lease.scene &&
                PXPGet(self,@"scene")==lease.scene && PXPViewUsable(PXPGet(self,@"hostView")) &&
                [PXPString(PXPGet(self,@"bundleID")) isEqual:bundle] &&
                PXPAccountStillMatches(bundle,lease.route.container);
            @try { if(completion) completion(valid); }
            @catch (__unused NSException *exception) { valid=NO; }
            // The original callback may synchronously close/replace the host.
            valid=valid && !lease.completed && [lease.route isCurrent] &&
                PXPLeaseGeneration(lease,self) && PXPGet(self,@"scene")==lease.scene &&
                PXPViewUsable(PXPGet(self,@"hostView"));
            PXPHostFinish(lease,valid,valid ? nil : PXPError(63,@"Payment host did not become visible"));
        });
    } copy];
    @try {
        ((void(*)(id,SEL,id,id,id,void(^)(BOOL)))PXPOpenOriginal)(self,cmd,bundle,canvas,keyboard,wrapped);
    } @finally { lease.initializing=NO; }
    BOOL afterKnown=NO; uint64_t after=PXPGeneration(self,&afterKnown);
    if(!afterKnown || !PXPHostInitialized(&lease->lifecycle,after))
        PXPHostFinish(lease,NO,PXPError(64,@"Payment host generation changed"));
}
static void PXPAttemptHost(PXPHostLease *lease,NSTimeInterval end) {
    if(lease.completed || lease->lifecycle.stopped) return;
    PXPRoute *r=lease.route;
    if(![r isCurrent]) { PXPHostFinish(lease,NO,PXPError(65,@"Payment host request expired")); return; }
    id scene=PXPExactScene(lease);
    if(!scene) {
        if(CACurrentMediaTime()>=end) { PXPHostFinish(lease,NO,PXPError(66,@"Exact payment scene unavailable")); return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/20),dispatch_get_main_queue(),^{ PXPAttemptHost(lease,end); }); return;
    }
    lease.scene=scene;
    Class entry=NSClassFromString(@"PXPanelEntry"); SEL open=NSSelectorFromString(@"externalOpenApplication:");
    if(!PXPSignature(entry,open,"v",@[@"@"])) { PXPHostFinish(lease,NO,PXPError(67,@"PX entry unavailable")); return; }
    PXPHostLease *previous=PXPStartingLease; PXPStartingLease=lease;
    @try { ((void(*)(id,SEL,id))objc_msgSend)(entry,open,lease.bundle); }
    @catch(__unused NSException *e) { PXPHostFinish(lease,NO,PXPError(68,@"PX host creation raised an exception")); }
    @finally { PXPStartingLease=previous; }
    if(!lease.opened) PXPHostFinish(lease,NO,PXPError(69,@"Existing or docked PX host reuse is not supported in this candidate"));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        PXPHostFinish(lease,NO,PXPError(70,@"PX host readiness timed out"));
    });
}
void PXPHostScene(PXPRoute *route,void (^completion)(BOOL,NSError *)) {
    NSCAssert(NSThread.isMainThread,@"Payment host must run on main");
    if(!PXPHostReady || ![route isCurrent] || !route.sceneIdentifier.length) {
        completion(NO,PXPError(71,@"Payment host adapter unavailable")); return;
    }
    PXPHostLease *lease=[PXPHostLease new]; lease.route=route; lease.bundle=route.bundle;
    lease.handle=route.sceneHandle; lease.identifier=route.sceneIdentifier; lease.completion=completion;
    [PXPPendingHosts setObject:lease forKey:route];
    PXPAttemptHost(lease,MIN(route.deadline,CACurrentMediaTime()+2));
}
void PXPClosePaymentHost(NSString *bundle) {
    NSCAssert(NSThread.isMainThread,@"Payment host close must run on main");
    for(id bridge in PXPBridges.allObjects) {
        PXPHostLease *lease=objc_getAssociatedObject(bridge,&PXPHostKey);
        if(lease && [lease.bundle isEqual:bundle] && PXPLeaseGeneration(lease,bridge)) PXPCall(bridge,@"close");
    }
}
void PXPCancelPaymentHost(PXPRoute *route) {
    NSCAssert(NSThread.isMainThread,@"Payment host cancellation must run on main");
    PXPHostLease *pending=[PXPPendingHosts objectForKey:route];
    [PXPPendingHosts removeObjectForKey:route];
    if(pending && !pending.completed) PXPHostFinish(pending,NO,PXPError(74,@"Payment route cancelled while waiting for scene"));
    for(id bridge in PXPBridges.allObjects) {
        PXPHostLease *lease=objc_getAssociatedObject(bridge,&PXPHostKey);
        if(lease.route!=route) continue;
        if(!lease.completed) PXPHostFinish(lease,NO,PXPError(74,@"Payment route cancelled while hosting"));
        else if(PXPLeaseGeneration(lease,bridge)) PXPCall(bridge,@"close");
    }
}
BOOL PXPInstallHostAdapter(void) {
    if(PXPHostReady) return YES;
    PXPBridges=[NSHashTable weakObjectsHashTable];
    PXPPendingHosts=[NSMapTable weakToStrongObjectsMapTable];
    Class cls=NSClassFromString(@"PXSceneBridge");
    BOOL a=PXPHook(cls,@"sceneForBundleID:",(IMP)PXPLookup,&PXPLookupOriginal,"@",@[@"@"]);
    BOOL b=PXPHook(cls,@"close",(IMP)PXPClose,&PXPCloseOriginal,"v",@[]);
    BOOL c=PXPHook(cls,@"openApplication:inView:keyboardOverlay:completion:",(IMP)PXPOpen,&PXPOpenOriginal,"v",@[@"@",@"@",@"@",@"@?"]);
    PXPHostReady=a&&b&&c; return PXPHostReady;
}
