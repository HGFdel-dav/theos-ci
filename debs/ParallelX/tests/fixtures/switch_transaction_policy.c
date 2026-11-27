#include "../../Common/PXCloneTransactionDiagnostics.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    PXCloneTransactionEdgeKey edges[PXCloneTransactionStageLimit] = {0};
    size_t count = 0;
    const char *stages[] = {"request", "closing_complete", "old_processes_exited", "authenticate_without_reload", "crane_reply_yes", "verification_started", "container_verified", "native_split_requested", "native_completion_received", "native_completion_ok", "done", "transaction_finished"};
    for (unsigned i = 0; i < 10; ++i) {
        int slot = PXCloneTransactionSlot(edges, count, stages[i], 0);
        assert(slot == (int)count); edges[count++] = (PXCloneTransactionEdgeKey){stages[i], 0};
    }
    for (unsigned i = 0; i < 5000; ++i) assert(PXCloneTransactionSlot(edges, count, "open_visibility", 0) == -1);
    assert(count == 10 && !strcmp(edges[0].stage, "request"));
    assert(PXCloneTransactionSlot(edges, count, "native_completion_ok", 0) == 9);
    assert(PXCloneTransactionSlot(edges, count, "native_completion_ok", 1) == 10);
    assert(fabs(PXCloneTransactionDeltaMS(100, 116.967) - 16967) < 0.001);
    assert(PXCloneTransactionDeltaMS(10, 9) == -1);
    assert(PXCloneTransactionDeltaMS(10, NAN) == -1);
    for (unsigned i = 10; i < 38; ++i) edges[count++] = (PXCloneTransactionEdgeKey){"native_retry", i};
    assert(PXCloneTransactionSlot(edges, count, "excess", 0) == -1);
    assert(PXCloneTransactionSlot(edges, count, "done", 0) == 38);
    edges[count++] = (PXCloneTransactionEdgeKey){"done", 0};
    assert(PXCloneTransactionSlot(edges, count, "transaction_finished", 0) == 39);
    edges[count++] = (PXCloneTransactionEdgeKey){"transaction_finished", 0};
    assert(PXCloneTransactionSlot(edges, count, "excess", 0) == -1);
    puts("production_policy_checks=5021");
    return 0;
}
