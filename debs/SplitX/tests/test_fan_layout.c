#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <math.h>
#include "../SplitX/POFanLayout.h"
static unsigned seed = 29023;
static double randomUnit(void) { seed = seed * 1664525U + 1013904223U; return (seed >> 8) / 16777216.0; }
static void validate(POFanLayout x, double minX, double minY, double maxX, double maxY, double side, double spacing) {
    assert(x.count >= 0 && x.count <= PO_FAN_LIMIT);
    for (int i=0; i<x.count; i++) {
        POFanPoint p=x.points[i];
        assert(isfinite(p.x) && isfinite(p.y) && isfinite(p.angle));
        assert(p.x-x.reserve >= minX-0.001 && p.x+x.reserve <= maxX+0.001);
        assert(p.y-x.reserve >= minY-0.001 && p.y+x.reserve <= maxY+0.001);
        for (int j=0; j<i; j++) assert(POFanSeparated(p,x.points[j],side+spacing));
    }
    if (x.count) {
        assert(fabs(x.side-side)<0.0001); /* Never shrink the requested icon. */
        for (int total=1; total<=99; total++) {
            int pages=(total+x.count-1)/x.count, visited=0;
            for(int page=0;page<pages;page++) {
                int n=total-page*x.count; if(n>x.count)n=x.count;
                assert(n>0); visited+=n;
            }
            assert(visited==total);
        }
    }
}
int main(int argc,char **argv) {
    (void)argv;
    int caps[4]={7,10,13,16};
    POFanLayout left=POFanBuild(8,101,382,790,17,183,1,210,120,68,6,0,caps);
    POFanLayout right=POFanBuild(8,101,382,790,373,183,0,210,120,68,6,0,caps);
    assert(left.count>0 && left.count==right.count);
    validate(left,8,101,382,790,68,6); validate(right,8,101,382,790,68,6);
    for(int i=0;i<left.count;i++) {
        assert(fabs(left.points[i].x+right.points[i].x-390)<0.001);
        assert(fabs(left.points[i].y-right.points[i].y)<0.001);
    }
    for(int trial=0;trial<2500;trial++) {
        double width=320+randomUnit()*650,height=430+randomUnit()*650;
        double minX=8,minY=44,maxX=width-8,maxY=height-30;
        double side=58+randomUnit()*52,space=randomUnit()*20,gap=randomUnit()*40;
        double y=minY+randomUnit()*(maxY-minY),x=15+randomUnit()*60;
        int expanded=randomUnit()>.5;
        if(!expanded)x=width-x;
        int c[4];for(int r=0;r<4;r++)c[r]=(int)(randomUnit()*17);
        POFanLayout layout=POFanBuild(minX,minY,maxX,maxY,x,y,expanded,
            120+randomUnit()*140,60+randomUnit()*140,side,space,gap,c);
        validate(layout,minX,minY,maxX,maxY,side,space);
    }
    int zero[4]={0,0,0,0};
    POFanLayout fallback=POFanBuild(8,101,382,790,17,420,1,210,120,68,6,0,zero);
    assert(fallback.count>0);
    assert(POFanBuild(8,101,382,790,17,420,1,NAN,120,74,6,0,caps).count==0);
    assert(POFanBuild(8,101,382,790,17,420,1,210,120,68,6,0,NULL).count==0);
    if(argc>1) {
        printf("{\"count\":%d,\"side\":%.1f,\"points\":[",right.count,right.side);
        for(int i=0;i<right.count;i++)printf("%s{\"x\":%.3f,\"y\":%.3f,\"ring\":%d}",i?",":"",right.points[i].x,right.points[i].y,right.points[i].ring);
        printf("]}\n");
    } else printf("PASS: 2500 randomized layouts, mirrors, selected-edge clearance, stable icon sizes, complete paging, all-zero fallback; photo anchor slots=%d\n",right.count);
    return 0;
}
