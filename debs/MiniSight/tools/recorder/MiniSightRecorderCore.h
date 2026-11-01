#ifndef MINISIGHT_RECORDER_CORE_H
#define MINISIGHT_RECORDER_CORE_H
/* Shared production reducer. Pure C: no Foundation, iOS code or fake backend. */
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

typedef enum {
    MiniSightRecorderIdle, MiniSightRecorderStarting, MiniSightRecorderRecording,
    MiniSightRecorderStopping, MiniSightRecorderSaving, MiniSightRecorderError
} MiniSightRecorderState;
typedef enum {
    MiniSightRecorderSourceNone, MiniSightRecorderSourceManual,
    MiniSightRecorderSourceAutomatic
} MiniSightRecorderSource;
typedef enum {
    MiniSightRecorderIssueNone, MiniSightRecorderIssueUnavailable,
    MiniSightRecorderIssueDisabled, MiniSightRecorderIssueExternalSession,
    MiniSightRecorderIssueDestination, MiniSightRecorderIssueStartFailed,
    MiniSightRecorderIssueStartTimeout, MiniSightRecorderIssueOwnershipLost,
    MiniSightRecorderIssueStopFailed, MiniSightRecorderIssueStopTimeout,
    MiniSightRecorderIssueMissingArtifact, MiniSightRecorderIssueSaveFailed,
    MiniSightRecorderIssueSaveTimeout, MiniSightRecorderIssueCancelled
} MiniSightRecorderIssue;
typedef unsigned MSRAction;
enum { MSRNoAction = 0, MSRStart = 1, MSRStop = 2, MSRSave = 4,
       MSRReport = 8, MSRCancelSave = 16 };
typedef struct {
    bool valid, available, recording, system, captured, destination, continuous;
} MSRSnapshot;
typedef struct {
    MiniSightRecorderState state;
    MiniSightRecorderSource owner;
    MiniSightRecorderIssue issue;
    uint64_t epoch;
    bool automaticEnabled, manualEnabled, automaticActive;
    bool pendingStart, pendingStop, owned, saving, stopWanted, cancelled;
    bool reported, interrupted, sawCapture, sawRecording;
    double requestedAt, deadline, lastToggle;
} MSRMachine;

