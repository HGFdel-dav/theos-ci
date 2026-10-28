#import "PXPRoute.h"
#import "PXPAccounts.h"
#include <string.h>

// Runtime declarations only. No SDK/private implementation is copied or patched.
@interface NSObject (PXPPrivateTransactionInit)
- (instancetype)initWithTransitionRequest:(id)request;
- (instancetype)initWithApplicationSceneEntity:(id)entity transitionRequest:(id)request;
@end
static Class PXPWorkspaceClass;
static IMP PXPExecuteOriginal, PXPSelectOriginal, PXPActivationOriginal, PXPCompletedOriginal;
static BOOL PXPReady;
static const char PXPAssociationKey;

PXPRoute *PXPAssociatedRoute(id o) {
    id r=o ? objc_getAssociatedObject(o,&PXPAssociationKey) : nil;
    return [r isKindOfClass:PXPRoute.class] ? r : nil;
}
void PXPAssociate(id o, PXPRoute *r) {
    if(o) objc_setAssociatedObject(o,&PXPAssociationKey,r,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static id PXPEntity(id context) {
    return PXPGet(context,@"resolvedActivatingWorkspaceEntity") ?: PXPGet(context,@"activatingEntity") ?:
        PXPGet(context,@"requestedActivatingWorkspaceEntity");
}
static NSString *PXPBundleOfHandle(id h) {
    id app=PXPGet(h,@"application");
    return PXPString(PXPGet(app,@"bundleIdentifier"));
}
BOOL PXPBindTransition(PXPRoute *r,id request) {
    if(!r || ![r isCurrent] || !r->state.forwarded || !request ||
       !PXPHasExactProvenance(r,request)) return NO;
    if(r.transitionRequest) return r.transitionRequest==request;
    id ctx=PXPGet(request,@"applicationContext");
    id handle=PXPGet(PXPEntity(ctx),@"sceneHandle");
    NSString *sid=PXPString(PXPGet(handle,@"sceneIdentifier"));
    if(!ctx || !sid || ![PXPBundleOfHandle(handle) isEqual:r.bundle] ||
       !PXPSignature(handle,NSSelectorFromString(@"sceneIfExists"),"@",@[])) return NO;
    // A bundle match only validates a request already owned by this route. It never
    // discovers an unrelated pending route by bundle or recent-URL heuristics.
    r.transitionRequest=request; r.transitionContext=ctx;
    r.sceneHandle=handle; r.sceneIdentifier=sid; r->state.bound=true;
    PXPAssociate(request,r); PXPAssociate(ctx,r);
    return YES;
}

@interface PXPSynchronizationDelegate : NSObject
@property(nonatomic,weak) PXPRoute *route;
@property(nonatomic) BOOL committed;
@end
@implementation PXPSynchronizationDelegate
- (void)synchronizedTransactionReadyToCommit:(id)transaction {
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(),^{ [self synchronizedTransactionReadyToCommit:transaction]; }); return;
    }
    PXPRoute *r=self.route;
    if(![r isCurrent] || transaction!=r.sceneUpdateTransaction || self.committed) return;
    BOOL known=NO;
    BOOL complete=PXPBool(transaction,@"isComplete",&known);
    if(!known || complete || PXPBool(transaction,@"isFailed",NULL) ||
        PXPBool(transaction,@"isInterrupted",NULL)) return;
    self.committed=YES;
    if(!PXPCall(transaction,@"performSynchronizedCommit"))
        [r fail:PXPError(31,@"Synchronized scene commit unavailable")];
}
- (void)synchronizedTransaction:(id)t willCommitSynchronizedTransactions:(id)transactions { (void)t; (void)transactions; }
- (void)synchronizedTransaction:(id)t didCommitSynchronizedTransactions:(id)transactions { (void)t; (void)transactions; }
@end
static void PXPSuperVoid(id obj,SEL sel) {
    struct objc_super sup={obj,class_getSuperclass(PXPWorkspaceClass)};
    ((void(*)(struct objc_super*,SEL))objc_msgSendSuper)(&sup,sel);
}
static void PXPWorkspaceBegin(id self,SEL cmd) {
    PXPRoute *r=PXPAssociatedRoute(self);
    SEL add=NSSelectorFromString(@"addMilestone:");
    SEL satisfy=NSSelectorFromString(@"satisfyMilestone:");
    NSString *milestone=@"PXP.Payment.SceneUpdate";
    ((void(*)(id,SEL,id))objc_msgSend)(self,add,milestone);
    PXPSuperVoid(self,cmd);
    if(![r isCurrent] || !r.sceneUpdateTransaction) {
        PXPSetObject(self,@"failWithReason:",@"Payment request expired before scene activation");
    } else if(!PXPSetObject(self,@"addChildTransaction:",r.sceneUpdateTransaction)) {
        PXPSetObject(self,@"failWithReason:",@"Unable to attach payment scene update");
        [r fail:PXPError(41,@"Unable to attach payment scene update")];
    } else {
        // ScreenCore 2.0.5 0x53450..0x53464: addChildTransaction alone
        // is not treated as proof of start. Check hasStarted; begin exactly once.
        BOOL known=NO;
        BOOL started=PXPBool(r.sceneUpdateTransaction,@"hasStarted",&known);
        if(!known || (!started && !PXPCall(r.sceneUpdateTransaction,@"begin"))) {
            PXPSetObject(self,@"failWithReason:",@"Cannot start payment scene update");
            [r fail:PXPError(42,@"Cannot start payment scene update")];
        }
    }
    if(!PXPBool(self,@"isComplete",NULL))
        ((void(*)(id,SEL,id))objc_msgSend)(self,satisfy,milestone);
}
static BOOL PXPWorkspaceShouldFail(id self,SEL cmd,id child) {
    PXPRoute *r=PXPAssociatedRoute(self);
    if(child==r.sceneUpdateTransaction) return YES;
    struct objc_super sup={self,class_getSuperclass(PXPWorkspaceClass)};
    return ((BOOL(*)(struct objc_super*,SEL,id))objc_msgSendSuper)(&sup,cmd,child);
}
static void PXPWorkspaceDidComplete(id self,SEL cmd) {
    PXPRoute *r=PXPAssociatedRoute(self);
    if([r isCurrent] && (PXPBool(self,@"isFailed",NULL) || PXPBool(self,@"isInterrupted",NULL))) {
        NSError *error=PXPGet(self,@"error") ?: PXPError(32,@"Payment scene transaction failed");
        if(PXPBool(r.transitionContext,@"needsToSendActivationResult",NULL))
            PXPSetObject(r.transitionContext,@"sendActivationResultError:",error);
        [r fail:error];
    }
    PXPSuperVoid(self,cmd);
}
static BOOL PXPCheckInstance(Class cls,NSString *name,const char *ret,NSArray *args) {
    return PXPInstanceSignature(cls,name,ret,args);
}
static id PXPSelectTransaction(id self,SEL cmd,id request) {
    id context=PXPGet(request,@"applicationContext");
    PXPRoute *r=PXPAssociatedRoute(request) ?: PXPAssociatedRoute(context);
    if(!r) return ((id(*)(id,SEL,id))PXPSelectOriginal)(self,cmd,request);
    if(!PXPBindTransition(r,request)) {
        [r fail:PXPError(37,@"Payment transition lacks exact source identity")]; return nil;
    }
    if(![r isCurrent] || r.transitionRequest!=request) return nil;
    if(r.workspaceTransaction) return r.workspaceTransaction;
    BOOL finalizedKnown=NO,backgroundKnown=NO;
    PXPBool(request,@"isFinalized",&finalizedKnown);
    BOOL background=PXPBool(context,@"isBackground",&backgroundKnown);
    BOOL configuratorKnown=NO,providerKnown=NO;
    BOOL configurator=PXPObjectGetterHasValue(request,@"transactionConfigurator",&configuratorKnown);
    BOOL provider=PXPObjectGetterHasValue(request,@"transactionProvider",&providerKnown);
    if(!finalizedKnown || !backgroundKnown || !configuratorKnown || !providerKnown || background ||
        configurator || provider ||
        PXPGet(PXPGet(request,@"transientOverlayContext"),@"transientOverlay") ||
        !PXPAccountStillMatches(r.bundle,r.container)) {
        [r fail:PXPError(33,@"Payment transition not ready")]; return nil;
    }
    id entity=PXPEntity(context);
    id handle=PXPGet(entity,@"sceneHandle");
    if(handle!=r.sceneHandle || ![PXPString(PXPGet(handle,@"sceneIdentifier")) isEqual:r.sceneIdentifier]) {
        [r fail:PXPError(34,@"Payment scene changed during activation")]; return nil;
    }
    id parent=[[PXPWorkspaceClass alloc] initWithTransitionRequest:request];
    // SBWorkspaceTransaction's initializer finalizes the transition request;
    // requiring finalization before this call would reject normal requests.
    if(!parent || !PXPBool(request,@"isFinalized",NULL) ||
        PXPGet(request,@"applicationContext")!=context) {
        [r fail:PXPError(35,@"Payment transition finalization failed")]; return nil;
    }
    Class sceneClass=NSClassFromString(@"SBApplicationSceneUpdateTransaction");
    id child=[[sceneClass alloc] initWithApplicationSceneEntity:entity transitionRequest:request];
    if(!parent || !child || ![PXPString(PXPGet(child,@"sceneIdentifier")) isEqual:r.sceneIdentifier]) {
        [r fail:PXPError(35,@"Cannot create exact payment scene transaction")]; return nil;
    }
    PXPSynchronizationDelegate *delegate=[PXPSynchronizationDelegate new]; delegate.route=r;
    r.nativeDelegate=delegate; r.workspaceTransaction=parent; r.sceneUpdateTransaction=child;
    PXPAssociate(parent,r); PXPAssociate(child,r);
    if(!PXPSetBool(child,@"setShouldSendActivationResult:",YES) ||
       !PXPSetObject(child,@"setSynchronizationDelegate:",delegate)) {
        [r fail:PXPError(36,@"Payment scene synchronization unsupported")]; return nil;
    }
    return parent;
}
static BOOL PXPExecute(id self,SEL cmd,id request,NSUInteger options,id validator) {
    // The evidenced options encoding is Q (scalar flags), NEVER an object.
    PXPRoute *r=PXPAssociatedRoute(request);
    // Source identity exists before scene resolution. The original executor is
    // allowed to populate/finalize the context; the selection hook below must
    // bind the exact scene before it can choose our custom transaction.
    if(r && (![r isCurrent] || !PXPHasExactProvenance(r,request))) {
        [r fail:PXPError(37,@"Cannot authenticate payment transition source")]; return NO;
    }
    BOOL accepted=((BOOL(*)(id,SEL,id,NSUInteger,id))PXPExecuteOriginal)(self,cmd,request,options,validator);
    if(!r) r=PXPAssociatedRoute(request);
    if(r && [r isCurrent]) {
        r->state.executed=true; r->state.accepted=accepted;
        if(!accepted) [r fail:PXPError(38,@"Payment activation rejected")];
        else [r advance];
    }
    return accepted;
}
static void PXPActivation(id self,SEL cmd,NSError *error) {
    PXPRoute *r=PXPAssociatedRoute(self);
    BOOL expected=PXPBool(self,@"needsToSendActivationResult",NULL);
    ((void(*)(id,SEL,id))PXPActivationOriginal)(self,cmd,error);
    if(!r || !expected) return;
    dispatch_async(dispatch_get_main_queue(),^{
        if(![r isCurrent]) return;
        if(error) [r fail:error]; else { r->state.activated=true; [r advance]; }
    });
}
static void PXPCompleted(id self,SEL cmd,id transaction) {
    PXPRoute *r=PXPAssociatedRoute(transaction);
    ((void(*)(id,SEL,id))PXPCompletedOriginal)(self,cmd,transaction);
    if(!r) return;
    dispatch_async(dispatch_get_main_queue(),^{
        if(![r isCurrent] || transaction!=r.workspaceTransaction) return;
        BOOL completeKnown=NO,failedKnown=NO,interruptedKnown=NO;
        BOOL complete=PXPBool(transaction,@"isComplete",&completeKnown);
        BOOL failed=PXPBool(transaction,@"isFailed",&failedKnown);
        BOOL interrupted=PXPBool(transaction,@"isInterrupted",&interruptedKnown);
        if(!completeKnown||!failedKnown||!interruptedKnown||!complete||failed||interrupted)
            [r fail:PXPGet(transaction,@"error") ?: PXPError(39,@"Scene transaction not completed successfully")];
        else { r->state.completed=true; [r advance]; }
    });
}

