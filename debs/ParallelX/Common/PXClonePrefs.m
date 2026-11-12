#import "PXClonePrefs.h"
#import "PXClonePaths.h"
#include <errno.h>
#include <fcntl.h>
#include <notify.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

NSString *const PXClonePrefsNotification = @"com.niubiprass.parallelxclone/changed";
NSString *const PXClonePrefsErrorDomain = @"com.niubiprass.parallelxclone.prefs";

static NSString *const PXHiddenKey = @"CXHiddenItems";
static NSString *const PXLegacyDomainFile = @"com.niubiprass.clonex.plist";

static BOOL PXOnWorker(dispatch_queue_t queue) {
    return dispatch_get_specific("com.niubiprass.parallelxclone.worker") ==
           (__bridge void *)queue;
}

static NSError *PXPrefsError(PXClonePrefsError code, NSString *message) {
    return [NSError errorWithDomain:PXClonePrefsErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"prefs error"}];
}

static id PXDeepImmutable(id value) {
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:[value count]];
        [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
            id copy = PXDeepImmutable(obj);
            if (copy) out[key] = copy;
        }];
        return [out copy];
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:[value count]];
        for (id obj in (NSArray *)value) {
            id copy = PXDeepImmutable(obj);
            if (copy) [out addObject:copy];
        }
        return [out copy];
    }
    if ([value isKindOfClass:NSDate.class] || [value isKindOfClass:NSData.class] ||
        [value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class])
        return [value copy];
    return [value copy];
}

static NSString *PXVisibleKey(NSString *bundleID, NSString *containerID) {
    return [NSString stringWithFormat:@"%@#%@", bundleID, containerID];
}

static NSArray<NSString *> *PXHiddenList(NSDictionary *snapshot) {
    id raw = snapshot[PXHiddenKey];
    if (![raw isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (id item in (NSArray *)raw)
        if ([item isKindOfClass:NSString.class] && [item length]) [out addObject:item];
    return out;
}

static NSDictionary * _Nullable PXReadDictionary(NSString *path, NSError **error) {
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (!data) return nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                         options:NSPropertyListImmutable
                                                          format:NULL error:error];
    if (![plist isKindOfClass:NSDictionary.class]) {
        if (error) *error = PXPrefsError(PXClonePrefsErrorCorruptStore, @"root is not a dictionary");
        return nil;
    }
    return (NSDictionary *)plist;
}

static BOOL PXWriteDictionary(NSDictionary *dictionary, NSString *path, NSError **error) {
    NSError *plistError = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:dictionary
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0 error:&plistError];
    if (!data) {
        if (error) *error = plistError ?: PXPrefsError(PXClonePrefsErrorWriteFailed, @"encode failed");
        return NO;
    }
    if (![data writeToFile:path options:NSDataWritingAtomic error:&plistError]) {
        if (error) *error = plistError ?: PXPrefsError(PXClonePrefsErrorWriteFailed, @"atomic write failed");
        return NO;
    }
    return YES;
}

static BOOL PXSameDictionary(NSDictionary *a, NSDictionary *b) {
    return a == b || [a isEqualToDictionary:b];
}

@interface PXClonePrefs () {
    dispatch_queue_t _worker;
    NSLock *_lock;
    NSDictionary *_snapshot;
    NSError *_storageError;
    NSString *_loadedRoot;
    BOOL _loaded;
    BOOL _reloadQueued;
    int _notifyToken;
}
@end

@implementation PXClonePrefs

+ (instancetype)shared {
    static PXClonePrefs *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[PXClonePrefs alloc] init]; });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _worker = dispatch_queue_create("com.niubiprass.parallelxclone.worker", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_worker, "com.niubiprass.parallelxclone.worker",
                                (__bridge void *)_worker, NULL);
    _lock = [[NSLock alloc] init];
    _snapshot = @{};
    _loaded = NO;
    _reloadQueued = NO;

    __weak typeof(self) weakSelf = self;
    notify_register_dispatch(PXClonePrefsNotification.UTF8String, &_notifyToken,
                             dispatch_get_main_queue(), ^(int token) {
        [weakSelf _queueReload];
    });

    dispatch_async(_worker, ^{
        NSError *error = nil;
        if (![weakSelf _loadLockedWithError:&error]) {
            [weakSelf _setError:error];
        }
    });
    return self;
}