static inline void MSRInit(MSRMachine *m) {
    memset(m, 0, sizeof(*m));
    m->lastToggle = -1.0e30;
}
static inline bool MSRBusy(const MSRMachine *m) {
    return m->pendingStart || m->pendingStop || m->owned || m->saving;
}
static inline MSRAction MSRReportOnce(MSRMachine *m) {
    if (m->reported) return MSRNoAction;
    m->reported = true;
    return MSRReport;
}
static inline MSRAction MSRFail(MSRMachine *m, MiniSightRecorderIssue issue) {
    m->state = MiniSightRecorderError;
    if (!m->reported) m->issue = issue;
    if (!MSRBusy(m)) m->owner = MiniSightRecorderSourceNone;
    return MSRReportOnce(m);
}
static inline MSRAction MSRObserve(MSRMachine *m, MSRSnapshot s) {
    if (!(m->pendingStart || m->owned) || m->pendingStop) return MSRNoAction;
    if (!s.valid || !s.continuous || (m->sawRecording && !s.recording) ||
        (m->sawCapture && !s.captured)) m->interrupted = true;
    m->sawRecording |= s.recording;
    m->sawCapture |= s.captured;
    if (m->owned && (m->interrupted || !s.recording || !s.system)) {
        m->owned = false; /* Never adopt a replacement session. */
        return MSRFail(m, MiniSightRecorderIssueOwnershipLost);
    }
    return MSRNoAction;
}
static inline MSRAction MSRRequestStop(MSRMachine *m,
        MiniSightRecorderSource source, double now, MSRSnapshot s) {
    if ((source != MiniSightRecorderSourceManual && source != MiniSightRecorderSourceAutomatic) ||
        source != m->owner) return MSRNoAction;
    if (m->pendingStart) {
        m->stopWanted = true;
        /* A normal stop during start is not cancellation: drain the accepted
           session and save any valid short clip. Only MSRCancel/timeouts discard. */
        return MSRNoAction;
    }
    if (!m->owned || m->pendingStop || m->saving) return MSRNoAction;
    MSRAction observed = MSRObserve(m, s);
    if (!m->owned) return observed;
    m->pendingStop = true;
    m->state = MiniSightRecorderStopping;
    m->deadline = now + 30.0;
    return MSRStop;
}
static inline MSRAction MSRBegin(MSRMachine *m,
        MiniSightRecorderSource source, double now, MSRSnapshot s) {
    if (source != MiniSightRecorderSourceManual &&
        source != MiniSightRecorderSourceAutomatic) return MSRNoAction;
    if (MSRBusy(m)) {
        /* Manual long-press never adopts or stops an automatic MCP session. */
        return MSRNoAction;
    }
    bool ae = m->automaticEnabled, me = m->manualEnabled, aa = m->automaticActive;
    uint64_t epoch = m->epoch + 1;
    double last = m->lastToggle;
    MSRInit(m);
    m->automaticEnabled = ae; m->manualEnabled = me; m->automaticActive = aa;
    m->epoch = epoch; m->lastToggle = last;
    if ((source == MiniSightRecorderSourceAutomatic && !ae) ||
        (source == MiniSightRecorderSourceManual && !me))
        return MSRFail(m, MiniSightRecorderIssueDisabled);
    if (!s.valid) return MSRFail(m, MiniSightRecorderIssueUnavailable);
    if (s.recording || s.captured) /* system is a mode flag, set BEFORE start succeeds. */
        return MSRFail(m, MiniSightRecorderIssueExternalSession);
    if (!s.available) return MSRFail(m, MiniSightRecorderIssueUnavailable);
    if (!s.destination) return MSRFail(m, MiniSightRecorderIssueDestination);
    m->owner = source; m->pendingStart = true;
    m->state = MiniSightRecorderStarting; m->requestedAt = now;
    m->deadline = now + 15.0;
    return MSRStart;
}
static inline MSRAction MSRStartReply(MSRMachine *m, uint64_t epoch,
        bool accepted, double now, MSRSnapshot s) {
    if (epoch != m->epoch || !m->pendingStart) return MSRNoAction;
    MSRAction a = MSRNoAction;
    if (now >= m->deadline && !m->reported) {
        m->stopWanted = true; m->cancelled = true;
        a = MSRFail(m, MiniSightRecorderIssueStartTimeout);
    }
    MSRObserve(m, s);
    m->pendingStart = false;
    if (!accepted) return a | MSRFail(m, MiniSightRecorderIssueStartFailed);
    if (m->interrupted || !s.valid || !s.continuous || !s.recording || !s.system)
        return a | MSRFail(m, MiniSightRecorderIssueOwnershipLost);
    m->owned = true;
    m->state = MiniSightRecorderRecording;
    if (m->stopWanted || m->reported || now - m->requestedAt >= 600.0)
        return a | MSRRequestStop(m, m->owner, now, s);
    return a;
}
static inline MSRAction MSRStopReply(MSRMachine *m, uint64_t epoch,
        bool stopped, bool hasURL, double now) {
    if (epoch != m->epoch || !m->pendingStop) return MSRNoAction;
    MSRAction a = MSRNoAction;
    if (now >= m->deadline && !m->reported) a = MSRFail(m, MiniSightRecorderIssueStopTimeout);
    m->pendingStop = false; m->owned = false;
    m->owner = MiniSightRecorderSourceNone;
    if (m->reported) { m->state = MiniSightRecorderError; return a; }
    if (!stopped) return MSRFail(m, MiniSightRecorderIssueStopFailed);
    if (m->cancelled) return MSRFail(m, MiniSightRecorderIssueCancelled);
    if (!hasURL) return MSRFail(m, MiniSightRecorderIssueMissingArtifact);
    m->saving = true; m->state = MiniSightRecorderSaving;
    m->deadline = now + 60.0;
    return MSRSave; /* A stop completion is NOT a save completion. */
}
static inline MSRAction MSRSaved(MSRMachine *m, uint64_t epoch, bool verified, double now) {
    if (epoch != m->epoch || !m->saving) return MSRNoAction;
    m->saving = false;
    if (now >= m->deadline)
        return MSRCancelSave | MSRFail(m, MiniSightRecorderIssueSaveTimeout);
    if (!verified) return MSRFail(m, MiniSightRecorderIssueSaveFailed);
    m->state = MiniSightRecorderIdle; m->issue = MiniSightRecorderIssueNone;
    return MSRReportOnce(m); /* The only successful result in the reducer. */
}
static inline MSRAction MSRTick(MSRMachine *m, double now, MSRSnapshot s) {
    MSRAction a = MSRObserve(m, s);
    if (m->pendingStart && now >= m->deadline && !m->reported) {
        m->stopWanted = true; m->cancelled = true;
        return a | MSRFail(m, MiniSightRecorderIssueStartTimeout);
        /* Keep pendingStart quarantined: a late success must still be drained. */
    }
    if (m->pendingStop && now >= m->deadline && m->state != MiniSightRecorderError)
        return a | MSRFail(m, MiniSightRecorderIssueStopTimeout);
    if (m->saving && now >= m->deadline) {
        m->saving = false;
        return a | MSRCancelSave | MSRFail(m, MiniSightRecorderIssueSaveTimeout);
    }
    if (m->owned && !m->pendingStop && now - m->requestedAt >= 600.0)
        return a | MSRRequestStop(m, m->owner, now, s);
    return a;
}
static inline MSRAction MSRConfigure(MSRMachine *m, bool automatic,
        bool manual, double now, MSRSnapshot s) {
    m->automaticEnabled = automatic; m->manualEnabled = manual;
    if ((m->owner == MiniSightRecorderSourceAutomatic && !automatic) ||
        (m->owner == MiniSightRecorderSourceManual && !manual))
        return MSRRequestStop(m, m->owner, now, s);
    /* Settings alone never start capture from an old activity snapshot. */
    return MSRNoAction;
}
static inline MSRAction MSRAutomaticActive(MSRMachine *m, bool active,
        double now, MSRSnapshot s) {
    if (m->automaticActive == active) return MSRNoAction; /* Edge, never a toggle. */
    m->automaticActive = active;
    if (!active) return MSRRequestStop(m, MiniSightRecorderSourceAutomatic, now, s);
    if (!m->automaticEnabled) return MSRNoAction;
    return MSRBegin(m, MiniSightRecorderSourceAutomatic, now, s);
}
static inline MSRAction MSRCancel(MSRMachine *m, double now, MSRSnapshot s) {
    if (!MSRBusy(m)) return MSRNoAction;
    m->cancelled = true;
    if (m->saving) {
        m->saving = false;
        return MSRCancelSave | MSRFail(m, MiniSightRecorderIssueCancelled);
    }
    return MSRRequestStop(m, m->owner, now, s);
}
static inline MSRAction MSRToggle(MSRMachine *m, double now, MSRSnapshot s) {
    if (!m->manualEnabled || now - m->lastToggle < 0.35) return MSRNoAction;
    m->lastToggle = now;
    if (m->pendingStart || m->owned)
        return MSRRequestStop(m, MiniSightRecorderSourceManual, now, s);
    if (m->pendingStop || m->saving) return MSRNoAction;
    return MSRBegin(m, MiniSightRecorderSourceManual, now, s);
}
#endif
