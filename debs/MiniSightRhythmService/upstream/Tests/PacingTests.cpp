#include "../FeaturePacing.h"

#include <assert.h>
#include <stdint.h>
#include <stdio.h>

static uint32_t CountDeliveries(uint16_t clientRate, uint16_t analysisRate,
                                uint32_t ticks) {
    MSHFFeaturePacer pacer{};
    MSHFResetFeaturePacer(&pacer);
    uint32_t deliveries = 0;
    for (uint32_t tick = 0; tick < ticks; ++tick) {
        deliveries += MSHFFeaturePacerShouldDeliver(
            &pacer, clientRate, analysisRate);
    }
    return deliveries;
}

int main(void) {
    for (uint16_t rate = 5; rate <= 60; ++rate) {
        assert(CountDeliveries(rate, 60, 60) == rate);
        assert(CountDeliveries(rate, 60, 600) == rate * 10);
    }

    assert(CountDeliveries(24, 24, 24) == 24);
    assert(CountDeliveries(5, 24, 24) == 5);
    assert(CountDeliveries(12, 24, 24) == 12);
    assert(CountDeliveries(30, 30, 30) == 30);
    assert(CountDeliveries(60, 60, 60) == 60);

    MSHFFeaturePacer pacer{};
    MSHFResetFeaturePacer(&pacer);
    assert(MSHFFeaturePacerShouldDeliver(&pacer, 24, 60));

    constexpr uint64_t heartbeat = UINT64_C(2000000000);
    MSHFSilencePacer silencePacer{};
    MSHFResetSilencePacer(&silencePacer);
    assert(MSHFSilencePacerShouldDeliver(&silencePacer, false, 1,
                                         heartbeat) ==
           MSHFSilencePacerDeliver);
    assert(MSHFSilencePacerShouldDeliver(&silencePacer, true, 2,
                                         heartbeat) ==
           MSHFSilencePacerDeliverTransition);
    for (uint64_t now = 3; now < heartbeat + 2; now += 10000000) {
        assert(MSHFSilencePacerShouldDeliver(&silencePacer, true, now,
                                             heartbeat) ==
               MSHFSilencePacerSuppress);
    }
    assert(MSHFSilencePacerShouldDeliver(&silencePacer, true, heartbeat + 2,
                                         heartbeat) ==
           MSHFSilencePacerDeliver);
    assert(MSHFSilencePacerShouldDeliver(&silencePacer, false, heartbeat + 3,
                                         heartbeat) ==
           MSHFSilencePacerDeliverTransition);
    assert(!MSHFFeaturePacerShouldDeliver(&pacer, 24, 60));
    MSHFResetFeaturePacer(&pacer);
    assert(MSHFFeaturePacerShouldDeliver(&pacer, 24, 60));

    puts("Feature pacing tests passed");
    return 0;
}
