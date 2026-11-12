#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const PXClonePrefsNotification;
FOUNDATION_EXPORT NSString *const PXClonePrefsErrorDomain;

typedef NS_ENUM(NSInteger, PXClonePrefsError) {
    PXClonePrefsErrorMainThreadLoad = 1,
    PXClonePrefsErrorCorruptStore,
    PXClonePrefsErrorReadFailed,
    PXClonePrefsErrorWriteFailed,
    PXClonePrefsErrorReadbackMismatch,
    PXClonePrefsErrorNotLoaded,
};

// All disk IO runs on a private serial worker. The snapshot is a deep immutable
// dictionary; taking it and reading visibility is memory-only.
@interface PXClonePrefs : NSObject

+ (instancetype)shared;

// Main thread calls are rejected (never block UI). Background calls serialize
// on the worker and also run the one-time legacy migration.
- (BOOL)reloadSnapshot:(NSError **)error;

// Deep immutable cache. An unloaded or invalidated cache is @{}.
- (NSDictionary *)snapshot;

// Fail-closed: before a successful load, or after a failed load with no last
// good snapshot, returns NO. Same-root write failures keep the last state.
- (BOOL)isVisibleBundle:(NSString *)bundleID container:(NSString *)containerID;

// Copies strings and the block. Reads/merges/writes on the worker under flock,
// publishes only after a full-dictionary readback, then posts the Darwin
// notification. A non-nil completion is called on the main thread exactly once.
- (void)setVisible:(BOOL)visible
            bundle:(NSString *)bundleID
         container:(NSString *)containerID
        completion:(void (^ _Nullable)(BOOL ok, NSError * _Nullable error))completion;

// Cached storage state, no IO.
- (NSError * _Nullable)storageError;

@end

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif
