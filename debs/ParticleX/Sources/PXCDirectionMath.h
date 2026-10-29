#ifndef PXC_DIRECTION_MATH_H
#define PXC_DIRECTION_MATH_H

#include <stdint.h>

/* Stable direction values in local UIKit coordinates (+x right, +y down):
 * 0: left to right, 1: right to left, 2: top to bottom,
 * 3: bottom to top, 4: random (resolved once per effect, not per particle).
 * No Foundation, SIMD, renderer, or random-generator dependency.
 */
static inline unsigned PXCResolvedDirection(unsigned requested, uint32_t entropy) {
    if (requested < 4u) return requested;
    if (requested == 4u) return (unsigned)(entropy & UINT32_C(3));
    return 0u;
}

/* Clamp normalized center coordinates. NaN and -infinity become 0;
 * +infinity becomes 1. The result is always finite and in [0, 1].
 */
static inline double PXCDirectionClamp01(double value) {
    if (!(value >= 0.0)) return 0.0;
    if (value > 1.0) return 1.0;
    return value;
}

/* Progress of the release wave at a particle's normalized center, not its
 * edge: 0 is the leading edge and 1 the trailing edge. Invalid/unresolved
 * directions (including 4) fall back to left-to-right without new entropy.
 */
static inline double PXCReleaseProgress(unsigned resolved, double x, double y) {
    x = PXCDirectionClamp01(x);
    y = PXCDirectionClamp01(y);
    switch (resolved) {
        case 1u: return 1.0 - x;
        case 2u: return y;
        case 3u: return 1.0 - y;
        default: return x;
    }
}

/* Unit flow vector; either output pointer may be null. Invalid/unresolved
 * directions fall back to (+1, 0), matching PXCReleaseProgress.
 */
static inline void PXCDirectionVector(unsigned resolved, double *x, double *y) {
    double dx = 1.0;
    double dy = 0.0;
    switch (resolved) {
        case 1u: dx = -1.0; break;
        case 2u: dx = 0.0; dy = 1.0; break;
        case 3u: dx = 0.0; dy = -1.0; break;
        default: break;
    }
    if (x) *x = dx;
    if (y) *y = dy;
}

#endif /* PXC_DIRECTION_MATH_H */
