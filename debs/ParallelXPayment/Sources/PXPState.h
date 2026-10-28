#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef enum {
    PXPQueued, PXPChoosing, PXPSwitching, PXPForwarding,
    PXPActivating, PXPHosting, PXPDone, PXPFailed, PXPCancelled
} PXPPhase;
typedef struct {
    uint64_t token;
    PXPPhase phase;
    bool forwarded, bound, executed, accepted, activated, completed;
    bool hostStarted, hostReady, resultDelivered;
} PXPState;
static inline bool PXPTerminal(const PXPState *s) {
    return s->phase == PXPDone || s->phase == PXPFailed || s->phase == PXPCancelled;
}
static inline bool PXPTransition(PXPState *s, PXPPhase p) {
    if (PXPTerminal(s)) return false;
    bool ok = (p == PXPFailed || p == PXPCancelled) ||
        (s->phase == PXPQueued && p == PXPChoosing) ||
        (s->phase == PXPChoosing && p == PXPSwitching) ||
        (s->phase == PXPSwitching && p == PXPForwarding) ||
        (s->phase == PXPForwarding && p == PXPActivating) ||
        (s->phase == PXPActivating && p == PXPHosting) ||
        (s->phase == PXPHosting && p == PXPDone && s->hostReady);
    if (ok) s->phase = p;
    return ok;
}
static inline bool PXPClaimForward(PXPState *s) {
    if (s->phase != PXPForwarding || s->forwarded || PXPTerminal(s)) return false;
    s->forwarded = true;
    return true;
}
static inline bool PXPCanHost(const PXPState *s) {
    return s->phase == PXPActivating && s->forwarded && s->bound && s->executed &&
        s->accepted && s->activated && s->completed && !s->hostStarted;
}
static inline bool PXPClaimHost(PXPState *s) {
    if (!PXPCanHost(s)) return false;
    s->hostStarted = true;
    return PXPTransition(s, PXPHosting);
}
static inline bool PXPClaimResult(PXPState *s) {
    if (s->resultDelivered) return false;
    s->resultDelivered = true;
    return true;
}
