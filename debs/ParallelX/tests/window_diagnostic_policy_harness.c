#include "../Common/PXWindowDiagnosticPolicy.h"
#include <assert.h>
#include <stdio.h>
static unsigned checks;
#define CHECK(x) do {checks++;assert(x);}while(0)
int main(void) {
 PXWMDiagnosticGate gate={0};
 CHECK(PXWMDiagnosticShouldRecord(&gate,1,PXWMLaneReady,PXWMReasonIdentity));
 for(unsigned i=0;i<2000;i++) CHECK(!PXWMDiagnosticShouldRecord(&gate,1,PXWMLaneReady,PXWMReasonIdentity));
 CHECK(PXWMDiagnosticShouldRecord(&gate,1,PXWMLaneQueue,PXWMReasonIdentity));
 CHECK(PXWMDiagnosticShouldRecord(&gate,2,PXWMLaneReady,PXWMReasonIdentity));CHECK(gate.count==1);
 unsigned accepted=1;
 for(unsigned lane=0;lane<PXWMLaneCount;lane++)for(unsigned reason=1;reason<30;reason++)
  if(PXWMDiagnosticShouldRecord(&gate,2,lane,reason))accepted++;
 CHECK(accepted==24);CHECK(gate.count==24);
 CHECK(!PXWMDiagnosticShouldRecord(&gate,2,99,1));CHECK(!PXWMDiagnosticShouldRecord(&gate,2,1,63));
 CHECK(PXWMDiagnosticShouldRecord(&gate,3,PXWMLaneCallback,PXWMReasonBudget));
 CHECK(PXWMDiagnosticMayAppendAfter(0,100,100));CHECK(PXWMDiagnosticMayAppendAfter(11,100,220));
 CHECK(!PXWMDiagnosticMayAppendAfter(12,100,110));CHECK(!PXWMDiagnosticMayAppendAfter(11,100,221));
 CHECK(!PXWMDiagnosticMayAppendAfter(0,100,99));CHECK(!PXWMDiagnosticMayAppendAfter(0,NAN,100));
 uint64_t state=PXWMDiagnosticPackStatus(8,8,5,70000);
 CHECK((state&255)==8);CHECK(((state>>8)&255)==8);CHECK(((state>>16)&65535)==5);CHECK(((state>>32)&65535)==65535);
 printf("DIAGNOSTIC_POLICY_PASS checks=%u\n",checks);return 0;
}
