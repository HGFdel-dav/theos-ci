#include "PXCClearLayout.h"
#include <assert.h>
#include <stdio.h>
#include <stdint.h>
static void inside(PXCClearRect r,PXCClearRect box) {
    assert(PXCClearRectValid(r));assert(r.x>=box.x-1e-8 && r.y>=box.y-1e-8);
    assert(r.x+r.w<=box.x+box.w+1e-8 && r.y+r.h<=box.y+box.h+1e-8);
}
int main(void) {
    PXCClearPlacement p;PXCClearRect z={0,0,0,0},host={0,0,390,844},safe={0,47,390,763};
    PXCClearRect a={46,744,50,50},b={294,744,50,50};
    assert(PXCClearLayoutMake(host,safe,a,b,1,138,&p));
    assert(p.nativeMatched && p.frame.w==50 && p.frame.h==50);
    assert(p.frame.x==170 && p.frame.y==744);
    assert(PXCClearLayoutMake(host,safe,a,b,0,138,&p));assert(p.frame.w==138 && p.frame.h==50);
    assert(p.frame.x>=a.x+a.w+10 && p.frame.x+p.frame.w<=b.x-10);
    assert(PXCClearLayoutMake(host,safe,z,z,1,140,&p));assert(!p.nativeMatched);inside(p.frame,safe);
    assert(PXCClearLayoutMake(host,safe,a,z,1,140,&p));assert(p.nativeMatched);inside(p.frame,safe);
    assert(!PXCClearLayoutMake(host,safe,a,b,1,NAN,&p));
    assert(!PXCClearLayoutMake(host,safe,a,b,1,140,0));
    assert(!PXCClearLayoutMake((PXCClearRect){0,0,10,20},safe,a,b,0,120,&p));
    assert(PXCClearLayoutMake((PXCClearRect){10,20,390,844},(PXCClearRect){10,67,390,763},(PXCClearRect){56,764,50,50},(PXCClearRect){304,764,50,50},1,140,&p));assert(p.frame.x==180 && p.frame.y==764);
    uint32_t seed=0x5588;
    for (unsigned i=0;i<20000;i++) {
        seed=seed*1664525u+1013904223u;double w=280+(seed%500);
        seed=seed*1664525u+1013904223u;double h=500+(seed%800);
        seed=seed*1664525u+1013904223u;double d=36+(seed%35);
        host=(PXCClearRect){0,0,w,h};safe=(PXCClearRect){0,40,w,h-74};
        a=(PXCClearRect){24,h-44-d,d,d};b=(PXCClearRect){w-24-d,h-44-d,d,d};
        for (unsigned style=0;style<2;style++) {
            assert(PXCClearLayoutMake(host,safe,a,b,style,150,&p));
            inside(p.frame,safe);assert(p.frame.h==d);if (style==1) assert(p.frame.w==d);
            assert(p.frame.x>=a.x+a.w+10-1e-8 && p.frame.x+p.frame.w<=b.x-10+1e-8);
        }
    }
    puts("PASS clear button layout: 40000 style cases, exact native diameter, gaps, safe area and fallback");
    return 0;
}
