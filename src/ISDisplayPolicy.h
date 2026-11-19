#ifndef ISDISPLAY_POLICY_H
#define ISDISPLAY_POLICY_H
#include <stdbool.h>
#include <stdint.h>

/*
 * Insulation "sunlight dimming" output-layer policy.
 *
 * SCOPE: one thing only. BackLightCCSingle -setBrightnessKey:value: receives
 * percentage CAPS ("MaxBrightness", "BrightnessWeakCap"), not slider brightness,
 * not nits, not backlight power. While the existing "prevent thermal dimming"
 * switch is ON, a plain percentage in 1..99 is replaced by 100 so that this one
 * extra thermal ceiling stops clamping the user's chosen brightness.
 *
 * 100 here means "no extra percentage cap from this path". It is NOT a lock of
 * the brightness slider, and it is never sent for 0 / negative / >= 100 values,
 * so a screen-off 0 can never be turned into illumination.
 */

#define ISD_CAP_PERCENT 100
#define ISD_MIN_CAPPED 1
#define ISD_MAX_CAPPED 99

/* Hard upper bound on os_log lines for the whole process lifetime. */
#define ISD_LOG_BUDGET 64

typedef enum {
    ISDUnknown = -1,
    ISDMaximum = 0, /* "MaxBrightness"      */
    ISDWeak = 1,    /* "BrightnessWeakCap"  */
    ISDKeyCount = 2
} ISDKey;

typedef struct {
    int systemRequest; /* last value the system itself asked for */
    int delivered;     /* value we actually forwarded              */
    bool present;
} ISDSlot;

typedef struct {
    ISDSlot slots[ISDKeyCount];
    bool enabledKnown;
    bool lastEnabled;
} ISDState;

typedef struct {
    bool send;      /* caller must call the saved IMP */
    bool touched;   /* key was recognised and state updated */
    int requested;  /* system request (what the daemon wanted) */
    int delivered;  /* value to forward */
} ISDDecision;

static inline bool ISDValidKey(ISDKey key) {
    return key >= 0 && key < ISDKeyCount;
}

/* The single place where a value can change. Only 1..99 -> 100, nothing else. */
static inline int ISDResolve(int requested, bool enabled) {
    if (!enabled) return requested;
    if (requested < ISD_MIN_CAPPED || requested > ISD_MAX_CAPPED) return requested;
    return ISD_CAP_PERCENT;
}

/* Remember what the system wanted, and what we forwarded for it. */
static inline ISDDecision ISDRequest(ISDState *state, ISDKey key,
                                     int requested, bool enabled) {
    ISDDecision d = { true, false, requested, requested };
    if (!state || !ISDValidKey(key)) return d;
    d.delivered = ISDResolve(requested, enabled);
    d.touched = true;
    state->slots[key].systemRequest = requested;
    state->slots[key].delivered = d.delivered;
    state->slots[key].present = true;
    state->enabledKnown = true;
    state->lastEnabled = enabled;
    return d;
}

/*
 * Re-apply the saved SYSTEM value under the current switch state.
 * Returns send=true only when the forwarded value actually has to change, so a
 * steady switch state never produces repeated writes (idempotent).
 */
static inline ISDDecision ISDReconcile(ISDState *state, ISDKey key, bool enabled) {
    ISDDecision d = { false, false, 0, 0 };
    if (!state || !ISDValidKey(key) || !state->slots[key].present) return d;
    ISDSlot *slot = &state->slots[key];
    d.touched = true;
    d.requested = slot->systemRequest;
    d.delivered = ISDResolve(slot->systemRequest, enabled);
    d.send = d.delivered != slot->delivered;
    if (d.send) slot->delivered = d.delivered;
    state->enabledKnown = true;
    state->lastEnabled = enabled;
    return d;
}

/* True exactly once per switch transition; the first observation is not one. */
static inline bool ISDNoteEnabled(ISDState *state, bool enabled) {
    if (!state) return false;
    if (!state->enabledKnown) {
        state->enabledKnown = true;
        state->lastEnabled = enabled;
        return false;
    }
    if (state->lastEnabled != enabled) {
        state->lastEnabled = enabled;
        return true;
    }
    return false;
}

/* A setter call that arrived off the main thread is not ours to reason about. */
static inline void ISDInvalidate(ISDState *state, ISDKey key) {
    if (!state || !ISDValidKey(key)) return;
    state->slots[key].systemRequest = 0;
    state->slots[key].delivered = 0;
    state->slots[key].present = false;
}

#endif /* ISDISPLAY_POLICY_H */
