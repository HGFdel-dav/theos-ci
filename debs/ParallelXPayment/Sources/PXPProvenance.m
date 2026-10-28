#import "PXPRoute.h"
#include <string.h>

// iOS 15.5 declarations verified against lechium/iPhone_OS_15.5:
// FBSOpenApplicationOptions copyWithZone:, SBMainWorkspace trusted-open handler,
// createRequestForApplicationActivation:options:. No URL/payload is altered.
static IMP PXPCopyOptionsOriginal,PXPTrustedOpenOriginal,PXPCreateActivationOriginal;
static BOOL PXPProvenanceReady;
@interface PXPRequestScope : NSObject
@property(nonatomic,strong) PXPRoute *route;
@property(nonatomic,strong) id application;
@property(nonatomic,weak) id workspace;
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
static void PXPTrustedOpen(id self,SEL cmd,id application,id options,id settings,id origin,id result) {
    if(!NSThread.isMainThread) {
        ((void(*)(id,SEL,id,id,id,id,id))PXPTrustedOpenOriginal)(self,cmd,application,options,settings,origin,result);
        return; // Never race the main-thread provenance scope.
    }
    PXPOptionsSource *source=objc_getAssociatedObject(options,&PXPWeakOptionsKey);
    PXPRoute *route=PXPAssociatedRoute(options) ?: source.route;
    PXPRequestScope *previous=PXPCurrentRequestScope;
    PXPRequestScope *scope=nil;
    if(NSThread.isMainThread && [route isCurrent] &&
       [PXPString(PXPGet(application,@"bundleIdentifier")) isEqual:route.bundle]) {
        scope=[PXPRequestScope new]; scope.route=route;
        scope.application=application; scope.workspace=self;
        // Save exact original source identity, not a matching URL string or bundle.
        PXPCurrentRequestScope=scope;
    } else PXPCurrentRequestScope=nil;
    @try {
        ((void(*)(id,SEL,id,id,id,id,id))PXPTrustedOpenOriginal)(self,cmd,application,options,settings,origin,result);
    } @finally { PXPCurrentRequestScope=previous; }
}
static id PXPCreateActivation(id self,SEL cmd,id application,NSUInteger options) {
    PXPRequestScope *scope=NSThread.isMainThread ? PXPCurrentRequestScope : nil;
    // Do not tag unrelated nested activations, even for a matching bundle.
    BOOL exact=scope && scope.workspace==self && scope.application==application && [scope.route isCurrent];
    id request=((id(*)(id,SEL,id,NSUInteger))PXPCreateActivationOriginal)(self,cmd,application,options);
    if(exact && request) {
        PXPRoute *route=scope.route;
        id source=objc_getAssociatedObject(request,&PXPSourceOptionsKey);
        if((source && source!=route.request) || (route.provenanceTransition && route.provenanceTransition!=request)) {
            [route fail:PXPError(81,@"More than one activation transition for the same payment request")];
        } else {
            route.provenanceTransition=request;
            objc_setAssociatedObject(request,&PXPSourceOptionsKey,route.request,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            PXPAssociate(request,route);
        }
    }
    return request;
}
BOOL PXPHasExactProvenance(PXPRoute *route,id request) {
    return route && request && route.provenanceTransition==request &&
        objc_getAssociatedObject(request,&PXPSourceOptionsKey)==route.request &&
        PXPAssociatedRoute(request)==route;
}
void PXPClearProvenance(PXPRoute *route) {
    id request=route.provenanceTransition;
    if(request && objc_getAssociatedObject(request,&PXPSourceOptionsKey)==route.request)
        objc_setAssociatedObject(request,&PXPSourceOptionsKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if(PXPAssociatedRoute(request)==route) PXPAssociate(request,nil);
    route.provenanceTransition=nil;
}
BOOL PXPInstallProvenance(void) {
    if(PXPProvenanceReady) return YES;
    Class optionsClass=NSClassFromString(@"FBSOpenApplicationOptions");
    Class workspace=NSClassFromString(@"SBMainWorkspace");
    // Use the actual NSZone pointer encoding; do not accept arbitrary pointers.
    Method copy=class_getInstanceMethod(optionsClass,@selector(copyWithZone:));
    NSMethodSignature *sig=copy ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(copy)] : nil;
    if(sig.numberOfArguments!=3) return NO;
    const char *zone=[sig getArgumentTypeAtIndex:2];
    if(strncmp(zone,"^{_NSZone",9) && strncmp(zone,"^{NSZone",8)) return NO;
    NSString *zoneType=[NSString stringWithUTF8String:zone];
    if(!PXPInstanceSignature(optionsClass,@"copyWithZone:","@",@[zoneType]) ||
       !PXPInstanceSignature(workspace,@"_handleTrustedOpenRequestForApplication:options:activationSettings:origin:withResult:","v",@[@"@",@"@",@"@",@"@",@"@?"]) ||
       !PXPInstanceSignature(workspace,@"createRequestForApplicationActivation:options:","@",@[@"@",@"Q"])) return NO;
    BOOL a=PXPHook(optionsClass,@"copyWithZone:",(IMP)PXPCopyOptions,&PXPCopyOptionsOriginal,"@",@[zoneType]);
    BOOL b=PXPHook(workspace,@"_handleTrustedOpenRequestForApplication:options:activationSettings:origin:withResult:",
        (IMP)PXPTrustedOpen,&PXPTrustedOpenOriginal,"v",@[@"@",@"@",@"@",@"@",@"@?"]);
    BOOL c=PXPHook(workspace,@"createRequestForApplicationActivation:options:",
        (IMP)PXPCreateActivation,&PXPCreateActivationOriginal,"@",@[@"@",@"Q"]);
    PXPProvenanceReady=a&&b&&c; return PXPProvenanceReady;
}
