#pragma once
#include <stdbool.h>

typedef enum { LCSButtonOriginNative=0, LCSButtonOriginCellular=1 } LCSButtonOrigin;
static inline bool LCSRoundButtonAllowsGesture(bool isCellularGesture,
                                               bool nativeOriginalDecision,
                                               bool cellularLocalGate) {
    return isCellularGesture ? cellularLocalGate : nativeOriginalDecision;
}