BOOL PXPRoutingAvailable(void) { return PXPReady; }
BOOL PXPInstallNativeRouting(void) {
    if(PXPReady) return YES;
    NSOperatingSystemVersion os=NSProcessInfo.processInfo.operatingSystemVersion;
    if(os.majorVersion!=15 || os.minorVersion!=5) return NO;
    Class base=NSClassFromString(@"SBMainWorkspaceTransaction");
    Class scene=NSClassFromString(@"SBApplicationSceneUpdateTransaction");
    Class context=NSClassFromString(@"SBWorkspaceApplicationSceneTransitionContext");
    if(!PXPCheckInstance(base,@"initWithTransitionRequest:","@",@[@"@"]) ||
       !PXPCheckInstance(base,@"_begin","v",@[]) ||
       !PXPCheckInstance(base,@"_didComplete","v",@[]) ||
       !PXPCheckInstance(base,@"_shouldFailForChildTransaction:","B",@[@"@"]) ||
       !PXPCheckInstance(base,@"addChildTransaction:","v",@[@"@"]) ||
       !PXPCheckInstance(base,@"addMilestone:","v",@[@"@"]) ||
       !PXPCheckInstance(base,@"satisfyMilestone:","v",@[@"@"]) ||
       !PXPCheckInstance(base,@"failWithReason:","v",@[@"@"]) ||
       !PXPCheckInstance(base,@"isFailed","B",@[]) ||
       !PXPCheckInstance(base,@"isInterrupted","B",@[]) ||
       !PXPCheckInstance(scene,@"initWithApplicationSceneEntity:transitionRequest:","@",@[@"@",@"@"]) ||
       !PXPCheckInstance(scene,@"sceneIdentifier","@",@[]) ||
       !PXPCheckInstance(scene,@"hasStarted","B",@[]) ||
       !PXPCheckInstance(scene,@"begin","v",@[]) ||
       !PXPCheckInstance(scene,@"setShouldSendActivationResult:","v",@[@"B"]) ||
       !PXPCheckInstance(scene,@"setSynchronizationDelegate:","v",@[@"@"]) ||
       !PXPCheckInstance(scene,@"performSynchronizedCommit","v",@[]) ||
       !PXPCheckInstance(context,@"needsToSendActivationResult","B",@[])) return NO;
    PXPWorkspaceClass=objc_allocateClassPair(base,"PXPWorkspaceTransaction",0);
    if(!PXPWorkspaceClass) return NO;
    NSArray *names=@[@"_begin",@"_shouldFailForChildTransaction:",@"_didComplete"];
    IMP impls[]={(IMP)PXPWorkspaceBegin,(IMP)PXPWorkspaceShouldFail,(IMP)PXPWorkspaceDidComplete};
    for(NSUInteger i=0;i<names.count;++i) {
        SEL sel=NSSelectorFromString(names[i]);
        Method m=class_getInstanceMethod(base,sel);
        if(!class_addMethod(PXPWorkspaceClass,sel,impls[i],method_getTypeEncoding(m))) {
            objc_disposeClassPair(PXPWorkspaceClass); PXPWorkspaceClass=Nil; return NO;
        }
    }
    objc_registerClassPair(PXPWorkspaceClass);
    Class workspace=NSClassFromString(@"SBMainWorkspace");
    // Validator is retained opaquely; permit its actual object or block encoding,
    // while the flags argument must remain the evidenced unsigned 64-bit scalar.
    Method executeMethod=class_getInstanceMethod(workspace,NSSelectorFromString(@"_executeTransitionRequest:options:validator:"));
    NSMethodSignature *executeSig=executeMethod ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(executeMethod)] : nil;
    NSString *validatorType=nil;
    if(executeSig.numberOfArguments==5) {
        const char *t=[executeSig getArgumentTypeAtIndex:4];
        if(!strcmp(t,"@")) validatorType=@"@";
        else if(!strcmp(t,"@?")) validatorType=@"@?";
    }
    BOOL a=validatorType && PXPHook(workspace,@"_executeTransitionRequest:options:validator:",(IMP)PXPExecute,
        &PXPExecuteOriginal,"B",@[@"@",@"Q",validatorType]);
    BOOL b=PXPHook(workspace,@"_selectTransactionForAppActivationRequest:",(IMP)PXPSelectTransaction,
        &PXPSelectOriginal,"@",@[@"@"]);
    BOOL c=PXPHook(context,@"sendActivationResultError:",(IMP)PXPActivation,
        &PXPActivationOriginal,"v",@[@"@"]);
    BOOL d=PXPHook(workspace,@"transactionDidComplete:",(IMP)PXPCompleted,
        &PXPCompletedOriginal,"v",@[@"@"]);
    PXPReady=a&&b&&c&&d;
    return PXPReady;
}

