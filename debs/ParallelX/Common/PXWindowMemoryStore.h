#pragma once
#import <Foundation/Foundation.h>
#import "PXWindowMemoryPolicy.h"

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const PXWindowMemoryNotification;
FOUNDATION_EXPORT NSString *const PXWindowMemoryDidLoadNotification;
FOUNDATION_EXPORT NSString *const PXWindowDiagnosticStatusNotification;

/* Uses the existing cached RootHide path resolver and verified atomic I/O.
 * The document is isolated from CXStore: account/UI writers cannot overwrite it.
 * All disk work, locking, serialization and diagnostics run off the main queue. */
@interface PXWindowMemoryStore : NSObject
+ (instancetype)shared;
- (NSDictionary *)snapshot;
- (BOOL)isLoaded;
- (NSString *)errorText;
/* Diagnostic health is independent: a logging failure never invalidates the
 * geometry snapshot or toggles the memory feature. */
- (uint64_t)diagnosticStatus;
- (NSString *)diagnosticStatusText;
- (void)reload;
/* Only the real completed resize calls saveGeometry. Position updates merge
 * with the latest same-direction record under the existing file lock; without
 * a remembered size they create no size record. */
- (void)saveGeometry:(PXWMGeometry)geometry bundle:(NSString *)bundle
        orientation:(unsigned)orientation observedEpoch:(uint64_t)epoch;
- (void)savePosition:(PXWMGeometry)geometry bundle:(NSString *)bundle
        orientation:(unsigned)orientation observedEpoch:(uint64_t)epoch;
- (void)setMemoryEnabled:(BOOL)enabled completion:(void (^)(BOOL ok))completion;
- (void)setDiagnosticsEnabled:(BOOL)enabled completion:(void (^)(BOOL ok))completion;
- (void)clearMemoryWithCompletion:(void (^)(BOOL ok))completion;
- (void)diagnostic:(NSString *)event details:(NSDictionary *)details;
@end

FOUNDATION_EXPORT BOOL PXWindowMemoryGeometry(NSDictionary *snapshot, NSString *bundle,
                                            unsigned orientation, PXWMGeometry *result);
NS_ASSUME_NONNULL_END
