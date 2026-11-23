#include "LCSCellularEntryPolicy.h"
#include <stdio.h>
#include <stdlib.h>
#include <float.h>

static unsigned checks;
#define NEED(x) do { ++checks; if (!(x)) { fprintf(stderr,"entry policy failed at %d\n",__LINE__); exit(1); } } while (0)
static LCSEntryGates gates(unsigned m) {
    return (LCSEntryGates){(m&1)!=0,(m&2)!=0,(m&4)!=0,(m&8)!=0,(m&16)!=0,
        (m&32)!=0,(m&64)!=0,(m&128)!=0,(m&256)!=0,(m&512)!=0};
}
int main(void) {
    const LCSEntryRect r={0,0,48,48};
    const LCSEntryGates good=gates(1023);
    for(unsigned m=0;m<1024;m++) {
        LCSEntryGates g=gates(m);bool expected=m==1023;
        LCSEntryAttempt a={0};
        NEED(LCSEntryEligible(g)==expected);
        NEED(LCSEntryReceive(&a,g,r,20,20,true,false)==expected);
        NEED((a.phase==LCSEntryTracking)==expected);
        a=(LCSEntryAttempt){.sequence=1,.phase=LCSEntryTracking,.start_x=20,.start_y=20};
        NEED(LCSEntryPreviewWait(&a,g,false,true,true,true,r,20,20)==expected);
        NEED(LCSEntryBegin(&a,g,r,20,20,false)==expected);
        if(expected) {
            NEED(a.phase==LCSEntryBegan);
            NEED(!LCSEntryBegin(&a,g,r,20,20,false));
        }
        LCSEntryCancel(&a);NEED(a.phase==LCSEntryIdle);
        NEED(!LCSEntryPreviewWait(&a,g,false,true,true,true,r,20,20));
    }
    LCSEntryAttempt a={0};
    NEED(!LCSEntryReceive(&a,good,r,20,20,false,false)); // Foreign hit/overlay.
    NEED(!LCSEntryReceive(&a,good,r,48,20,true,false));
    NEED(!LCSEntryReceive(&a,good,r,-1,20,true,false));
    NEED(!LCSEntryReceive(&a,good,r,20,48,true,false));
    NEED(!LCSEntryReceive(&a,good,r,20,-1,true,false));
    NEED(a.sequence==0&&a.phase==LCSEntryIdle);
    NEED(LCSEntryReceive(&a,good,r,20,20,true,false));
    NEED(!LCSEntryReceive(&a,good,r,20,20,true,false)); // One touch per attempt.
    for(unsigned m=0;m<8;m++) {
        bool sameContainer=(m&1)!=0,sameInteraction=(m&2)!=0,related=(m&4)!=0;
        NEED(LCSEntryPreviewWait(&a,good,false,sameContainer,sameInteraction,related,r,20,20)==(m==7));
    }
    NEED(!LCSEntryPreviewWait(&a,good,true,true,true,true,r,20,20));
    NEED(!LCSEntryPreviewWait(&a,good,false,true,true,true,r,80,20));
    NEED(!LCSEntryBegin(&a,good,r,20,20,true)); // System expanded first.
    LCSEntryCancel(&a);
    NEED(!LCSEntryBegin(&a,good,r,20,20,false)); // Early release/cancel cannot present.
    NEED(!LCSEntryPreviewWait(&a,good,false,true,true,true,r,20,20));
    NEED(LCSEntryReceive(&a,good,r,20,20,true,true));
    NEED(!LCSEntryPreviewWait(&a,good,true,true,true,true,r,20,20));
    NEED(LCSEntryBegin(&a,good,r,20,20,true)); // Existing expanded button still works.
    NEED(!LCSEntryBegin(&a,good,r,20,20,true));
    LCSEntryCancel(&a);
    NEED(LCSEntryReceive(&a,good,r,20,20,true,false));
    NEED(LCSEntryBegin(&a,good,r,20,20,false));
    NEED(LCSEntryPreviewWait(&a,good,false,true,true,true,r,20,20)); // Own card animation.
    LCSEntryCancel(&a);NEED(!LCSEntryPreviewWait(&a,good,false,true,true,true,r,20,20));
    a=(LCSEntryAttempt){.sequence=UINT64_MAX,.phase=LCSEntryIdle};
    NEED(LCSEntryReceive(&a,good,r,20,20,true,false));NEED(a.sequence==1);
    const double bad[]={NAN,INFINITY,-INFINITY};
    for(unsigned i=0;i<3;i++) {
        double x=bad[i];
        NEED(!LCSEntryContains(r,x,20));NEED(!LCSEntryContains(r,20,x));
        NEED(!LCSEntryRectValid((LCSEntryRect){x,0,48,48}));
        NEED(!LCSEntryRectValid((LCSEntryRect){0,x,48,48}));
        NEED(!LCSEntryRectValid((LCSEntryRect){0,0,x,48}));
        NEED(!LCSEntryRectValid((LCSEntryRect){0,0,48,x}));
    }
    NEED(!LCSEntryRectValid((LCSEntryRect){0,0,0,48}));
    NEED(!LCSEntryRectValid((LCSEntryRect){0,0,48,-1}));
    NEED(!LCSEntryRectValid((LCSEntryRect){DBL_MAX,0,DBL_MAX,48}));
    NEED(!LCSEntryReceive(NULL,good,r,20,20,true,false));
    NEED(!LCSEntryBegin(NULL,good,r,20,20,false));
    NEED(!LCSEntryPreviewWait(NULL,good,false,true,true,true,r,20,20));
    LCSEntryCancel(NULL);
    printf("PASS cellular entry production policy: %u assertions; no UIKit/device/SIM execution.\n",checks);
    return 0;
}
