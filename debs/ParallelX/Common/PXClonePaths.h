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

// One authority for all writes: official jbroot conversion first, then a
// bounded physical AppGroup discovery ranked module > MobileSubstrate > usr/lib
// and newest mtime. Successful selection is cached for the process lifetime.
// Returns a canonical hidden root, never a Bundle/Application // alias.
NSString * _Nullable PXCloneActiveRoot(NSError **error);

// <active-root>/var/mobile/Library/Preferences/com.niubiprass.clonex.plist
NSString * _Nullable PXCloneCurrentPrefsPath(NSError **error);
NSString * _Nullable PXCloneCurrentLockPath(NSError **error);
NSString * _Nullable PXCloneCurrentTracePath(NSError **error);
// Read-only identity check; different rootfs paths may name the live domain.
BOOL PXCloneIsCurrentPrefsFile(NSString *path);

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
