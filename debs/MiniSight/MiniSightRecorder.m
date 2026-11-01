#import "MiniSightRecorder.h"
#import "tools/recorder/MiniSightRecorderFile.h"
#import <UIKit/UIKit.h>
#import <ReplayKit/ReplayKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <math.h>
#import <stdlib.h>
#import <mach/mach_time.h>

/* iOS 15 binary evidence: NSError-only start and (NSURL *, NSError *) stop.
   No generic invocation/IMP casts, delegate replacement or App-scope fallback. */
@protocol MSRSystemBackend <NSObject>
+ (id)sharedRecorder;
- (BOOL)isAvailable;
- (BOOL)isRecording;
- (BOOL)systemRecording;
- (BOOL)screenRecordingAllowed;
- (BOOL)screenRecordingSupportedOnDevice;
- (BOOL)isMicrophoneEnabled;
- (void)setMicrophoneEnabled:(BOOL)enabled;
- (void)startSystemRecordingWithMicrophoneEnabled:(BOOL)enabled
                                       handler:(void (^)(NSError *error))handler;
- (void)stopSystemRecordingWithURLHandler:(void (^)(NSURL *url, NSError *error))handler;
@end

static double MSRNow(void) {
    static mach_timebase_info_data_t scale;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&scale); });
    return (double)mach_continuous_time() * (double)scale.numer / (double)scale.denom / 1.0e9;
}
static BOOL MSRMethodMatches(Method method, const char *result,
                            unsigned count, const char *const *types) {
    if (!method || method_getNumberOfArguments(method) != count) return NO;
    char *type = method_copyReturnType(method);
    BOOL ok = type && !strcmp(type, result);
    free(type);
    for (unsigned i = 0; ok && i < count; ++i) {
        type = method_copyArgumentType(method, i);
        ok = type && !strcmp(type, types[i]);
        free(type);
    }
    return ok;
}
static BOOL MSRBackendABI(Class cls) {
    const char *two[] = { "@", ":" };
    const char *mic[] = { "@", ":", "B" };
    const char *start[] = { "@", ":", "B", "@?" };
    const char *stop[] = { "@", ":", "@?" };
    if (!cls) return NO;
    const char *getters[] = { "isAvailable", "isRecording", "systemRecording",
        "screenRecordingAllowed", "screenRecordingSupportedOnDevice", "isMicrophoneEnabled" };
    for (unsigned i = 0; i < sizeof(getters) / sizeof(getters[0]); ++i)
        if (!MSRMethodMatches(class_getInstanceMethod(cls, sel_registerName(getters[i])),
                              "B", 2, two)) return NO;
    return MSRMethodMatches(class_getInstanceMethod(cls, @selector(setMicrophoneEnabled:)), "v", 3, mic) &&
        MSRMethodMatches(class_getInstanceMethod(cls, sel_registerName("setRecording:")), "v", 3, mic) &&
        MSRMethodMatches(class_getInstanceMethod(cls, @selector(startSystemRecordingWithMicrophoneEnabled:handler:)), "v", 4, start) &&
        MSRMethodMatches(class_getInstanceMethod(cls, @selector(stopSystemRecordingWithURLHandler:)), "v", 3, stop);
}

@interface MiniSightRecordingResult ()
@property(nonatomic) uint64_t epoch;
@property(nonatomic) BOOL success;
@property(nonatomic) MiniSightRecorderIssue issue;
@property(nonatomic) MiniSightRecorderSaveStage saveStage;
@property(nonatomic) NSInteger systemErrorCode;
@property(nonatomic, copy, nullable) NSURL *fileURL;
@property(nonatomic) uint64_t byteCount;
@property(nonatomic) NSTimeInterval duration;
@end
@implementation MiniSightRecordingResult
@end

typedef void (^MSRFileCompletion)(BOOL, NSURL *, uint64_t, double, MiniSightRecorderSaveStage);
@interface MSRFileJob : NSObject {
    atomic_bool _cancelled;
    dispatch_queue_t _queue;
    MSRFileCompletion _completion;
    NSURL *_temporaryURL, *_finalURL;
    NSString *_temporaryName, *_finalName;
    AVURLAsset *_asset;
    int _dirFD;
    BOOL _done;
    bool _published;
    uint64_t _bytes;
}
@property(nonatomic) uint64_t epoch;
- (instancetype)initWithQueue:(dispatch_queue_t)queue epoch:(uint64_t)epoch;
- (void)start:(NSURL *)source directory:(NSURL *)directory completion:(MSRFileCompletion)completion;
- (void)cancel;
@end

