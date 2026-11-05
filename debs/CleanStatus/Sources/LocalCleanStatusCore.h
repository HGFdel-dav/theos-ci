#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <math.h>

typedef enum {
    LocalCleanStatusAirplane = 0, LocalCleanStatusAlarm, LocalCleanStatusBluetooth, LocalCleanStatusSiri, LocalCleanStatusCarPlay,
    LocalCleanStatusFocus, LocalCleanStatusLocation, LocalCleanStatusRotationLock, LocalCleanStatusCellular, LocalCleanStatusVPN, LocalCleanStatusWiFi,
    LocalCleanStatusUnknownParts, LocalCleanStatusModernBattery, LocalCleanStatusHideBolt, LocalCleanStatusTapLowPower, LocalCleanStatusFeatureCount
} LocalCleanStatusFeature;

static const char * const local_cleanstatus_featureNames[LocalCleanStatusFeatureCount] = {
    "hideAirplane", "hideAlarm", "hideBluetooth", "hideSiri", "hideCarPlay",
    "hideFocus", "hideLocation", "hideRotationLock", "hideCellular", "hideVPN", "hideWiFi",
    "hideUnknownParts", "modernBattery", "hideChargingBolt", "tapLowPower"
};

static inline uint32_t local_cleanstatus_featureBit(LocalCleanStatusFeature feature) {
    return (unsigned)feature < LocalCleanStatusFeatureCount ? (UINT32_C(1) << feature) : 0;
}
static inline bool local_cleanstatus_hasFeature(uint32_t flags, LocalCleanStatusFeature feature) {
    return (flags & local_cleanstatus_featureBit(feature)) != 0;
}
static inline uint32_t local_cleanstatus_effectiveFlags(bool enabled, uint32_t flags) {
    return enabled ? flags & ((UINT32_C(1) << LocalCleanStatusFeatureCount) - 1) : 0;
}
static inline int local_cleanstatus_batteryNumber(double fraction) {
    if (!isfinite(fraction) || fraction < 0.0) return -1;
    if (fraction > 1.0) fraction = 1.0;
    return (int)floor(fraction * 100.0 + 0.5);
}
static inline bool local_cleanstatus_tapAllowed(uint32_t flags, bool attached, bool locked,
                                  double now, double previous) {
    return local_cleanstatus_hasFeature(flags, LocalCleanStatusTapLowPower) && attached && !locked &&
        isfinite(now) && isfinite(previous) && now >= previous && now - previous >= 0.65;
}
