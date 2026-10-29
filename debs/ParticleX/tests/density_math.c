#include "PXCDensity.h"
#include "PXCSliderMath.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
int main(void) {
    const unsigned counts[]={1000,6000,12000,16000};
    const double rates[]={0.20,1.0,1.85,2.50};
    for (unsigned d=0;d<4;d++) {
        PXCDensityProfile p=PXCDensityGet(d);
        assert(p.dustParticles==counts[d] && p.sliderRate==rates[d]);
        if (d) assert(p.dustParticles>PXCDensityGet(d-1).dustParticles);
        assert(p.dustParticles<=16000 && p.sliderScale>=0.1 && p.sliderScale<=0.16);
        for (unsigned i=0;i<10000;i++) {
            double delta=((double)i-5000)/10000;
            PXCSliderGeometry g;
            assert(PXCSliderGeometryMake(72,158,0.5,delta,d,&g));
            assert(fabs(g.birthRate-(0.6+fmin(fabs(delta)*28,1.8))*rates[d])<1e-9);
            if (d) {
                PXCSliderGeometry less;assert(PXCSliderGeometryMake(72,158,0.5,delta,d-1,&less));
                assert(g.birthRate>less.birthRate);
            }
        }
    }
    assert(PXCDensityGet(1).dustParticles==6000 && PXCDensityGet(1).sliderScale==0.13);
    assert(PXCDensityGet(99).dustParticles==16000);
    puts("PASS density: 40000 slider comparisons, four bounded distinct tiers, standard unchanged");
    return 0;
}
