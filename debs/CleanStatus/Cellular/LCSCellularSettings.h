#pragma once
#import <Foundation/Foundation.h>
#import "LCSCellularPolicy.h"

FOUNDATION_EXPORT NSString * const LCSCellularPreferencesDidChange;
NSString *LCSCellularRoot(void);
NSString *LCSCellularPreferencesPath(void);
NSDictionary *LCSCellularDefaults(void);
NSDictionary *LCSCellularReadPreferences(void);
BOOL LCSCellularMigratePreferences(NSError **error);
BOOL LCSCellularSaveSetting(NSString *key,BOOL value,NSError **error);
void LCSCellularStartConfiguration(void);
BOOL LCSCellularFeatureEnabled(LCSCellularKind kind);
BOOL LCSCellularIsSpringBoard(void);
BOOL LCSCellularIsUnlocked(void);
// Worker-side gate; includes enabled feature, iOS15, host and live lock state.
BOOL LCSCellularMayMutate(LCSCellularKind kind);
int LCSCellularAcquireOperationLock(NSError **error);
void LCSCellularReleaseOperationLock(int descriptor);
void LCSCellularLog(LCSCellularKind kind,NSString *event,NSString *reason,NSInteger slot);
// Resolve under the cached root, never by a caller-provided arbitrary path.
NSString *LCSCellularSIMToolPath(void);