- (void)dealloc {
    if (_notifyToken) notify_cancel(_notifyToken);
}

#pragma mark - Public

- (BOOL)reloadSnapshot:(NSError **)error {
    if (NSThread.isMainThread) {
        if (error) *error = PXPrefsError(PXClonePrefsErrorMainThreadLoad, @"reload on main thread");
        return NO;
    }

    __block BOOL ok = NO;
    __block NSError *result = nil;
    void (^work)(void) = ^{
        ok = [self _loadLockedWithError:&result];
        if (!ok) [self _setError:result];
    };
    if (PXOnWorker(_worker)) work();
    else dispatch_sync(_worker, work);

    if (!ok && error) *error = result;
    return ok;
}

- (NSDictionary *)snapshot {
    [_lock lock];
    NSDictionary *snapshot = _snapshot;
    [_lock unlock];
    return snapshot;
}

- (BOOL)isVisibleBundle:(NSString *)bundleID container:(NSString *)containerID {
    if (!bundleID.length || !containerID.length) return NO;
    [_lock lock];
    BOOL loaded = _loaded;
    NSDictionary *snapshot = _snapshot;
    [_lock unlock];
    if (!loaded) return NO;
    return ![PXHiddenList(snapshot) containsObject:PXVisibleKey(bundleID, containerID)];
}

- (void)setVisible:(BOOL)visible
            bundle:(NSString *)bundleID
         container:(NSString *)containerID
        completion:(void (^)(BOOL, NSError *))completion {
    NSString *bundle = [bundleID copy];
    NSString *container = [containerID copy];
    void (^done)(BOOL, NSError *) = [completion copy];

    if (!bundle.length || !container.length) {
        NSError *error = PXPrefsError(PXClonePrefsErrorWriteFailed, @"empty bundle/container");
        [self _finishOnMain:done ok:NO error:error];
        return;
    }

    dispatch_async(_worker, ^{
        NSString *key = PXVisibleKey(bundle, container);
        NSError *error = nil;
        BOOL ok = [self _mutateVisibility:visible key:key error:&error];
        if (ok) {
            int token = 0;
            notify_post(PXClonePrefsNotification.UTF8String);
            (void)token;
        } else {
            [self _setError:error];
        }
        [self _finishOnMain:done ok:ok error:error];
    });
}

- (NSError *)storageError {
    [_lock lock];
    NSError *error = _storageError;
    [_lock unlock];
    return error;
}

#pragma mark - Worker

- (void)_queueReload {
    [_lock lock];
    if (_reloadQueued) { [_lock unlock]; return; }
    _reloadQueued = YES;
    [_lock unlock];

    dispatch_async(self->_worker, ^{
        NSError *error = nil;
        if (![self _loadLockedWithError:&error]) [self _setError:error];
        [_lock lock];
        _reloadQueued = NO;
        [_lock unlock];
    });
}

- (void)_finishOnMain:(void (^)(BOOL, NSError *))completion ok:(BOOL)ok error:(NSError *)error {
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, error); });
}

- (void)_setError:(NSError *)error {
    [_lock lock];
    _storageError = error;
    [_lock unlock];
}

- (void)_publish:(NSDictionary *)snapshot root:(NSString *)root {
    NSDictionary *immutable = PXDeepImmutable(snapshot ?: @{});
    [_lock lock];
    _snapshot = immutable;
    _loaded = YES;
    _storageError = nil;
    _loadedRoot = root;
    [_lock unlock];
}

