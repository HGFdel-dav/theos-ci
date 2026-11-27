#define main PXLegacyTraceFixtureMain
#import "../trace_writer_host.m"
#undef main
#import "../../Common/PXCloneTransactionDiagnostics.h"
#include <assert.h>
static NSDictionary *sample(NSString *session, unsigned token, NSString *stage, double time, unsigned phase, unsigned retry) {
    return @{ @"session": session, @"token": @(token), @"stage": stage, @"monotonic": @(time),
        @"phase": @(phase), @"retry": @(retry), @"code": @0, @"bundle": @"test.bundle", @"targetHash": @42,
        @"processPID": @123, @"time": @(-9000000 + time) };
}
static PXCloneTraceState save(NSArray *rows) {
    __block BOOL done = NO;
    __block PXCloneTraceState result = PXCloneTraceStateUnknown;
    [PXCloneTrace writeEvents:@[] completion:^(PXCloneTraceState state, NSError *error) {
        (void)error; result = state; done = YES;
    } transactions:rows];
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:8];
    while (!done && end.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    assert(done); return result;
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        NSString *session = @"00000000-0000-0000-0000-000000000001";
        NSString *other = @"00000000-0000-0000-0000-000000000002";
        if (argc == 2 && !strcmp(argv[1], "legacy")) { assert(writeEvents(@[]) == PXCloneTraceStatePersisted); return 0; }
        if (argc == 2 && !strcmp(argv[1], "corrupt")) { assert(save(@[]) == PXCloneTraceStateReadbackFailure); return 0; }
        if (argc == 2 && !strcmp(argv[1], "restart")) {
            NSArray *next = PXCloneTransactionObserve(@[], sample(other, 5, @"request", 1, 1, 0));
            assert(save(next) == PXCloneTraceStatePersisted); return 0;
        }
        NSArray *rows = @[];
        const char *stages[] = {"request", "closing_complete", "old_processes_exited", "authenticate_without_reload", "crane_reply_yes", "verification_started", "container_verified", "native_split_requested", "native_completion_received", "native_completion_ok"};
        unsigned phases[] = {1,2,2,3,3,4,4,5,5,5};
        for (unsigned i=0; i<10; ++i)
            rows = PXCloneTransactionObserve(rows, sample(session,5,@(stages[i]),100+i*.1,phases[i],0));
        for (unsigned i=0; i<5000; ++i)
            rows = PXCloneTransactionObserve(rows, sample(session,5,@"open_visibility",101+i*.003,5,0));
        rows = PXCloneTransactionObserve(rows, sample(session,5,@"done ms=16967 ok=1",116.967,5,0));
        rows = PXCloneTransactionObserve(rows, sample(session,5,@"transaction_finished",116.967,5,0));
        NSDictionary *slow = rows[0];
        assert([slow[@"stages"] count] == 12);
        assert([slow[@"stages"][0][@"stage"] isEqual:@"request"]);
        assert([slow[@"visibilitySamples"] intValue] == 5000);
        assert(fabs([slow[@"elapsedMS"] doubleValue]-16967) < .001);
        double total=0; for (NSNumber *n in [slow[@"phaseDurationsMS"] allValues]) total += n.doubleValue;
        assert(fabs(total-16967)<.001 && [slow[@"status"] isEqual:@"success"]);
        assert(PXCloneTransactionsValid(rows));
        assert(save(rows) == PXCloneTraceStatePersisted);
        NSArray *ongoing=PXCloneTransactionObserve(@[],sample(session,6,@"request",200,1,0));
        ongoing=PXCloneTransactionObserve(ongoing,sample(session,6,@"native_retry",201,5,1));
        assert([ongoing[0][@"retryCount"] intValue]==1 && ![ongoing[0][@"completed"] boolValue]);
        assert(save(ongoing) == PXCloneTraceStatePersisted);
        NSArray *isolated=PXCloneTransactionsMerge(rows,PXCloneTransactionObserve(@[],sample(other,5,@"request",1,1,0)));
        assert(isolated.count==2);
        NSArray *failed=PXCloneTransactionObserve(@[],sample(session,7,@"request",1,1,0));
        failed=PXCloneTransactionObserve(failed,sample(session,7,@"failed",2,1,0));
        failed=PXCloneTransactionObserve(failed,sample(session,7,@"transaction_finished",2,1,0));
        assert([failed[0][@"status"] isEqual:@"failed"]);
        NSArray *cancelled=PXCloneTransactionObserve(@[],sample(session,8,@"request",1,1,0));
        cancelled=PXCloneTransactionObserve(cancelled,sample(session,8,@"transaction_finished",1.1,1,0));
        assert([cancelled[0][@"status"] isEqual:@"superseded"]);
        for (unsigned i=10; i<20; ++i) rows=PXCloneTransactionObserve(rows,sample(session,i,@"request",i,1,0));
        assert(rows.count==4 && [rows[0][@"token"] intValue]==16);
        assert(PXCloneTransactionObserve(rows,sample(session,19,@"old_processes_exited",0,2,0))==rows);
        puts("production_builder_and_writer=PASS");
        return 0;
    }
}
