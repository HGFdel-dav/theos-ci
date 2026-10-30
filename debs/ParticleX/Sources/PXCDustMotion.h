#ifndef PXC_DUST_MOTION_H
#define PXC_DUST_MOTION_H
/* Shared by portable C tests and the embedded Metal shader. Style 0 is Wind,
 * style 1 is the original Crystal trajectory. All inputs are normalized. */
#ifdef __METAL_VERSION__
#define PXC_MOTION_SIN sin
#define PXC_MOTION_EXP exp
#define PXC_MOTION_ATAN2 atan2
#define PXC_MOTION_THREAD thread
#else
#include <math.h>
#define PXC_MOTION_SIN sinf
#define PXC_MOTION_EXP expf
#define PXC_MOTION_ATAN2 atan2f
#define PXC_MOTION_THREAD
#endif

typedef struct {
    float forward;
    float lateral;
    float shrink;
    float grain;
    float rotation;
    float fade;
} PXCWindMotion;

#ifdef __METAL_VERSION__
typedef float2 PXCWindWarp;
#else
typedef struct {
    float x;
    float y;
} PXCWindWarp;
#endif

typedef struct {
    float angle;
    float curve;
} PXCWindStream;

static inline float PXCMotionClamp(float x, float low, float high) {
    if (!(x >= low)) return low;
    return x > high ? high : x;
}
static inline float PXCMotionClamp01(float x) { return PXCMotionClamp(x, 0.0f, 1.0f); }
static inline float PXCMotionSmooth(float low, float high, float x) {
    float t = PXCMotionClamp01((x - low) / (high - low));
    return t * t * (3.0f - 2.0f * t);
}
/* Three localized starting kernels per card. Phases come from one effect seed;
 * all particles on a card share them so release is coherent, not random noise.
 * Outputs are x0,y0,x1,y1,x2,y2. */
static inline void PXCWindSeedPoints(float phase, PXC_MOTION_THREAD float *out) {
    float a = phase * 6.28318530718f;
    out[0] = 0.11f + 0.13f * (0.5f + 0.5f * PXC_MOTION_SIN(a * 1.31f + 0.40f));
    out[1] = 0.76f + 0.13f * (0.5f + 0.5f * PXC_MOTION_SIN(a * 0.87f + 2.20f));
    out[2] = 0.74f + 0.15f * (0.5f + 0.5f * PXC_MOTION_SIN(a * 1.73f + 3.10f));
    out[3] = 0.13f + 0.13f * (0.5f + 0.5f * PXC_MOTION_SIN(a * 1.09f + 4.40f));
    out[4] = 0.36f + 0.22f * (0.5f + 0.5f * PXC_MOTION_SIN(a * 2.17f + 5.20f));
    out[5] = 0.40f + 0.24f * (0.5f + 0.5f * PXC_MOTION_SIN(a * 1.47f + 1.30f));
    for (int i = 0; i < 6; i++) out[i] = PXCMotionClamp(out[i], 0.07f, 0.93f);
}

/* Lower-left, upper-right and middle kernels release independently. Keep the
 * last 54%+ of each particle's life for travelling instead of vanishing in place. */
static inline float PXCWindReleaseAt(float x, float y, float random, float phase, float urgent) {
    float s[6];
    PXCWindSeedPoints(phase, s);
    x = PXCMotionClamp01(x);
    y = PXCMotionClamp01(y);
    random = PXCMotionClamp01(random);
    float d0 = (x - s[0]) * (x - s[0]) + (y - s[1]) * (y - s[1]) * 0.42f;
    float d1 = (x - s[2]) * (x - s[2]) + (y - s[3]) * (y - s[3]) * 0.42f;
    float d2 = (x - s[4]) * (x - s[4]) + (y - s[5]) * (y - s[5]) * 0.42f;
    float nearest = d0 < d1 ? d0 : d1;
    nearest = nearest < d2 ? nearest : d2;
    nearest = sqrt(nearest);
    urgent = PXCMotionClamp01(urgent);
    /* A tapped clear must move on the first frames instead of holding the
     * card while later rows are still waiting to be released. */
    float release = nearest * (0.62f - 0.51f * urgent) + (random - 0.5f) * 0.09f / (1.0f + 2.0f * urgent);
    return PXCMotionClamp(release, 0.005f + 0.005f * urgent, 0.46f - 0.37f * urgent);
}

/* A broad, continuous warped surface. Cards bend and twist before grain
 * separates; neighbouring tiles sample the same field so contours stay joined. */
