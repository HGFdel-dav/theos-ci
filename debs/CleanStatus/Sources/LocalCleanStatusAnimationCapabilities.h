#pragma once
#include <stdint.h>
#include <notify.h>

// In-memory Darwin notify state, published only by SpringBoard after ABI checks.
// No preference/configuration file is written by injected code.
enum {
    LCSAnimationAppSupported = 1u << 0,
    LCSAnimationGenieSupported = 1u << 1,
    LCSAnimationIconsSupported = 1u << 2,
    LCSAnimationDropletSupported = 1u << 3,
    LCSAnimationSheetSupported = 1u << 4,
    LCSAnimationGlobalSlowSupported = 1u << 5,
    LCSAnimationBlurSupported = 1u << 6,
};
#define LCS_ANIMATION_CAPABILITIES_NAME "com.local.cleanstatus.animation-capabilities.v1"
#define LCS_ANIMATION_CAPABILITIES_MAGIC UINT64_C(0x4c43534100010000)
static inline void local_cleanstatus_publishAnimationCapabilities(uint32_t flags) {
    // Keep a registration alive for the lifetime of the publishing process.
    static int token = -1;
    if (token == -1 && notify_register_check(LCS_ANIMATION_CAPABILITIES_NAME, &token) != NOTIFY_STATUS_OK) {
        token = -1;
        return;
    }
    if (notify_set_state(token, LCS_ANIMATION_CAPABILITIES_MAGIC | (flags & 127u)) == NOTIFY_STATUS_OK)
        notify_post(LCS_ANIMATION_CAPABILITIES_NAME);
}
static inline uint32_t local_cleanstatus_animationCapabilityFlags(int *known) {
    int token = 0;
    uint64_t state = 0;
    if (known) *known = 0;
    if (notify_register_check(LCS_ANIMATION_CAPABILITIES_NAME, &token) != NOTIFY_STATUS_OK) return 0;
    uint32_t status = notify_get_state(token, &state);
    notify_cancel(token);
    if (status != NOTIFY_STATUS_OK || (state & ~UINT64_C(127)) != LCS_ANIMATION_CAPABILITIES_MAGIC) return 0;
    if (known) *known = 1;
    return (uint32_t)(state & 127u);
}
