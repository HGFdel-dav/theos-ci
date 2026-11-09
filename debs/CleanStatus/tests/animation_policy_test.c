#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../Sources/LocalCleanStatusAnimationPolicy.h"

int main(void) {
    assert(LCS_ANIMATION_BOOL_COUNT == 8);
    assert(LCS_ANIMATION_NUMBER_COUNT == 6);
    assert(!lcsAnimationBoolSettings[0].fallback);
    assert(!strcmp(lcsAnimationBoolSettings[0].key, "animationEnabled"));
    // The separate animation master can never be enabled by an old feature flag.
    for (int enabled = 0; enabled <= 1; ++enabled) {
        for (int reduced = 0; reduced <= 1; ++reduced) {
            assert(local_cleanstatus_animationActive(enabled, reduced) == (enabled && !reduced));
        }
    }
    for (size_t i = 0; i < LCS_ANIMATION_NUMBER_COUNT; ++i) {
        const LCSAnimationNumberSetting *s = &lcsAnimationNumberSettings[i];
        assert(s->fallback >= s->minimum && s->fallback <= s->maximum);
        assert(local_cleanstatus_animationNumber(s->minimum, s) == s->minimum);
        assert(local_cleanstatus_animationNumber(s->maximum, s) == s->maximum);
        assert(local_cleanstatus_animationNumber(NAN, s) == s->fallback);
        assert(local_cleanstatus_animationNumber(INFINITY, s) == s->fallback);
        assert(local_cleanstatus_animationNumber(-INFINITY, s) == s->fallback);
        assert(local_cleanstatus_animationNumber(s->minimum - 0.01, s) == s->fallback);
        assert(local_cleanstatus_animationNumber(s->maximum + 0.01, s) == s->fallback);
        double mid = (s->minimum + s->maximum) / 2;
        assert(local_cleanstatus_animationNumber(mid, s) == mid);
    }
    puts("PASS animation master/reduce-motion truth table, finite/range/default boundaries");
}
