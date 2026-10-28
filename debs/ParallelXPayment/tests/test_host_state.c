#include "../Sources/PXPHostState.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    unsigned checks=0;
    PXPHostState overflow={0};
    assert(!PXPHostStart(&overflow,UINT64_MAX));
    for(unsigned generation=0;generation<1000;++generation) {
        PXPHostState s={0};
        assert(PXPHostStart(&s,generation));
        assert(s.generation==generation+1);
        assert(!PXPHostStart(&s,generation));
        assert(!PXPHostLive(&s,generation));
        assert(PXPHostLive(&s,generation+1));
        assert(!PXPHostInitialized(&s,generation));
        assert(PXPHostInitialized(&s,generation+1));
        assert(!PXPHostInitialized(&s,generation+1));
        assert(PXPHostClaimCallback(&s));
        assert(!PXPHostClaimCallback(&s));
        s.visible=true;
        assert(PXPHostStop(&s));
        assert(!s.visible);
        assert(!PXPHostLive(&s,generation+1));
        assert(!PXPHostStop(&s));
        assert(!PXPHostStart(&s,generation+1));
        checks+=15;
        PXPHostState early={0};
        assert(PXPHostStart(&early,generation));
        assert(PXPHostStop(&early));
        assert(!PXPHostInitialized(&early,generation+1));
        // An original callback is still forwarded exactly once after cancellation,
        // but cannot resurrect host liveness or visibility.
        assert(PXPHostClaimCallback(&early));
        assert(!PXPHostClaimCallback(&early));
        assert(!PXPHostLive(&early,generation+1));
        checks+=6;
    }
    printf("PASS: %u host lifecycle checks; no UIKit/iOS code executed\n",checks+1);
    return 0;
}
