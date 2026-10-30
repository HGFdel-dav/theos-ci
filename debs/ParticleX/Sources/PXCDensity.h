#pragma once
#include <stddef.h>

typedef struct {
    unsigned dustParticles;
    double sliderRate;
    double sliderScale;
    double sliderScaleRange;
} PXCDensityProfile;
// Stable existing keys: 0 power saving, 1 standard, 2 fine; add 3 dense.
// Standard preserves dev2's 6000 textured tiles and 1.0 slider multiplier.
static inline PXCDensityProfile PXCDensityGet(unsigned level) {
    if (level>3) level=3;
    switch (level) {
        case 0: return (PXCDensityProfile){1000,0.20,0.16,0.04};
        case 1: return (PXCDensityProfile){6000,1.00,0.13,0.07};
        case 2: return (PXCDensityProfile){12000,1.85,0.10,0.04};
        default:return (PXCDensityProfile){16000,2.50,0.10,0.04};
    }
}
