#pragma once
#include <math.h>
#include <stddef.h>
#include <stdbool.h>

typedef struct { const char *key; bool fallback; } LCSAnimationBoolSetting;
typedef struct { const char *key; double fallback, minimum, maximum; } LCSAnimationNumberSetting;
static const LCSAnimationBoolSetting lcsAnimationBoolSettings[] = {
    {"animationEnabled", false}, {"animationApps", true},
    {"animationGenie", true}, {"animationIcons", true},
    {"animationDroplet", true}, {"animationGestureBounce", true},
    {"animationClearSheet", true}, {"animationFlyBlur", true},
};
static const LCSAnimationNumberSetting lcsAnimationNumberSettings[] = {
    {"animationOpenResponse", 0.24, 0.12, 0.50},
    {"animationCloseSpeed", 1.0, 0.5, 2.0},
    {"animationGenieIntensity", 1.0, 0.0, 2.0},
    {"animationFlyStrength", 1.0, 0.0, 3.0},
    {"animationSlowFactor", 1.0, 1.0, 10.0},
    {"animationGlobalSlow", 1.0, 1.0, 5.0},
};
#define LCS_ANIMATION_BOOL_COUNT (sizeof(lcsAnimationBoolSettings)/sizeof(lcsAnimationBoolSettings[0]))
#define LCS_ANIMATION_NUMBER_COUNT (sizeof(lcsAnimationNumberSettings)/sizeof(lcsAnimationNumberSettings[0]))
static inline double local_cleanstatus_animationNumber(double value, const LCSAnimationNumberSetting *setting) {
    return isfinite(value) && value >= setting->minimum && value <= setting->maximum ? value : setting->fallback;
}
static inline bool local_cleanstatus_animationActive(bool animation, bool reduceMotion) {
    return animation && !reduceMotion;
}
