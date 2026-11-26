#pragma once
#include "PXWindowMemoryPolicy.h"

/* Move requests own their centre, not their size. Reuse the existing storage
 * centre mapping so runtime and saved position cannot disagree. */
static inline bool PXWMKeepMoveSize(PXWMGeometry anchor, PXWMGeometry requested,
                                    PXWMRect *out) {
    if (!out || !PXWMValidGeometry(anchor) || !PXWMValidGeometry(requested)) return false;
    if (fabs(anchor.reference.x-requested.reference.x)>1 ||
        fabs(anchor.reference.y-requested.reference.y)>1 ||
        fabs(anchor.reference.width-requested.reference.width)>1 ||
        fabs(anchor.reference.height-requested.reference.height)>1 ||
        (anchor.frame.width>anchor.frame.height)!=(requested.frame.width>requested.frame.height)) return false;
    PXWMGeometry merged;
    if (!PXWMUpdateRememberedPosition(anchor,requested,&merged)) return false;
    *out=merged.frame;
    return true;
}

static inline bool PXWMContinuityAllowed(bool bound, bool identityMatches,
                                         bool enabled, uint64_t targetEpoch,
                                         uint64_t currentEpoch, uint64_t targetGeneration,
                                         uint64_t currentGeneration, bool transient,
                                         bool directionMatches, bool referenceMatches) {
    return bound && identityMatches && enabled && targetEpoch==currentEpoch &&
           targetGeneration==currentGeneration && !transient && directionMatches && referenceMatches;
}

/* Event-driven recovery is bounded even if two geometries alternate. A real
 * gesture/open advances generation; layout callbacks do not reset the budget. */
static inline bool PXWMContentSyncMayAttempt(unsigned sameGeometryAttempts, unsigned generationAttempts) {
    return sameGeometryAttempts < 2 && generationAttempts < 4;
}

/* The vendor uniformly fits the source into canvas bounds, centered. Compare
 * its transformed rectangle in that SAME coordinate space, not host.bounds. */
static inline bool PXWMContentFit(PXWMRect canvas, double sourceW, double sourceH,
                                  PXWMRect *out, double *scale) {
    if (!out || !scale || !PXWMValidRect(canvas) || !isfinite(sourceW) ||
        !isfinite(sourceH) || sourceW<=0 || sourceH<=0) return false;
    double s=fmin(canvas.width/sourceW,canvas.height/sourceH);
    if (!isfinite(s) || s<=0) return false;
    *out=(PXWMRect){canvas.x+(canvas.width-sourceW*s)/2,
                   canvas.y+(canvas.height-sourceH*s)/2,sourceW*s,sourceH*s};
    *scale=s;
    return true;
}
static inline bool PXWMRectNear(PXWMRect a, PXWMRect b, double tolerance) {
    return isfinite(a.x) && isfinite(a.y) && isfinite(a.width) && isfinite(a.height) &&
           isfinite(b.x) && isfinite(b.y) && isfinite(b.width) && isfinite(b.height) &&
           fabs(a.x-b.x)<=tolerance && fabs(a.y-b.y)<=tolerance &&
           fabs(a.width-b.width)<=tolerance && fabs(a.height-b.height)<=tolerance;
}
