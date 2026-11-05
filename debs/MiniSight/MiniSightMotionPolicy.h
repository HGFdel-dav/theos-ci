// Screen and sensor gate used by production and host-only regression tests.
#ifndef MINISIGHT_MOTION_POLICY_H
#define MINISIGHT_MOTION_POLICY_H
#include <stdint.h>

typedef struct { int known; int blanked; } MSScreenState;
// hasBlankedScreen reports 0 = lit, 1 = blanked. Unknown is not a guessed toggle.
static inline MSScreenState MSScreenReadResult(int ok, uint64_t raw) {
    MSScreenState s = { ok && raw <= 1, 1 };
    if (s.known) s.blanked = raw == 1;
    return s;
}
static inline int MSScreenAllowsMotion(MSScreenState s, int visible, int enabled) {
    return s.known && !s.blanked && visible && enabled;
}

typedef enum {
    MSMotionSourceNone = 0, MSMotionSourceDevice = 1,
    MSMotionSourceAccelerometer = 2, MSMotionSourceFailed = 3
} MSMotionSource;
typedef struct {
    unsigned long generation;
    MSMotionSource source;
    unsigned long samples;
} MSMotionAttempt;
static inline void MSMotionStop(MSMotionAttempt *a) {
    ++a->generation; a->source = MSMotionSourceNone; a->samples = 0;
}
static inline void MSMotionStart(MSMotionAttempt *a, int deviceAvailable, int accAvailable) {
    ++a->generation; a->samples = 0;
    a->source = deviceAvailable ? MSMotionSourceDevice :
        (accAvailable ? MSMotionSourceAccelerometer : MSMotionSourceFailed);
}
static inline int MSMotionAccepts(const MSMotionAttempt *a, unsigned long generation,
                                  MSMotionSource source, int gateOpen) {
    return gateOpen && a->generation == generation && a->source == source &&
        (source == MSMotionSourceDevice || source == MSMotionSourceAccelerometer);
}
// One device->accelerometer fallback, then terminal failure; no retry loop.
static inline int MSMotionFail(MSMotionAttempt *a, unsigned long generation, int accAvailable) {
    if (a->generation != generation ||
        (a->source != MSMotionSourceDevice && a->source != MSMotionSourceAccelerometer)) return 0;
    const int fallback = a->source == MSMotionSourceDevice && accAvailable;
    ++a->generation; a->samples = 0;
    a->source = fallback ? MSMotionSourceAccelerometer : MSMotionSourceFailed;
    return fallback;
}
static inline int MSMotionFirstSampleDeadline(const MSMotionAttempt *a,
                                               unsigned long generation) {
    return a->generation == generation && a->samples == 0 &&
        (a->source == MSMotionSourceDevice || a->source == MSMotionSourceAccelerometer);
}
#endif
