/* Production drag-box geometry, independent of UIKit for host verification. */
#ifndef MINISIGHT_REGION_SELECTION_H
#define MINISIGHT_REGION_SELECTION_H
#include "MiniSightGeometry.h"

static inline MSPoint MSRegionClampPoint(MSPoint p, MSRect bounds) {
    double w = fmax(0., MSFinite(bounds.w, 0.));
    double h = fmax(0., MSFinite(bounds.h, 0.));
    return (MSPoint){MSClamp(MSFinite(p.x, bounds.x), bounds.x, bounds.x + w),
                     MSClamp(MSFinite(p.y, bounds.y), bounds.y, bounds.y + h)};
}

static inline MSRect MSRegionBetween(MSPoint start, MSPoint end, MSRect bounds) {
    start = MSRegionClampPoint(start, bounds);
    end = MSRegionClampPoint(end, bounds);
    return (MSRect){fmin(start.x, end.x), fmin(start.y, end.y),
                    fabs(end.x - start.x), fabs(end.y - start.y)};
}

static inline int MSRegionValid(MSRect rect) {
    return isfinite(rect.x) && isfinite(rect.y) && isfinite(rect.w) &&
           isfinite(rect.h) && rect.w >= 24. && rect.h >= 24.;
}

static inline MSRect MSRegionNormalized(MSRect rect, MSRect bounds) {
    if (!(bounds.w > 0. && bounds.h > 0.) || !MSRegionValid(rect))
        return (MSRect){0, 0, 0, 0};
    MSRect clipped = MSRegionBetween((MSPoint){rect.x, rect.y},
        (MSPoint){rect.x + rect.w, rect.y + rect.h}, bounds);
    return (MSRect){(clipped.x - bounds.x) / bounds.w,
                    (clipped.y - bounds.y) / bounds.h,
                    clipped.w / bounds.w, clipped.h / bounds.h};
}
#endif
