#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <math.h>
#include "LocalCleanStatusCore.h"

// Portable policy shared by the injected picker and the standalone module.
// This file performs no networking, private API calls or system actions.
typedef enum {
    LocalCleanStatusCCKindWiFi = 0,
    LocalCleanStatusCCKindBluetooth = 1,
    LocalCleanStatusCCKindSystem = 2
} LocalCleanStatusCCKind;

typedef enum {
    LocalCleanStatusCCActionNone = 0,
    LocalCleanStatusCCActionRespring = 1,
    LocalCleanStatusCCActionUserspaceReboot = 2,
    LocalCleanStatusCCActionReboot = 3,
    LocalCleanStatusCCActionShutdown = 4
} LocalCleanStatusCCAction;

typedef struct {
    uint64_t generation;
    bool active;
    bool pending;
} LocalCleanStatusCCTicket;

static inline bool local_cleanstatus_ccValidKind(LocalCleanStatusCCKind kind) {
    return kind == LocalCleanStatusCCKindWiFi || kind == LocalCleanStatusCCKindBluetooth ||
           kind == LocalCleanStatusCCKindSystem;
}
static inline LocalCleanStatusFeature local_cleanstatus_ccFeature(LocalCleanStatusCCKind kind) {
    if (kind == LocalCleanStatusCCKindWiFi) return LocalCleanStatusCCWiFi;
    if (kind == LocalCleanStatusCCKindBluetooth) return LocalCleanStatusCCBluetooth;
    return LocalCleanStatusSystemActions;
}
static inline bool local_cleanstatus_ccCanPresent(uint32_t flags, LocalCleanStatusCCKind kind,
    bool unlocked, bool expanded, bool attached, bool presenting, bool conflictingPicker) {
    return local_cleanstatus_ccValidKind(kind) && unlocked && !expanded && attached &&
        !presenting && !conflictingPicker && local_cleanstatus_hasFeature(flags,local_cleanstatus_ccFeature(kind));
}
static inline uint64_t local_cleanstatus_ccNextGeneration(uint64_t generation) {
    return generation == UINT64_MAX ? UINT64_C(1) : generation + UINT64_C(1);
}
static inline uint64_t local_cleanstatus_ccBegin(LocalCleanStatusCCTicket *ticket) {
    if (!ticket) return 0;
    ticket->generation = local_cleanstatus_ccNextGeneration(ticket->generation);
    ticket->active = true; ticket->pending = false;
    return ticket->generation;
}
static inline bool local_cleanstatus_ccCurrent(const LocalCleanStatusCCTicket *ticket,uint64_t generation) {
    return ticket && ticket->active && generation != 0 && ticket->generation == generation;
}
static inline bool local_cleanstatus_ccRequest(LocalCleanStatusCCTicket *ticket,uint64_t generation) {
    if (!local_cleanstatus_ccCurrent(ticket,generation) || ticket->pending) return false;
    ticket->pending = true;
    return true;
}
static inline bool local_cleanstatus_ccComplete(LocalCleanStatusCCTicket *ticket,uint64_t generation) {
    if (!local_cleanstatus_ccCurrent(ticket,generation) || !ticket->pending) return false;
    ticket->pending = false;
    return true;
}
static inline void local_cleanstatus_ccInvalidate(LocalCleanStatusCCTicket *ticket) {
    if (!ticket) return;
    ticket->generation = local_cleanstatus_ccNextGeneration(ticket->generation);
    ticket->active = false; ticket->pending = false;
}
static inline bool local_cleanstatus_ccCanExecute(LocalCleanStatusCCAction action,
    bool enabled,bool unlocked,bool confirmed,bool backendAvailable,bool inFlight) {
    return action >= LocalCleanStatusCCActionRespring && action <= LocalCleanStatusCCActionShutdown &&
        enabled && unlocked && confirmed && backendAvailable && !inFlight;
}
static inline bool local_cleanstatus_ccExpired(double now,double started,double timeout) {
    return !isfinite(now) || !isfinite(started) || !isfinite(timeout) || timeout <= 0 ||
        now < started || now - started >= timeout;
}
