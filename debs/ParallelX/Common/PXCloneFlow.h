#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef enum {
    PXCloneFlowIdle = 0,
    PXCloneFlowClosing,
    PXCloneFlowTerminating,
    PXCloneFlowAuthenticating,
    PXCloneFlowVerifying,
    PXCloneFlowOpening,
    PXCloneFlowFailed,
    PXCloneFlowQuarantined,
} PXCloneFlowPhase;

typedef struct {
    uint64_t token;
    PXCloneFlowPhase phase;
} PXCloneFlow;

// Production policy also compiled by host tests; no Objective-C/UI mocks here.
static inline bool PXCloneFlowBegin(PXCloneFlow *flow, uint64_t token) {
    if (!flow || !token || flow->phase != PXCloneFlowIdle) return false;
    flow->token = token;
    flow->phase = PXCloneFlowClosing;
    return true;
}

static inline bool PXCloneFlowIsCurrent(const PXCloneFlow *flow, uint64_t token) {
    return flow && token && flow->token == token && flow->phase != PXCloneFlowIdle;
}

static inline bool PXCloneFlowAdvance(PXCloneFlow *flow, uint64_t token,
                                      PXCloneFlowPhase from, PXCloneFlowPhase to) {
    if (!PXCloneFlowIsCurrent(flow, token) || flow->phase != from) return false;
    bool allowed = (from == PXCloneFlowClosing && to == PXCloneFlowTerminating) ||
        (from == PXCloneFlowTerminating && (to == PXCloneFlowAuthenticating ||
                                            to == PXCloneFlowVerifying)) ||
        (from == PXCloneFlowAuthenticating && to == PXCloneFlowVerifying) ||
        (from == PXCloneFlowVerifying && to == PXCloneFlowOpening);
    if (!allowed) return false;
    flow->phase = to;
    return true;
}

static inline bool PXCloneFlowMayOpen(const PXCloneFlow *flow, uint64_t token,
                                      bool containerVerified, bool hasNewerTarget) {
    return PXCloneFlowIsCurrent(flow, token) && flow->phase == PXCloneFlowVerifying &&
           containerVerified && !hasNewerTarget;
}

static inline bool PXCloneFlowMaySucceed(const PXCloneFlow *flow, uint64_t token,
                                         bool containerVerified, bool hostedVisible) {
    return PXCloneFlowIsCurrent(flow, token) && flow->phase == PXCloneFlowOpening &&
           containerVerified && hostedVisible;
}

static inline bool PXCloneFlowTimeout(PXCloneFlow *flow, uint64_t token) {
    if (!PXCloneFlowIsCurrent(flow, token)) return false;
    // An outstanding biometric callback may still change the container. Do
    // not begin another switch until it returns, even after showing an error.
    flow->phase = flow->phase == PXCloneFlowAuthenticating ?
                  PXCloneFlowQuarantined : PXCloneFlowFailed;
    return true;
}

static inline bool PXCloneFlowRelease(PXCloneFlow *flow, uint64_t token) {
    if (!PXCloneFlowIsCurrent(flow, token)) return false;
    flow->phase = PXCloneFlowIdle;
    return true;
}
