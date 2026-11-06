#import "PXClonePrefs.h"
#import "PXClonePaths.h"
#import <CoreFoundation/CoreFoundation.h>
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

static BOOL PXSameDictionary(NSDictionary *a, NSDictionary *b) {
    return a == b || [a isEqualToDictionary:b];
}

// The store lives in a preferences domain, so cfprefsd writes the file into the
// active root's Library/Preferences - the same directory the tweak reads. No path
// is assembled or canonicalised here, which is what the old file store got wrong.
NSString *const PXClonePrefsStoreDomain = @"com.niubiprass.clonex";

static NSString *const PXStoreKey = @"CXStore";

static NSDictionary * _Nullable PXReadDomainStore(NSError **error) {
    CFPropertyListRef raw = CFPreferencesCopyAppValue((__bridge CFStringRef)PXStoreKey,
                                                      (__bridge CFStringRef)PXClonePrefsStoreDomain);
    if (!raw) return nil;
    id value = CFBridgingRelease(raw);
    if (![value isKindOfClass:NSDictionary.class]) {
        if (error) *error = PXPrefsError(PXClonePrefsErrorCorruptStore,
                                         @"preferences domain holds a non-dictionary store");
        return nil;
    }
    return (NSDictionary *)value;
}

static BOOL PXWriteDomainStore(NSDictionary *store, NSError **error) {
    CFPreferencesSetAppValue((__bridge CFStringRef)PXStoreKey,
                             (__bridge CFPropertyListRef)store,
                             (__bridge CFStringRef)PXClonePrefsStoreDomain);
    for (int attempt = 0; attempt < 2; attempt++) {
        if (CFPreferencesAppSynchronize((__bridge CFStringRef)PXClonePrefsStoreDomain) &&
            PXSameDictionary(PXReadDomainStore(NULL), store)) {
            return YES;
        }
        usleep(20000);
    }
    if (error) *error = PXPrefsError(PXClonePrefsErrorWriteFailed,
                                     @"preferences domain write did not read back");
    return NO;
}

// Unknown keys are kept (forward compatibility); the hidden list is normalised.
static NSDictionary * _Nullable PXCloneNormalizedStore(NSDictionary *store, NSError **error) {
    id hidden = store[PXHiddenKey];
    if (hidden && ![hidden isKindOfClass:NSArray.class]) {
        if (error) *error = PXPrefsError(PXClonePrefsErrorCorruptStore,
                                         @"hidden list is not an array");
        return nil;
    }
    for (id item in (NSArray *)hidden) {
        if (![item isKindOfClass:NSString.class]) {
            if (error) *error = PXPrefsError(PXClonePrefsErrorCorruptStore,
                                             @"hidden list holds a non-string entry");
            return nil;
        }
    }
    NSMutableDictionary *out = [store mutableCopy];
    out[PXHiddenKey] = PXHiddenList(store);
    return [out copy];
}

static NSDictionary * _Nullable PXCloneFileFingerprint(NSString *path) {
    if (![path isKindOfClass:NSString.class] || !path.length) return nil;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
    if (!attributes) return nil;
    return @{ @"mtime": attributes[NSFileModificationDate] ?: NSDate.distantPast,
              @"size": attributes[NSFileSize] ?: @0 };
}

static BOOL PXCloneFingerprintIsNewer(NSDictionary *a, NSDictionary *b) {
    if (!a) return NO;
    if (!b) return YES;
    NSDate *left = a[@"mtime"];
    NSDate *right = b[@"mtime"];
    if (![left isEqualToDate:right]) return [left laterDate:right] == left;
    return [a[@"size"] longLongValue] > [b[@"size"] longLongValue];
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
    NSError *readError = nil;
    NSDictionary *stored = PXReadDomainStore(&readError);
    if (readError) {
        if (error) *error = readError;
        return NO;
    }
    if (stored) {
        NSDictionary *normalized = PXCloneNormalizedStore(stored, error);
        if (!normalized) return NO;
        [self _publish:normalized root:PXClonePrefsStoreDomain];
        return YES;
    }
    return [self _importLegacyStoreWithError:error];
}

