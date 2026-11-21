#include "../Common/PXWindowMemoryPolicy.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static unsigned checks;
#define CHECK(x) do { ++checks; assert(x); } while(0)
static bool near(double a,double b) { return fabs(a-b)<0.000001; }
static void same(PXWMRect a,PXWMRect b) {
    CHECK(near(a.x,b.x)); CHECK(near(a.y,b.y)); CHECK(near(a.width,b.width)); CHECK(near(a.height,b.height));
}
static void native_lifecycle(void) {
    PXWMNativeLifecycle old = {0}, next = {0};
    /* Real native order: enter -> close old scene -> install canvas -> return. */
    PXWMNativeBegin(&old, 1);
    CHECK(!PXWMNativeBindingActive(&old, 1));
    CHECK(PXWMNativeClose(&old));
    CHECK(!PXWMNativeBindingActive(&old, 1));
    CHECK(PXWMNativeReturned(&old, true, true, true));
    CHECK(PXWMNativeBindingActive(&old, 1));
    CHECK(!PXWMNativeReturned(&old, true, false, true));
    CHECK(PXWMNativeBindingActive(&old, 1));

    PXWMNativeBegin(&next, 2);
    CHECK(!PXWMNativeBindingActive(&next, 2));
    CHECK(!PXWMNativeClose(&old));
    CHECK(PXWMNativeClose(&next));
    CHECK(!PXWMNativeBindingActive(&old, 1));
    CHECK(PXWMNativeReturned(&next, true, true, true));
    CHECK(PXWMNativeBindingActive(&next, 2));
    CHECK(!PXWMNativeBindingActive(&next, 1));
    CHECK(!PXWMNativeClose(&next));
    CHECK(!PXWMNativeBindingActive(&next, 2));

    /* A second close during entry is not the first native cleanup. */
    PXWMNativeBegin(&next, 3);
    CHECK(PXWMNativeClose(&next));
    CHECK(!PXWMNativeClose(&next));
    CHECK(!PXWMNativeReturned(&next, true, true, true));
    CHECK(!PXWMNativeBindingActive(&next, 3));

    for (unsigned which=0; which<5; ++which) {
        uint64_t serial = which == 4 ? 0 : 10 + which;
        PXWMNativeBegin(&next, serial);
        if (which != 3 && which != 4) CHECK(PXWMNativeClose(&next));
        /* Superseded, wrong canvas, exception, missing cleanup, invalid token. */
        CHECK(!PXWMNativeReturned(&next, which!=0, which!=1, which!=2));
        CHECK(!PXWMNativeBindingActive(&next, serial));
    }
    CHECK(!PXWMNativeBindingActive(NULL, 1));
    CHECK(!PXWMNativeClose(NULL));
}

static void native_gesture_policy(void) {
    CHECK(PXWMMayWaitForGestureGeometry(false,0,30));
    CHECK(PXWMMayWaitForGestureGeometry(false,29,30));
    CHECK(!PXWMMayWaitForGestureGeometry(false,30,30));
    CHECK(!PXWMMayWaitForGestureGeometry(true,0,30));
    CHECK(PXWMMayCommitGesture(false,0,0,4,4)==false);
    CHECK(PXWMMayCommitGesture(true,0,0,4,4));
    CHECK(!PXWMMayCommitGesture(true,0,1,4,4));
    CHECK(!PXWMMayCommitGesture(true,0,0,4,5));
}

