#import "PXClonePaths.h"
#import "PXRootHideCompat.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

NSString *const PXClonePathsErrorDomain = @"com.niubiprass.parallelxclone.paths";

static NSError *PXPathError(PXClonePathsError code, NSString *message) {
    return [NSError errorWithDomain:PXClonePathsErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"path error"}];
}

static BOOL PXSetError(NSError **error, PXClonePathsError code, NSString *message) {
    if (error) *error = PXPathError(code, message);
    return NO;
}

static NSString *PXCanonical(NSString *path, NSError **error) {
    if (!path.length) { PXSetError(error, PXClonePathsErrorRealPath, @"empty path"); return nil; }
    char resolved[PATH_MAX];
    if (!realpath(path.fileSystemRepresentation, resolved)) {
        PXSetError(error, PXClonePathsErrorRealPath,
                   [NSString stringWithFormat:@"realpath failed: %s", strerror(errno)]);
        return nil;
    }
    return [NSString stringWithUTF8String:resolved];
}

BOOL PXCloneValidateRoot(NSString *root, NSError **error) {
    if (!root.length) return PXSetError(error, PXClonePathsErrorInvalidRoot, @"no active root");
    if (![root isAbsolutePath]) return PXSetError(error, PXClonePathsErrorInvalidRoot, @"root not absolute");

    struct stat st;
    if (stat(root.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode))
        return PXSetError(error, PXClonePathsErrorNotDirectory, @"root is not a directory");

    // realpath must resolve to the same string: a symlinked /var/jb is not the
    // hidden root, while the real .jbroot-UUID directory is.
    NSString *canonical = PXCanonical(root, error);
    if (!canonical) return NO;
    if (![canonical isEqualToString:root])
        return PXSetError(error, PXClonePathsErrorInvalidRoot, @"root is a symlink");

    NSString *last = canonical.lastPathComponent;
    BOOL hidden = [last hasPrefix:@".jbroot-"];
    if (!hidden) {
        // rootless fallback only; a plain "/" is not accepted because writes
        // would leak into the real domain.
        if (![canonical isEqualToString:@"/var/jb"])
            return PXSetError(error, PXClonePathsErrorInvalidRoot, @"not a hidden root");
    }
    return YES;
}

NSString *PXCloneActiveRoot(NSError **error) {
    NSString *converted = PXCloneJBROOT(@"/");
    if (!converted.length)
        return (PXSetError(error, PXClonePathsErrorNoRootHide, @"jbroot unavailable"), nil);

    NSString *canonical = PXCanonical(converted, error);
    if (!canonical) return nil;
    if (!PXCloneValidateRoot(canonical, error)) return nil;
    return canonical;
}

static NSString *PXPrefsRelativePath(void) {
    return @"/var/mobile/Library/Preferences/com.niubiprass.clonex.plist";
}

NSString *PXCloneCurrentPrefsPath(NSError **error) {
    NSString *root = PXCloneActiveRoot(error);
    if (!root) return nil;
    return [root stringByAppendingString:PXPrefsRelativePath()];
}

NSString *PXCloneCurrentLockPath(NSError **error) {
    NSString *root = PXCloneActiveRoot(error);
    if (!root) return nil;
    return [[root stringByAppendingString:@"/var/mobile/Library/Preferences"]
            stringByAppendingPathComponent:@"com.niubiprass.clonex.lock"];
}

BOOL PXCloneEnsureStorage(NSError **error) {
    NSString *root = PXCloneActiveRoot(error);
    if (!root) return NO;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = [root stringByAppendingString:@"/var/mobile/Library/Preferences"];
    NSError *fmError = nil;
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES
                        attributes:nil error:&fmError]) {
        if (error) *error = fmError;
        return NO;
    }

    NSString *canonicalDir = PXCanonical(dir, error);
    if (!canonicalDir) return NO;
    if (![canonicalDir hasPrefix:[root stringByAppendingString:@"/"]])
        return PXSetError(error, PXClonePathsErrorInvalidRoot, @"prefs escaped active root");

    if (access(canonicalDir.fileSystemRepresentation, W_OK) != 0)
        return PXSetError(error, PXClonePathsErrorNotWritable,
                          [NSString stringWithFormat:@"prefs not writable: %s", strerror(errno)]);

    // A pre-existing symlink at the lock path would silently redirect flock.
    NSString *lock = [canonicalDir stringByAppendingPathComponent:@"com.niubiprass.clonex.lock"];
    int fd = open(lock.fileSystemRepresentation, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) {
        return PXSetError(error, PXClonePathsErrorNotWritable,
                          [NSString stringWithFormat:@"lock open failed: %s", strerror(errno)]);
    }
    close(fd);
    return YES;
}

static void PXAddCandidate(NSMutableArray<NSString *> *out, NSMutableSet<NSString *> *seen,
                           NSString *candidate, NSString *currentRoot) {
    if (!candidate.length) return;
    struct stat st;
    if (lstat(candidate.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode)) return;

    char resolved[PATH_MAX];
    if (!realpath(candidate.fileSystemRepresentation, resolved)) return;
    NSString *canonical = [NSString stringWithUTF8String:resolved];
    if (!canonical.length) return;
    if (currentRoot.length && [canonical hasPrefix:[currentRoot stringByAppendingString:@"/"]]) return;
    if ([seen containsObject:canonical]) return;
    [seen addObject:canonical];
    [out addObject:canonical];
}

NSArray<NSString *> *PXCloneLegacyPrefsSources(NSError **error) {
    NSString *current = PXCloneActiveRoot(error);
    if (!current) return @[];

    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    // The real pre-RootHide domain. Missing on a fresh install is normal.
    NSString *real = PXCloneROOTFS(PXPrefsRelativePath());
    if (real.length) PXAddCandidate(out, seen, real, current);

    NSArray<NSString *> *bases = @[
        @"/var/mobile/Containers/Shared/AppGroup",
        @"/var/containers/Bundle/Application",
        @"/var/mobile/Containers/Bundle/Application",
    ];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *base in bases) {
        NSError *listError = nil;
        NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:base error:&listError];
        if (!entries) {
            // A missing base is normal; a real permission error is reported only
            // when no source at all could be discovered.
            continue;
        }
        for (NSString *name in entries) {
            if (![name hasPrefix:@".jbroot-"]) continue;
            NSString *root = [base stringByAppendingPathComponent:name];
            if ([root isEqualToString:current]) continue;
            PXAddCandidate(out, seen, [root stringByAppendingString:PXPrefsRelativePath()], current);
        }
    }
    return out;
}
