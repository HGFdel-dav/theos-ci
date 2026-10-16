// TWCraneBridge.h
// Dynamic bridge into Crane (libcrane.dylib / CraneManager).
// No compile-time dependency on Crane: everything is resolved at runtime,
// exactly like ScreenCore does it. If Crane is absent, all calls no-op.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TWCraneBridge : NSObject
// YES if CraneManager class is reachable (loaded or dlopened).
+ (BOOL)isCraneAvailable;
// Container ID that is currently active for a given app ("" if none/unavailable).
+ (NSString *)activeContainerForBundleID:(NSString *)bundleID;
// Ask Crane to switch the app to the given container, then (re)apply.
+ (BOOL)setContainer:(NSString *)containerID forBundleID:(NSString *)bundleID;
// Convenience: if the user configured a container for this bundleID under
// the Crane apps list AND the crane switch is on, apply it. NO otherwise.
+ (BOOL)applyContainerIfConfiguredForBundleID:(NSString *)bundleID;
@end

NS_ASSUME_NONNULL_END