// Must run on the worker. Returns NO with an error; never publishes defaults.
- (BOOL)_loadLockedWithError:(NSError **)error {
    NSError *pathError = nil;
    NSString *currentRoot = PXCloneActiveRoot(&pathError);
    if (!currentRoot) {
        if (error) *error = pathError;
        return NO;
    }

    // jbrand/root changes invalidate the cache immediately.
    BOOL rootChanged = NO;
    [_lock lock];
    rootChanged = _loaded && ![currentRoot isEqualToString:_loadedRoot];
    [_lock unlock];
    if (rootChanged) {
        [_lock lock];
        _loaded = NO;
        _snapshot = @{};
        [_lock unlock];
    }

    NSString *prefs = [currentRoot stringByAppendingString:
                       @"/var/mobile/Library/Preferences/com.niubiprass.clonex.plist"];
    NSString *lockPath = [currentRoot stringByAppendingString:
                          @"/var/mobile/Library/Preferences/com.niubiprass.clonex.lock"];

    NSError *ensureError = nil;
    if (!PXCloneEnsureStorage(&ensureError)) {
        if (error) *error = ensureError;
        return NO;
    }

    int fd = open(lockPath.fileSystemRepresentation, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) {
        if (error) *error = PXPrefsError(PXClonePrefsErrorReadFailed,
                                         [NSString stringWithFormat:@"lock open: %s", strerror(errno)]);
        return NO;
    }
    if (flock(fd, LOCK_EX) != 0) {
        if (error) *error = PXPrefsError(PXClonePrefsErrorReadFailed,
                                         [NSString stringWithFormat:@"flock: %s", strerror(errno)]);
        close(fd);
        return NO;
    }

    BOOL ok = NO;
    NSDictionary *chosen = nil;
    NSString *chosenPath = nil;
    NSMutableDictionary<NSString *, NSNumber *> *mtimes = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *sources = [NSMutableArray array];

    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:prefs]) [sources addObject:prefs];
    [sources addObjectsFromArray:PXCloneLegacyPrefsSources(nil)];

    for (NSString *path in sources) {
        struct stat st;
        if (stat(path.fileSystemRepresentation, &st) != 0) continue;
        NSError *readError = nil;
        NSDictionary *dictionary = PXReadDictionary(path, &readError);
        if (!dictionary) continue; // a corrupt candidate must not hide a good one
        mtimes[path] = @((double)st.st_mtimespec.tv_sec + (double)st.st_mtimespec.tv_nsec / 1e9);
        if (!chosen || [mtimes[path] doubleValue] > [mtimes[chosenPath] doubleValue]) {
            chosen = dictionary;
            chosenPath = path;
        }
    }

    if (!chosen) {
        if ([fm fileExistsAtPath:prefs]) {
            NSError *readError = nil;
            NSDictionary *dictionary = PXReadDictionary(prefs, &readError);
            if (!dictionary) {
                if (error) *error = readError ?: PXPrefsError(PXClonePrefsErrorCorruptStore, @"corrupt store");
            }
            if (dictionary) {
                [self _publish:dictionary root:currentRoot];
                ok = YES;
            }
        } else {
            // Fresh install: an empty store is a valid loaded state.
            [self _publish:@{} root:currentRoot];
            ok = YES;
        }
    } else {
        if (!PXSameDictionary(chosen, PXReadDictionary(prefs, nil) ?: @{})) {
            NSError *writeError = nil;
            if (!PXWriteDictionary(chosen, prefs, &writeError)) {
                if (error) *error = writeError;
            } else {
                NSError *readError = nil;
                NSDictionary *readback = PXReadDictionary(prefs, &readError);
                if (!readback || !PXSameDictionary(readback, chosen)) {
                    if (error) *error = PXPrefsError(PXClonePrefsErrorReadbackMismatch,
                                                     @"migration readback mismatch");
                } else {
                    [self _publish:readback root:currentRoot];
                    ok = YES;
                }
            }
        } else {
            [self _publish:chosen root:currentRoot];
            ok = YES;
        }
    }

    if (ok) {
        // Only after a fully verified target may old copies be removed.
        for (NSString *path in sources) {
            if ([path isEqualToString:prefs]) continue;
            struct stat before;
            if (stat(path.fileSystemRepresentation, &before) != 0) continue;
            NSString *ownerRoot = [path stringByDeletingLastPathComponent];
            NSString *currentPath = [currentRoot stringByAppendingString:
                                     @"/var/mobile/Library/Preferences/com.niubiprass.clonex.plist"];
            if (![path hasPrefix:[currentRoot stringByAppendingString:@"/"]] &&
                ![path hasSuffix:PXLegacyDomainFile]) continue;
            if ([path isEqualToString:currentPath]) continue;
            // A source that changed while we were copying is left in place.
            struct stat after;
            if (stat(path.fileSystemRepresentation, &after) != 0) continue;
            if (before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec ||
                before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec ||
                before.st_size != after.st_size) continue;
            unlink(path.fileSystemRepresentation);
            (void)ownerRoot;
        }
    }

    flock(fd, LOCK_UN);
    close(fd);
    return ok;
}

