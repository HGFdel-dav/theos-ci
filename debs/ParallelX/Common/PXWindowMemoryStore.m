#import "PXWindowMemoryStore.h"
#import "PXClonePaths.h"
#import "PXCloneRootPolicy.h"
#import "PXCloneTraceIO.h"
#import "PXWindowDiagnosticHistory.h"
#import <os/log.h>
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
static const char *PXWMIncidentFile = "com.niubiprass.clonex.window-memory-incidents.plist";
NSString *const PXWindowDiagnosticStatusNotification = @"PXWindowDiagnosticStatusNotification";
static const char *PXWMDiagnosticChannel = "com.niubiprass.parallelxclone/window-diagnostic-health";

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
    int _diagnosticToken;
    NSString *_diagnosticSession;
    uint64_t _diagnosticSequence;
    uint64_t _diagnosticStatus;
    unsigned _diagnosticFailureCount;
    unsigned _diagnosticLastFailure;
    unsigned _diagnosticLastError;
    unsigned _diagnosticPublishedState;
    CFAbsoluteTime _diagnosticLastPublished;
    CFAbsoluteTime _diagnosticLastSystemLog;
    CFAbsoluteTime _diagnosticLastNotifyLog;
    unsigned _diagnosticNotificationError;
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
    _diagnosticSession=NSUUID.UUID.UUIDString;
    _diagnosticToken=-1;
    int diagnosticStatus=notify_register_dispatch(PXWMDiagnosticChannel,&_diagnosticToken,_worker,^(int token) {
        uint64_t value=0;
        if (notify_get_state(token,&value)==NOTIFY_STATUS_OK) [weakSelf receiveDiagnosticStatus:value];
    });
    if (diagnosticStatus!=NOTIFY_STATUS_OK) {
        _diagnosticToken=-1;_diagnosticNotificationError=(unsigned)diagnosticStatus;
        os_log_error(OS_LOG_DEFAULT,"PXWindowDiagnostic health registration failed code=%{public}u",(unsigned)diagnosticStatus);
    }
    [self reload];
    return self;
}
- (void)dealloc {
    if (_directory >= 0) close(_directory);
    if (_notifyToken >= 0) notify_cancel(_notifyToken);
    if (_diagnosticToken >= 0) notify_cancel(_diagnosticToken);
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
- (void)receiveDiagnosticStatus:(uint64_t)value {
    [_memoryLock lock];
    BOOL localFailure=(_diagnosticStatus&255)>PXWMDiagnosticVerified &&
        (_diagnosticStatus>>48)==(uint64_t)(getpid()&65535);
    if (localFailure && (value&255)==PXWMDiagnosticVerified && (value>>48)!=(_diagnosticStatus>>48)) {
        [_memoryLock unlock]; return;
    }
    BOOL changed=_diagnosticStatus!=value; _diagnosticStatus=value; [_memoryLock unlock];
    if (changed) dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:PXWindowDiagnosticStatusNotification object:self];
    });
}
- (uint64_t)diagnosticStatus {
    uint64_t value=0,local=0;
    [_memoryLock lock]; local=_diagnosticStatus; [_memoryLock unlock];
    if ((local&255)>PXWMDiagnosticVerified && (local>>48)==(uint64_t)(getpid()&65535)) return local;
    if (_diagnosticToken>=0 && notify_get_state(_diagnosticToken,&value)==NOTIFY_STATUS_OK && value) return value;
    return local;
}
- (NSString *)diagnosticStatusText {
    [_memoryLock lock]; unsigned notificationError=_diagnosticNotificationError; [_memoryLock unlock];
    if (notificationError) return [NSString stringWithFormat:@"诊断状态通知不可用（错误 %u）；本进程有独立错误记录，不能据此确认另一进程写入成功。",notificationError];
    uint64_t status=self.diagnosticStatus;
    unsigned current=(unsigned)(status&255),last=(unsigned)((status>>8)&255);
    unsigned count=(unsigned)((status>>32)&65535),code=(unsigned)((status>>16)&65535);
    if (!current) return @"本次尚未确认诊断写入；状态不依赖诊断文件。";
    if (current==PXWMDiagnosticVerified)
        return last ? [NSString stringWithFormat:@"诊断现已写入并读回；记录进程曾失败 %u 次，最近原因 %u（错误 %u），故障期间的记录可能缺失。",count,last,code] :
            @"最近一次诊断已写入并读回。";
    NSArray *reasons=@[@"未知",@"已读回",@"目录或日志锁不可用",@"普通记录无法读取",
        @"异常片段无法读取",@"普通记录写入失败",@"异常片段写入失败",@"异常片段超过容量上限",
        @"普通记录写后读回失败",@"异常片段写后读回失败"];
    NSString *reason=current<reasons.count ? reasons[current] : @"未知故障";
    return [NSString stringWithFormat:@"诊断未完整保存：%@（错误 %u）。窗口记忆本身不受此状态控制。",reason,code];
}
- (void)reportDiagnosticState:(PXWMDiagnosticIOState)state error:(NSError *)error {
    CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();
    if (state!=PXWMDiagnosticVerified) {
        if (_diagnosticFailureCount<65535) _diagnosticFailureCount++;
        _diagnosticLastFailure=(unsigned)state;
        _diagnosticLastError=(unsigned)llabs((long long)(error.code ?: EIO));
        if (!_diagnosticLastSystemLog || now-_diagnosticLastSystemLog>=5) {
            _diagnosticLastSystemLog=now;
            os_log_error(OS_LOG_DEFAULT,"PXWindowDiagnostic IO failure state=%{public}u code=%{public}u count=%{public}u",
                         (unsigned)state,_diagnosticLastError,_diagnosticFailureCount);
        }
    }
    /* Repeat errors update local counters but publish at most once per 5s.
     * A state transition (including recovery) remains immediately observable. */
    if (_diagnosticPublishedState==(unsigned)state && now-_diagnosticLastPublished<5) return;
    _diagnosticPublishedState=(unsigned)state; _diagnosticLastPublished=now;
    uint64_t value=PXWMDiagnosticPackStatus((unsigned)state,_diagnosticLastFailure,
                       _diagnosticLastError,_diagnosticFailureCount)|((uint64_t)(getpid()&65535)<<48);
    [self receiveDiagnosticStatus:value];
    if (_diagnosticToken>=0) {
        uint64_t remote=0;notify_get_state(_diagnosticToken,&remote);
        /* A successful Settings writer must not erase SpringBoard's failure. */
        BOOL foreignFailure=((remote&255)>PXWMDiagnosticVerified || ((remote>>8)&255)>0) &&
            (remote>>48)!=(value>>48);
        BOOL foreignActiveFailure=(remote&255)>PXWMDiagnosticVerified && (remote>>48)!=(value>>48);
        if (!(state==PXWMDiagnosticVerified && (foreignActiveFailure || (foreignFailure && !_diagnosticLastFailure)))) {
            int sent=notify_set_state(_diagnosticToken,value);
            if (sent==NOTIFY_STATUS_OK) sent=notify_post(PXWMDiagnosticChannel);
            [_memoryLock lock]; _diagnosticNotificationError=(unsigned)sent; [_memoryLock unlock];
            if (sent!=NOTIFY_STATUS_OK && (!_diagnosticLastNotifyLog || now-_diagnosticLastNotifyLog>=5)) {
                _diagnosticLastNotifyLog=now;
                os_log_error(OS_LOG_DEFAULT,"PXWindowDiagnostic health notification failed code=%{public}u",(unsigned)sent);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [NSNotificationCenter.defaultCenter postNotificationName:PXWindowDiagnosticStatusNotification object:self];
                });
            }
        }
    }
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
    BOOL diagnostic=!strcmp(name,PXWMLogFile) || !strcmp(name,PXWMIncidentFile);
    int fd = openat(_directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (diagnostic ? O_NONBLOCK : 0));
    if (fd < 0) {
        if (errno == ENOENT) { if (absent) *absent = YES; return nil; }
        if (error) *error = PXWMError(2, @"窗口记忆文件无法安全读取"); return nil;
    }
    struct stat st;
    off_t limit=!strcmp(name,PXWMIncidentFile) ? PXWMDiagnosticArchiveBytes : 2*1024*1024;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size < 0 || st.st_size > limit) {
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
        if (error) *error = [NSError errorWithDomain:@"com.niubiprass.parallelxclone.window-memory"
            code:errorNumber ?: EIO userInfo:@{NSLocalizedDescriptionKey:@"窗口记忆写入或逐字节读回未通过",
                                               @"traceIOResult":@(result)}];
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
    if (![[self snapshot][@"diagnostics"] boolValue]) return;
    NSString *name=[event copy]; NSDictionary *values=[details copy];
    NSTimeInterval observed=NSDate.date.timeIntervalSince1970;
    dispatch_async(_worker, ^{
        if (![[self snapshot][@"diagnostics"] boolValue]) return;
        NSMutableDictionary *safe=[NSMutableDictionary dictionary];
        for (NSString *key in values) {
            if (safe.count>=128) break;
            if ([key isKindOfClass:NSString.class] && key.length<=64 &&
                [values[key] isKindOfClass:NSNumber.class] && isfinite([values[key] doubleValue])) safe[key]=values[key];
        }
        NSDictionary *entry=@{@"time":@(observed),@"build":@"clone0.116",@"pid":@(getpid()),
            @"session":self->_diagnosticSession,@"sequence":@(++self->_diagnosticSequence),
            @"event":name.length && name.length<=96 ? name : @"invalid_event",@"state":safe};
        NSError *error=nil;
        int lock=[self lockDocument:&error];
        if (lock<0) { [self reportDiagnosticState:PXWMDiagnosticLockFailed error:error]; return; }
        PXWMDiagnosticIOState result=PXWMDiagnosticVerified;
        @try {
            BOOL recentAbsent=NO,archiveAbsent=NO;
            NSError *recentError=nil,*archiveError=nil;
            id old=[self readDocument:PXWMLogFile absent:&recentAbsent error:&recentError];
            BOOL recentOK=recentAbsent || (old && PXWMDiagnosticValidRecent(old));
            NSMutableArray *events=recentOK && !recentAbsent ? [old mutableCopy] : [NSMutableArray array];
            if (!recentOK) { result=PXWMDiagnosticRecentReadFailed; error=recentError; }
            id archive=[self readDocument:PXWMIncidentFile absent:&archiveAbsent error:&archiveError];
            BOOL archiveOK=archiveAbsent || (archive && PXWMDiagnosticValidArchive(archive));
            if (!archiveOK) { result=PXWMDiagnosticArchiveReadFailed; error=archiveError; }
            if (archiveOK) {
                NSDictionary *previous=archiveAbsent ? @{@"schema":@1,@"incidents":@[]} : archive;
                NSDictionary *next=PXWMDiagnosticMerge(previous,events,entry);
                if (![next isEqual:previous]) {
                    NSData *encoded=[NSPropertyListSerialization dataWithPropertyList:next
                        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&archiveError];
                    if (!encoded || encoded.length>PXWMDiagnosticArchiveBytes) {
                        result=PXWMDiagnosticArchiveSizeFailed;error=archiveError;
                    } else if (![self writeDocument:next name:PXWMIncidentFile error:&archiveError]) {
                        result=[archiveError.userInfo[@"traceIOResult"] unsignedIntegerValue]==PXCloneTraceIOReadbackFailed ?
                            PXWMDiagnosticArchiveReadbackFailed : PXWMDiagnosticArchiveWriteFailed;
                        error=archiveError;
                    }
                }
            }
            if (recentOK) {
                [events addObject:entry];
                while (events.count > 256) [events removeObjectAtIndex:0];
                if (![self writeDocument:events name:PXWMLogFile error:&recentError]) {
                    result=[recentError.userInfo[@"traceIOResult"] unsignedIntegerValue]==PXCloneTraceIOReadbackFailed ?
                        PXWMDiagnosticRecentReadbackFailed : PXWMDiagnosticRecentWriteFailed;
                    error=recentError;
                }
            }
        } @catch (__unused NSException *exception) {
            result=PXWMDiagnosticArchiveReadFailed;
            error=PXWMError(EINVAL,@"诊断结构无法安全处理，保留原文件");
        } @finally { flock(lock,LOCK_UN); close(lock); }
        [self reportDiagnosticState:result error:error];
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
                    /* A move with no record still owns its position: create the
                     * record from the observed (normal) geometry so the next open
                     * uses it. Existing records keep their stored size. */
                    if (!error && ![frames[key] isEqual:packed]) {
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
              (noRememberedSize ? (changed ? @"position_only_created" : @"position_only_unchanged") :
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
