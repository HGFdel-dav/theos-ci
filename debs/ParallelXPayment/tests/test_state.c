#include "../Sources/PXPState.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
static void ready(PXPState *s) {
    *s=(PXPState){.token=1,.phase=PXPQueued};
    assert(PXPTransition(s,PXPChoosing));
    assert(PXPTransition(s,PXPSwitching));
    assert(PXPTransition(s,PXPForwarding));
    assert(PXPClaimForward(s));
    assert(!PXPClaimForward(s));
    assert(PXPTransition(s,PXPActivating));
}
int main(void) {
    unsigned checks=0;
    for(unsigned mask=0;mask<64;++mask) {
        PXPState s; ready(&s);
        s.bound=mask&1; s.executed=mask&2; s.accepted=mask&4;
        s.activated=mask&8; s.completed=mask&16;
        s.hostStarted=mask&32;
        bool expected=(mask==31);
        assert(PXPCanHost(&s)==expected); ++checks;
        if(expected) {
            assert(PXPClaimHost(&s));
            assert(!PXPClaimHost(&s));
            assert(!PXPTransition(&s,PXPDone));
            s.hostReady=true; assert(PXPTransition(&s,PXPDone));
            assert(!PXPTransition(&s,PXPFailed));
        }
    }
    for(unsigned phase=PXPQueued;phase<=PXPHosting;++phase) {
        for(unsigned terminal=PXPFailed;terminal<=PXPCancelled;++terminal) {
            PXPState s={.token=2,.phase=phase};
            assert(PXPTransition(&s,terminal));
            for(unsigned next=PXPQueued;next<=PXPCancelled;++next)
                assert(!PXPTransition(&s,next));
            assert(!PXPClaimForward(&s)); assert(!PXPClaimHost(&s));
            assert(PXPClaimResult(&s)); assert(!PXPClaimResult(&s)); ++checks;
        }
    }
    for(unsigned seed=1;seed<=1000;++seed) {
        srand(seed); PXPState s={.token=seed,.phase=PXPQueued};
        unsigned forwards=0,hosts=0,results=0;
        for(unsigned i=0;i<100;++i) {
            switch(rand()%7) {
              case 0: PXPTransition(&s,rand()%9); break;
              case 1: forwards+=PXPClaimForward(&s); break;
              case 2: s.bound=s.executed=s.accepted=s.activated=s.completed=true; break;
              case 3: hosts+=PXPClaimHost(&s); break;
              case 4: results+=PXPClaimResult(&s); break;
              case 5: PXPTransition(&s,PXPCancelled); break;
              case 6: s.hostReady=true; PXPTransition(&s,PXPDone); break;
            }
            assert(forwards<=1 && hosts<=1 && results<=1);
            ++checks;
        }
    }
    printf("PASS: %u state assertions/scenarios; no iOS code executed\n",checks);
    return 0;
}