void PXPTeardownNative(PXPRoute *r,void (^completion)(BOOL)) {
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(),^{ PXPTeardownNative(r,completion); }); return;
    }
    // A failed route does not authorize dropping a live native transaction or
    // its synchronization delegate. Keep ownership and global serialization
    // until both evidenced transaction terminal states can be observed.
    id parent=r.workspaceTransaction,child=r.sceneUpdateTransaction;
    if(r->state.forwarded && !parent && !child) {
        // The original open may still own asynchronous work. No native objects
        // observed is NOT proof of cancellation: keep the account queue fenced.
        completion(NO); return;
    }
    if(parent) PXPSetObject(parent,@"failWithReason:",@"Payment routing cancelled");
    if(child) PXPSetObject(child,@"failWithReason:",@"Payment routing cancelled");
    if(PXPBool(r.transitionContext,@"needsToSendActivationResult",NULL))
        PXPSetObject(r.transitionContext,@"sendActivationResultError:",
            r.systemError ?: PXPError(40,@"Payment routing cancelled"));
    __block unsigned attempts=0;
    __block void (^poll)(void);
    poll=^{
        BOOL parentKnown=!parent,childKnown=!child;
        BOOL parentDone=parent ? PXPBool(parent,@"isComplete",&parentKnown) : YES;
        BOOL childDone=child ? PXPBool(child,@"isComplete",&childKnown) : YES;
        if(parentKnown&&childKnown&&parentDone&&childDone) {
            if(child) PXPSetObject(child,@"setSynchronizationDelegate:",nil);
            poll=nil; completion(YES); return;
        }
        if(++attempts>=40) {
            // Fail closed: caller leaves route/delegate retained and queue busy.
            poll=nil; completion(NO); return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/20),dispatch_get_main_queue(),poll);
    };
    poll();
}