@implementation MSRFileJob
- (instancetype)initWithQueue:(dispatch_queue_t)queue epoch:(uint64_t)epoch {
    if ((self = [super init])) {
        _queue = queue; _epoch = epoch; _dirFD = -1;
        atomic_init(&_cancelled, false);
    }
    return self;
}
- (void)finish:(BOOL)verified duration:(double)duration stage:(MiniSightRecorderSaveStage)stage {
    if (_done) return;
    _done = YES;
    verified = verified && !atomic_load(&_cancelled) && isfinite(duration) && duration > 0.0;
    if (verified) {
        stage = MiniSightRecorderSaveStagePublish;
        verified = MSRFilePublish(_dirFD, _temporaryName.UTF8String,
            _finalName.UTF8String, _bytes, &_cancelled, &_published);
        if (!verified) stage = MiniSightRecorderSaveStagePublish;
    } else if (atomic_load(&_cancelled)) {
        stage = MiniSightRecorderSaveStageUnknown;
    }
    MSRFileCleanup(_dirFD, _temporaryName.UTF8String, _finalName.UTF8String,
                   _published && !verified);
    _dirFD = -1;
    _asset = nil;
    MSRFileCompletion completion = _completion;
    _completion = nil;
    if (completion) completion(verified, verified ? _finalURL : nil,
                               verified ? _bytes : 0, verified ? duration : 0.0,
                               verified ? MiniSightRecorderSaveStageNone : stage);
}
- (void)start:(NSURL *)source directory:(NSURL *)directory completion:(MSRFileCompletion)completion {
    _completion = [completion copy];
    dispatch_async(_queue, ^{
        @autoreleasepool {
            if (atomic_load(&self->_cancelled) || !source.isFileURL || !directory.isFileURL) {
                [self finish:NO duration:0 stage:MiniSightRecorderSaveStageSourceMissing]; return;
            }
            NSError *error = nil;
            if (![[NSFileManager defaultManager] createDirectoryAtURL:directory
                    withIntermediateDirectories:YES attributes:nil error:&error]) {
                [self finish:NO duration:0 stage:MiniSightRecorderSaveStageDestination]; return;
            }
            NSString *name = [NSString stringWithFormat:@"rec-%@", NSUUID.UUID.UUIDString];
            self->_temporaryName = [name stringByAppendingString:@".partial.mp4"];
            self->_finalName = [name stringByAppendingString:@".mp4"];
            self->_temporaryURL = [directory URLByAppendingPathComponent:self->_temporaryName];
            self->_finalURL = [directory URLByAppendingPathComponent:self->_finalName];
            if (!MSRFileCopy(source.fileSystemRepresentation, directory.fileSystemRepresentation,
                    self->_temporaryName.UTF8String, &self->_cancelled,
                    &self->_bytes, &self->_dirFD)) {
                [self finish:NO duration:0 stage:MiniSightRecorderSaveStageCopy]; return;
            }
            self->_asset = [AVURLAsset URLAssetWithURL:self->_temporaryURL options:nil];
            AVURLAsset *asset = self->_asset;
            [asset loadValuesAsynchronouslyForKeys:@[@"duration", @"tracks", @"playable"] completionHandler:^{
                dispatch_async(self->_queue, ^{
                    if (self->_done) return;
                    BOOL valid = !atomic_load(&self->_cancelled);
                    for (NSString *key in @[@"duration", @"tracks", @"playable"])
                        valid &= [asset statusOfValueForKey:key error:nil] == AVKeyValueStatusLoaded;
                    double seconds = 0.0;
                    if (valid) {
                        CMTime time = asset.duration;
                        valid = CMTIME_IS_NUMERIC(time) && asset.playable &&
                            [asset tracksWithMediaType:AVMediaTypeVideo].count > 0;
                        if (valid) seconds = CMTimeGetSeconds(time);
                    }
                    [self finish:valid duration:seconds stage:MiniSightRecorderSaveStageInspect];
                });
            }];
        }
    });
}
- (void)cancel {
    atomic_store(&_cancelled, true); /* Visible even while the serial queue copies. */
    dispatch_async(_queue, ^{
        if (self->_done) return;
        [self->_asset cancelLoading];
        [self finish:NO duration:0 stage:MiniSightRecorderSaveStageUnknown];
    });
}
@end

