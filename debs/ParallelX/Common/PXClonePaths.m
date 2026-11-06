#import "PXClonePaths.h"
#import "PXRootHideCompat.h"
#import "PXCloneRootPolicy.h"
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
    if (!root.length || !root.isAbsolutePath)
        return PXSetError(error, PXClonePathsErrorInvalidRoot, @"root not absolute");
    struct stat st;
    if (stat(root.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode))
        return PXSetError(error, PXClonePathsErrorNotDirectory, @"root is not a directory");
    NSString *canonical = PXCanonical(root, error);
    if (!canonical || ![canonical isEqualToString:root])
        return PXSetError(error, PXClonePathsErrorInvalidRoot, @"root is not canonical");
    if (PXCloneRootIsAppGroup(canonical.fileSystemRepresentation)) return YES;
    // Rootless /var/jb is commonly a symlink into preboot. Accept its canonical
    // target only on a rootless build/environment; never the RootHide // alias.
    if (!PXCloneIsRootHide()) {
        NSString *rootless = PXCanonical(@"/var/jb", NULL);
        if (rootless.length && ![rootless isEqualToString:@"/"] && [canonical isEqualToString:rootless]) return YES;
    }
    return PXSetError(error, PXClonePathsErrorInvalidRoot, @"not an AppGroup hidden root");
}

static int PXRootMarkerRank(NSString *root) {
    NSFileManager *manager = NSFileManager.defaultManager;
    BOOL hasModule = [manager fileExistsAtPath:[root stringByAppendingPathComponent:
                        @"Library/MobileSubstrate/DynamicLibraries/ParallelXClone.dylib"]];
    BOOL directory = NO;
    BOOL hasSubstrate = [manager fileExistsAtPath:[root stringByAppendingPathComponent:@"Library/MobileSubstrate"]
                                    isDirectory:&directory] && directory;
    directory = NO;
    BOOL hasLibraries = [manager fileExistsAtPath:[root stringByAppendingPathComponent:@"usr/lib"]
                                    isDirectory:&directory] && directory;
    return PXCloneRootRank(hasModule, hasSubstrate, hasLibraries);
}

static NSString *PXDiscoverRoot(NSError **error) {
    NSError *resolutionError = nil;
    NSString *converted = PXCloneJBROOT(@"/");
    NSString *canonical = converted.length ? PXCanonical(converted, &resolutionError) : nil;
    if (canonical && PXCloneValidateRoot(canonical, NULL)) return canonical;

    // One bounded, shallow discovery of physical AppGroup roots. Never scan
    // preference contents or Bundle/Application .jbroot aliases (often -> //).
    NSMutableArray<NSString *> *bases = [NSMutableArray array];
    NSString *group = @"/var/mobile/Containers/Shared/AppGroup";
    NSString *physicalGroup = PXCloneROOTFS(group);
    if (physicalGroup.length) [bases addObject:physicalGroup];
    if (![bases containsObject:group]) [bases addObject:group];
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *chosen = nil;
    int bestRank = 0;
    NSTimeInterval bestMtime = 0;
    NSMutableSet *visited = [NSMutableSet set];
    NSUInteger examined = 0;
    for (NSString *base in bases) {
        NSArray *names = [manager contentsOfDirectoryAtPath:base error:&resolutionError];
        for (NSString *name in names) {
            if (![name hasPrefix:@".jbroot-"]) continue;
            if (++examined > 256) break;
            NSString *candidate = PXCanonical([base stringByAppendingPathComponent:name], NULL);
            if (!candidate.length || !PXCloneRootIsAppGroup(candidate.fileSystemRepresentation) ||
                !PXCloneValidateRoot(candidate, NULL)) continue;
            struct stat st;
            if (stat(candidate.fileSystemRepresentation, &st) != 0) continue;
            NSString *identity = [NSString stringWithFormat:@"%llu:%llu", (unsigned long long)st.st_dev,
                                   (unsigned long long)st.st_ino];
            if ([visited containsObject:identity]) continue;
            [visited addObject:identity];
            int rank = PXRootMarkerRank(candidate);
            NSTimeInterval mtime = (NSTimeInterval)st.st_mtime;
            if (!PXCloneRootOutranks(rank, mtime, bestRank, bestMtime)) continue;
            bestRank = rank;
            bestMtime = mtime;
            chosen = candidate;
        }
        if (examined > 256) break;
    }
    if (chosen.length) return chosen;
    if (!PXCloneIsRootHide()) {
        NSString *rootless = PXCanonical(@"/var/jb", NULL);
        if (rootless && PXCloneValidateRoot(rootless, NULL)) return rootless;
    }
    if (error) *error = resolutionError ?: PXPathError(PXClonePathsErrorNoRootHide,
                                                     @"未找到可用的当前 AppGroup 隐根");
    return nil;
}

