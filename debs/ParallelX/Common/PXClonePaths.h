#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const PXClonePathsErrorDomain;

typedef NS_ENUM(NSInteger, PXClonePathsError) {
    PXClonePathsErrorNoRootHide = 1,
    PXClonePathsErrorInvalidRoot,
    PXClonePathsErrorRealPath,
    PXClonePathsErrorNotDirectory,
    PXClonePathsErrorNotWritable,
};

// The only authority for where this tweak writes. The current root is always
// the official jbroot() conversion; callers never scan for a "best" root.
// Returns the canonical (realpath) active root without trailing slash.
NSString * _Nullable PXCloneActiveRoot(NSError **error);

// <active-root>/var/mobile/Library/Preferences/com.niubiprass.clonex.plist
NSString * _Nullable PXCloneCurrentPrefsPath(NSError **error);
NSString * _Nullable PXCloneCurrentLockPath(NSError **error);

// Creates the hidden Preferences directory and the O_NOFOLLOW lock file.
BOOL PXCloneEnsureStorage(NSError **error);

// Legacy sources for one-time migration only:
//  * com.niubiprass.clonex.plist under every other .jbroot-* candidate
//  * the true pre-RootHide path obtained through rootfs()
// Deduplicated by realpath, current root excluded.
NSArray<NSString *> *PXCloneLegacyPrefsSources(NSError **error);

// YES only for a canonical directory that is the RootHide hidden root, or the
// explicit /var/jb rootless fallback.
BOOL PXCloneValidateRoot(NSString *root, NSError **error);

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif
