#pragma once
#include <stdbool.h>

typedef enum { LCSButtonOriginNative=0, LCSButtonOriginCellular=1 } LCSButtonOrigin;
static inline bool LCSRoundButtonAllowsGesture(bool isCellularGesture,
                                               bool nativeOriginalDecision,
                                               bool cellularLocalGate) {
    return isCellularGesture ? cellularLocalGate : nativeOriginalDecision;
}

typedef enum { LCSCellularExpansionUnknown=-1, LCSCellularExpansionCollapsed=0, LCSCellularExpansionExpanded=1 } LCSCellularExpansion;
static inline bool LCSCellularMayBeginPress(LCSCellularExpansion expansion,
                                            bool gestureIsOwned,
                                            bool localGate) {
    bool validExpansion=expansion==LCSCellularExpansionUnknown||
        expansion==LCSCellularExpansionCollapsed||expansion==LCSCellularExpansionExpanded;
    return validExpansion && gestureIsOwned && localGate;
}
static inline bool LCSCellularWindowFallbackAllows(bool usingWindowFallback,
                                                    bool directTouch,
                                                    bool visible,
                                                    bool hitTargetRegion) {
    return usingWindowFallback && !directTouch && visible && hitTargetRegion;
}