NSString *PXCloneActiveRoot(NSError **error) {
    static NSObject *guard;
    static NSString *selectedRoot;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ guard = [NSObject new]; });
    @synchronized (guard) {
        if (selectedRoot) return selectedRoot;
        NSString *resolved = PXDiscoverRoot(error);
        if (resolved) selectedRoot = [resolved copy];
        return resolved;
    }
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

BOOL PXCloneIsCurrentPrefsFile(NSString *path) {
    struct stat source;
    if (!path.length || stat(path.fileSystemRepresentation, &source) != 0) return NO;
    NSMutableArray *currentPaths = [NSMutableArray array];
    NSString *own = PXCloneCurrentPrefsPath(NULL);
    NSString *mapped = PXCloneJBROOT(PXPrefsRelativePath());
    if (own.length) [currentPaths addObject:own];
    if (mapped.length) [currentPaths addObject:mapped];
    // Only metadata is read from the process's logical Preferences view.
    // This raw logical path is NEVER a write destination.
    [currentPaths addObject:PXPrefsRelativePath()];
    for (NSString *current in currentPaths) {
        struct stat target;
        if (stat(current.fileSystemRepresentation, &target) == 0 &&
            source.st_dev == target.st_dev && source.st_ino == target.st_ino) return YES;
    }
    return NO;
}

NSString *PXCloneCurrentTracePath(NSError **error) {
    NSString *prefsPath = PXCloneCurrentPrefsPath(error);
    if (!prefsPath.length) return nil;
    return [[[prefsPath stringByDeletingPathExtension] stringByAppendingString:@".launch-trace"]
             stringByAppendingPathExtension:@"plist"];
}

BOOL PXCloneEnsureStorage(NSError **error) {
    NSString *root = PXCloneActiveRoot(error);
    if (!root) return NO;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = [root stringByAppendingString:@"/var/mobile/Library/Preferences"];
    // Validate the existing parent BEFORE creating anything. A Library or
    // Preferences symlink leading outside the chosen hidden root is rejected.
    NSString *parent = PXCanonical(dir.stringByDeletingLastPathComponent, error);
    if (!parent || !PXClonePathIsContained(root.fileSystemRepresentation, parent.fileSystemRepresentation))
        return PXSetError(error, PXClonePathsErrorInvalidRoot, @"preferences parent escaped selected root");
    struct stat before;
    if (lstat(dir.fileSystemRepresentation, &before) == 0) {
        NSString *existing = PXCanonical(dir, error);
        if (!existing || !PXClonePathIsContained(root.fileSystemRepresentation, existing.fileSystemRepresentation))
            return PXSetError(error, PXClonePathsErrorInvalidRoot, @"preferences directory escaped selected root");
    }
    NSError *fmError = nil;
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES
                        attributes:nil error:&fmError]) {
        if (error) *error = fmError;
        return NO;
    }

    NSString *canonicalDir = PXCanonical(dir, error);
    if (!canonicalDir) return NO;
    if (!PXClonePathIsContained(root.fileSystemRepresentation, canonicalDir.fileSystemRepresentation))
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
    // Different rootfs/private aliases can name the same current file. Never
    // offer that file as an old migration source that could later be deleted.
    struct stat currentFile;
    NSString *currentPath = [currentRoot stringByAppendingString:PXPrefsRelativePath()];
    if (currentRoot.length && stat(currentPath.fileSystemRepresentation, &currentFile) == 0 &&
        st.st_dev == currentFile.st_dev && st.st_ino == currentFile.st_ino) return;
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
