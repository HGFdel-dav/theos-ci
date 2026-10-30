#pragma once
#include <stdbool.h>

typedef struct {
    bool allowed;
    unsigned overlays, perEffectParticles, totalParticles;
    unsigned textureBytes, totalTextureBytes, textureSide, fps, maxDensity;
} PXCPerformanceBudget;

/* Thermal values match NSProcessInfo's Nominal/Fair/Serious/Critical enum.
 * Safety caps are independent of the selected visual mode. */
static inline PXCPerformanceBudget PXCPerformancePolicy(bool lowPower, unsigned thermal) {
    if (thermal >= 2) return (PXCPerformanceBudget){false,0,0,0,0,0,0,0,0};
    if (lowPower || thermal == 1)
        return (PXCPerformanceBudget){true,1,1200,1200,2u*1024u*1024u,2u*1024u*1024u,960,24,0};
    return (PXCPerformanceBudget){true,2,16000,20000,4u*1024u*1024u,6u*1024u*1024u,1280,30,3};
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
