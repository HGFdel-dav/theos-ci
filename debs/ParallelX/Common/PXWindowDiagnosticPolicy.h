#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <math.h>

enum { PXWMDiagnosticRecentLimit=256, PXWMDiagnosticIncidentLimit=4,
       PXWMDiagnosticBeforeLimit=12, PXWMDiagnosticAfterLimit=12,
       PXWMDiagnosticReasonLimit=24, PXWMDiagnosticArchiveBytes=512*1024 };
typedef enum {
    PXWMReasonNone=0, PXWMReasonInactive, PXWMReasonRestoring, PXWMReasonBinding,
    PXWMReasonGeometry, PXWMReasonDisabled, PXWMReasonEpoch, PXWMReasonGeneration,
    PXWMReasonIdentity, PXWMReasonDirection, PXWMReasonReference, PXWMReasonTransient,
    PXWMReasonQueued, PXWMReasonSyncing, PXWMReasonNoLayout, PXWMReasonResize,
    PXWMReasonNoHost, PXWMReasonHostTree, PXWMReasonNoSourceMethod,
    PXWMReasonSourceException, PXWMReasonSourceSize, PXWMReasonConvertedRect,
    PXWMReasonBudget, PXWMReasonChangedTarget, PXWMReasonNoCard,
    PXWMReasonCancelled, PXWMReasonSavePending, PXWMReasonNotMeasured,
    PXWMReasonDiagnosticLimit, PXWMReasonInteracting
} PXWMDiagnosticReason;
typedef enum { PXWMLaneArm=0,PXWMLaneReady,PXWMLaneContent,PXWMLaneQueue,
    PXWMLaneCallback,PXWMLaneReconcile,PXWMLaneFirstFrame,PXWMLaneCount } PXWMDiagnosticLane;
typedef struct { uint64_t generation; uint64_t seen[PXWMLaneCount]; unsigned count; bool limitReported; } PXWMDiagnosticGate;
/* A transition is recorded once per lane/reason/generation. Normal per-frame
 * fast paths never allocate a dictionary or write a diagnostic on their own. */
static inline bool PXWMDiagnosticShouldRecord(PXWMDiagnosticGate *gate,
        uint64_t generation,unsigned lane,unsigned reason) {
    if (!gate || lane>=PXWMLaneCount || !reason || reason>=63) return false;
    if (gate->generation!=generation) *gate=(PXWMDiagnosticGate){.generation=generation};
    uint64_t bit=UINT64_C(1)<<reason;
    if ((gate->seen[lane]&bit) || gate->count>=PXWMDiagnosticReasonLimit) return false;
    gate->seen[lane]|=bit; gate->count++; return true;
}
static inline bool PXWMDiagnosticMayAppendAfter(unsigned count, double started, double now) {
    return count<PXWMDiagnosticAfterLimit && isfinite(started) && isfinite(now) &&
           now>=started && now-started<=120;
}
typedef enum { PXWMDiagnosticUnknown=0,PXWMDiagnosticVerified=1,
    PXWMDiagnosticLockFailed=2,PXWMDiagnosticRecentReadFailed=3,
    PXWMDiagnosticArchiveReadFailed=4,PXWMDiagnosticRecentWriteFailed=5,
    PXWMDiagnosticArchiveWriteFailed=6,PXWMDiagnosticArchiveSizeFailed=7,
    PXWMDiagnosticRecentReadbackFailed=8,PXWMDiagnosticArchiveReadbackFailed=9 } PXWMDiagnosticIOState;
static inline uint64_t PXWMDiagnosticPackStatus(unsigned current,unsigned lastFailure,
                                               unsigned errorCode,unsigned failures) {
    return (uint64_t)(current&255)|((uint64_t)(lastFailure&255)<<8)|
           ((uint64_t)(errorCode&65535)<<16)|((uint64_t)(failures>65535?65535:failures)<<32);
}
