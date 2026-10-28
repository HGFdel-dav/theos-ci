#import "PXPRoute.h"
#include <string.h>

// iOS 15.5 declarations verified against lechium/iPhone_OS_15.5:
// FBSOpenApplicationOptions copyWithZone:, SBMainWorkspace trusted-open handler,
// createRequestForApplicationActivation:options:. No URL/payload is altered.
static IMP PXPCopyOptionsOriginal,PXPTrustedOpenOriginal,PXPCreateActivationOriginal;
static IMP PXPCopyTransitionOriginal,PXPSetRequestOptionsOriginal;
static IMP PXPInnerOpenOriginal,PXPValidateOpenOriginal;
static IMP PXPOptionsDictionaryOriginal,PXPMergeDictionaryOriginal;
static BOOL PXPProvenanceReady;
@interface PXPRequestScope : NSObject
@property(nonatomic,strong) PXPRoute *route;
@property(nonatomic,strong) id application;
@property(nonatomic,weak) id workspace;
@property(nonatomic,strong) id sourceResult;
@property(nonatomic,strong) id sourceOptions;
@property(nonatomic,strong) id sourceTarget;
@property(nonatomic) BOOL factoryClaimed;
@end
@implementation PXPRequestScope
@end
@interface PXPOptionsSource : NSObject
@property(nonatomic,weak) PXPRoute *route;
@end
@implementation PXPOptionsSource
@end
static const char PXPWeakOptionsKey;
static PXPRequestScope *PXPCurrentRequestScope;
static const char PXPSourceOptionsKey;
typedef id (*PXPCopyOptionsIMP)(id,SEL,NSZone *) __attribute__((ns_returns_retained));
static id PXPCopyOptions(id self,SEL cmd,NSZone *zone) __attribute__((ns_returns_retained));
static id PXPCopyOptions(id self,SEL cmd,NSZone *zone) {
    // copy-family ownership must remain +1 under ARC, on both sides of the hook.
    PXPCopyOptionsIMP copyIMP=(PXPCopyOptionsIMP)PXPCopyOptionsOriginal;
    id result=copyIMP(self,cmd,zone);
    PXPOptionsSource *source=objc_getAssociatedObject(self,&PXPWeakOptionsKey);
    PXPRoute *route=PXPAssociatedRoute(self) ?: source.route;
    if(route && result && result!=self) {
        PXPOptionsSource *copySource=[PXPOptionsSource new]; copySource.route=route;
        objc_setAssociatedObject(result,&PXPWeakOptionsKey,copySource,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return result;
}
static PXPRoute *PXPOptionsRoute(id object) {
    PXPOptionsSource *source=objc_getAssociatedObject(object,&PXPWeakOptionsKey);
    return PXPAssociatedRoute(object) ?: source.route;
}
static void PXPAttachOptionsSource(id object,PXPRoute *route) {
    if(!object || !route) return;
    PXPOptionsSource *source=[PXPOptionsSource new]; source.route=route;
    objc_setAssociatedObject(object,&PXPWeakOptionsKey,source,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static id PXPOptionsDictionary(id self,SEL cmd) {
    id dictionary=((id(*)(id,SEL))PXPOptionsDictionaryOriginal)(self,cmd);
    PXPAttachOptionsSource(dictionary,PXPOptionsRoute(self));
    return dictionary;
}
static void PXPMergeDictionary(id self,SEL cmd,id other) {
    PXPRoute *source=PXPOptionsRoute(other);
    PXPRoute *destination=PXPOptionsRoute(self);
    ((void(*)(id,SEL,id))PXPMergeDictionaryOriginal)(self,cmd,other);
    // The exact systemService method obtains options.dictionary and then calls
    // addEntriesFromDictionary: on its local NSMutableDictionary. Payload stays
    // byte-for-byte untouched. Never infer identity from keys, values or URL.
    if(source && (!destination || destination==source)) PXPAttachOptionsSource(self,source);
    else if(source && destination!=source) {
        objc_setAssociatedObject(self,&PXPWeakOptionsKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [source fail:PXPError(84,@"Options dictionaries from different requests were merged")];
    }
}
static void PXPSetRequestOptions(id self,SEL cmd,id options) {
    PXPRoute *route=PXPAssociatedRoute(self);
    ((void(*)(id,SEL,id))PXPSetRequestOptionsOriginal)(self,cmd,options);
    if(!route) return;
    id actual=PXPGet(self,@"options");
    if(!actual) return;
    PXPOptionsSource *source=[PXPOptionsSource new]; source.route=route;
    // Attach only to the actual value stored on this exact original request.
    // No global option dictionary, URL match or arbitrary same-app association.
    objc_setAssociatedObject(actual,&PXPWeakOptionsKey,source,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void PXPTrustedOpen(id self,SEL cmd,id application,id options,id settings,id origin,id result) {
    if(!NSThread.isMainThread) {
        ((void(*)(id,SEL,id,id,id,id,id))PXPTrustedOpenOriginal)(self,cmd,application,options,settings,origin,result);
        return; // Never race the main-thread provenance scope.
    }
    PXPOptionsSource *source=objc_getAssociatedObject(options,&PXPWeakOptionsKey);
    PXPRoute *route=PXPRouteForForwardedResult(self,result) ?: PXPAssociatedRoute(options) ?: source.route;
    if(route) {
        PXPOptionsSource *proof=[PXPOptionsSource new]; proof.route=route;
        objc_setAssociatedObject(options,&PXPWeakOptionsKey,proof,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Verified on this device: trusted handler captures the SAME result,
        // application and NSDictionary options in its delayed event blocks.
        objc_setAssociatedObject(result,&PXPWeakOptionsKey,proof,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // The trusted handler may only queue an event. It must not own a factory
    // scope; that scope starts at the actual inner handler after the queue fires.
    PXPRequestScope *previous=PXPCurrentRequestScope;
    PXPCurrentRequestScope=nil;
    @try {
        ((void(*)(id,SEL,id,id,id,id,id))PXPTrustedOpenOriginal)(self,cmd,application,options,settings,origin,result);
    } @finally { PXPCurrentRequestScope=previous; }
}
static void PXPInnerOpen(id self,SEL cmd,id application,id options,id settings,id origin,id result) {
    if(!NSThread.isMainThread) {
        ((void(*)(id,SEL,id,id,id,id,id))PXPInnerOpenOriginal)(self,cmd,application,options,settings,origin,result); return;
    }
    PXPOptionsSource *source=objc_getAssociatedObject(result,&PXPWeakOptionsKey);
    PXPRoute *route=PXPRouteForForwardedResult(self,result) ?: source.route ?: PXPOptionsRoute(options);
    if(route && ![route isCurrent]) {
        // Device descriptor 0x1dd710640 -> 0x1ae7a63c2:
        // v16@?0@\"NSError\"8. The inner handler's result really is NSError*,
        // not the integer result used by unrelated URL service callbacks.
        if(result) ((PXPSystemCompletion)result)(PXPError(NSUserCancelledError,@"Payment request expired before activation"));
        return;
    }
    PXPRequestScope *previous=PXPCurrentRequestScope;
    PXPRequestScope *scope=nil;
    NSString *target=PXPString(application) ?: PXPString(PXPGet(application,@"bundleIdentifier"));
    if(route && [route isCurrent] && [target isEqual:route.bundle]) {
        scope=[PXPRequestScope new]; scope.route=route;
        scope.workspace=self; scope.sourceResult=result;
        scope.sourceOptions=options; scope.sourceTarget=application;
    }
    // Install only while the real inner handler executes. Its delayed event
    // retains result identity; this does not span unrelated main-queue work.
    PXPCurrentRequestScope=scope;
    @try {
        ((void(*)(id,SEL,id,id,id,id,id))PXPInnerOpenOriginal)(self,cmd,application,options,settings,origin,result);
    } @finally { PXPCurrentRequestScope=previous; }
}
static id PXPValidateOpen(id self,SEL cmd,id target,id options,id origin,id __autoreleasing *error) {
    id application=((id(*)(id,SEL,id,id,id,id __autoreleasing *))PXPValidateOpenOriginal)(self,cmd,target,options,origin,error);
    PXPRequestScope *scope=NSThread.isMainThread ? PXPCurrentRequestScope : nil;
    // Device 0x1ae0ad14c..174 returns the SBApplication from these exact
    // target/options arguments. The later factory uses that returned object.
    if(scope && scope.workspace==self && scope.sourceTarget==target && scope.sourceOptions==options &&
       [PXPString(PXPGet(application,@"bundleIdentifier")) isEqual:scope.route.bundle]) scope.application=application;
    return application;
}
static id PXPCreateActivation(id self,SEL cmd,id application,NSUInteger options) {
    PXPRequestScope *scope=NSThread.isMainThread ? PXPCurrentRequestScope : nil;
    // Do not tag unrelated nested activations, even for a matching bundle.
    BOOL exact=scope && scope.workspace==self && scope.application==application && [scope.route isCurrent];
    if(exact && scope.factoryClaimed) {
        [scope.route fail:PXPError(81,@"Payment inner handler requested more than one activation")];
        return nil;
    }
    if(exact) scope.factoryClaimed=YES;
    // Exclude nested factory calls made by the original factory itself.
    if(NSThread.isMainThread) PXPCurrentRequestScope=nil;
    id request=nil;
    @try { request=((id(*)(id,SEL,id,NSUInteger))PXPCreateActivationOriginal)(self,cmd,application,options); }
    @finally { if(NSThread.isMainThread) PXPCurrentRequestScope=scope; }
    if(exact && request) {
        PXPRoute *route=scope.route;
        id source=objc_getAssociatedObject(request,&PXPSourceOptionsKey);
        if((source && source!=route.request) || (route.provenanceTransition && route.provenanceTransition!=request)) {
            [route fail:PXPError(81,@"More than one activation transition for the same payment request")];
        } else {
            route.provenanceTransition=request;
            if(!route.provenanceRequests) route.provenanceRequests=[NSHashTable hashTableWithOptions:NSPointerFunctionsStrongMemory|NSPointerFunctionsObjectPointerPersonality];
            [route.provenanceRequests addObject:request];
            objc_setAssociatedObject(request,&PXPSourceOptionsKey,route.request,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            PXPAssociate(request,route);
        }
    }
    return request;
}
BOOL PXPHasExactProvenance(PXPRoute *route,id request) {
    return route && request && [route.provenanceRequests containsObject:request] &&
        objc_getAssociatedObject(request,&PXPSourceOptionsKey)==route.request &&
        PXPAssociatedRoute(request)==route;
}
typedef id (*PXPCopyTransitionIMP)(id,SEL) __attribute__((ns_returns_retained));
static id PXPCopyTransition(id self,SEL cmd) __attribute__((ns_returns_retained));
static id PXPCopyTransition(id self,SEL cmd) {
    PXPCopyTransitionIMP original=(PXPCopyTransitionIMP)PXPCopyTransitionOriginal;
    PXPRoute *route=PXPAssociatedRoute(self);
    // The copied transition can execute after this method returns. Record the
    // actual returned object, never recover identity by bundle/URL/timing.
    id result=original(self,cmd);
    if(!route || !result || result==self || !PXPHasExactProvenance(route,self)) return result;
    if(!NSThread.isMainThread || ![route isCurrent] || route.transitionRequest) {
        // Already-bound replacements are deliberately not adopted. Keep their
        // route tombstone so native execution refuses instead of default full screen.
        PXPAssociate(result,route);
        [route fail:PXPError(82,@"Payment transition copied after native binding")];
        return result;
    }
    PXPRoute *owner=PXPAssociatedRoute(result);
    if(owner && owner!=route) {
        [route fail:PXPError(83,@"Conflicting owner for copied payment transition")]; return result;
    }
    [route.provenanceRequests addObject:result];
    objc_setAssociatedObject(result,&PXPSourceOptionsKey,route.request,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    PXPAssociate(result,route);
    return result;
}
void PXPClearProvenance(PXPRoute *route) {
    for(id request in route.provenanceRequests.allObjects) {
        if(objc_getAssociatedObject(request,&PXPSourceOptionsKey)==route.request)
            objc_setAssociatedObject(request,&PXPSourceOptionsKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if(PXPAssociatedRoute(request)==route) PXPAssociate(request,nil);
    }
    [route.provenanceRequests removeAllObjects];
    route.provenanceTransition=nil;
}
BOOL PXPInstallProvenance(void) {
    if(PXPProvenanceReady) return YES;
    Class optionsClass=NSClassFromString(@"FBSOpenApplicationOptions");
    Class workspace=NSClassFromString(@"SBMainWorkspace");
    Class transitionClass=NSClassFromString(@"SBMainWorkspaceTransitionRequest");
    Class requestClass=NSClassFromString(@"FBSystemServiceOpenApplicationRequest");
    // Use the actual NSZone pointer encoding; do not accept arbitrary pointers.
    Method copy=class_getInstanceMethod(optionsClass,@selector(copyWithZone:));
    NSMethodSignature *sig=copy ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(copy)] : nil;
    if(sig.numberOfArguments!=3) return NO;
    const char *zone=[sig getArgumentTypeAtIndex:2];
    if(strncmp(zone,"^{_NSZone",9) && strncmp(zone,"^{NSZone",8)) return NO;
    NSString *zoneType=[NSString stringWithUTF8String:zone];
    if(!PXPInstanceSignature(optionsClass,@"copyWithZone:","@",@[zoneType]) ||
       !PXPInstanceSignature(workspace,@"_handleTrustedOpenRequestForApplication:options:activationSettings:origin:withResult:","v",@[@"@",@"@",@"@",@"@",@"@?"]) ||
       !PXPInstanceSignature(workspace,@"createRequestForApplicationActivation:options:","@",@[@"@",@"Q"]) ||
       !PXPInstanceSignature(transitionClass,@"copyMainWorkspaceTransitionRequest","@",@[]) ||
       !PXPInstanceSignature(requestClass,@"setOptions:","v",@[@"@"]) ||
       !PXPInstanceSignature(optionsClass,@"dictionary","@",@[]) ||
       !PXPInstanceSignature(NSClassFromString(@"__NSDictionaryM"),@"addEntriesFromDictionary:","v",@[@"@"]) ||
       !PXPInstanceSignature(workspace,@"_handleOpenApplicationRequest:options:activationSettings:origin:withResult:","v",@[@"@",@"@",@"@",@"@",@"@?"]) ||
       !PXPInstanceSignature(workspace,@"_validateRequestToOpenApplication:options:origin:error:","@",@[@"@",@"@",@"@",@"^@"])) return NO;
    BOOL a=PXPHook(optionsClass,@"copyWithZone:",(IMP)PXPCopyOptions,&PXPCopyOptionsOriginal,"@",@[zoneType]);
    BOOL b=PXPHook(workspace,@"_handleTrustedOpenRequestForApplication:options:activationSettings:origin:withResult:",
        (IMP)PXPTrustedOpen,&PXPTrustedOpenOriginal,"v",@[@"@",@"@",@"@",@"@",@"@?"]);
    BOOL c=PXPHook(workspace,@"createRequestForApplicationActivation:options:",
        (IMP)PXPCreateActivation,&PXPCreateActivationOriginal,"@",@[@"@",@"Q"]);
    BOOL d=PXPHook(transitionClass,@"copyMainWorkspaceTransitionRequest",(IMP)PXPCopyTransition,
        &PXPCopyTransitionOriginal,"@",@[]);
    BOOL e=PXPHook(requestClass,@"setOptions:",(IMP)PXPSetRequestOptions,&PXPSetRequestOptionsOriginal,"v",@[@"@"]);
    BOOL f=PXPHook(workspace,@"_handleOpenApplicationRequest:options:activationSettings:origin:withResult:",
        (IMP)PXPInnerOpen,&PXPInnerOpenOriginal,"v",@[@"@",@"@",@"@",@"@",@"@?"]);
    BOOL g=PXPHook(workspace,@"_validateRequestToOpenApplication:options:origin:error:",
        (IMP)PXPValidateOpen,&PXPValidateOpenOriginal,"@",@[@"@",@"@",@"@",@"^@"]);
    BOOL h=PXPHook(optionsClass,@"dictionary",(IMP)PXPOptionsDictionary,&PXPOptionsDictionaryOriginal,"@",@[]);
    BOOL i=PXPHook(NSClassFromString(@"__NSDictionaryM"),@"addEntriesFromDictionary:",
        (IMP)PXPMergeDictionary,&PXPMergeDictionaryOriginal,"v",@[@"@"]);
    PXPProvenanceReady=a&&b&&c&&d&&e&&f&&g&&h&&i; return PXPProvenanceReady;
}
