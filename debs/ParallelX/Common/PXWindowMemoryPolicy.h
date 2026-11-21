#pragma once
#include <math.h>
#include <stdbool.h>
#include <stdint.h>

/* Portable production policy: UIKit is only an adapter around this code. */
typedef struct { double x, y, width, height; } PXWMRect;
typedef struct { PXWMRect frame, reference; } PXWMGeometry;

static inline bool PXWMValidRect(PXWMRect r) {
    return isfinite(r.x) && isfinite(r.y) && isfinite(r.width) && isfinite(r.height) &&
           fabs(r.x) <= 32768 && fabs(r.y) <= 32768 &&
           r.width >= 1 && r.height >= 1 && r.width <= 32768 && r.height <= 32768;
}

static inline unsigned PXWMOrientationKey(bool hostLandscape, bool contentLandscape) {
    return (hostLandscape ? 2u : 0u) | (contentLandscape ? 1u : 0u);
}

static inline bool PXWMValidGeometry(PXWMGeometry g) {
    if (!PXWMValidRect(g.frame) || !PXWMValidRect(g.reference)) return false;
    const double tolerance = 1.0;
    return g.frame.width >= 64 && g.frame.height >= 64 &&
           g.frame.x >= g.reference.x - tolerance && g.frame.y >= g.reference.y - tolerance &&
           g.frame.x + g.frame.width <= g.reference.x + g.reference.width + tolerance &&
           g.frame.y + g.frame.height <= g.reference.y + g.reference.height + tolerance;
}

static inline double PXWMClamp(double value, double low, double high) {
    return fmin(fmax(value, low), high);
}

/* Preserve the native content aspect ratio; never stretch an app to old data.
 * When display dimensions change, scale uniformly and keep a normalized centre.
 * Bad/missing data must leave the native layout untouched. */
static inline bool PXWMRestore(PXWMGeometry saved, PXWMRect available,
                              PXWMRect native, PXWMRect *result) {
    if (!result || !PXWMValidGeometry(saved) || !PXWMValidRect(available) ||
        !PXWMValidRect(native) || available.width < 64 || available.height < 64) return false;
    bool oldLandscape = saved.reference.width > saved.reference.height;
    bool newLandscape = available.width > available.height;
    if (oldLandscape != newLandscape) return false;
    double referenceScale = fmin(available.width / saved.reference.width,
                                available.height / saved.reference.height);
    double width = saved.frame.width * referenceScale;
    double height = saved.frame.height * referenceScale;
    double scale = fmin(width / native.width, height / native.height);
    scale = fmin(scale, fmin(available.width / native.width, available.height / native.height));
    width = native.width * scale;
    height = native.height * scale;
    if (!isfinite(width) || !isfinite(height) || width < 64 || height < 64) return false;
    double cx = (saved.frame.x + saved.frame.width / 2 - saved.reference.x) / saved.reference.width;
    double cy = (saved.frame.y + saved.frame.height / 2 - saved.reference.y) / saved.reference.height;
    PXWMRect out = { available.x + cx * available.width - width / 2,
                     available.y + cy * available.height - height / 2, width, height };
    out.x = PXWMClamp(out.x, available.x, available.x + available.width - width);
    out.y = PXWMClamp(out.y, available.y, available.y + available.height - height);
    if (!PXWMValidGeometry((PXWMGeometry){out, available})) return false;
    *result = out;
    return true;
}

/* A queued save cannot resurrect records cleared/disabled in Settings. */
static inline bool PXWMMaySave(bool enabled, uint64_t observedEpoch, uint64_t currentEpoch,
                              bool settled, bool normalLayout, bool userCompleted) {
    return enabled && observedEpoch == currentEpoch && settled && normalLayout && userCompleted;
}

/* A user gesture owns the current layout immediately, even when the first
 * storage load arrives late. Only a real direction change re-arms restore. */
static inline bool PXWMMayRestoreLayout(bool resolved, bool keyKnown,
                                      unsigned previousKey, unsigned currentKey,
                                      bool interacting, bool savePending) {
    return !interacting && !savePending &&
           (!resolved || (keyKnown && previousKey != currentKey));
}

/* A just-opened native ticket may still be inside alpha437's synchronous
 * layout. It can reapply only the geometry it already matched, and only while
 * storage remains enabled at the same clear/reset epoch. */
static inline bool PXWMMayReapplyInitialGeometry(bool activeBinding, bool currentTicket,
                                                bool nativeEntering, bool cleanupSeen,
                                                bool cancelled, bool initialRestoreActive,
                                                bool enabled, bool epochMatches, bool withinInitialWindow,
                                                bool interacting, bool savePending) {
    bool owns = activeBinding || (currentTicket && nativeEntering && cleanupSeen && !cancelled);
    return owns && initialRestoreActive && enabled && epochMatches && withinInitialWindow &&
           !interacting && !savePending;
}

