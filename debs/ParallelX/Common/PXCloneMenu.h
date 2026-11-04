#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const PXCloneVirtualPrefix;

// Only ids with our own prefix are ever resolved/handled.
BOOL PXCloneIsVirtualIdentifier(NSString *identifier);
NSDictionary<NSString *, NSString *> * _Nullable PXCloneItemForIdentifier(NSString *identifier);

// Rebuilds only the virtual records in the ParallelX menu domain. Existing
// entries keep their order; nothing else is touched.
void PXCloneSyncMenu(void);

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif
