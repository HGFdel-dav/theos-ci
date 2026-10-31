#ifndef PXC_NOTIFICATION_SAND_H
#define PXC_NOTIFICATION_SAND_H
#include <math.h>
#include <stdbool.h>
#include "PXCDensity.h"
#include "PXCPerformance.h"

/* A notification buffer stores sparse parent samples, not large moving tiles.
 * GPU expansion creates independent, point-sized grains per sample. This does
 * not lift texture, overlay, buffer, serious-thermal or memory-warning limits. */
typedef struct {
    unsigned groups;
    unsigned subdivisions;
    unsigned drawLimit;
} PXCNotificationSandPlan;

static inline PXCNotificationSandPlan PXCNotificationSandMakePlan(
    double coveredArea, unsigned density, unsigned remaining, unsigned remainingDraws, PXCPerformanceBudget b) {
    PXCNotificationSandPlan p={0,0,0};
    if (!b.allowed || !isfinite(coveredArea) || coveredArea<=0 || !remaining || !remainingDraws) return p;
    /* The constrained profile stays at 30fps but still needs the bounded
     * sparse plan; do not infer visibility from frame rate alone. */
    bool limited=b.maxDensity<=1 || b.perEffectParticles<=2400u;
    unsigned maxGroups=limited ? 1000u : 1200u;
    unsigned requested=PXCDensityGet(density>3 ? 3 : density).dustParticles;
    unsigned groups=requested<maxGroups ? requested : maxGroups;
    if (groups>b.perEffectParticles) groups=b.perEffectParticles;
    if (groups>remaining) groups=remaining;
    if (!groups) return p;
    const double spacing[4]={2.35,2.05,1.8,1.6};
    unsigned tier=limited ? 0 : (density>3 ? 3 : density);
    double desired=coveredArea/(spacing[tier]*spacing[tier]);
    unsigned n=1;
    unsigned maxN=limited ? 6u : 7u;
    unsigned cap=limited ? 36000u : 60000u;
    if (cap>remainingDraws) cap=remainingDraws;
    /* Each parent uses nine continuous-surface patches plus n*n grains. */
    if (groups>cap/10u) groups=cap/10u;
    if (!groups) return p;
    while (n<maxN && (double)groups*n*n<desired && groups*((n+1)*(n+1)+9u)<=cap) n++;
    p.groups=groups;p.subdivisions=n;p.drawLimit=cap;
    return p;
}

/* Pitch is conservatively fitted below the parent buffer cap. The caller
 * counts occupied cells and coarsens again, rather than dropping random cells
 * and leaving visible square holes in the notification texture. */
static inline double PXCNotificationSandPitch(double area, unsigned target) {
    if (!isfinite(area) || area<=0 || !target) return 0;
    return sqrt(area/(double)target)*1.12;
}
static inline bool PXCNotificationSandKeep(double x,double y,double w,double h,
                                          double rx,double ry,double rw,double rh) {
    return x+w>rx && rx+rw>x && y+h>ry && ry+rh>y;
}
#endif
