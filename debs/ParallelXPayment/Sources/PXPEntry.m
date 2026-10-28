#import "PXPRoute.h"
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#include <string.h>
#include <dispatch/dispatch.h>

// Review build stays inert until native and host adapters pass ABI/function review.
// Changing this is a release decision, not an installation-time side effect.
#ifndef PXP_ENABLE_CANDIDATE
#define PXP_ENABLE_CANDIDATE 0
#endif
static BOOL PXPVerifiedEngine(void) {
    static const uint8_t uuid[16]={0x89,0xe3,0x2f,0x12,0xc2,0x62,0x35,0x65,
        0xb6,0xf0,0x6b,0x7c,0xe5,0x65,0xab,0x79};
    for(uint32_t i=0;i<_dyld_image_count();++i) {
        const char *path=_dyld_get_image_name(i);
        if(!path || strcmp(strrchr(path,'/') ? strrchr(path,'/')+1 : path,"ParallelX.dylib")) continue;
        const struct mach_header *header=_dyld_get_image_header(i);
        if(!header || header->magic!=MH_MAGIC_64) return NO;
        const struct mach_header_64 *h=(const void*)header;
        const uint8_t *p=(const void*)(h+1),*end=p+h->sizeofcmds;
        for(uint32_t n=0;n<h->ncmds;++n) {
            if(p+sizeof(struct load_command)>end) return NO;
            const struct load_command *lc=(const void*)p;
            if(lc->cmdsize<sizeof(*lc)||lc->cmdsize>(size_t)(end-p)) return NO;
            if(lc->cmd==LC_UUID && lc->cmdsize>=sizeof(struct uuid_command))
                return !memcmp(((const struct uuid_command*)lc)->uuid,uuid,sizeof(uuid));
            p+=lc->cmdsize;
        }
    }
    return NO;
}
static void PXPInstall(unsigned attempt) {
    if(!PXP_ENABLE_CANDIDATE) return;
    // Both routing engines must not own the same system request. No plugin is
    // unloaded, disabled or configured on the user's behalf.
    if(NSClassFromString(@"SCExternalLinkCoordinator") || NSClassFromString(@"CXCraneBridge")) return;
    if(!PXPVerifiedEngine()) {
        if(attempt<12) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/2),
            dispatch_get_main_queue(),^{ PXPInstall(attempt+1); });
        return;
    }
    if(PXPInstallHostAdapter() && PXPInstallProvenance() && PXPInstallNativeRouting()) PXPInstallRequestIntake();
}
__attribute__((constructor)) static void PXPEntry(void) {
    @autoreleasepool {
        if(![NSProcessInfo.processInfo.processName isEqual:@"SpringBoard"]) return;
        dispatch_async(dispatch_get_main_queue(),^{ PXPInstall(0); });
    }
}
