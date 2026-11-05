#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../Sources/LocalCleanStatusCore.h"
int main(void) {
    unsigned long checks = 0;
    for (uint32_t mask = 0; mask < (UINT32_C(1) << LocalCleanStatusFeatureCount); mask++) {
        assert(local_cleanstatus_effectiveFlags(false, mask) == 0);
        assert(local_cleanstatus_effectiveFlags(true, mask) == mask);
        checks += 2;
        for (unsigned f = 0; f < LocalCleanStatusFeatureCount; f++) {
            assert(local_cleanstatus_hasFeature(mask,(LocalCleanStatusFeature)f) == ((mask >> f) & 1));
            checks++;
        }
    }
    assert(local_cleanstatus_featureBit((LocalCleanStatusFeature)-1) == 0);
    assert(local_cleanstatus_featureBit((LocalCleanStatusFeature)99) == 0);
    assert(local_cleanstatus_effectiveFlags(true,UINT32_MAX) == ((1u << LocalCleanStatusFeatureCount)-1));
    for (int i = 0; i <= 10000; i++) {
        int v = local_cleanstatus_batteryNumber(i/10000.0);
        assert(v >= 0 && v <= 100);
        checks++;
    }
    assert(local_cleanstatus_batteryNumber(NAN) == -1); assert(local_cleanstatus_batteryNumber(INFINITY) == -1);
    assert(local_cleanstatus_batteryNumber(-0.1) == -1); assert(local_cleanstatus_batteryNumber(0) == 0);
    assert(local_cleanstatus_batteryNumber(0.56) == 56); assert(local_cleanstatus_batteryNumber(1) == 100);
    assert(local_cleanstatus_batteryNumber(1.2) == 100);
    uint32_t tap = local_cleanstatus_featureBit(LocalCleanStatusTapLowPower);
    assert(local_cleanstatus_tapAllowed(tap,true,false,2,1));
    assert(!local_cleanstatus_tapAllowed(0,true,false,2,1));
    assert(!local_cleanstatus_tapAllowed(tap,false,false,2,1));
    assert(!local_cleanstatus_tapAllowed(tap,true,true,2,1));
    assert(!local_cleanstatus_tapAllowed(tap,true,false,1.6,1));
    assert(!local_cleanstatus_tapAllowed(tap,true,false,0,1));
    assert(!local_cleanstatus_tapAllowed(tap,true,false,NAN,1));
    for (unsigned i=0;i<LocalCleanStatusFeatureCount;i++) {
        assert(local_cleanstatus_featureNames[i] && strlen(local_cleanstatus_featureNames[i])>0);
        for (unsigned j=i+1;j<LocalCleanStatusFeatureCount;j++) assert(strcmp(local_cleanstatus_featureNames[i],local_cleanstatus_featureNames[j])!=0);
    }
    printf("PASS core: %lu exhaustive checks + battery/tap/namespace boundaries\n",checks);
    return 0;
}
