#pragma once
#import <Foundation/Foundation.h>
#import <dlfcn.h>

#ifdef __cplusplus
extern "C" {
#endif

NS_ASSUME_NONNULL_BEGIN

// RootHide's libroothide exports C++-mangled entry points. Resolve them at
// runtime so the same dylib also loads on Dopamine/rootless (where they are
// absent) without a hard link dependency.
typedef NSString * _Nullable (*PXClonePathFn)(NSString *path);
typedef BOOL (*PXCloneJBrandFn)(void);

static inline PXClonePathFn _Nullable PXCloneLookupPathFn(const char *cxx, const char *plain) {
    void *sym = dlsym(RTLD_DEFAULT, cxx);
    if (!sym) sym = dlsym(RTLD_DEFAULT, plain);
    return (PXClonePathFn)sym;
}

static inline NSString * _Nullable PXCloneJBROOT(NSString *path) {
    static PXClonePathFn fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fn = PXCloneLookupPathFn("__Z6jbrootP8NSString", "jbroot"); });
    return fn ? fn(path) : nil;
}

static inline NSString * _Nullable PXCloneROOTFS(NSString *path) {
    static PXClonePathFn fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fn = PXCloneLookupPathFn("__Z6rootfsP8NSString", "rootfs"); });
    return fn ? fn(path) : nil;
}

static inline BOOL PXCloneIsRootHide(void) {
    static PXCloneJBrandFn fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (PXCloneJBrandFn)dlsym(RTLD_DEFAULT, "__Z6jbrandv");
        if (!fn) fn = (PXCloneJBrandFn)dlsym(RTLD_DEFAULT, "jbrand");
    });
    return fn ? fn() : NO;
}

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif
