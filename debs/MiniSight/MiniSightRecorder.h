#ifndef MINISIGHT_RECORDER_H
#define MINISIGHT_RECORDER_H
#include "tools/recorder/MiniSightRecorderCore.h"
#ifdef __OBJC__
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

/* Stage attached only to SaveFailed; identifies where artifact handling stopped. */
typedef NS_ENUM(NSInteger, MiniSightRecorderSaveStage) {
    MiniSightRecorderSaveStageNone = 0,
    MiniSightRecorderSaveStageDestination,
    MiniSightRecorderSaveStageSourceMissing,
    MiniSightRecorderSaveStageCopy,
    MiniSightRecorderSaveStageInspect,
    MiniSightRecorderSaveStagePublish,
    MiniSightRecorderSaveStageUnknown
};

/* Every observation/result and every property access belongs to the main thread.
   Commands called off-main are enqueued onto main. No implicit external adoption. */
@interface MiniSightRecordingResult : NSObject
@property(nonatomic, readonly) uint64_t epoch;
@property(nonatomic, readonly) BOOL success;
@property(nonatomic, readonly) MiniSightRecorderIssue issue;
@property(nonatomic, readonly) MiniSightRecorderSaveStage saveStage;
@property(nonatomic, readonly) NSInteger systemErrorCode; /* Numeric only; no private text. */
@property(nonatomic, readonly, copy, nullable) NSURL *fileURL; /* Durable, verified App artifact. */
@property(nonatomic, readonly) uint64_t byteCount;
@property(nonatomic, readonly) NSTimeInterval duration;
@end

typedef void (^MiniSightRecorderStateHandler)(MiniSightRecorderState state,
    MiniSightRecorderSource owner, MiniSightRecorderIssue issue, BOOL quarantined);
typedef void (^MiniSightRecorderResultHandler)(MiniSightRecordingResult *result);

@interface MiniSightRecorder : NSObject
+ (instancetype)sharedRecorder;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@property(nonatomic, readonly) MiniSightRecorderState state;
@property(nonatomic, readonly) MiniSightRecorderSource owner;
@property(nonatomic, readonly) MiniSightRecorderIssue issue;
@property(nonatomic, readonly, getter=isQuarantined) BOOL quarantined;
@property(nonatomic, readonly) BOOL backendAvailable;
@property(nonatomic, readonly, nullable) MiniSightRecordingResult *lastResult;
@property(nonatomic, copy, nullable) MiniSightRecorderStateHandler stateHandler;
@property(nonatomic, copy, nullable) MiniSightRecorderResultHandler resultHandler;

/* Defaults: both flags OFF, destination nil. Caller supplies a trusted absolute file
   URL of Documents/MiniSight/recordings. There is no guessed-container fallback.
   New directory is a main-thread snapshot; an active session keeps its start snapshot.
   Disabling a source drains only the session owned by that source. */
/* Apply source switches immediately, before asynchronous directory preparation.
   This never starts recording, and never alters another source's owner. */
- (void)setAutomaticEnabled:(BOOL)automaticEnabled manualEnabled:(BOOL)manualEnabled;
- (void)configureAutomaticEnabled:(BOOL)automaticEnabled
                   manualEnabled:(BOOL)manualEnabled
                 outputDirectory:(nullable NSURL *)directory;
/* Agent notifications use this edge-triggered API, NOT toggle. Repeated started/
   stopped/settings messages cannot restart a limited/failed/manual session. */
- (void)setAutomaticActive:(BOOL)active;
- (void)startWithSource:(MiniSightRecorderSource)source;
- (void)stopWithSource:(MiniSightRecorderSource)source;
- (void)toggle; /* Manual long press; 350 ms debounce. */
- (void)cancel; /* Discard own pending/active/save result; never stops a foreign one. */
@end
NS_ASSUME_NONNULL_END
#endif
#endif
