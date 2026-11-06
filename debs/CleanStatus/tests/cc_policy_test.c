#include <assert.h>
#include <stdio.h>
#include "LocalCleanStatusCCPolicy.h"

int main(void) {
    unsigned checks=0;
    for (int kind=0;kind<3;kind++) {
        uint32_t bit=local_cleanstatus_featureBit(local_cleanstatus_ccFeature((LocalCleanStatusCCKind)kind));
        for (unsigned mask=0;mask<128;mask++) {
            bool enabled=mask&1,unlocked=mask&2,expanded=mask&4,attached=mask&8;
            bool presenting=mask&16,conflict=mask&32,master=mask&64;
            uint32_t flags=local_cleanstatus_effectiveFlags(master,enabled?bit:0);
            bool expected=enabled&&master&&unlocked&&!expanded&&attached&&!presenting&&!conflict;
            assert(local_cleanstatus_ccCanPresent(flags,(LocalCleanStatusCCKind)kind,
                unlocked,expanded,attached,presenting,conflict)==expected); checks++;
        }
    }
    assert(!local_cleanstatus_ccCanPresent(UINT32_MAX,(LocalCleanStatusCCKind)-1,true,false,true,false,false));checks++;
    assert(!local_cleanstatus_ccCanPresent(UINT32_MAX,(LocalCleanStatusCCKind)9,true,false,true,false,false));checks++;
    for(int action=-1;action<7;action++) for(unsigned mask=0;mask<32;mask++) {
        bool enabled=mask&1,unlocked=mask&2,confirmed=mask&4,backend=mask&8,busy=mask&16;
        bool expected=action>=1&&action<=4&&enabled&&unlocked&&confirmed&&backend&&!busy;
        assert(local_cleanstatus_ccCanExecute((LocalCleanStatusCCAction)action,enabled,
            unlocked,confirmed,backend,busy)==expected);checks++;
    }
    LocalCleanStatusCCTicket t={0};
    uint64_t first=local_cleanstatus_ccBegin(&t);
    assert(first==1&&local_cleanstatus_ccCurrent(&t,first));checks++;
    assert(local_cleanstatus_ccRequest(&t,first));checks++;
    assert(!local_cleanstatus_ccRequest(&t,first));checks++;
    local_cleanstatus_ccInvalidate(&t);
    assert(!local_cleanstatus_ccComplete(&t,first)&&!local_cleanstatus_ccCurrent(&t,first));checks++;
    uint64_t next=local_cleanstatus_ccBegin(&t);
    assert(next!=first&&local_cleanstatus_ccRequest(&t,next));checks++;
    assert(!local_cleanstatus_ccComplete(&t,first));checks++;
    assert(local_cleanstatus_ccComplete(&t,next)&&!t.pending);checks++;
    assert(!local_cleanstatus_ccComplete(&t,next));checks++;
    t.generation=UINT64_MAX;
    assert(local_cleanstatus_ccBegin(&t)==1);checks++;
    assert(local_cleanstatus_ccBegin(NULL)==0);checks++;
    local_cleanstatus_ccInvalidate(NULL);
    assert(local_cleanstatus_ccExpired(8,0,8));checks++;
    assert(!local_cleanstatus_ccExpired(7.99,0,8));checks++;
    assert(local_cleanstatus_ccExpired(0,1,8));checks++;
    assert(local_cleanstatus_ccExpired(NAN,0,8));checks++;
    assert(local_cleanstatus_ccExpired(INFINITY,0,8));checks++;
    assert(local_cleanstatus_ccExpired(1,0,0));checks++;
    printf("PASS CC portable policy: %u assertions; no networking or system actions executed.\n",checks);
    return 0;
}
