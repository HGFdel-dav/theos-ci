#include "../ActiveSourceToken.h"
#include "../LifecyclePolicy.h"

#include <assert.h>
#include <stdint.h>
#include <stdio.h>

int main(void) {
    uint32_t slot = 0;
    uint64_t generation = 0;

    uint64_t firstA = MSHFActiveSourceToken::Encode(0, 1);
    uint64_t sourceB = MSHFActiveSourceToken::Encode(1, 2);
    uint64_t reusedA = MSHFActiveSourceToken::Encode(0, 3);
    assert(firstA != 0 && sourceB != 0 && reusedA != 0);
    assert(firstA != reusedA);

    assert(MSHFActiveSourceToken::Decode(firstA, 2, &slot, &generation));
    assert(slot == 0 && generation == 1);
    assert(MSHFActiveSourceToken::Decode(sourceB, 2, &slot, &generation));
    assert(slot == 1 && generation == 2);
    assert(MSHFActiveSourceToken::Decode(reusedA, 2, &slot, &generation));
    assert(slot == 0 && generation == 3);

    assert(!MSHFActiveSourceToken::Decode(0, 2, &slot, &generation));
    assert(!MSHFActiveSourceToken::Decode(
        MSHFActiveSourceToken::Encode(2, 1), 2, &slot, &generation));
    assert(MSHFActiveSourceToken::Encode(0, 0) == 0);

    MSHFLifecyclePolicy::Backoff backoff{};
    uint64_t previousDelay = 0;
    for (unsigned attempt = 0; attempt < 32; ++attempt) {
        uint64_t delay = MSHFLifecyclePolicy::NextDelay(&backoff);
        assert(delay >= previousDelay);
        assert(delay <= MSHFLifecyclePolicy::kMaximumBackoffNs);
        previousDelay = delay;
    }
    assert(previousDelay == MSHFLifecyclePolicy::kMaximumBackoffNs);
    assert(!MSHFLifecyclePolicy::ShouldQuarantine(
        MSHFLifecyclePolicy::kDrainTimeoutNs - 1));
    assert(MSHFLifecyclePolicy::ShouldQuarantine(
        MSHFLifecyclePolicy::kDrainTimeoutNs));
    assert(MSHFLifecyclePolicy::kQuarantinePollNs >
           MSHFLifecyclePolicy::kMaximumBackoffNs);

    puts("Active source token tests passed");
    return 0;
}