// Must run on the worker; it takes its own flock (necessarily a separate
// critical section from the migration load above).
- (BOOL)_mutateVisibility:(BOOL)visible key:(NSString *)key error:(NSError **)error {
    // Migration must happen before a write, otherwise a fresh write could be
    // replaced by a newer legacy copy on the next load.
    NSError *loadError = nil;
    if (![self _loadLockedWithError:&loadError]) {
        if (error) *error = loadError;
        return NO;
    }

    NSError *pathError = nil;
    NSString *root = PXCloneActiveRoot(&pathError);
    if (!root) {
        if (error) *error = pathError;
        return NO;
    }
    NSError *ensureError = nil;
    if (!PXCloneEnsureStorage(&ensureError)) {
        if (error) *error = ensureError;
        return NO;
    }

    NSString *prefs = [root stringByAppendingString:
                       @"/var/mobile/Library/Preferences/com.niubiprass.clonex.plist"];
    NSString *lockPath = [root stringByAppendingString:
                          @"/var/mobile/Library/Preferences/com.niubiprass.clonex.lock"];

    int fd = open(lockPath.fileSystemRepresentation, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) {
        if (error) *error = PXPrefsError(PXClonePrefsErrorWriteFailed, @"lock open failed");
        return NO;
    }
    if (flock(fd, LOCK_EX) != 0) {
        if (error) *error = PXPrefsError(PXClonePrefsErrorWriteFailed, @"flock failed");
        close(fd);
        return NO;
    }

    NSMutableDictionary *dictionary = nil;
    NSError *readError = nil;
    NSDictionary *onDisk = PXReadDictionary(prefs, &readError);
    if (onDisk) {
        dictionary = [onDisk mutableCopy];
    } else if (readError && [NSFileManager.defaultManager fileExistsAtPath:prefs]) {
        if (error) *error = readError;
        flock(fd, LOCK_UN);
        close(fd);
        return NO;
    } else {
        dictionary = [NSMutableDictionary dictionary];
    }

    NSMutableArray<NSString *> *hidden = [PXHiddenList(dictionary) mutableCopy];
    [hidden removeObject:key];
    if (!visible) [hidden addObject:key];
    dictionary[PXHiddenKey] = hidden;

    BOOL ok = NO;
    NSError *writeError = nil;
    if (!PXWriteDictionary(dictionary, prefs, &writeError)) {
        if (error) *error = writeError;
    } else {
        NSError *verifyError = nil;
        NSDictionary *readback = PXReadDictionary(prefs, &verifyError);
        if (!readback || !PXSameDictionary(readback, dictionary)) {
            if (error) *error = PXPrefsError(PXClonePrefsErrorReadbackMismatch,
                                             @"write readback mismatch");
        } else {
            [self _publish:readback root:root];
            ok = YES;
        }
    }

    flock(fd, LOCK_UN);
    close(fd);
    return ok;
}

@end
