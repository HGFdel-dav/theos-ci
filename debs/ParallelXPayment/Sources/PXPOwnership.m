#import "PXPRoute.h"
#include <dlfcn.h>
#include <string.h>

// This scope is ONLY for the synchronous native PX ownership decision. It is
// never used to infer an asynchronous transition's identity. No defaults are
// written, no other URL request or normal menu open loses native behavior.
static IMP PXPDefaultsInitOriginal,PXPDefaultsObjectOriginal,PXPDefaultsBoolOriginal;
static const char PXPNativeDomainKey;
static PXPRoute *PXPForwardOwner;
static BOOL PXPOwnershipReady;
typedef id (*PXPDefaultsInitIMP)(__attribute__((ns_consumed)) id,SEL,id) __attribute__((ns_returns_retained));
static id PXPDefaultsInit(__attribute__((ns_consumed)) id self,SEL cmd,id suite) __attribute__((ns_returns_retained));
static id PXPDefaultsInit(__attribute__((ns_consumed)) id self,SEL cmd,id suite) {
    PXPDefaultsInitIMP original=(PXPDefaultsInitIMP)PXPDefaultsInitOriginal;
    id result=original(self,cmd,suite);
    if(result && [suite isEqual:@"com.moxuan.parallelx"])
        objc_setAssociatedObject(result,&PXPNativeDomainKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return result;
}
static BOOL PXPIsNativeOwnershipRead(id defaults,id key,void *caller) {
    if(!NSThread.isMainThread || ![PXPForwardOwner isCurrent] || ![key isEqual:@"urlSplitEnabled"] ||
       ![objc_getAssociatedObject(defaults,&PXPNativeDomainKey) boolValue]) return NO;
    Dl_info info={0};
    if(!caller || !dladdr(caller,&info) || !info.dli_fname) return NO;
    const char *base=strrchr(info.dli_fname,'/'); base=base ? base+1 : info.dli_fname;
    return !strcmp(base,"ParallelX.dylib");
}
static id PXPDefaultsObject(id self,SEL cmd,id key) {
    if(PXPIsNativeOwnershipRead(self,key,__builtin_return_address(0))) return @NO;
    return ((id(*)(id,SEL,id))PXPDefaultsObjectOriginal)(self,cmd,key);
}
static BOOL PXPDefaultsBool(id self,SEL cmd,id key) {
    if(PXPIsNativeOwnershipRead(self,key,__builtin_return_address(0))) return NO;
    return ((BOOL(*)(id,SEL,id))PXPDefaultsBoolOriginal)(self,cmd,key);
}
void PXPCallOriginalRequest(IMP original,id receiver,SEL selector,id service,id request,
                            PXPSystemCompletion completion,PXPRoute *owner) {
    if(!original) return;
    if(!NSThread.isMainThread) {
        ((void(*)(id,SEL,id,id,PXPSystemCompletion))original)(receiver,selector,service,request,completion); return;
    }
    PXPRoute *previous=PXPForwardOwner;
    // Every request intake uses this bridge. An unrelated reentrant request clears
    // the override, including normal apps and payment-return callbacks.
    PXPForwardOwner=owner && owner.receiver==receiver && owner.request==request && [owner isCurrent] ? owner : nil;
    @try { ((void(*)(id,SEL,id,id,PXPSystemCompletion))original)(receiver,selector,service,request,completion); }
    @finally { PXPForwardOwner=previous; }
}
BOOL PXPInstallOwnership(void) {
    if(PXPOwnershipReady) return YES;
    Class cls=NSUserDefaults.class;
    if(!PXPInstanceSignature(cls,@"initWithSuiteName:","@",@[@"@"]) ||
       !PXPInstanceSignature(cls,@"objectForKey:","@",@[@"@"]) ||
       !PXPInstanceSignature(cls,@"boolForKey:","B",@[@"@"])) return NO;
    BOOL a=PXPHook(cls,@"initWithSuiteName:",(IMP)PXPDefaultsInit,&PXPDefaultsInitOriginal,"@",@[@"@"]);
    BOOL b=PXPHook(cls,@"objectForKey:",(IMP)PXPDefaultsObject,&PXPDefaultsObjectOriginal,"@",@[@"@"]);
    BOOL c=PXPHook(cls,@"boolForKey:",(IMP)PXPDefaultsBool,&PXPDefaultsBoolOriginal,"B",@[@"@"]);
    PXPOwnershipReady=a&&b&&c; return PXPOwnershipReady;
}
