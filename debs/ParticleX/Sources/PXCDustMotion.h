#ifndef PXC_DUST_MOTION_H
#define PXC_DUST_MOTION_H
/* Shared by portable C tests and the embedded Metal shader. Style 0 is Wind,
 * style 1 is the original Crystal trajectory. All inputs are normalized. */
#ifdef __METAL_VERSION__
#define PXC_MOTION_SIN sin
#else
#include <math.h>
#define PXC_MOTION_SIN sinf
#endif

typedef struct {
    float forward;
    float lateral;
    float shrink;
    float grain;
    float rotation;
    float fade;
} PXCWindMotion;

static inline float PXCMotionClamp01(float x) {
    if (!(x >= 0.0f)) return 0.0f;
    return x > 1.0f ? 1.0f : x;
}
static inline float PXCMotionSmooth(float low, float high, float x) {
    float t = PXCMotionClamp01((x - low) / (high - low));
    return t * t * (3.0f - 2.0f * t);
}
static inline float PXCWindReleaseProgress(float primary, float cross, float random) {
    primary = PXCMotionClamp01(primary);
    cross = PXCMotionClamp01(cross);
    random = PXCMotionClamp01(random);
    /* An irregular advancing front rather than simultaneously released rows.
     * Limit the release span to leave at least 43% of the effect for drifting. */
    float bend = PXC_MOTION_SIN(cross * 7.3f + 0.8f) * 0.035f
               + PXC_MOTION_SIN(cross * 18.7f) * 0.014f;
    float release = primary * 0.48f + bend + (random - 0.5f) * 0.13f;
    return release < 0.0f ? 0.0f : release > 0.57f ? 0.57f : release;
}
static inline PXCWindMotion PXCWindEvaluate(float age01, float seed, float drift, float swirl) {
    float t = PXCMotionClamp01(age01);
    seed = PXCMotionClamp01(seed);
    drift = PXCMotionClamp01(drift);
    swirl = PXCMotionClamp01((swirl + 1.0f) * 0.5f) * 2.0f - 1.0f;
    float caught = PXCMotionSmooth(0.0f, 0.28f, t);
    float grain = PXCMotionSmooth(0.02f, 0.24f, t);
    float phase = seed * 6.28318530718f;
    /* Zero displacement and zero speed at release. Turbulence is introduced
     * smoothly; never add a seeded sine offset instantaneously at t=0. */
    float carry = (0.30f + 0.70f * drift) * t * t * (1.15f - 0.15f * t);
    float eddy = caught * (0.42f * swirl * PXC_MOTION_SIN(phase + t * 4.8f)
               + 0.20f * PXC_MOTION_SIN(phase * 1.7f + t * 9.2f));
    float lift = caught * (drift - 0.5f) * 0.30f * t;
    float targetScale = 0.20f + 0.24f * seed;
    PXCWindMotion m;
    m.forward = carry;
    m.lateral = eddy + lift;
    m.shrink = 1.0f - (1.0f - targetScale) * grain;
    m.grain = grain;
    m.rotation = caught * (swirl * 2.5f * t + 0.45f * PXC_MOTION_SIN(phase + t * 5.0f));
    m.fade = 1.0f - PXCMotionSmooth(0.22f + seed * 0.10f, 1.0f, t);
    return m;
}

#undef PXC_MOTION_SIN
#endif
