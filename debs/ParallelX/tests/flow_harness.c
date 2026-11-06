#include "../Common/PXCloneFlow.h"
#include <assert.h>
#include <stdio.h>

static unsigned checks;
#define CHECK(x) do { assert(x); ++checks; } while (0)

static void test_roundtrip(uint64_t token, bool auth) {
    PXCloneFlow flow = {0};
    CHECK(PXCloneFlowBegin(&flow, token));
    CHECK(!PXCloneFlowBegin(&flow, token + 1));
    CHECK(!PXCloneFlowMayOpen(&flow, token, true, false));
    CHECK(!PXCloneFlowAdvance(&flow, token, PXCloneFlowClosing, PXCloneFlowOpening));
    CHECK(PXCloneFlowAdvance(&flow, token, PXCloneFlowClosing, PXCloneFlowTerminating));
    CHECK(!PXCloneFlowMayOpen(&flow, token, true, false));
    if (auth) {
        CHECK(PXCloneFlowAdvance(&flow, token, PXCloneFlowTerminating, PXCloneFlowAuthenticating));
        CHECK(!PXCloneFlowMayOpen(&flow, token, true, false));
        CHECK(!PXCloneFlowAdvance(&flow, token + 1, PXCloneFlowAuthenticating, PXCloneFlowVerifying));
        CHECK(PXCloneFlowAdvance(&flow, token, PXCloneFlowAuthenticating, PXCloneFlowVerifying));
    } else {
        CHECK(PXCloneFlowAdvance(&flow, token, PXCloneFlowTerminating, PXCloneFlowVerifying));
    }
    CHECK(!PXCloneFlowMayOpen(&flow, token, false, false));
    CHECK(!PXCloneFlowMayOpen(&flow, token, true, true));
    CHECK(!PXCloneFlowMayOpen(&flow, token + 1, true, false));
    CHECK(PXCloneFlowMayOpen(&flow, token, true, false));
    CHECK(PXCloneFlowAdvance(&flow, token, PXCloneFlowVerifying, PXCloneFlowOpening));
    CHECK(!PXCloneFlowMaySucceed(&flow, token, true, false));
    CHECK(!PXCloneFlowMaySucceed(&flow, token, false, true));
    CHECK(!PXCloneFlowMaySucceed(&flow, token + 1, true, true));
    CHECK(PXCloneFlowMaySucceed(&flow, token, true, true));
    CHECK(PXCloneFlowRelease(&flow, token));
    CHECK(!PXCloneFlowRelease(&flow, token));
    CHECK(!PXCloneFlowMaySucceed(&flow, token, true, true));
}

int main(void) {
    // The same production gate applies to first A, switched B, returned A,
    // new C, and reused A. No special "second launch" success shortcut.
    for (uint64_t i = 1; i <= 1000; i++) {
        test_roundtrip(i * 4, false);
        test_roundtrip(i * 4 + 1, true);
        test_roundtrip(i * 4 + 2, true);
        test_roundtrip(i * 4 + 3, true);
    }
    for (int phase = PXCloneFlowClosing; phase <= PXCloneFlowOpening; phase++) {
        PXCloneFlow flow = {41, (PXCloneFlowPhase)phase};
        CHECK(PXCloneFlowTimeout(&flow, 41));
        CHECK(flow.phase == (phase == PXCloneFlowAuthenticating ?
                             PXCloneFlowQuarantined : PXCloneFlowFailed));
        CHECK(!PXCloneFlowBegin(&flow, 42));
        CHECK(!PXCloneFlowMayOpen(&flow, 41, true, false));
        CHECK(!PXCloneFlowMaySucceed(&flow, 41, true, true));
        // In production, only the actual late authentication callback releases
        // a quarantine; the timer is not allowed to start another switch.
        CHECK(PXCloneFlowRelease(&flow, 41));
        CHECK(PXCloneFlowBegin(&flow, 42));
        CHECK(!PXCloneFlowAdvance(&flow, 41, PXCloneFlowClosing, PXCloneFlowTerminating));
    }
    printf("production_flow_checks=%u\n", checks);
    return 0;
}
