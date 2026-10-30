#pragma once
// Generated: run generate_motion_source.py after changing PXCDustMotion.h.
#define PXC_DUST_MOTION_METAL_SOURCE \
    "#ifndef PXC_DUST_MOTION_H\n" \
    "#define PXC_DUST_MOTION_H\n" \
    "/* Shared by portable C tests and the embedded Metal shader. Style 0 is Wind,\n" \
    " * style 1 is the original Crystal trajectory. All inputs are normalized. */\n" \
    "#ifdef __METAL_VERSION__\n" \
    "#define PXC_MOTION_SIN sin\n" \
    "#else\n" \
    "#include <math.h>\n" \
    "#define PXC_MOTION_SIN sinf\n" \
    "#endif\n" \
    "\n" \
    "typedef struct {\n" \
    "    float forward;\n" \
    "    float lateral;\n" \
    "    float shrink;\n" \
    "    float grain;\n" \
    "    float rotation;\n" \
    "    float fade;\n" \
    "} PXCWindMotion;\n" \
    "\n" \
    "static inline float PXCMotionClamp01(float x) {\n" \
    "    if (!(x >= 0.0f)) return 0.0f;\n" \
    "    return x > 1.0f ? 1.0f : x;\n" \
    "}\n" \
    "static inline float PXCMotionSmooth(float low, float high, float x) {\n" \
    "    float t = PXCMotionClamp01((x - low) / (high - low));\n" \
    "    return t * t * (3.0f - 2.0f * t);\n" \
    "}\n" \
    "static inline float PXCWindReleaseProgress(float primary, float cross, float random) {\n" \
    "    primary = PXCMotionClamp01(primary);\n" \
    "    cross = PXCMotionClamp01(cross);\n" \
    "    random = PXCMotionClamp01(random);\n" \
    "    /* An irregular advancing front rather than simultaneously released rows.\n" \
    "     * Limit the release span to leave at least 43% of the effect for drifting. */\n" \
    "    float bend = PXC_MOTION_SIN(cross * 7.3f + 0.8f) * 0.035f\n" \
    "               + PXC_MOTION_SIN(cross * 18.7f) * 0.014f;\n" \
    "    float release = primary * 0.48f + bend + (random - 0.5f) * 0.13f;\n" \
    "    return release < 0.0f ? 0.0f : release > 0.57f ? 0.57f : release;\n" \
    "}\n" \
    "static inline PXCWindMotion PXCWindEvaluate(float age01, float seed, float drift, float swirl) {\n" \
    "    float t = PXCMotionClamp01(age01);\n" \
    "    seed = PXCMotionClamp01(seed);\n" \
    "    drift = PXCMotionClamp01(drift);\n" \
    "    swirl = PXCMotionClamp01((swirl + 1.0f) * 0.5f) * 2.0f - 1.0f;\n" \
    "    float caught = PXCMotionSmooth(0.0f, 0.28f, t);\n" \
    "    float grain = PXCMotionSmooth(0.02f, 0.24f, t);\n" \
    "    float phase = seed * 6.28318530718f;\n" \
    "    /* Zero displacement and zero speed at release. Turbulence is introduced\n" \
    "     * smoothly; never add a seeded sine offset instantaneously at t=0. */\n" \
    "    float carry = (0.30f + 0.70f * drift) * t * t * (1.15f - 0.15f * t);\n" \
    "    float eddy = caught * (0.42f * swirl * PXC_MOTION_SIN(phase + t * 4.8f)\n" \
    "               + 0.20f * PXC_MOTION_SIN(phase * 1.7f + t * 9.2f));\n" \
    "    float lift = caught * (drift - 0.5f) * 0.30f * t;\n" \
    "    float targetScale = 0.20f + 0.24f * seed;\n" \
    "    PXCWindMotion m;\n" \
    "    m.forward = carry;\n" \
    "    m.lateral = eddy + lift;\n" \
    "    m.shrink = 1.0f - (1.0f - targetScale) * grain;\n" \
    "    m.grain = grain;\n" \
    "    m.rotation = caught * (swirl * 2.5f * t + 0.45f * PXC_MOTION_SIN(phase + t * 5.0f));\n" \
    "    m.fade = 1.0f - PXCMotionSmooth(0.22f + seed * 0.10f, 1.0f, t);\n" \
    "    return m;\n" \
    "}\n" \
    "\n" \
    "#undef PXC_MOTION_SIN\n" \
    "#endif\n"