static inline bool PXWMMayCommitGesture(bool orientationKnown, unsigned gestureKey,
                                      unsigned currentKey, uint64_t gestureGeneration,
                                      uint64_t currentGeneration) {
    return orientationKnown && gestureKey == currentKey &&
           gestureGeneration == currentGeneration;
}

static inline bool PXWMMayWaitForGestureGeometry(bool normalGeometry, unsigned samples,
                                                  unsigned maximumSamples) {
    return !normalGeometry && samples < maximumSamples;
}

/* If direction was unavailable when a user starts the first resize, bind it
 * once the final host geometry becomes readable. Never guess an unknown key. */
static inline bool PXWMResolveGestureOrientation(bool geometryReady, bool *known,
                                                  unsigned *gestureKey, unsigned currentKey) {
    if (!geometryReady || !known || !gestureKey) return false;
    if (!*known) { *known = true; *gestureKey = currentKey; return true; }
    return *gestureKey == currentKey;
}

/* Stable, non-account identifier for joining per-App diagnostics across
 * processes. Only hashes a public bundle identifier, never account content. */
static inline uint64_t PXWMIdentifierHash(const char *identifier) {
    const unsigned char *bytes = (const unsigned char *)identifier;
    uint64_t hash = UINT64_C(1469598103934665603);
    if (bytes) while (*bytes) { hash ^= *bytes++; hash *= UINT64_C(1099511628211); }
    return hash;
}

/* alpha437 openApplication first closes its PREVIOUS scene, then assigns the
 * incoming canvas. This is not the same event as closing the new window.
 * No UIKit/ObjC is needed to execute these exact production transitions. */
typedef struct {
    uint64_t serial;
    bool entering;
    bool initialCleanupSeen;
    bool cancelled;
    bool bound;
} PXWMNativeLifecycle;

static inline void PXWMNativeBegin(PXWMNativeLifecycle *state, uint64_t serial) {
    if (!state) return;
    *state = (PXWMNativeLifecycle){serial, true, false, false, false};
}

/* True only for the one synchronous pre-canvas cleanup at native entry.
 * The native close implementation is still called on every path. */
static inline bool PXWMNativeClose(PXWMNativeLifecycle *state) {
    if (!state) return false;
    if (state->serial && state->entering && !state->initialCleanupSeen && !state->cancelled) {
        state->initialCleanupSeen = true;
        return true;
    }
    state->cancelled = true;
    state->bound = false;
    return false;
}

static inline bool PXWMNativeReturned(PXWMNativeLifecycle *state, bool currentTicket,
                                     bool matchingCanvasAndBundle, bool returnedNormally) {
    if (!state || !state->entering) return false;
    state->entering = false;
    state->bound = state->serial && currentTicket && returnedNormally &&
                   matchingCanvasAndBundle && state->initialCleanupSeen && !state->cancelled;
    if (!state->bound) state->cancelled = true;
    return state->bound;
}

static inline bool PXWMNativeBindingActive(const PXWMNativeLifecycle *state, uint64_t serial) {
    return state && serial && state->serial == serial && state->bound &&
           !state->entering && !state->cancelled;
}

/* Geometry preparation is permitted inside the native open only after its
 * old-scene cleanup and assignment of this canvas/bundle. Saves still require
 * the complete visible, bound host. No ownership is inferred from a pointer. */
static inline bool PXWMMayPrepareInitialLayout(bool activeBinding, bool currentTicket,
                                              bool nativeEntering, bool cleanupSeen,
                                              bool cancelled, bool matchingCanvasAndBundle,
                                              bool loaded, bool enabled, bool resolved,
                                              bool interacting, bool savePending) {
    bool owns = activeBinding || (currentTicket && nativeEntering && cleanupSeen && !cancelled);
    return owns && matchingCanvasAndBundle && loaded && enabled &&
           !resolved && !interacting && !savePending;
}

static inline bool PXWMMayScheduleRestore(bool bound, bool resolved, bool interacting,
                                         bool savePending, bool loaded,
                                         unsigned attempts, unsigned maximum) {
    return bound && !resolved && !interacting && !savePending && loaded && attempts < maximum;
}

/* Keep the bounded diagnostics useful: stable retries must not evict saves
 * and failures with one event per display-poll interval. */
static inline bool PXWMShouldLogRestoreWait(unsigned attempt, unsigned gate, unsigned lastGate) {
    return attempt == 1 || gate != lastGate || attempt % 25 == 0;
}

/* A user resize may start before the native content orientation exists.
 * Do not write a speculative orientation; retry reading it from the same host. */
static inline bool PXWMMayStoreGesture(bool directionKnown, unsigned gestureKey,
                                      unsigned currentKey, uint64_t gestureGeneration,
                                      uint64_t currentGeneration, bool nativeClose) {
    return directionKnown && gestureKey == currentKey &&
           gestureGeneration == currentGeneration && !nativeClose;
}
