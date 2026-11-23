#pragma once
/* Pure entry policy used by the UIKit adapter. No framework calls or SIM actions. */
#include <stdbool.h>
#include <stdint.h>
#include <math.h>

typedef struct {
    bool feature, unlocked, foreground, lifecycle;
    bool visible, local_host, same_window, unique_button;
    bool safe_short_tap, no_modal;
} LCSEntryGates;
typedef struct { double x, y, width, height; } LCSEntryRect;
typedef enum { LCSEntryIdle, LCSEntryTracking, LCSEntryBegan } LCSEntryPhase;
typedef struct {
    uint64_t sequence;
    LCSEntryPhase phase;
    bool expanded_at_touch;
    double start_x, start_y;
} LCSEntryAttempt;

static inline bool LCSEntryEligible(LCSEntryGates g) {
    return g.feature && g.unlocked && g.foreground && g.lifecycle &&
        g.visible && g.local_host && g.same_window && g.unique_button &&
        g.safe_short_tap && g.no_modal;
}
static inline bool LCSEntryRectValid(LCSEntryRect r) {
    return isfinite(r.x) && isfinite(r.y) && isfinite(r.width) &&
        isfinite(r.height) && r.width > 0 && r.height > 0 &&
        isfinite(r.x + r.width) && isfinite(r.y + r.height);
}
static inline bool LCSEntryContains(LCSEntryRect r, double x, double y) {
    return LCSEntryRectValid(r) && isfinite(x) && isfinite(y) &&
        x >= r.x && y >= r.y && x < r.x + r.width && y < r.y + r.height;
}
static inline bool LCSEntryReceive(LCSEntryAttempt *a, LCSEntryGates g,
                                  LCSEntryRect r, double x, double y,
                                  bool related_hit, bool expanded) {
    if (!a || a->phase != LCSEntryIdle || !LCSEntryEligible(g) ||
        !related_hit || !LCSEntryContains(r, x, y)) return false;
    a->sequence = a->sequence == UINT64_MAX ? 1 : a->sequence + 1;
    a->phase = LCSEntryTracking;
    a->expanded_at_touch = expanded;
    a->start_x = x; a->start_y = y;
    return true;
}
static inline bool LCSEntryPreviewWait(const LCSEntryAttempt *a, LCSEntryGates g,
                                      bool expanded, bool same_container,
                                      bool same_interaction, bool related_view,
                                      LCSEntryRect r, double x, double y) {
    return a && (a->phase == LCSEntryTracking || a->phase == LCSEntryBegan) &&
        !a->expanded_at_touch && !expanded && LCSEntryEligible(g) &&
        same_container && same_interaction && related_view && LCSEntryContains(r, x, y);
}
static inline bool LCSEntryBegin(LCSEntryAttempt *a, LCSEntryGates g,
                                LCSEntryRect r, double x, double y,
                                bool expanded) {
    if (!a || a->phase != LCSEntryTracking || !LCSEntryEligible(g) ||
        expanded != a->expanded_at_touch || !LCSEntryContains(r, x, y)) return false;
    a->phase = LCSEntryBegan;
    return true;
}
static inline void LCSEntryCancel(LCSEntryAttempt *a) {
    if (a) a->phase = LCSEntryIdle;
}
