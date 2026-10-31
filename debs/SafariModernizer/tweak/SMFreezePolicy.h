#ifndef SM_FREEZE_POLICY_H
#define SM_FREEZE_POLICY_H

#include <string.h>

/* A module-loader freeze must skip the loader on the next page load. */
static inline int SMFreezeStageNeedsModuleOff(const char *stage) {
    if (!stage) return 0;
    return strncmp(stage, "module rewrite ", 15) == 0 ||
           strncmp(stage, "module scan ", 12) == 0;
}

static inline int SMFreezeNextLevel(int currentLevel, int tweakStep, int moduleStep) {
    if (!tweakStep || currentLevel >= 3) return currentLevel;
    int nextLevel = currentLevel + 1;
    if (moduleStep && nextLevel < 2) nextLevel = 2;
    return nextLevel;
}

#endif
