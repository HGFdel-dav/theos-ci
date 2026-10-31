#pragma once
#include <stdbool.h>

typedef struct {
    bool allowed;
    unsigned overlays, perEffectParticles, totalParticles;
    unsigned textureBytes, totalTextureBytes, textureSide, fps, maxDensity;
} PXCPerformanceBudget;

/* Thermal values match NSProcessInfo's Nominal/Fair/Serious/Critical enum.
 * Safety caps are independent of the selected visual mode. The constrained
 * profile keeps 30fps and a visible density floor; it limits work and
 * concurrency instead of making a 24fps/zero-density effect look disabled. */
static inline PXCPerformanceBudget PXCPerformancePolicy(bool lowPower, unsigned thermal) {
    if (thermal >= 2) return (PXCPerformanceBudget){false,0,0,0,0,0,0,0,0};
    if (lowPower || thermal == 1)
        return (PXCPerformanceBudget){true,1,1200,2400,2u*1024u*1024u,2u*1024u*1024u,960,30,1};
    return (PXCPerformanceBudget){true,2,16000,20000,4u*1024u*1024u,6u*1024u*1024u,1280,30,3};
}

/* A memory warning drops the next effect to a bounded, still-visible profile.
 * It is deliberately not a hard-off state: the user can clear again while
 * SpringBoard is under transient pressure, and the next refresh restores the
 * normal event-driven budget. */
static inline PXCPerformanceBudget PXCPerformanceMemoryPolicy(bool lowPower, unsigned thermal) {
    PXCPerformanceBudget b=PXCPerformancePolicy(lowPower,thermal);
    if (!b.allowed) return b;
    return (PXCPerformanceBudget){true,1,1400,1400,2u*1024u*1024u,2u*1024u*1024u,960,30,1};
}
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#ifdef __cplusplus
extern "C" {
#endif
FOUNDATION_EXPORT PXCPerformanceBudget PXCPerformanceGet(void);
FOUNDATION_EXPORT void PXCPerformanceStart(void);
#ifdef __cplusplus
}
#endif
#endif