static inline PXCWindWarp PXCWindWarpAt(float x, float y, float age01, float phase, float urgent) {
    float t = PXCMotionClamp01(age01);
    urgent = PXCMotionClamp01(urgent);
    float ramp = 0.17f - 0.135f * urgent;
    float strength = PXCMotionSmooth(0.0f, ramp, t)
                   * (1.0f - PXCMotionSmooth(0.47f, 0.86f, t));
    float s[6];
    PXCWindSeedPoints(phase, s);
    float wx = 0.0f;
    float wy = 0.0f;
    for (int i = 0; i < 3; i++) {
        float qx = x - s[i * 2];
        float qy = (y - s[i * 2 + 1]) * 1.45f;
        float weight = PXC_MOTION_EXP(-(qx * qx / 0.090f + qy * qy / 0.026f));
        float angle = (i == 1 ? -0.62f : 0.56f) * weight * strength;
        float c = PXC_MOTION_SIN(1.57079632679f + angle);
        float sn = PXC_MOTION_SIN(angle);
        wx += (qx * c - qy * sn - qx) * weight;
        wy += (qx * sn + qy * c - qy) * weight;
    }
    /* Low-frequency shear bends long text and card edges as well. */
    wx += 0.018f * PXC_MOTION_SIN(y * 7.4f + phase * 6.28318530718f) * strength;
    wy += 0.030f * PXC_MOTION_SIN(x * 8.1f + phase * 4.0f) * strength;
    PXCWindWarp w;
    w.x = wx;
    w.y = wy;
    return w;
}

/* Curl field: a few broad eddies point in deliberately different quadrants;
 * close particles share one heading while separate eddies curl away. */
static inline PXCWindStream PXCWindStreamAt(float x, float y, float phase, float seed) {
    const float cx[5] = { 0.12f, 0.86f, 0.42f, 0.66f, 0.50f };
    const float cy[5] = { 0.78f, 0.18f, 0.20f, 0.84f, 0.52f };
    const float heading[5] = { 2.55f, -0.75f, -2.45f, 1.05f, 0.15f };
    float a = phase * 6.28318530718f;
    float sx = 0.0f;
    float sy = 0.0f;
    for (int i = 0; i < 5; i++) {
        float qx = x - cx[i];
        float qy = (y - cy[i]) * 1.55f;
        float weight = PXC_MOTION_EXP(-(qx * qx / 0.105f + qy * qy / 0.045f));
        sx += PXC_MOTION_SIN(1.57079632679f + heading[i]) * weight;
        sy += PXC_MOTION_SIN(heading[i]) * weight;
    }
    float field = PXC_MOTION_ATAN2(sy, sx);
    float wobble = 0.20f * PXC_MOTION_SIN(x * 5.3f + y * 2.1f + a)
                 + 0.11f * PXC_MOTION_SIN(x * 2.4f - y * 6.7f + a * 1.7f);
    float curve = 1.25f * PXC_MOTION_SIN(x * 3.9f - y * 4.7f + a * 1.3f)
                + 0.55f * PXC_MOTION_SIN(x * 7.1f + y * 1.9f + a * 0.7f);
    PXCWindStream stream;
    stream.angle = PXCMotionClamp(field + wobble + (seed - 0.5f) * 0.40f, -2.85f, 2.85f);
    stream.curve = PXCMotionClamp(curve, -1.70f, 1.70f);
    return stream;
}

static inline PXCWindMotion PXCWindEvaluate(float age01, float seed, float drift, float swirl) {
    float t = PXCMotionClamp01(age01);
    seed = PXCMotionClamp01(seed);
    drift = PXCMotionClamp01(drift);
    swirl = PXCMotionClamp01((swirl + 1.0f) * 0.5f) * 2.0f - 1.0f;
    float caught = PXCMotionSmooth(0.0f, 0.24f, t);
    /* Surface breaks into a grain quickly; the grain itself then travels. */
    float grain = PXCMotionSmooth(0.005f, 0.085f, t);
    float phase = seed * 6.28318530718f;
    /* Zero displacement and zero speed at release. Turbulence is introduced
     * smoothly; never add a seeded sine offset instantaneously at t=0. */
    float carry = (0.34f + 0.72f * drift) * t * t * (1.18f - 0.18f * t);
    float eddy = caught * (0.54f * swirl * PXC_MOTION_SIN(phase + t * 5.6f)
               + 0.24f * PXC_MOTION_SIN(phase * 1.7f + t * 10.4f));
    float lift = caught * (drift - 0.5f) * 0.16f * t;
    float targetScale = 0.20f + 0.24f * seed;
    PXCWindMotion m;
    m.forward = carry;
    m.lateral = eddy + lift;
    m.shrink = 1.0f - (1.0f - targetScale) * grain;
    m.grain = 0.30f + 0.70f * grain;
    m.rotation = caught * (swirl * 2.2f * t + 0.55f * PXC_MOTION_SIN(phase + t * 5.0f));
    m.fade = 1.0f - PXCMotionSmooth(0.28f + seed * 0.10f, 1.0f, t);
    return m;
}

#undef PXC_MOTION_SIN
#undef PXC_MOTION_EXP
#undef PXC_MOTION_ATAN2
#undef PXC_MOTION_THREAD
#endif
