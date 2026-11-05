#pragma once
#import <Foundation/Foundation.h>
#import <roothide.h>

// roothide.h selects the real API for the roothide scheme and the official
// rootless stubs otherwise. Use the NSString overload directly. The plain
// C symbol jbroot takes const char*, not NSString*, and jbrand returns uint64.
NS_ASSUME_NONNULL_BEGIN

static inline NSString *PXCloneJBROOT(NSString *path) {
    return jbroot(path);
}

static inline NSString *PXCloneROOTFS(NSString *path) {
    return rootfs(path);
}

static inline BOOL PXCloneIsRootHide(void) {
    return jbrand() != 0;
}

NS_ASSUME_NONNULL_END
