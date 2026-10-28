#import "PXPRoute.h"
#include <dlfcn.h>
#include <string.h>
#include <mach-o/loader.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

// alpha377-only seam, established from the exact engine's machine code. This
// is NOT a generic return-address heuristic: installation verifies the image
// UUID, current request IMP offset and the BL target before any hook is installed.
// Only the initial enabled check of the exact original request wrapper yields;
// normal windows, other callers and every unrelated/reentrant request stay native.
static PXPRoute *PXPForwardOwner;
static BOOL PXPOwnershipReady;
static BOOL (*PXPNativeEnabledOriginal)(void);
static uintptr_t PXPInitialEnabledReturn;
static uintptr_t PXPUnsignedCode(const void *pointer) {
#if __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip((void *)pointer,ptrauth_key_function_pointer);
#else
    return (uintptr_t)pointer;
#endif
}
static BOOL PXPNativeEnabled(void) {
    uintptr_t caller=PXPUnsignedCode(__builtin_return_address(0));
    if(NSThread.isMainThread && [PXPForwardOwner isCurrent] && caller==PXPInitialEnabledReturn) return NO;
    return PXPNativeEnabledOriginal();
}
static BOOL PXPMatchEngine(const struct mach_header_64 *header) {
    const uint8_t uuid[16]={0x89,0xe3,0x2f,0x12,0xc2,0x62,0x35,0x65,0xb6,0xf0,0x6b,0x7c,0xe5,0x65,0xab,0x79};
    if(!header || header->magic!=MH_MAGIC_64) return NO;
    const uint8_t *p=(const void *)(header+1),*end=p+header->sizeofcmds;
    for(uint32_t i=0;i<header->ncmds;++i) {
        if((size_t)(end-p)<sizeof(struct load_command)) return NO;
        const struct load_command *lc=(const void *)p;
        if(lc->cmdsize<sizeof(*lc)||lc->cmdsize>(size_t)(end-p)) return NO;
        if(lc->cmd==LC_UUID && lc->cmdsize>=sizeof(struct uuid_command))
            return !memcmp(((const struct uuid_command *)lc)->uuid,uuid,sizeof(uuid));
        p+=lc->cmdsize;
    }
    return NO;
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
    SEL request=NSSelectorFromString(@"systemService:handleOpenApplicationRequest:withCompletion:");
    Method method=class_getInstanceMethod(NSClassFromString(@"SBMainWorkspace"),request);
    if(!method) return NO;
    uintptr_t imp=PXPUnsignedCode(method_getImplementation(method));
    Dl_info info={0};
    if(!dladdr((const void *)imp,&info) || !info.dli_fbase || !PXPMatchEngine(info.dli_fbase)) return NO;
    uintptr_t base=(uintptr_t)info.dli_fbase;
    // Only install BEFORE this extension's intake hook wraps the method.
    // Unknown top-level hook order is not silently bypassed.
    if(imp!=base+0x676c) return NO;
    uint32_t instruction=0; memcpy(&instruction,(const void *)(base+0x67cc),sizeof(instruction));
    if((instruction&0xfc000000)!=0x94000000) return NO;
    int64_t delta=((int64_t)(instruction&0x03ffffff)<<38)>>36;
    uintptr_t called=(uintptr_t)((int64_t)(base+0x67cc)+delta);
    void *symbol=dlsym(RTLD_DEFAULT,"PXPluginIsEnabled");
    if(!symbol || PXPUnsignedCode(symbol)!=called || called!=base+0x58464) return NO;
    void (*hook)(void *,void *,void **)=dlsym(RTLD_DEFAULT,"MSHookFunction");
    if(!hook) return NO;
    PXPInitialEnabledReturn=base+0x67d0;
    hook(symbol,(void *)PXPNativeEnabled,(void **)&PXPNativeEnabledOriginal);
    PXPOwnershipReady=PXPNativeEnabledOriginal!=NULL;
    return PXPOwnershipReady;
}
