#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const PXCloneVirtualPrefix;
// Marker written into each injected customActions record. Cleanup matches on
// this instead of the id prefix, so ParallelX's own px.custom.* records are
// never touched.
FOUNDATION_EXPORT NSString *const PXCloneRecordType;

// Only ids that resolve to a known clone container are ever handled.
BOOL PXCloneIsVirtualIdentifier(NSString *identifier);
NSDictionary<NSString *, NSString *> * _Nullable PXCloneItemForIdentifier(NSString *identifier);

// Rebuilds only the virtual records in the ParallelX menu domain. Existing
// entries keep their order; nothing else is touched.
void PXCloneSyncMenu(void);

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif
