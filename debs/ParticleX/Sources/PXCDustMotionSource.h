#pragma once
// Generated: run generate_motion_source.py after changing PXCDustMotion.h.
#define PXC_DUST_MOTION_METAL_SOURCE \
    "#ifndef PXC_DUST_MOTION_H\n" \
    "#define PXC_DUST_MOTION_H\n" \
    "/* Shared by portable C tests and the embedded Metal shader. Style 0 is Wind,\n" \
    " * style 1 is the original Crystal trajectory. All inputs are normalized. */\n" \
    "#ifdef __METAL_VERSION__\n" \
    "#define PXC_MOTION_SIN sin\n" \
    "#define PXC_MOTION_EXP exp\n" \
    "#define PXC_MOTION_ATAN2 atan2\n" \
    "#define PXC_MOTION_THREAD thread\n" \
    "#else\n" \
    "#include <math.h>\n" \
    "#define PXC_MOTION_SIN sinf\n" \
    "#define PXC_MOTION_EXP expf\n" \
    "#define PXC_MOTION_ATAN2 atan2f\n" \
    "#define PXC_MOTION_THREAD\n" \
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
    "#ifdef __METAL_VERSION__\n" \
    "typedef float2 PXCWindWarp;\n" \
    "#else\n" \
    "typedef struct {\n" \
    "    float x;\n" \
    "    float y;\n" \
    "} PXCWindWarp;\n" \
    "#endif\n" \
    "\n" \
    "typedef struct {\n" \
    "    float angle;\n" \
    "    float curve;\n" \
    "} PXCWindStream;\n" \
    "\n" \
    "static inline float PXCMotionClamp(float x, float low, float high) {\n" \
    "    if (!(x >= low)) return low;\n" \
    "    return x > high ? high : x;\n" \
    "}\n" \
    "static inline float PXCMotionClamp01(float x) { return PXCMotionClamp(x, 0.0f, 1.0f); }\n" \
    "static inline float PXCMotionSmooth(float low, float high, float x) {\n" \
    "    float t = PXCMotionClamp01((x - low) / (high - low));\n" \
    "    return t * t * (3.0f - 2.0f * t);\n" \
    "}\n" \
    "/* Three localized starting kernels per card. Phases come from one effect seed;\n" \
    " * all particles on a card share them so release is coherent, not random noise.\n" \
    " * Outputs are x0,y0,x1,y1,x2,y2. */\n" \
    "static inline void PXCWindSeedPoints(float phase, PXC_MOTION_THREAD float *out) {\n" \
    "    float a = phase * 6.28318530718f;\n" \
    "    out[0] = 0.11f + 0.13f * (0.5f + 0.5f * PXC_MOTION_SIN(a * 1.31f + 0.40f));\n" \
    "    out[1] = 0.76f + 0.13f * (0.5f + 0.5f * PXC_MOTION_SIN(a * 0.87f + 2.20f));\n" \
    "    out[2] = 0.74f + 0.15f * (0.5f + 0.5f * PXC_MOTION_SIN(a * 1.73f + 3.10f));\n" \
    "    out[3] = 0.13f + 0.13f * (0.5f + 0.5f * PXC_MOTION_SIN(a * 1.09f + 4.40f));\n" \
    "    out[4] = 0.36f + 0.22f * (0.5f + 0.5f * PXC_MOTION_SIN(a * 2.17f + 5.20f));\n" \
    "    out[5] = 0.40f + 0.24f * (0.5f + 0.5f * PXC_MOTION_SIN(a * 1.47f + 1.30f));\n" \
    "    for (int i = 0; i < 6; i++) out[i] = PXCMotionClamp(out[i], 0.07f, 0.93f);\n" \
    "}\n" \
    "\n" \
    "/* Lower-left, upper-right and middle kernels release independently. Keep the\n" \
    " * last 54%+ of each particle's life for travelling instead of vanishing in place. */\n" \
    "static inline float PXCWindReleaseAt(float x, float y, float random, float phase, float urgent) {\n" \
    "    float s[6];\n" \
    "    PXCWindSeedPoints(phase, s);\n" \
    "    x = PXCMotionClamp01(x);\n" \
    "    y = PXCMotionClamp01(y);\n" \
    "    random = PXCMotionClamp01(random);\n" \
    "    float d0 = (x - s[0]) * (x - s[0]) + (y - s[1]) * (y - s[1]) * 0.42f;\n" \
    "    float d1 = (x - s[2]) * (x - s[2]) + (y - s[3]) * (y - s[3]) * 0.42f;\n" \
    "    float d2 = (x - s[4]) * (x - s[4]) + (y - s[5]) * (y - s[5]) * 0.42f;\n" \
    "    float nearest = d0 < d1 ? d0 : d1;\n" \
    "    nearest = nearest < d2 ? nearest : d2;\n" \
    "    nearest = sqrt(nearest);\n" \
    "    urgent = PXCMotionClamp01(urgent);\n" \
    "    /* A tapped clear must move on the first frames instead of holding the\n" \
    "     * card while later rows are still waiting to be released. */\n" \
    "    float release = nearest * (0.62f - 0.51f * urgent) + (random - 0.5f) * 0.09f / (1.0f + 2.0f * urgent);\n" \
    "    return PXCMotionClamp(release, 0.005f + 0.005f * urgent, 0.46f - 0.37f * urgent);\n" \
    "}\n" \
    "\n" \
    "/* A broad, continuous warped surface. Cards bend and twist before grain\n" \
    " * separates; neighbouring tiles sample the same field so contours stay joined. */\n" \
    "static inline PXCWindWarp PXCWindWarpAt(float x, float y, float age01, float phase, float urgent) {\n" \
    "    float t = PXCMotionClamp01(age01);\n" \
    "    urgent = PXCMotionClamp01(urgent);\n" \
    "    float ramp = 0.17f - 0.135f * urgent;\n" \
    "    float strength = PXCMotionSmooth(0.0f, ramp, t)\n" \
    "                   * (1.0f - PXCMotionSmooth(0.47f, 0.86f, t));\n" \
    "    float s[6];\n" \
    "    PXCWindSeedPoints(phase, s);\n" \
    "    float wx = 0.0f;\n" \
    "    float wy = 0.0f;\n" \
    "    for (int i = 0; i < 3; i++) {\n" \
    "        float qx = x - s[i * 2];\n" \
    "        float qy = (y - s[i * 2 + 1]) * 1.45f;\n" \
    "        float weight = PXC_MOTION_EXP(-(qx * qx / 0.090f + qy * qy / 0.026f));\n" \
    "        float angle = (i == 1 ? -0.62f : 0.56f) * weight * strength;\n" \
    "        float c = PXC_MOTION_SIN(1.57079632679f + angle);\n" \
    "        float sn = PXC_MOTION_SIN(angle);\n" \
    "        wx += (qx * c - qy * sn - qx) * weight;\n" \
    "        wy += (qx * sn + qy * c - qy) * weight;\n" \
    "    }\n" \
    "    /* Low-frequency shear bends long text and card edges as well. */\n" \
    "    wx += 0.018f * PXC_MOTION_SIN(y * 7.4f + phase * 6.28318530718f) * strength;\n" \
    "    wy += 0.030f * PXC_MOTION_SIN(x * 8.1f + phase * 4.0f) * strength;\n" \
    "    PXCWindWarp w;\n" \
    "    w.x = wx;\n" \
    "    w.y = wy;\n" \
    "    return w;\n" \
    "}\n" \
    "\n" \
    "/* Curl field: a few broad eddies point in deliberately different quadrants;\n" \
    " * close particles share one heading while separate eddies curl away. */\n" \
    "static inline PXCWindStream PXCWindStreamAt(float x, float y, float phase, float seed) {\n" \
    "    const float cx[5] = { 0.12f, 0.86f, 0.42f, 0.66f, 0.50f };\n" \
    "    const float cy[5] = { 0.78f, 0.18f, 0.20f, 0.84f, 0.52f };\n" \
    "    const float heading[5] = { 2.55f, -0.75f, -2.45f, 1.05f, 0.15f };\n" \
    "    float a = phase * 6.28318530718f;\n" \
    "    float sx = 0.0f;\n" \
    "    float sy = 0.0f;\n" \
    "    for (int i = 0; i < 5; i++) {\n" \
    "        float qx = x - cx[i];\n" \
    "        float qy = (y - cy[i]) * 1.55f;\n" \
    "        float weight = PXC_MOTION_EXP(-(qx * qx / 0.105f + qy * qy / 0.045f));\n" \
    "        sx += PXC_MOTION_SIN(1.57079632679f + heading[i]) * weight;\n" \
    "        sy += PXC_MOTION_SIN(heading[i]) * weight;\n" \
    "    }\n" \
    "    float field = PXC_MOTION_ATAN2(sy, sx);\n" \
    "    float wobble = 0.20f * PXC_MOTION_SIN(x * 5.3f + y * 2.1f + a)\n" \
    "                 + 0.11f * PXC_MOTION_SIN(x * 2.4f - y * 6.7f + a * 1.7f);\n" \
    "    float curve = 1.25f * PXC_MOTION_SIN(x * 3.9f - y * 4.7f + a * 1.3f)\n" \
    "                + 0.55f * PXC_MOTION_SIN(x * 7.1f + y * 1.9f + a * 0.7f);\n" \
    "    PXCWindStream stream;\n" \
    "    stream.angle = PXCMotionClamp(field + wobble + (seed - 0.5f) * 0.40f, -2.85f, 2.85f);\n" \
    "    stream.curve = PXCMotionClamp(curve, -1.70f, 1.70f);\n" \
    "    return stream;\n" \
    "}\n" \
    "\n" \
    "static inline PXCWindMotion PXCWindEvaluateUrgent(float age01, float seed, float drift, float swirl, float urgent) {\n" \
    "    float t = PXCMotionClamp01(age01);\n" \
    "    seed = PXCMotionClamp01(seed);\n" \
    "    drift = PXCMotionClamp01(drift);\n" \
    "    swirl = PXCMotionClamp01((swirl + 1.0f) * 0.5f) * 2.0f - 1.0f;\n" \
    "    urgent = PXCMotionClamp01(urgent);\n" \
    "    float caught = PXCMotionSmooth(0.0f, 0.24f - 0.16f * urgent, t);\n" \
    "    /* Surface breaks into a grain quickly; the grain itself then travels. */\n" \
    "    float grain = PXCMotionSmooth(0.005f, 0.085f, t);\n" \
    "    float phase = seed * 6.28318530718f;\n" \
    "    /* Urgent removal has a non-zero initial velocity. It still starts at the\n" \
    "     * source position, but avoids a multi-frame static preview after a tap. */\n" \
    "    float regularCarry = (0.34f + 0.72f * drift) * t * t * (1.18f - 0.18f * t);\n" \
    "    float urgentCarry = (0.42f + 0.68f * drift) * t * (1.42f - 0.42f * t);\n" \
    "    float carry = regularCarry * (1.0f - urgent) + urgentCarry * urgent;\n" \
    "    float eddy = caught * (0.54f * swirl * PXC_MOTION_SIN(phase + t * 5.6f)\n" \
    "               + 0.24f * PXC_MOTION_SIN(phase * 1.7f + t * 10.4f));\n" \
    "    float lift = caught * (drift - 0.5f) * 0.16f * t;\n" \
    "    float targetScale = 0.20f + 0.24f * seed;\n" \
    "    PXCWindMotion m;\n" \
    "    m.forward = carry;\n" \
    "    m.lateral = eddy + lift;\n" \
    "    m.shrink = 1.0f - (1.0f - targetScale) * grain;\n" \
    "    /* The preview already shows the intact surface. Every particle frame is\n" \
    "     * fully grain, never a square tile that later breaks. */\n" \
    "    m.grain = 1.0f;\n" \
    "    m.rotation = caught * (swirl * 2.2f * t + 0.55f * PXC_MOTION_SIN(phase + t * 5.0f));\n" \
    "    m.fade = 1.0f - PXCMotionSmooth(0.28f + seed * 0.10f, 1.0f, t);\n" \
    "    return m;\n" \
    "}\n" \
    "static inline PXCWindMotion PXCWindEvaluate(float age01, float seed, float drift, float swirl) {\n" \
    "    return PXCWindEvaluateUrgent(age01,seed,drift,swirl,0.0f);\n" \
    "}\n" \
    "\n" \
    "/* Visible sand uses its own time profile. Urgent means start immediately,\n" \
    " * not release the entire card at once. Legacy widget motion stays unchanged. */\n" \
    "static inline float PXCSandReleaseAtUrgent(float x,float y,float random,float phase,float urgent) {\n" \
    "    (void)random; /* same continuous release map for surface and grains */\n" \
    "    urgent=PXCMotionClamp01(urgent);\n" \
    "    float r=PXCWindReleaseAt(x,y,0.5f,phase,urgent);\n" \
    "    return PXCMotionClamp(r*(0.72f-0.20f*urgent),0.002f,0.32f-0.22f*urgent);\n" \
    "}\n" \
    "static inline float PXCSandReleaseAt(float x,float y,float random,float phase) {\n" \
    "    return PXCSandReleaseAtUrgent(x,y,random,phase,0.0f);\n" \
    "}\n" \
    "static inline float PXCSandReveal(float progress,float release) {\n" \
    "    return PXCMotionSmooth(release-0.006f,release+0.065f,progress);\n" \
    "}\n" \
    "static inline float PXCSandCarry(float age01,float drift) {\n" \
    "    float t=PXCMotionClamp01(age01);\n" \
    "    /* Give the first rendered frames a real velocity; the old cubic catch-up\n" \
    "     * was visually stationary even though the particle had been accepted. */\n" \
    "    float caught=PXCMotionSmooth(0.0f,0.045f,t);\n" \
    "    return (0.78f+0.42f*PXCMotionClamp01(drift))*t*(1.55f-0.55f*t)*caught;\n" \
    "}\n" \
    "static inline float PXCSandFade(float age01,float seed) {\n" \
    "    float t=PXCMotionClamp01(age01);\n" \
    "    return 1.0f-PXCMotionSmooth(0.62f+0.08f*PXCMotionClamp01(seed),1.0f,t);\n" \
    "}\n" \
    "/* Size follows sample spacing, never a fraction of a microscopic 6x6 tile. */\n" \
    "static inline float PXCSandDiameter(float cellWidth,float cellHeight,float divisions,float seed) {\n" \
    "    float spacing=sqrt(cellWidth*cellHeight)/(divisions>0.0f?divisions:1.0f);\n" \
    "    float d=spacing*(0.90f+0.14f*PXCMotionClamp01(seed));\n" \
    "    return PXCMotionClamp(d,1.15f,2.10f);\n" \
    "}\n" \
    "\n" \
    "#undef PXC_MOTION_SIN\n" \
    "#undef PXC_MOTION_EXP\n" \
    "#undef PXC_MOTION_ATAN2\n" \
    "#undef PXC_MOTION_THREAD\n" \
    "#endif\n"
