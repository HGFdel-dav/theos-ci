#include "../Common/PXWindowMemoryPolicy.h"
#include <assert.h>
#include <stdio.h>

static unsigned checks;
#define CHECK(x) do { ++checks; assert(x); } while(0)
static void size_is(PXWMGeometry g,double w,double h) {
    CHECK(fabs(g.frame.width-w)<1e-8); CHECK(fabs(g.frame.height-h)<1e-8);
}
static void replay_video(void) {
    PXWMGeometry memory={{158,84.4,220,476.10256410256414},{0,0,390,844}};
    PXWMGeometry normal={{66,84.4,312,675.2},{0,0,390,844}};
    PXWMRect target;
    /* Reopen reads the last real resize, then native dock expansion substitutes
     * the target once. A layout/dock/expand is never itself a save. */
    for(unsigned i=0;i<200;i++) {
        CHECK(PXWMRestore(memory,normal.reference,normal.frame,&target));
        CHECK(fabs(target.width-220)<1e-8);
        CHECK(PXWMMayApplyExpansion(true,true,true,true,false,false,true,false));
        CHECK(!PXWMMayApplyExpansion(true,true,true,true,false,false,true,true));
        size_is(memory,220,476.10256410256414);
        /* This reproduces 11:49:38: a 312x675 automatic frame is moved. The
         * source uses this exact production merge, retaining 220x476 instead. */
        PXWMGeometry moved={{48.66667175292969,54.73334350585935,312,675.2},{0,0,390,844}};
        PXWMGeometry updated;
        CHECK(PXWMUpdateRememberedPosition(memory,moved,&updated));
        size_is(updated,220,476.10256410256414);
        memory=updated;
        CHECK(PXWMRestore(memory,normal.reference,normal.frame,&target));
        CHECK(fabs(target.width-220)<1e-8);
    }
    PXWMRect before=memory.frame, resized={118.11335304224097,54.73334350585935,242.55331871068873,524.9102589533879};
    CHECK(PXWMUserSizeChanged(true,before,resized));
    CHECK(!PXWMUserSizeChanged(false,before,resized));
    CHECK(!PXWMUserSizeChanged(true,before,before));
    memory.frame=resized;
    CHECK(PXWMRestore(memory,normal.reference,normal.frame,&target));
    CHECK(fabs(target.width-242.55331871068873)<1e-8);
}
static void expansion_gate(void) {
    for(unsigned mask=0;mask<256;mask++) {
        bool b[8];for(unsigned k=0;k<8;k++) b[k]=(mask&(1u<<k))!=0;
        bool expected=b[0]&&b[1]&&b[2]&&b[3]&&!b[4]&&!b[5]&&b[6]&&!b[7];
        CHECK(PXWMMayApplyExpansion(b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7])==expected);
    }
}
static void positions(void) {
    PXWMGeometry empty={0}, out={0};
    PXWMGeometry saved={{158,84.4,220,476.10256410256414},{0,0,390,844}};
    PXWMGeometry moved={{30,20,312,675.2},{0,0,390,844}};
    CHECK(!PXWMUpdateRememberedPosition(empty,moved,&out));
    CHECK(!PXWMUpdateRememberedPosition(saved,empty,&out));
    CHECK(!PXWMUpdateRememberedPosition(saved,moved,NULL));
    for(unsigned host=0;host<2;host++) for(unsigned content=0;content<2;content++) {
        PXWMRect ref=host?(PXWMRect){0,0,844,390}:(PXWMRect){0,0,390,844};
        PXWMGeometry s={{10,10,content?300:180,content?140:300},ref};
        for(unsigned n=0;n<80;n++) {
            double x=20+n%10,y=25+n%5;
            PXWMGeometry observed={{x,y,content?312:220,content?144:350},ref};
            CHECK(PXWMUpdateRememberedPosition(s,observed,&out));
            size_is(out,s.frame.width,s.frame.height);
            CHECK(PXWMValidGeometry(out));
            CHECK(out.reference.width==s.reference.width);
        }
    }
    moved.reference=(PXWMRect){0,0,844,390}; moved.frame=(PXWMRect){10,10,312,144};
    CHECK(!PXWMUpdateRememberedPosition(saved,moved,&out));
    PXWMRect invalid={0,0,0,0};
    CHECK(!PXWMUserSizeChanged(true,invalid,saved.frame));
    CHECK(!PXWMUserSizeChanged(true,saved.frame,invalid));
}
int main(void) {
    replay_video(); expansion_gate(); positions();
    printf("WINDOW_MEMORY_CYCLE_PASS checks=%u\n",checks);
    return 0;
}