static void initial_layout_policy(void) {
    // All eleven inputs are exercised independently, including a stale ticket,
    // native cleanup, user ownership, unavailable storage, and disabled memory.
    for (unsigned mask=0; mask<2048; ++mask) {
        bool b[11];
        for (unsigned bit=0;bit<11;++bit) b[bit]=(mask&(1u<<bit))!=0;
        bool allowed=true;
        if (!b[0] && (!b[1] || !b[2] || !b[3] || b[4])) allowed=false;
        if (!b[5] || !b[6] || !b[7] || b[8] || b[9] || b[10]) allowed=false;
        CHECK(PXWMMayPrepareInitialLayout(b[0],b[1],b[2],b[3],b[4],b[5],
                                         b[6],b[7],b[8],b[9],b[10])==allowed);
    }
    unsigned logCount=0;
    for (unsigned attempt=1;attempt<=100;++attempt) {
        bool logged=PXWMShouldLogRestoreWait(attempt,3,3);
        CHECK(logged==(attempt==1 || attempt==25 || attempt==50 || attempt==75 || attempt==100));
        if (logged) ++logCount;
        CHECK(PXWMShouldLogRestoreWait(attempt,3,2));
    }
    CHECK(logCount==5);
    // The first internal close must remain native, while early geometry may
    // be prepared in its subsequent layout without publishing the binding.
    PXWMNativeLifecycle state={0};
    PXWMNativeBegin(&state,91);
    CHECK(!PXWMMayPrepareInitialLayout(false,true,state.entering,state.initialCleanupSeen,
          state.cancelled,true,true,true,false,false,false));
    CHECK(PXWMNativeClose(&state));
    CHECK(PXWMMayPrepareInitialLayout(false,true,state.entering,state.initialCleanupSeen,
          state.cancelled,true,true,true,false,false,false));
    CHECK(!PXWMNativeBindingActive(&state,91));
    CHECK(PXWMNativeReturned(&state,true,true,true));
    CHECK(PXWMNativeBindingActive(&state,91));
    CHECK(!PXWMMayPrepareInitialLayout(true,false,false,true,false,true,true,true,true,false,false));
    CHECK(!PXWMNativeClose(&state));
    CHECK(!PXWMMayPrepareInitialLayout(false,false,state.entering,state.initialCleanupSeen,
          state.cancelled,true,true,true,false,false,false));
}

