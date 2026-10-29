#include "PXCSliderMath.h"
#include <assert.h>
#include <stdio.h>
#include <stdint.h>
int main(void) {
    PXCSliderGeometry g;
    assert(!PXCSliderGeometryMake(NAN,100,.5,.1,1,&g));
    assert(!PXCSliderGeometryMake(100,INFINITY,.5,.1,1,&g));
    assert(!PXCSliderGeometryMake(100,100,NAN,.1,1,&g));
    assert(!PXCSliderGeometryMake(100,100,.5,INFINITY,1,&g));
    assert(!PXCSliderGeometryMake(7,100,.5,.1,1,&g));
    assert(!PXCSliderGeometryMake(100,100,.5,.1,1,0));
    assert(PXCSliderGeometryMake(60,140,0,0,1,&g));assert(g.y==140);
    assert(PXCSliderGeometryMake(60,140,1,0,1,&g));assert(g.y==0);
    assert(PXCSliderGeometryMake(140,60,0,0,1,&g));assert(g.x==0);
    assert(PXCSliderGeometryMake(140,60,1,0,1,&g));assert(g.x==140);
    uint32_t r=0x12345678;
    for (unsigned i=0;i<100000;i++) {
        r=r*1664525u+1013904223u;double w=8+(r%204000)/100.0;
        r=r*1664525u+1013904223u;double h=8+(r%204000)/100.0;
        r=r*1664525u+1013904223u;double v=((int)(r%100000)-50000)/10000.0;
        assert(PXCSliderGeometryMake(w,h,v,v,4,&g));
        assert(isfinite(g.x)&&g.x>=0&&g.x<=w);
        assert(isfinite(g.y)&&g.y>=0&&g.y<=h);
        assert(g.birthRate>=.4&&g.birthRate<=3.13);
    }
    puts("PASS slider geometry: 100010 cases, finite bounds, horizontal/vertical, birth rate capped");
    return 0;
}
