#include "../Common/PXWindowContinuity.h"
#include <assert.h>
#include <stdio.h>
static unsigned checks;
#define CHECK(x) do { checks++; assert(x); } while(0)
int main(void) {
    PXWMRect ref={0,0,390,844};
    PXWMGeometry taobao={{47.38468886099716,103.06665649414055,285.7788323316529,618.4547038151668},ref};
    PXWMGeometry requested={{47.91805533097258,60.558544256748235,312,675.2},ref};
    PXWMRect target;
    CHECK(PXWMKeepMoveSize(taobao,requested,&target));
    CHECK(fabs(target.width-taobao.frame.width)<1e-9);
    CHECK(fabs(target.height-taobao.frame.height)<1e-9);
    CHECK(fabs(target.x+target.width/2-(requested.frame.x+156))<1e-9);
    CHECK(fabs(target.y+target.height/2-(requested.frame.y+337.6))<1e-9);
    for (unsigned i=0;i<300;i++) {
        double x=(double)(i%70),y=(double)(i%160);
        requested.frame=(PXWMRect){x,y,312,675.2};
        CHECK(PXWMKeepMoveSize(taobao,requested,&target));
        CHECK(fabs(target.width-taobao.frame.width)<1e-9);
        CHECK(fabs(target.height-taobao.frame.height)<1e-9);
        CHECK(fabs(target.x+target.width/2-(x+156))<1e-9);
        CHECK(fabs(target.y+target.height/2-(y+337.6))<1e-9);
    }
    /* Offscreen/native edge gestures and changed orientation are not clamped
     * into an ordinary window by this adapter. */
    requested.frame.x=-100;
    CHECK(!PXWMKeepMoveSize(taobao,requested,&target));
    requested.frame=(PXWMRect){50,60,312,675.2};
    requested.reference=(PXWMRect){0,0,844,390};
    CHECK(!PXWMKeepMoveSize(taobao,requested,&target));
    requested.reference=ref;requested.reference.x=5;
    CHECK(!PXWMKeepMoveSize(taobao,requested,&target));
    requested.reference=ref;requested.frame.width=NAN;
    CHECK(!PXWMKeepMoveSize(taobao,requested,&target));
    CHECK(!PXWMKeepMoveSize(taobao,taobao,NULL));
    /* Exercise every independent lifecycle gate, not a copied truth table. */
    for(unsigned mask=0;mask<128;mask++) {
        bool bound=mask&1,identity=mask&2,enabled=mask&4,epoch=mask&8;
        bool generation=mask&16,direction=mask&32,reference=mask&64;
        bool allowed=PXWMContinuityAllowed(bound,identity,enabled,9,epoch?9:10,
            3,generation?3:4,false,direction,reference);
        CHECK(allowed==(mask==127));
        CHECK(!PXWMContinuityAllowed(bound,identity,enabled,9,9,3,3,true,direction,reference));
    }
    for (unsigned per=0;per<5;per++) for (unsigned total=0;total<7;total++) {
        bool expected=per<2 && total<4;
        CHECK(PXWMContentSyncMayAttempt(per,total)==expected);
    }
    PXWMRect canvas={0,0,285.66666666666663,618.3333333333333},fit;
    double scale;
    CHECK(PXWMContentFit(canvas,390,844,&fit,&scale));
    CHECK(fabs(scale-0.7324786324786324)<1e-12);
    PXWMRect normal=fit;
    CHECK(PXWMRectNear(normal,fit,1));
    /* Same 390x844 local bounds are healthy after scaling; old bounds-only
     * clip/scaleMismatch rejected this exact real normal/recovered frame. */
    PXWMRect bad={(canvas.width-390*0.7997630331753555)/2,
                 (canvas.height-844*0.7997630331753555)/2,
                 390*0.7997630331753555,844*0.7997630331753555};
    CHECK(!PXWMRectNear(bad,fit,1));
    bad=fit;bad.x+=12;CHECK(!PXWMRectNear(bad,fit,1));
    CHECK(!PXWMContentFit(canvas,0,844,&fit,&scale));
    CHECK(!PXWMContentFit(canvas,NAN,844,&fit,&scale));
    CHECK(!PXWMContentFit(canvas,390,INFINITY,&fit,&scale));
    CHECK(PXWMContentFit((PXWMRect){5,6,300,500},390,844,&fit,&scale));
    CHECK(fabs(fit.height-500)<1e-9 && fabs(scale-500.0/844)<1e-12);
    CHECK(fabs(fit.x-(5+(300-390*500.0/844)/2))<1e-9);
    CHECK(!PXWMRectNear((PXWMRect){NAN,0,100,100},fit,1));
    puts("WINDOW_CONTINUITY_PASS");printf("checks=%u\n",checks);
    return 0;
}