int main(void) {
    native_lifecycle();
    native_gesture_policy();
    initial_layout_policy();
    PXWMGeometry saved={{50,140,260,520},{0,0,390,844}};
    PXWMRect native={10,70,320,640}, out={-7,-7,-7,-7};
    CHECK(PXWMValidGeometry(saved));
    CHECK(PXWMRestore(saved,saved.reference,native,&out)); same(out,saved.frame);
    CHECK(PXWMRestore(saved,(PXWMRect){0,0,430,932},native,&out));
    CHECK(PXWMValidGeometry((PXWMGeometry){out,{0,0,430,932}}));
    CHECK(near(out.width/out.height,native.width/native.height));
    CHECK(!PXWMRestore(saved,(PXWMRect){0,0,844,390},native,&out));
    CHECK(!PXWMRestore(saved,saved.reference,native,NULL));
    PXWMGeometry bad=saved; bad.frame.width=NAN;
    CHECK(!PXWMValidGeometry(bad));
    out=(PXWMRect){-7,-7,-7,-7};
    CHECK(!PXWMRestore(bad,saved.reference,native,&out)); same(out,(PXWMRect){-7,-7,-7,-7});
    bad=saved; bad.frame.x=INFINITY; CHECK(!PXWMValidGeometry(bad));
    bad=saved; bad.frame.height=0; CHECK(!PXWMValidGeometry(bad));
    bad=saved; bad.frame.x=-1000; CHECK(!PXWMValidGeometry(bad));
    bad=saved; bad.reference.width=0; CHECK(!PXWMValidGeometry(bad));
    CHECK(!PXWMRestore(saved,(PXWMRect){0,0,5,10},native,&out));
    CHECK(!PXWMRestore(saved,saved.reference,(PXWMRect){0,0,0,100},&out));
    CHECK(PXWMOrientationKey(false,false)==0);
    CHECK(PXWMOrientationKey(false,true)==1);
    CHECK(PXWMOrientationKey(true,false)==2);
    CHECK(PXWMOrientationKey(true,true)==3);
    CHECK(PXWMMaySave(true,2,2,true,true,true));
    CHECK(!PXWMMaySave(true,2,3,true,true,true));
    CHECK(!PXWMMaySave(false,2,2,true,true,true));
    CHECK(!PXWMMaySave(true,2,2,false,true,true));
    CHECK(!PXWMMaySave(true,2,2,true,false,true));
    CHECK(!PXWMMaySave(true,2,2,true,true,false));
    CHECK(PXWMMayScheduleRestore(true,false,false,false,true,0,24));
    CHECK(!PXWMMayScheduleRestore(true,true,false,false,true,0,24));
    CHECK(!PXWMMayScheduleRestore(true,false,true,false,true,0,24));
    CHECK(!PXWMMayScheduleRestore(true,false,false,true,true,0,24));
    CHECK(!PXWMMayScheduleRestore(true,false,false,false,false,0,24));
    CHECK(!PXWMMayScheduleRestore(false,false,false,false,true,0,24));
    CHECK(!PXWMMayScheduleRestore(true,false,false,false,true,24,24));
    CHECK(PXWMMayStoreGesture(true,0,0,7,7,false));
    CHECK(!PXWMMayStoreGesture(false,0,0,7,7,false));
    CHECK(!PXWMMayStoreGesture(true,0,2,7,7,false));
    CHECK(!PXWMMayStoreGesture(true,0,0,7,8,false));
    CHECK(!PXWMMayStoreGesture(true,0,0,7,7,true));
    PXWMNativeLifecycle restoreState={0};
    PXWMNativeBegin(&restoreState,20);
    CHECK(PXWMNativeClose(&restoreState));
    CHECK(PXWMNativeReturned(&restoreState,true,true,true));
    CHECK(PXWMNativeBindingActive(&restoreState,20));
    /* User starts before a normal layout reports orientation. First valid
     * geometry at gesture end establishes the key; a true later rotation fails. */
    bool known=false; unsigned firstKey=0;
    CHECK(PXWMResolveGestureOrientation(true,&known,&firstKey,0));
    CHECK(known && firstKey==0);
    CHECK(PXWMMayWaitForGestureGeometry(false,0,30));
    CHECK(PXWMMayWaitForGestureGeometry(false,29,30));
    CHECK(!PXWMMayWaitForGestureGeometry(false,30,30));
    CHECK(!PXWMMayWaitForGestureGeometry(true,0,30));
    CHECK(PXWMResolveGestureOrientation(true,&known,&firstKey,0));
    CHECK(!PXWMResolveGestureOrientation(true,&known,&firstKey,1));
    CHECK(firstKey==0);
    /* First geometry preflight not-ready leaves restore pending while the
     * native scene later lays out; it must not disarm the committed record. */
    bool restoreResolved=false;
    for(unsigned attempt=0; attempt<24 && !restoreResolved; ++attempt)
        restoreResolved = PXWMMayScheduleRestore(PXWMNativeBindingActive(&restoreState,20),
                         restoreResolved,false,false,true,attempt,24) && attempt==6;
    CHECK(restoreResolved);
    CHECK(PXWMNativeBindingActive(&restoreState,20));
    CHECK(!PXWMMayScheduleRestore(true,false,false,false,true,24,24));
    /* Storage-load notification after Ended must not override the user's
     * layout, even if the first orientation observation hasn't happened. */
    CHECK(PXWMMayRestoreLayout(false,false,0,0,false,false));
    CHECK(!PXWMMayRestoreLayout(true,false,0,0,false,false));
    CHECK(!PXWMMayRestoreLayout(true,true,0,0,false,false));
    CHECK(!PXWMMayRestoreLayout(true,false,0,0,false,true));
    CHECK(!PXWMMayRestoreLayout(false,true,0,2,true,false));
    CHECK(!PXWMMayRestoreLayout(true,true,0,2,false,true));
    CHECK(PXWMMayRestoreLayout(true,true,0,2,false,false));
    CHECK(PXWMMayCommitGesture(true,0,0,7,7));
    CHECK(!PXWMMayCommitGesture(true,0,2,7,7));
    CHECK(!PXWMMayCommitGesture(false,0,0,7,7));
    CHECK(!PXWMMayCommitGesture(true,0,0,7,8));
    /* Exhaustively exercise fit/clamp across offsets and all four orientation
     * keys. These are the very functions used by the UIKit adapter. */
    for (unsigned host=0;host<2;host++) for(unsigned content=0;content<2;content++) {
        PXWMRect ref=host ? (PXWMRect){10,20,844,390} : (PXWMRect){10,20,390,844};
        for(unsigned wi=1;wi<=6;wi++) for(unsigned xi=0;xi<6;xi++) for(unsigned yi=0;yi<6;yi++) {
            double ratio=content ? 2.0 : 0.5;
            double w=160+wi*12, h=w/ratio;
            if(h>ref.height-1) continue;
            double x=ref.x+(ref.width-w)*xi/5, y=ref.y+(ref.height-h)*yi/5;
            PXWMGeometry g={{x,y,w,h},ref};
            PXWMRect target={15,25,ref.width*0.85,ref.height*0.85};
            PXWMRect base={0,0,content?240:120,content?120:240};
            CHECK(PXWMRestore(g,target,base,&out));
            CHECK(PXWMValidGeometry((PXWMGeometry){out,target}));
            CHECK(near(out.width/out.height,ratio));
            CHECK(out.x>=target.x && out.y>=target.y);
            CHECK(out.x+out.width<=target.x+target.width+0.000001);
            CHECK(out.y+out.height<=target.y+target.height+0.000001);
        }
    }
    printf("WINDOW_MEMORY_POLICY_PASS checks=%u\n",checks);
    return 0;
}
