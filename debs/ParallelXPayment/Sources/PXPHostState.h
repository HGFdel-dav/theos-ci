#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef struct {
    uint64_t generation;
    bool starting;
    bool initialized;
    bool resultDelivered;
    bool visible;
    bool stopped;
} PXPHostState;

static inline bool PXPHostStart(PXPHostState *s, uint64_t before) {
    if(s->starting || s->initialized || s->stopped || before==UINT64_MAX) return false;
    s->generation=before+1;
    s->starting=true;
    return true;
}
static inline bool PXPHostInitialized(PXPHostState *s, uint64_t actual) {
    if(!s->starting || s->stopped || actual!=s->generation) return false;
    s->starting=false;
    s->initialized=true;
    return true;
}
static inline bool PXPHostClaimCallback(PXPHostState *s) {
    if(s->resultDelivered) return false;
    s->resultDelivered=true;
    return true;
}
static inline bool PXPHostLive(const PXPHostState *s,uint64_t generation) {
    return !s->stopped && (s->starting || s->initialized) && s->generation==generation;
}
static inline bool PXPHostStop(PXPHostState *s) {
    if(s->stopped) return false;
    s->stopped=true;
    s->starting=false;
    s->visible=false;
    return true;
}
