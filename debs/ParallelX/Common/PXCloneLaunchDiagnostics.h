#pragma once
#include <stdbool.h>
#include <stdint.h>

/* Diagnostic-only mirror of the existing pollOpened gates. Never authorizes an
 * open, retry, success or account change. Unknown != false: checkedMask says
 * which observations were available; later gates may be unobservable. */
enum {
    PXLaunchDiagBridge = 1u << 0,
    PXLaunchDiagBundle = 1u << 1,
    PXLaunchDiagScene = 1u << 2,
    PXLaunchDiagSurface = 1u << 3,
    PXLaunchDiagCanvas = 1u << 4,
    PXLaunchDiagWindow = 1u << 5,
    PXLaunchDiagCompletion = 1u << 6, /* reuse OR accepted native completion */
    PXLaunchDiagHierarchy = 1u << 7,
    PXLaunchDiagWindowVisible = 1u << 8,
    PXLaunchDiagWindowIntersection = 1u << 9,
    PXLaunchDiagAccount = 1u << 10,
    PXLaunchDiagAll = (1u << 11) - 1,
};
static inline uint32_t PXLaunchDiagnosticFailed(uint32_t checked, uint32_t passed) {
    return checked & ~passed & PXLaunchDiagAll;
}
static inline uint32_t PXLaunchDiagnosticUnknown(uint32_t checked) {
    return PXLaunchDiagAll & ~checked;
}
static inline unsigned PXLaunchDiagnosticFirstGate(uint32_t checked, uint32_t passed) {
    uint32_t failed = PXLaunchDiagnosticFailed(checked, passed);
    for (unsigned i = 0; i < 11; ++i) if (failed & (1u << i)) return i + 1;
    return 0; /* no KNOWN failure, not proof of success */
}

static inline const char *PXLaunchDiagnosticGateName(unsigned gate) {
    static const char *const names[] = { "none_known", "bridge_missing", "bundle_mismatch", "scene_missing",
        "surface_missing", "canvas_not_view", "window_missing", "completion_not_accepted",
        "hierarchy_hidden_or_transparent", "window_hidden_or_transparent", "window_intersection_empty",
        "account_mismatch" };
    return gate < sizeof(names) / sizeof(names[0]) ? names[gate] : "unknown";
}

typedef struct {
    uint64_t signature;
    unsigned lastPoll, writes;
    bool hasWritten;
} PXLaunchDiagnosticThrottle;
/* 100ms polls: change writes at most every 500ms, heartbeat every 2s, at most
 * 12 ordinary snapshots per native attempt. A forced terminal snapshot must
 * bypass all limits, so the last现场 survives even after a noisy transition. */
static inline bool PXLaunchDiagnosticShouldWrite(PXLaunchDiagnosticThrottle *state,
                                                 uint64_t signature, unsigned poll,
                                                 bool force) {
    if (!state) return false;
    if (!force && state->hasWritten) {
        unsigned elapsed = poll >= state->lastPoll ? poll - state->lastPoll : 0;
        if (state->writes >= 12 || elapsed < 5 ||
            (state->signature == signature && elapsed < 20)) return false;
    }
    state->hasWritten = true;
    state->signature = signature;
    state->lastPoll = poll;
    if (!force) ++state->writes;
    return true;
}
static inline uint64_t PXLaunchDiagnosticMix(uint64_t hash, uint64_t value) {
    return (hash ^ value) * UINT64_C(1099511628211);
}
