#include "../Common/PXWindowInputPolicy.h"
#include <assert.h>
#include <stdio.h>
static unsigned checks;
#define CHECK(x) do{checks++;assert(x);}while(0)
int main(void) {
 PXInputRate r={0};
 for(unsigned i=0;i<8;i++) CHECK(PXInputRateTake(&r,0));
 for(unsigned i=0;i<70000;i++) CHECK(!PXInputRateTake(&r,0));
 CHECK(r.suppressed==65535);CHECK(!PXInputRateTake(&r,9.999));
 CHECK(PXInputRateTake(&r,10));CHECK(r.used==1);
 CHECK(!PXInputRateTake(&r,NAN));CHECK(!PXInputRateTake(&r,INFINITY));CHECK(!PXInputRateTake(&r,-1));
 CHECK(PXInputRateTake(&r,2));CHECK(r.used==1);
 for(unsigned m=0;m<16;m++) {
  CHECK(PXInputScopeCurrent(m&1,m&2,m&4,m&8,9,9)==(m==15));
  CHECK(!PXInputScopeCurrent(m&1,m&2,m&4,m&8,9,10));
 }
 CHECK(!PXInputScopeCurrent(true,true,true,true,0,0));
 CHECK(PXInputSameGeneration(2,2,true));CHECK(!PXInputSameGeneration(2,3,true));
 CHECK(!PXInputSameGeneration(2,2,false));CHECK(!PXInputSameGeneration(0,0,true));
 CHECK(PXInputMilliseconds(100,116.967)>16966.99);
 CHECK(PXInputMilliseconds(10,9)==-1);CHECK(PXInputMilliseconds(NAN,10)==-1);
 CHECK(PXInputMilliseconds(0,0)==0);
 printf("INPUT_POLICY_PASS checks=%u\n",checks);return 0;
}
