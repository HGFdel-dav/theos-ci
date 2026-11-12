#pragma once
#import <Foundation/Foundation.h>
#import "LocalCleanStatusAnimationPolicy.h"

#ifdef __cplusplus
extern "C" {
#endif
// Shared by the new animation dylib and its two preference controllers only.
FOUNDATION_EXPORT NSString * const LCSAnimationPreferencesChanged;
FOUNDATION_EXPORT NSDictionary *local_cleanstatus_animationDefaults(void);
FOUNDATION_EXPORT NSDictionary *local_cleanstatus_sanitizedAnimationPreferences(NSDictionary *values);
FOUNDATION_EXPORT NSDictionary *local_cleanstatus_readAnimationPreferences(void);
// Called only by the animation preferences panel, never from frame callbacks.
FOUNDATION_EXPORT BOOL local_cleanstatus_migrateAnimationPreferences(NSError **error);
FOUNDATION_EXPORT BOOL local_cleanstatus_writeAnimationPreferences(NSDictionary *values, NSError **error);
FOUNDATION_EXPORT void local_cleanstatus_notifyAnimationsApplied(void);
FOUNDATION_EXPORT NSString *local_cleanstatus_animationPreferencesPath(void);
#ifdef __cplusplus
}
#endif