static char MSRRecordingObservation;
@interface MiniSightRecorder () {
    MSRMachine _machine;
    id<MSRSystemBackend> _system;
    UIScreen *_screen;
    NSURL *_outputDirectory, *_sessionDirectory;
    dispatch_queue_t _fileQueue;
    dispatch_source_t _timer;
    MSRFileJob *_fileJob;
    MiniSightRecordingResult *_lastResult;
    atomic_uint_fast64_t _recordingDrops;
    uint64_t _dropBaseline;
    NSInteger _systemErrorCode;
    BOOL _observing, _prepared, _publishedState;
    dispatch_block_t _saveTimeoutWork;
    MiniSightRecorderState _lastState;
    MiniSightRecorderSource _lastOwner;
    MiniSightRecorderIssue _lastIssue;
    MiniSightRecorderSaveStage _saveStage;
    BOOL _lastQuarantine;
}
- (instancetype)initPrivate;
- (void)msrPrepare;
- (MSRSnapshot)msrSnapshot;
- (void)msrApply:(MSRAction)action file:(NSURL *)file bytes:(uint64_t)bytes duration:(double)duration;
- (void)msrStartBackend;
- (void)msrStopBackend;
- (void)msrSaveURL:(NSURL *)url;
- (void)msrUpdateTimer;
@end