// The domain is empty, so this is a fresh install or an upgrade from the old
// file-based store. Import the newest readable copy once, then keep using the
// domain. A copy that changed while we were writing is left alone; verified
// copies are removed so a later re-jailbreak cannot resurrect stale data, and any
// failure leaves every source file untouched.
- (BOOL)_importLegacyStoreWithError:(NSError **)error {
    NSString *ownPath = PXCloneCurrentPrefsPath(NULL);
    NSMutableArray<NSString *> *sources = [NSMutableArray array];
    if (ownPath.length) [sources addObject:ownPath];
    [sources addObjectsFromArray:PXCloneLegacyPrefsSources(NULL)];

    NSMutableDictionary<NSString *, NSDictionary *> *fingerprints = [NSMutableDictionary dictionary];
    for (NSString *path in sources) {
        NSDictionary *fingerprint = PXCloneFileFingerprint(path);
        if (fingerprint) fingerprints[path] = fingerprint;
    }

    NSString *chosenPath = nil;
    NSDictionary *chosen = nil;
    for (NSString *path in sources) {
        NSDictionary *raw = PXReadDictionary(path, NULL);
        if (!raw) continue;
        NSDictionary *candidate = PXCloneNormalizedStore(raw, NULL);
        if (!candidate) continue;
        if (!chosen || PXCloneFingerprintIsNewer(fingerprints[path], fingerprints[chosenPath])) {
            chosen = candidate;
            chosenPath = path;
        }
    }

    if (!chosen) {
        [self _publish:@{} root:PXClonePrefsStoreDomain];
        return YES;
    }

    NSError *writeError = nil;
    if (!PXWriteDomainStore(chosen, &writeError)) {
        if (error) *error = writeError;
        return NO;
    }

    NSDictionary *readback = PXReadDomainStore(NULL);
    if (!readback || !PXSameDictionary(readback, chosen)) {
        if (error) *error = PXPrefsError(PXClonePrefsErrorReadbackMismatch,
                                         @"migration readback mismatch");
        return NO;
    }

    for (NSString *path in sources) {
        if ([path isEqualToString:ownPath]) continue;
        NSDictionary *before = fingerprints[path];
        NSDictionary *now = PXCloneFileFingerprint(path);
        if (!now) continue;
        if (before && ![before isEqual:now]) continue;  // changed mid-copy: keep it
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    }

    [self _publish:readback root:PXClonePrefsStoreDomain];
    return YES;
}

// Must run on the worker. Read-modify-write against the domain; the published
// snapshot only moves once the domain read back what was written.
- (BOOL)_mutateVisibility:(BOOL)visible key:(NSString *)key error:(NSError **)error {
    NSDictionary *current = PXReadDomainStore(NULL);
    NSMutableArray<NSString *> *hidden = [PXHiddenList(current) mutableCopy];
    if (visible) {
        [hidden removeObject:key];
    } else if (![hidden containsObject:key]) {
        [hidden addObject:key];
    }

    NSMutableDictionary *dictionary = [(current ?: @{}) mutableCopy];
    dictionary[PXHiddenKey] = [hidden sortedArrayUsingSelector:@selector(compare:)];

    NSError *writeError = nil;
    if (!PXWriteDomainStore(dictionary, &writeError)) {
        if (error) *error = writeError;
        return NO;
    }

    NSDictionary *readback = PXReadDomainStore(NULL);
    if (!readback || !PXSameDictionary(readback, dictionary)) {
        if (error) *error = PXPrefsError(PXClonePrefsErrorReadbackMismatch,
                                         @"write readback mismatch");
        if (readback) [self _publish:readback root:PXClonePrefsStoreDomain];
        return NO;
    }

    [self _publish:readback root:PXClonePrefsStoreDomain];
    return YES;
}
@end
