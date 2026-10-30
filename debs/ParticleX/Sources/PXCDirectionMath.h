#ifndef PXC_DIRECTION_MATH_H
#define PXC_DIRECTION_MATH_H

#include <math.h>

/* Dispatch has no direction picker any more. Every effect resolves one random
 * full-circle angle; this helper only maps a point onto that flow axis for the
 * Crystal release front. Coordinates are normalized UIKit points. */

/* Clamp normalized center coordinates. NaN and -infinity become 0;
 * +infinity becomes 1. The result is always finite and in [0, 1].
 */
static inline double PXCDirectionClamp01(double value) {
    if (!(value >= 0.0)) return 0.0;
    if (value > 1.0) return 1.0;
    return value;
}

/* 0 is the leading side and 1 the trailing side along `angle` radians.
 * At the card center it is exactly 0.5; opposite points sum to 1. */
static inline double PXCReleaseProgressAngle(double angle, double x, double y) {
    x = PXCDirectionClamp01(x);
    y = PXCDirectionClamp01(y);
    double dx = cos(angle), dy = sin(angle);
    double span = fabs(dx) + fabs(dy);
    if (!(span > 1e-9)) return 0.5;
    double progress = 0.5 + ((x - 0.5) * dx + (y - 0.5) * dy) / span;
    return progress < 0.0 ? 0.0 : progress > 1.0 ? 1.0 : progress;
}

#endif /* PXC_DIRECTION_MATH_H */
