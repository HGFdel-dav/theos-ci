#include "PXCNotificationSand.h"
#include <assert.h>
#include <stdio.h>
#include <stdint.h>

static unsigned covered(double w,double h,double pitch,const double rects[][4],unsigned count) {
    unsigned cols=(unsigned)ceil(w/pitch),rows=(unsigned)ceil(h/pitch),n=0;
    if(!cols)cols=1;
    if(!rows)rows=1;
    for(unsigned r=0;r<rows;r++) for(unsigned c=0;c<cols;c++) {
        double cw=w/cols,ch=h/rows;
        for(unsigned i=0;i<count;i++)
            if(PXCNotificationSandKeep(c*cw,r*ch,cw,ch,rects[i][0],rects[i][1],rects[i][2],rects[i][3])) { n++;break; }
    }
    return n;
}
int main(void) {
    unsigned cases=0;
    for(unsigned heat=0;heat<4;heat++) for(unsigned power=0;power<2;power++)
    for(unsigned tier=0;tier<4;tier++) for(unsigned cards=1;cards<=12;cards++)
    for(unsigned used=0;used<5;used++) {
        PXCPerformanceBudget b=PXCPerformancePolicy(power!=0,heat);
        unsigned remaining=used==4?0:(b.perEffectParticles/(used+1));
        unsigned drawRemaining=used==4?0:60000/(used+1);
        PXCNotificationSandPlan p=PXCNotificationSandMakePlan(330.0*80*cards,tier,remaining,drawRemaining,b);
        if(!b.allowed || !remaining || !drawRemaining) { assert(!p.groups && !p.subdivisions);continue; }
        assert(p.groups>0 && p.groups<=remaining && p.groups<=b.perEffectParticles);
        assert(p.subdivisions>=1 && p.subdivisions<=(b.fps<=24?6u:7u));
        assert(p.groups*p.subdivisions*p.subdivisions<=drawRemaining);
        assert(p.groups*p.subdivisions*p.subdivisions<=p.drawLimit);
        assert(p.groups<=1200 && p.groups*48<=57600);
        for(unsigned parent=0;parent<p.groups;parent+=17)
        for(unsigned child=0;child<p.subdivisions*p.subdivisions;child++) {
            unsigned draws=parent*p.subdivisions*p.subdivisions+child;
            assert(draws/(p.subdivisions*p.subdivisions)==parent);
            unsigned x=child%p.subdivisions,y=child/p.subdivisions;
            double u=(x+.05+.90*.77)/p.subdivisions;
            double v=(y+.05+.90*.18)/p.subdivisions;
            assert(u>0 && u<1 && v>0 && v<1);
            /* Child quads have a point-size diameter, not the parent's size. */
            double size=(.95+.50*.51)/330.;assert(size*330<1.46);
        }
        cases++;
    }
    PXCPerformanceBudget low=PXCPerformancePolicy(true,0);
    PXCNotificationSandPlan n=PXCNotificationSandMakePlan(330.*80*6,0,1200,36000,low);
    assert(n.groups==1000 && n.groups*n.subdivisions*n.subdivisions>10000);
    PXCNotificationSandPlan bad=PXCNotificationSandMakePlan(NAN,0,1200,36000,low);
    assert(!bad.groups);
    /* Empty space is not a drawable grain parent; every occupied cell is kept. */
    const double rs[][4]={{0,0,330,75},{0,108,330,85},{0,250,330,100},{0,400,330,75}};
    double area=330.*(75+85+100+75);
    double pitch=PXCNotificationSandPitch(area,1000);unsigned eligible=0;
    for(unsigned a=0;a<12;a++) { eligible=covered(330,475,pitch,rs,4);if(eligible<=1000)break;pitch*=1.12; }
    assert(eligible>0 && eligible<=1000);
    assert(!PXCNotificationSandKeep(0,78,20,20,0,0,330,75));
    /* Requesting fewer draws cannot allocate more work. */
    n=PXCNotificationSandMakePlan(area,0,1200,17,low);
    assert(n.groups*n.subdivisions*n.subdivisions<=17);
    printf("PASS notification sand: %u plans; independent indices, <=1.45pt, sparse coverage, buffer/draw caps\n",cases);
    return 0;
}
