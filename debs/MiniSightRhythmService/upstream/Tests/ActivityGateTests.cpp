#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>

#include "../AudioActivityGate.h"

namespace {

using MSHFAudioActivity::EnergyAccumulator;
using MSHFAudioActivity::Gate;
using MSHFAudioActivity::Observation;

bool FeedBurst(double sampleRate, double burstMilliseconds) {
    EnergyAccumulator accumulator;
    Gate gate;
    uint64_t burstFrames = static_cast<uint64_t>(
        llround(sampleRate * burstMilliseconds / 1000.0));
    for (uint64_t index = 0; index < burstFrames; ++index) {
        Observation observation;
        if (accumulator.Append(0.01f, sampleRate, &observation)) {
            gate.Observe(observation);
        }
    }
    return gate.active();
}

void QualifyActive(Gate *gate) {
    Observation energetic{UINT64_C(20000000), -40.0f};
    for (unsigned index = 0; index < 5; ++index) {
        gate->Observe(energetic);
    }
    assert(gate->active());
}

} // namespace

int main(void) {
    for (double sampleRate : {44100.0, 48000.0}) {
        assert(!FeedBurst(sampleRate, 20));
        assert(!FeedBurst(sampleRate, 60));
        assert(!FeedBurst(sampleRate, 90));
        assert(FeedBurst(sampleRate, 110));
        assert(FeedBurst(sampleRate, 200));
    }

    Gate gate;
    assert(!gate.active());
    Observation energetic{UINT64_C(50000000), -40.0f};
    gate.Observe(energetic);
    assert(!gate.active());
    assert(gate.attackDurationNanoseconds() == UINT64_C(50000000));
    gate.Observe({UINT64_C(10000000), -75.0f});
    assert(gate.attackDurationNanoseconds() == 0);

    QualifyActive(&gate);
    gate.Observe({UINT64_C(300000000), -90.0f});
    assert(gate.active());
    gate.Observe({UINT64_C(10000000), -77.0f});
    assert(gate.active());
    assert(gate.releaseDurationNanoseconds() == 0);
    gate.Observe({UINT64_C(1249000000), -90.0f});
    assert(gate.active());
    gate.Observe({UINT64_C(1000000), -90.0f});
    assert(!gate.active());

    QualifyActive(&gate);
    gate.Observe({UINT64_C(1000000000), -90.0f});
    gate.BreakContinuity();
    assert(gate.active());
    assert(gate.releaseDurationNanoseconds() == 0);
    gate.Observe({UINT64_C(100000000), -90.0f});
    assert(gate.active());

    gate.ObserveCaptureAge(UINT64_C(1249000000));
    assert(gate.active());
    gate.ObserveCaptureAge(UINT64_C(1250000000));
    assert(!gate.active());

    gate.Observe({UINT64_C(80000000), -40.0f});
    assert(gate.attackDurationNanoseconds() == UINT64_C(80000000));
    gate.BreakContinuity();
    assert(!gate.active());
    assert(gate.attackDurationNanoseconds() == 0);

    EnergyAccumulator accumulator;
    Observation observation;
    for (uint32_t index = 0;
         index < MSHFAudioActivity::kEnergyBlockFrames - 1; ++index) {
        assert(!accumulator.Append(0.5f, 48000, &observation));
    }
    assert(accumulator.pendingFrameCount() == 255);
    accumulator.Reset();
    assert(accumulator.pendingFrameCount() == 0);
    for (uint32_t index = 0;
         index < MSHFAudioActivity::kEnergyBlockFrames; ++index) {
        bool complete = accumulator.Append(0.5f, 48000, &observation);
        assert(complete ==
               (index + 1 == MSHFAudioActivity::kEnergyBlockFrames));
    }
    assert(observation.coveredDurationNanoseconds == UINT64_C(5333333));
    assert(fabsf(observation.rmsDecibels + 6.0206f) < 0.001f);

    puts("Audio activity gate tests passed");
    return 0;
}