@implementation MiniSightRecorder
+ (instancetype)sharedRecorder {
    static MiniSightRecorder *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] initPrivate]; });
    return instance;
}
- (instancetype)initPrivate {
    if ((self = [super init])) {
        MSRInit(&_machine); atomic_init(&_recordingDrops, 0);
        dispatch_queue_attr_t fileAttributes = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        _fileQueue = dispatch_queue_create("com.openminis.minisight.recorder.files", fileAttributes);
        if ([NSThread isMainThread]) [self msrPrepare];
        else dispatch_async(dispatch_get_main_queue(), ^{ [self msrPrepare]; });
    }
    return self;
}
- (void)msrPrepare {
    if (_prepared) return;
    _prepared = YES;
    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
    if (os.majorVersion != 15 || os.minorVersion != 5 ||
        ![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    const char *two[] = { "@", ":" };
    Class cls = [RPScreenRecorder class]; /* Explicit ReplayKit link; not an App recorder call. */
    if (!MSRBackendABI(cls) ||
        !MSRMethodMatches(class_getClassMethod(cls, @selector(sharedRecorder)), "@", 2, two) ||
        !MSRMethodMatches(class_getClassMethod([UIScreen class], @selector(mainScreen)), "@", 2, two) ||
        !MSRMethodMatches(class_getInstanceMethod([UIScreen class], @selector(isCaptured)), "B", 2, two)) return;
    @try {
        if (![(Class)cls automaticallyNotifiesObserversForKey:@"recording"]) return;
        _system = [(Class<MSRSystemBackend>)cls sharedRecorder];
        if (![(id)_system isKindOfClass:cls] || !MSRBackendABI(object_getClass(_system))) {
            _system = nil; return;
        }
        _screen = UIScreen.mainScreen;
        if (!_screen) { _system = nil; return; }
        /* iOS 15 updateStateWithActive:error: uses setRecording:. Passive KVO catches
           a false->true replacement even between polls; never overwrite CC delegates. */
        [(id)_system addObserver:self forKeyPath:@"recording"
            options:NSKeyValueObservingOptionNew context:&MSRRecordingObservation];
        _observing = YES;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(msrCaptureChanged:)
            name:UIScreenCapturedDidChangeNotification object:_screen];
    } @catch (__unused NSException *exception) {
        if (_observing) {
            @try { [(id)_system removeObserver:self forKeyPath:@"recording" context:&MSRRecordingObservation]; }
            @catch (__unused NSException *ignored) {}
        }
        _observing = NO; _system = nil; _screen = nil;
    }
}
- (void)dealloc {
    if (_timer) dispatch_source_cancel(_timer);
    [_fileJob cancel];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_observing) {
        @try { [(id)_system removeObserver:self forKeyPath:@"recording" context:&MSRRecordingObservation]; }
        @catch (__unused NSException *exception) {}
    }
}
- (MSRSnapshot)msrSnapshot {
    MSRSnapshot s = {0};
    s.continuous = atomic_load(&_recordingDrops) == _dropBaseline;
    s.destination = _outputDirectory.isFileURL && [_outputDirectory.path hasPrefix:@"/"];
    if (!_system || !_screen || !_observing || !MSRBackendABI(object_getClass(_system))) return s;
    @try {
        s.captured = _screen.isCaptured;
        s.recording = [_system isRecording]; s.system = [_system systemRecording];
        s.available = [_system isAvailable] && [_system screenRecordingAllowed] &&
                      [_system screenRecordingSupportedOnDevice];
        s.valid = true;
    } @catch (__unused NSException *exception) { s.valid = false; }
    return s;
}
- (MiniSightRecorderState)state { return _machine.state; }
- (MiniSightRecorderSource)owner { return _machine.owner; }
- (MiniSightRecorderIssue)issue { return _machine.issue; }
- (BOOL)isQuarantined {
    return _machine.state == MiniSightRecorderError && (_machine.pendingStart || _machine.pendingStop);
}
- (BOOL)backendAvailable {
    if (![NSThread isMainThread]) return NO;
    MSRSnapshot s = [self msrSnapshot];
    return s.valid && s.available && s.destination && !s.recording && !s.captured;
}
- (MiniSightRecordingResult *)lastResult { return _lastResult; }
- (void)msrCaptureChanged:(NSNotification *)note {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self msrCaptureChanged:note]; }); return;
    }
    [self msrApply:MSRObserve(&_machine, [self msrSnapshot]) file:nil bytes:0 duration:0];
}
- (void)observeValueForKeyPath:(NSString *)key ofObject:(id)object
                       change:(NSDictionary *)change context:(void *)context {
    if (context != &MSRRecordingObservation) {
        [super observeValueForKeyPath:key ofObject:object change:change context:context]; return;
    }
    id value = change[NSKeyValueChangeNewKey];
    if (![value isKindOfClass:[NSNumber class]] || ![value boolValue])
        atomic_fetch_add(&_recordingDrops, 1); /* Includes off-main notifications immediately. */
    if ([NSThread isMainThread]) [self msrCaptureChanged:nil];
    else dispatch_async(dispatch_get_main_queue(), ^{ [self msrCaptureChanged:nil]; });
}
- (void)msrApply:(MSRAction)action file:(NSURL *)file bytes:(uint64_t)bytes duration:(double)duration {
    BOOL quarantined = self.isQuarantined;
    if (!_publishedState || _lastState != _machine.state || _lastOwner != _machine.owner ||
        _lastIssue != _machine.issue || _lastQuarantine != quarantined) {
        _publishedState = YES;
        _lastState = _machine.state; _lastOwner = _machine.owner;
        _lastIssue = _machine.issue; _lastQuarantine = quarantined;
        MiniSightRecorderStateHandler handler = [self.stateHandler copy];
        MiniSightRecorderState state = _machine.state;
        MiniSightRecorderSource owner = _machine.owner;
        MiniSightRecorderIssue issue = _machine.issue;
        if (handler) dispatch_async(dispatch_get_main_queue(), ^{ handler(state, owner, issue, quarantined); });
    }
    if (action & MSRReport) {
        MiniSightRecordingResult *result = [MiniSightRecordingResult new];
        result.epoch = _machine.epoch; result.issue = _machine.issue;
        result.saveStage = _machine.issue == MiniSightRecorderIssueSaveFailed
            ? _saveStage : MiniSightRecorderSaveStageNone;
        result.systemErrorCode = (_machine.issue == MiniSightRecorderIssueStartFailed ||
            _machine.issue == MiniSightRecorderIssueStopFailed) ? _systemErrorCode : 0;
        result.success = _machine.state == MiniSightRecorderIdle && file.isFileURL &&
                         bytes >= 1024 && isfinite(duration) && duration > 0.0;
        if (result.success) { result.fileURL = file; result.byteCount = bytes; result.duration = duration; }
        _lastResult = result;
        MiniSightRecorderResultHandler handler = [self.resultHandler copy];
        if (handler) dispatch_async(dispatch_get_main_queue(), ^{ handler(result); });
    }
    if (action & MSRCancelSave) {
        [_fileJob cancel]; _fileJob = nil;
        if (_saveTimeoutWork) { dispatch_block_cancel(_saveTimeoutWork); _saveTimeoutWork = nil; }
    }
    if (action & MSRStart) [self msrStartBackend];
    if (action & MSRStop) [self msrStopBackend];
    if (action & MSRSave) [self msrSaveURL:file];
    [self msrUpdateTimer];
}
- (void)msrStartBackend {
    uint64_t epoch = _machine.epoch;
    _systemErrorCode = 0;
    _dropBaseline = atomic_load(&_recordingDrops);
    MSRSnapshot s = [self msrSnapshot];
    if (!s.valid || !s.available || !s.destination || s.recording || s.captured) {
        _machine.pendingStart = false;
        MiniSightRecorderIssue issue = (s.recording || s.captured) ? MiniSightRecorderIssueExternalSession :
            (!s.destination ? MiniSightRecorderIssueDestination : MiniSightRecorderIssueUnavailable);
        [self msrApply:MSRFail(&_machine, issue) file:nil bytes:0 duration:0]; return;
    }
    _sessionDirectory = [_outputDirectory copy];
    @try {
        /* The 15.0 implementation reads isMicrophoneEnabled internally, not merely
           the scalar argument. Explicitly disable mic before OUR accepted start. */
        [_system setMicrophoneEnabled:NO];
        [_system startSystemRecordingWithMicrophoneEnabled:NO handler:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (epoch != self->_machine.epoch || !self->_machine.pendingStart) return;
                self->_systemErrorCode = [error isKindOfClass:[NSError class]] ? error.code : 0;
                MSRAction a = MSRStartReply(&self->_machine, epoch, error == nil,
                                           MSRNow(), [self msrSnapshot]);
                [self msrApply:a file:nil bytes:0 duration:0];
            });
        }];
    } @catch (__unused NSException *exception) {
        [self msrApply:MSRStartReply(&_machine, epoch, false, MSRNow(), [self msrSnapshot])
                   file:nil bytes:0 duration:0];
    }
}
- (void)msrStopBackend {
    uint64_t epoch = _machine.epoch;
    MSRSnapshot s = [self msrSnapshot];
    if (!_machine.owned || !s.valid || !s.continuous || !s.recording || !s.system ||
        _machine.interrupted || (_machine.sawCapture && !s.captured)) {
        _machine.pendingStop = false; _machine.owned = false;
        [self msrApply:MSRFail(&_machine, MiniSightRecorderIssueOwnershipLost)
                   file:nil bytes:0 duration:0]; return; /* No global stop call. */
    }
    @try {
        [_system stopSystemRecordingWithURLHandler:^(NSURL *url, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (epoch != self->_machine.epoch || !self->_machine.pendingStop) return;
                self->_systemErrorCode = [error isKindOfClass:[NSError class]] ? error.code : 0;
                BOOL hasURL = [url isKindOfClass:[NSURL class]] && url.isFileURL;
                MSRAction a = MSRStopReply(&self->_machine, epoch, error == nil, hasURL, MSRNow());
                [self msrApply:a file:hasURL ? url : nil bytes:0 duration:0];
            });
        }];
    } @catch (__unused NSException *exception) {
        _systemErrorCode = 0;
        [self msrApply:MSRStopReply(&_machine, epoch, false, false, MSRNow())
                   file:nil bytes:0 duration:0];
    }
}
- (void)msrSaveURL:(NSURL *)url {
    uint64_t epoch = _machine.epoch;
    if (!url.isFileURL || !_sessionDirectory.isFileURL) {
        [self msrApply:MSRSaved(&_machine, epoch, false, MSRNow()) file:nil bytes:0 duration:0]; return;
    }
    if (_saveTimeoutWork) dispatch_block_cancel(_saveTimeoutWork);
    __weak MiniSightRecorder *weakSelf = self;
    _saveTimeoutWork = dispatch_block_create(0, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            MiniSightRecorder *strongSelf = weakSelf;
            if (!strongSelf || strongSelf->_machine.epoch != epoch || !strongSelf->_machine.saving) return;
            [strongSelf msrApply:MSRTick(&strongSelf->_machine, MSRNow(), [strongSelf msrSnapshot])
                             file:nil bytes:0 duration:0];
        });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), _saveTimeoutWork);
    _fileJob = [[MSRFileJob alloc] initWithQueue:_fileQueue epoch:epoch];
    _saveStage = MiniSightRecorderSaveStageNone;
    dispatch_queue_t queue = _fileQueue;
    [_fileJob start:url directory:_sessionDirectory completion:^(BOOL verified, NSURL *file, uint64_t bytes, double duration, MiniSightRecorderSaveStage stage) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MiniSightRecorder *strongSelf = weakSelf;
            if (!strongSelf) {
                if (file) dispatch_async(queue, ^{ [NSFileManager.defaultManager removeItemAtURL:file error:nil]; });
                return;
            }
            if (strongSelf->_fileJob.epoch == epoch) {
                strongSelf->_fileJob = nil;
                if (strongSelf->_saveTimeoutWork) {
                    dispatch_block_cancel(strongSelf->_saveTimeoutWork);
                    strongSelf->_saveTimeoutWork = nil;
                }
            }
            if (!verified) strongSelf->_saveStage = stage;
            MSRAction a = MSRSaved(&strongSelf->_machine, epoch, verified, MSRNow());
            BOOL accepted = (a & MSRReport) && strongSelf->_machine.state == MiniSightRecorderIdle;
            /* A stale, cancelled or expired job can never announce success. Its unique
               published file is cleaned off-main, without touching any prior recording. */
            if (file && !accepted)
                dispatch_async(queue, ^{ [NSFileManager.defaultManager removeItemAtURL:file error:nil]; });
            [strongSelf msrApply:a file:accepted ? file : nil bytes:accepted ? bytes : 0
                         duration:accepted ? duration : 0];
        });
    }];
}
- (void)msrUpdateTimer {
    /* Saving is pure background file work; do not poll ReplayKit on main every 250 ms. */
    BOOL needsTimer = (_machine.pendingStart || _machine.pendingStop || _machine.owned) &&
                      _machine.state != MiniSightRecorderError;
    if (!needsTimer) {
        if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
        return;
    }
    if (_timer) return;
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(0.25 * NSEC_PER_SEC), (uint64_t)(0.05 * NSEC_PER_SEC));
    __weak MiniSightRecorder *weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{
        MiniSightRecorder *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf msrApply:MSRTick(&strongSelf->_machine, MSRNow(), [strongSelf msrSnapshot])
                         file:nil bytes:0 duration:0];
    });
    dispatch_resume(_timer);
}
- (void)setAutomaticEnabled:(BOOL)automatic manualEnabled:(BOOL)manual {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self setAutomaticEnabled:automatic manualEnabled:manual]; });
        return;
    }
    [self msrApply:MSRConfigure(&_machine, automatic, manual, MSRNow(), [self msrSnapshot])
               file:nil bytes:0 duration:0];
}
- (void)configureAutomaticEnabled:(BOOL)automatic manualEnabled:(BOOL)manual outputDirectory:(NSURL *)directory {
    if (![NSThread isMainThread]) {
        NSURL *snapshot = [directory copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self configureAutomaticEnabled:automatic manualEnabled:manual outputDirectory:snapshot];
        }); return;
    }
    _outputDirectory = directory.isFileURL && [directory.path hasPrefix:@"/"] ? [directory copy] : nil;
    [self msrApply:MSRConfigure(&_machine, automatic, manual, MSRNow(), [self msrSnapshot])
               file:nil bytes:0 duration:0];
}
- (void)setAutomaticActive:(BOOL)active {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self setAutomaticActive:active]; }); return;
    }
    [self msrApply:MSRAutomaticActive(&_machine, active, MSRNow(), [self msrSnapshot])
               file:nil bytes:0 duration:0];
}
- (void)startWithSource:(MiniSightRecorderSource)source {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self startWithSource:source]; }); return;
    }
    [self msrApply:MSRBegin(&_machine, source, MSRNow(), [self msrSnapshot]) file:nil bytes:0 duration:0];
}
- (void)stopWithSource:(MiniSightRecorderSource)source {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self stopWithSource:source]; }); return;
    }
    [self msrApply:MSRRequestStop(&_machine, source, MSRNow(), [self msrSnapshot]) file:nil bytes:0 duration:0];
}
- (void)toggle {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self toggle]; }); return;
    }
    [self msrApply:MSRToggle(&_machine, MSRNow(), [self msrSnapshot]) file:nil bytes:0 duration:0];
}
- (void)cancel {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self cancel]; }); return;
    }
    [self msrApply:MSRCancel(&_machine, MSRNow(), [self msrSnapshot]) file:nil bytes:0 duration:0];
}
@end
