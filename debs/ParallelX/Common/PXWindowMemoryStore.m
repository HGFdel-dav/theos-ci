#import "PXWindowMemoryStore.h"
#import "PXClonePaths.h"
#import "PXCloneRootPolicy.h"
#import "PXCloneTraceIO.h"
#include <fcntl.h>
#include <limits.h>
#include <notify.h>
#include <stdlib.h>
#include <sys/file.h>

NSString *const PXWindowMemoryNotification = @"com.niubiprass.parallelxclone/window-memory-changed";
NSString *const PXWindowMemoryDidLoadNotification = @"PXWindowMemoryDidLoadNotification";
static const char *PXWMStateFile = "com.niubiprass.clonex.window-memory.plist";
static const char *PXWMLockFile = "com.niubiprass.clonex.window-memory.lock";
static const char *PXWMLogFile = "com.niubiprass.clonex.window-memory-diagnostics.plist";

static NSDictionary *PXWMDefaults(void) {
    return @{ @"schema": @1, @"revision": @0, @"epoch": @0,
              @"enabled": @YES, @"diagnostics": @YES, @"apps": @{} };
}

static NSError *PXWMError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"com.niubiprass.parallelxclone.window-memory"
                              code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL PXWMBundle(NSString *bundle) {
    if (![bundle isKindOfClass:NSString.class] || !bundle.length || bundle.length > 255) return NO;
    return [bundle rangeOfCharacterFromSet:
            [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"].invertedSet].location == NSNotFound;
}

static NSArray *PXWMPackGeometry(PXWMGeometry g) {
    return @[@(g.frame.x), @(g.frame.y), @(g.frame.width), @(g.frame.height),
             @(g.reference.x), @(g.reference.y), @(g.reference.width), @(g.reference.height)];
}

static BOOL PXWMUnpackGeometry(id object, PXWMGeometry *out) {
    if (![object isKindOfClass:NSArray.class] || [object count] != 8 || !out) return NO;
    double d[8];
    for (unsigned i = 0; i < 8; ++i) {
        if (![object[i] isKindOfClass:NSNumber.class]) return NO;
        d[i] = [object[i] doubleValue];
    }
    PXWMGeometry g = {{d[0],d[1],d[2],d[3]}, {d[4],d[5],d[6],d[7]}};
    if (!PXWMValidGeometry(g)) return NO;
    *out = g;
    return YES;
}

BOOL PXWindowMemoryGeometry(NSDictionary *snapshot, NSString *bundle,
                            unsigned orientation, PXWMGeometry *out) {
    if (orientation > 3 || !PXWMBundle(bundle) || ![snapshot isKindOfClass:NSDictionary.class] ||
        ![snapshot[@"enabled"] isKindOfClass:NSNumber.class] || ![snapshot[@"enabled"] boolValue]) return NO;
    id apps = snapshot[@"apps"];
    if (![apps isKindOfClass:NSDictionary.class]) return NO;
    id frames = apps[bundle];
    if (![frames isKindOfClass:NSDictionary.class]) return NO;
    return PXWMUnpackGeometry(frames[[@(orientation) stringValue]], out);
}

static BOOL PXWMUInt(id value) {
    return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) &&
           [value doubleValue] >= 0 && [value doubleValue] < 9007199254740991.0 &&
           floor([value doubleValue]) == [value doubleValue];
}

static BOOL PXWMBoolNumber(id value) {
    return [value isKindOfClass:NSNumber.class] &&
           ([value doubleValue] == 0.0 || [value doubleValue] == 1.0);
}

static BOOL PXWMValidState(id value) {
    if (![value isKindOfClass:NSDictionary.class] || !PXWMUInt(value[@"schema"]) ||
        [value[@"schema"] unsignedIntegerValue] != 1 || !PXWMUInt(value[@"revision"]) ||
        !PXWMUInt(value[@"epoch"]) || !PXWMBoolNumber(value[@"enabled"]) ||
        !PXWMBoolNumber(value[@"diagnostics"])) return NO;
    NSDictionary *apps = value[@"apps"];
    if (![apps isKindOfClass:NSDictionary.class] || apps.count > 512) return NO;
    for (NSString *bundle in apps) {
        id orientations = apps[bundle];
        if (!PXWMBundle(bundle) || ![orientations isKindOfClass:NSDictionary.class] ||
            [orientations count] > 4) return NO;
        for (NSString *key in orientations) {
            PXWMGeometry g;
            if (![@[@"0",@"1",@"2",@"3"] containsObject:key] ||
                !PXWMUnpackGeometry(orientations[key], &g)) return NO;
        }
    }
    return YES;
}

@interface PXWindowMemoryStore () {
    dispatch_queue_t _worker;
    NSLock *_memoryLock;
    NSDictionary *_snapshot;
    NSString *_errorText;
    NSString *_root;
    NSString *_parent;
    struct stat _directoryIdentity;
    int _directory;
    int _notifyToken;
    BOOL _loaded;
}
@end

@implementation PXWindowMemoryStore
+ (instancetype)shared {
    static PXWindowMemoryStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [self new]; });
    return store;
}
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _worker = dispatch_queue_create("com.niubiprass.parallelxclone.window-memory", DISPATCH_QUEUE_SERIAL);
    _memoryLock = [NSLock new];
    _snapshot = PXWMDefaults();
    _errorText = @"";
    _directory = -1;
    _notifyToken = -1;
    __weak typeof(self) weakSelf = self;
    int status = notify_register_dispatch(PXWindowMemoryNotification.UTF8String, &_notifyToken,
                _worker, ^(int token) { (void)token; [weakSelf loadOnWorker]; });
    if (status != NOTIFY_STATUS_OK) _notifyToken = -1;
    [self reload];
    return self;
}
- (void)dealloc {
    if (_directory >= 0) close(_directory);
    if (_notifyToken >= 0) notify_cancel(_notifyToken);
}
- (NSDictionary *)snapshot {
    [_memoryLock lock]; NSDictionary *snapshot = _snapshot; [_memoryLock unlock];
    return snapshot;
}
- (BOOL)isLoaded {
    [_memoryLock lock]; BOOL loaded = _loaded; [_memoryLock unlock]; return loaded;
}
- (NSString *)errorText {
    [_memoryLock lock]; NSString *message = _errorText; [_memoryLock unlock]; return message;
}
- (void)publish:(NSDictionary *)snapshot error:(NSError *)error {
    [_memoryLock lock];
    if (snapshot) { _snapshot = snapshot; _loaded = YES; }
    if (error) _loaded = NO;
    _errorText = error.localizedDescription ?: @"";
    [_memoryLock unlock];
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:PXWindowMemoryDidLoadNotification object:self];
    });
}
- (BOOL)directoryCurrent:(NSError **)error {
    if (_directory < 0) {
        NSError *cause = nil;
        if (!PXCloneEnsureStorage(&cause)) { if (error) *error = cause; return NO; }
        _root = PXCloneActiveRoot(&cause);
        _parent = [PXCloneCurrentPrefsPath(&cause) stringByDeletingLastPathComponent];
        if (!_root.length || !_parent.length) { if (error) *error = cause; return NO; }
        _directory = open(_parent.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (_directory < 0 || fstat(_directory, &_directoryIdentity) != 0) {
            if (_directory >= 0) close(_directory);
            _directory = -1;
            if (error) *error = PXWMError(1, @"无法固定窗口记忆的隐根目录"); return NO;
        }
    }
    struct stat actual, pinned;
    char canonical[PATH_MAX];
    if (!PXCloneValidateRoot(_root, NULL) || !realpath(_parent.fileSystemRepresentation, canonical) ||
        (!PXClonePathIsUnderAppGroup(canonical) &&
         (PXCloneRootIsAppGroup(_root.fileSystemRepresentation) || !PXClonePathIsContained(_root.fileSystemRepresentation, canonical))) ||
        stat(_parent.fileSystemRepresentation, &actual) != 0 || fstat(_directory, &pinned) != 0 ||
        actual.st_dev != _directoryIdentity.st_dev || actual.st_ino != _directoryIdentity.st_ino ||
        actual.st_dev != pinned.st_dev || actual.st_ino != pinned.st_ino) {
        if (error) *error = PXWMError(1, @"隐根目录已变化，未写入其他位置"); return NO;
    }
    return YES;
}

- (id)readDocument:(const char *)name absent:(BOOL *)absent error:(NSError **)error {
    if (absent) *absent = NO;
    int fd = openat(_directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) {
        if (errno == ENOENT) { if (absent) *absent = YES; return nil; }
        if (error) *error = PXWMError(2, @"窗口记忆文件无法安全读取"); return nil;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size < 0 || st.st_size > 2 * 1024 * 1024) {
        close(fd); if (error) *error = PXWMError(2, @"窗口记忆文件类型或大小异常"); return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t count = read(fd, (unsigned char *)data.mutableBytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        offset += (NSUInteger)count;
    }
    close(fd);
    if (offset != data.length) { if (error) *error = PXWMError(2, @"窗口记忆文件读取不完整"); return nil; }
    return [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable
                                                     format:NULL error:error];
}
- (int)lockDocument:(NSError **)error {
    if (![self directoryCurrent:error]) return -1;
    int fd = openat(_directory, PXWMLockFile, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        if (fd >= 0) close(fd);
        if (error) *error = PXWMError(3, @"窗口记忆锁文件不可用"); return -1;
    }
    /* Off-main only. A dead process releases flock automatically. */
    if (flock(fd, LOCK_EX) != 0) {
        close(fd); if (error) *error = PXWMError(3, @"无法锁定窗口记忆"); return -1;
    }
    return fd;
}
- (BOOL)writeDocument:(id)document name:(const char *)name error:(NSError **)error {
    if (![self directoryCurrent:error]) return NO;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:document
                    format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data || data.length > 2 * 1024 * 1024) return NO;
    int errorNumber = 0;
    PXCloneTraceIOResult result = PXCloneWriteTraceAt(_directory, name, data.bytes, data.length, &errorNumber);
    if (result != PXCloneTraceIOVerified) {
        if (error) *error = PXWMError(errorNumber ?: EIO, @"窗口记忆写入或逐字节读回未通过");
        return NO;
    }
    return [self directoryCurrent:error];
}
- (NSDictionary *)readState:(NSError **)error {
    BOOL absent = NO;
    id state = [self readDocument:PXWMStateFile absent:&absent error:error];
    if (absent) return PXWMDefaults();
    if (!PXWMValidState(state)) {
        if (error && !*error) *error = PXWMError(4, @"窗口记忆数据异常，保持原版窗口布局");
        return nil;
    }
    return state;
}
- (void)loadOnWorker {
    NSError *error = nil;
    int lock = [self lockDocument:&error];
    NSDictionary *state = lock >= 0 ? [self readState:&error] : nil;
    if (lock >= 0) { flock(lock, LOCK_UN); close(lock); }
    [self publish:state error:error];
}
- (void)reload {
    dispatch_async(_worker, ^{ [self loadOnWorker]; });
}
- (void)diagnostic:(NSString *)event details:(NSDictionary *)details {
    NSString *name = [event copy];
    NSDictionary *values = [details copy];
    dispatch_async(_worker, ^{
        if (![[self snapshot][@"diagnostics"] boolValue]) return;
        NSError *error = nil;
        int lock = [self lockDocument:&error];
        if (lock < 0) return;
        BOOL absent = NO;
        id old = [self readDocument:PXWMLogFile absent:&absent error:NULL];
        NSMutableArray *events = [old isKindOfClass:NSArray.class] ? [old mutableCopy] : [NSMutableArray array];
        /* Fixed names and numeric/boolean values only. No account names, IDs,
         * URLs, chat content, tokens or arbitrary exception descriptions. */
        NSMutableDictionary *safe = [NSMutableDictionary dictionary];
        for (NSString *key in values)
            if ([key isKindOfClass:NSString.class] && [values[key] isKindOfClass:NSNumber.class]) safe[key] = values[key];
        [events addObject:@{ @"time": @(NSDate.date.timeIntervalSince1970), @"build": @"clone0.105",
                             @"pid": @(getpid()), @"event": name ?: @"unknown", @"state": safe }];
        while (events.count > 256) [events removeObjectAtIndex:0];
        [self writeDocument:events name:PXWMLogFile error:NULL];
        flock(lock, LOCK_UN); close(lock);
    });
}
- (void)change:(NSString *)operation bundle:(NSString *)bundle orientation:(unsigned)orientation
     geometry:(PXWMGeometry)geometry epoch:(uint64_t)epoch enabled:(BOOL)enabled
   completion:(void (^)(BOOL))completion {
    NSString *action = [operation copy];
    NSString *identifier = [bundle copy];
    void (^done)(BOOL) = [completion copy];
    dispatch_async(_worker, ^{
        NSError *error = nil;
        int lock = [self lockDocument:&error];
        NSDictionary *current = lock >= 0 ? [self readState:&error] : nil;
        NSMutableDictionary *next = [current mutableCopy];
        BOOL stale = NO, changed = NO, noRememberedSize = NO;
        BOOL positionOnly = [action isEqual:@"position"];
        if (next) {
            if ([action isEqual:@"save"] || positionOnly) {
                stale = !PXWMMaySave([current[@"enabled"] boolValue], epoch,
                                    [current[@"epoch"] unsignedLongLongValue], YES, YES, YES);
                if (!stale) {
                    NSMutableDictionary *apps = [current[@"apps"] mutableCopy];
                    NSMutableDictionary *frames = [apps[identifier] mutableCopy] ?: [NSMutableDictionary dictionary];
                    NSString *key = [@(orientation) stringValue];
                    PXWMGeometry merged = geometry;
                    if (positionOnly) {
                        PXWMGeometry latest;
                        noRememberedSize = !PXWMUnpackGeometry(frames[key], &latest);
                        if (!noRememberedSize && !PXWMUpdateRememberedPosition(latest, geometry, &merged))
                            error = PXWMError(7, @"窗口方向或参考尺寸已变化，未更新记忆位置");
                    }
                    NSArray *packed = PXWMPackGeometry(merged);
                    if (!noRememberedSize && !error && ![frames[key] isEqual:packed]) {
                        if (!apps[identifier] && apps.count >= 512) {
                            error = PXWMError(5, @"窗口记忆条目已达到上限");
                        } else {
                            frames[key] = packed; apps[identifier] = [frames copy];
                            next[@"apps"] = [apps copy]; changed = YES;
                        }
                    }
                }
            } else if ([action isEqual:@"clear"]) {
                next[@"apps"] = @{};
                next[@"epoch"] = @([current[@"epoch"] unsignedLongLongValue] + 1); changed = YES;
            } else if ([action isEqual:@"enable"]) {
                next[@"enabled"] = @(enabled);
                next[@"epoch"] = @([current[@"epoch"] unsignedLongLongValue] + 1); changed = YES;
            } else if ([action isEqual:@"diagnostics"]) {
                next[@"diagnostics"] = @(enabled); changed = YES;
            }
            if (changed) next[@"revision"] = @([current[@"revision"] unsignedLongLongValue] + 1);
        }
        BOOL ok = next && !error && (stale || !changed ||
                  (PXWMValidState(next) && [self writeDocument:next name:PXWMStateFile error:&error]));
        NSDictionary *confirmed = ok ? [self readState:&error] : nil;
        if (ok && ![confirmed isEqual:next]) {
            ok = NO; error = PXWMError(6, @"窗口记忆回读不一致");
        }
        if (lock >= 0) { flock(lock, LOCK_UN); close(lock); }
        if (!ok && !error) error = PXWMError(6, @"窗口记忆操作未完成");
        [self publish:ok ? confirmed : nil error:error];
        PXWMGeometry readback = {0};
        BOOL hasReadback = PXWindowMemoryGeometry(confirmed, identifier, orientation, &readback);
        [self diagnostic:stale ? @"save_discarded_after_reset" :
              (noRememberedSize ? @"position_no_size_no_save" :
               [NSString stringWithFormat:@"%@_%@", action, ok ? @"verified" : @"failed"])
                  details:@{ @"orientation": @(orientation), @"revision": confirmed[@"revision"] ?: @0,
                             @"appHash": @(([action isEqual:@"save"] || positionOnly) ? PXWMIdentifierHash(identifier.UTF8String) : 0),
                             @"errno": @(error.code), @"changed": @(changed), @"positionOnly": @(positionOnly),
                             @"hasReadback": @(hasReadback), @"savedW": @(readback.frame.width),
                             @"savedH": @(readback.frame.height) }];
        if (ok && changed) {
            int notified = notify_post(PXWindowMemoryNotification.UTF8String);
            [self diagnostic:@"settings_notification" details:@{@"result":@(notified)}];
        }
        if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(ok); });
    });
}
- (void)saveGeometry:(PXWMGeometry)geometry bundle:(NSString *)bundle
        orientation:(unsigned)orientation observedEpoch:(uint64_t)epoch {
    if (!PXWMBundle(bundle) || orientation > 3 || !PXWMValidGeometry(geometry)) {
        [self diagnostic:@"save_rejected_geometry" details:@{}]; return;
    }
    [self change:@"save" bundle:bundle orientation:orientation geometry:geometry epoch:epoch enabled:YES completion:nil];
}
- (void)savePosition:(PXWMGeometry)geometry bundle:(NSString *)bundle
        orientation:(unsigned)orientation observedEpoch:(uint64_t)epoch {
    if (!PXWMBundle(bundle) || orientation > 3 || !PXWMValidGeometry(geometry)) {
        [self diagnostic:@"position_rejected_geometry" details:@{}]; return;
    }
    [self change:@"position" bundle:bundle orientation:orientation geometry:geometry epoch:epoch enabled:YES completion:nil];
}
- (void)setMemoryEnabled:(BOOL)enabled completion:(void (^)(BOOL))completion {
    [self change:@"enable" bundle:@"" orientation:0 geometry:(PXWMGeometry){0} epoch:0 enabled:enabled completion:completion];
}
- (void)setDiagnosticsEnabled:(BOOL)enabled completion:(void (^)(BOOL))completion {
    [self change:@"diagnostics" bundle:@"" orientation:0 geometry:(PXWMGeometry){0} epoch:0 enabled:enabled completion:completion];
}
- (void)clearMemoryWithCompletion:(void (^)(BOOL))completion {
    [self change:@"clear" bundle:@"" orientation:0 geometry:(PXWMGeometry){0} epoch:0 enabled:NO completion:completion];
}
@end
