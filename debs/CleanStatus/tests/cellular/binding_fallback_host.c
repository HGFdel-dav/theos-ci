/* Executes translated production qualification expressions, not UIKit gestures. */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct {
    bool appeared, controller, loaded, button, nativeClass, descendant, owner;
    bool attached, boundWindow, controllerWindow, visible, tapSafe;
    bool panel, feature, foreground, unlocked, dismissing, presenting;
    bool directTouch, hit;
    bool top, topDismissing, topPresenting;
    int expansion, phase;
    uintptr_t directPress, windowPress;
} BFInput;
static const BFInput *E;
static bool LCSVisible(bool v){(void)v;return E->visible;}
static bool LCSDirectTouch(bool v){(void)v;return E->directTouch;}
static bool LCSTapContract(bool v){(void)v;return E->tapSafe;}
static bool LCSCellularFeatureEnabled(int kind){(void)kind;return E->feature;}
static bool LCSCellularIsUnlocked(void){return E->unlocked;}
static bool LCSCellularIsSpringBoard(void){return true;}
#define LCSCellularSIMManager 0
#define UIGestureRecognizerStateBegan 1
#include "production_binding_fallback.h"

static unsigned checks, pipelinePasses;
#define T(v) do{checks++;if(!(v)){fprintf(stderr,"binding/fallback case line %d\n",__LINE__);exit(1);}}while(0)
static BFInput ready(void){
    BFInput v={0};
    v.appeared=v.controller=v.loaded=v.button=v.nativeClass=v.descendant=v.owner=true;
    v.attached=v.boundWindow=v.controllerWindow=v.visible=v.tapSafe=true;
    v.feature=v.foreground=v.unlocked=v.hit=v.top=true;
    v.directPress=1;v.windowPress=2;v.phase=1;v.expansion=-1;
    return v;
}
static bool receive(BFInput *v,uintptr_t g){E=v;return HostReceive(g);}
static bool begin(BFInput *v,uintptr_t g){E=v;return HostBegin(g);}
static bool action(BFInput *v,uintptr_t g){E=v;return HostAction(g);}
static bool whole(BFInput *v,uintptr_t g){return receive(v,g)&&begin(v,g)&&action(v,g);}

int main(void){
    /* Every common live-use gate is independently varied (2^18 inputs). */
    for(unsigned mask=0;mask<(1u<<18);mask++){
        BFInput v=ready();bool *p[]={&v.appeared,&v.controller,&v.loaded,&v.button,
            &v.nativeClass,&v.descendant,&v.owner,&v.attached,&v.boundWindow,
            &v.controllerWindow,&v.visible,&v.tapSafe,&v.feature,&v.foreground,
            &v.unlocked,&v.panel,&v.dismissing,&v.presenting};
        for(unsigned j=0;j<18;j++)*p[j]=!!(mask&(1u<<j));
        E=&v;bool expected=(mask&0x7fffu)==0x7fffu && (mask&0x38000u)==0;
        T(HostEntryReady()==expected);
    }
    for(unsigned d=0;d<2;d++)for(unsigned hit=0;hit<2;hit++)for(int ex=-2;ex<=2;ex++)
    for(int phase=0;phase<6;phase++)for(uintptr_t gesture=0;gesture<4;gesture++){
        BFInput v=ready();v.directTouch=d;v.hit=hit;v.expansion=ex;v.phase=phase;
        bool valid=ex>=-1&&ex<=1;
        bool route=gesture==1?d:(gesture==2?!d:false);
        bool rec=route&&(gesture!=2||hit);
        bool beg=route&&valid;
        bool act=route&&phase==1;
        T(receive(&v,gesture)==rec);
        T(begin(&v,gesture)==beg);
        T(action(&v,gesture)==act);
        T(whole(&v,gesture)==(rec&&beg&&act));
        pipelinePasses+=whole(&v,gesture);
    }
    for(unsigned d=0;d<2;d++){
        BFInput v=ready();v.directTouch=d;uintptr_t own=d?1:2;
        T(whole(&v,own));
        /* Direct capability changes between the real receive/begin/action gates. */
        T(receive(&v,own));v.directTouch=!d;
        T(!begin(&v,own));T(!action(&v,own));T(!whole(&v,own));
        v=ready();v.directTouch=d;T(begin(&v,own));v.visible=false;
        T(!receive(&v,own));T(!begin(&v,own));T(!action(&v,own));
        v=ready();v.directTouch=d;v.panel=true;T(!whole(&v,own));
        v=ready();v.directTouch=d;v.owner=false;T(!whole(&v,own));
        v=ready();v.directTouch=d;v.top=false;T(!action(&v,own));
        v=ready();v.directTouch=d;v.topDismissing=true;T(!action(&v,own));
        v=ready();v.directTouch=d;v.topPresenting=true;T(!action(&v,own));
    }
    /* Preparing a hidden/windowless instance is not permission to use it. */
    BFInput v=ready();v.visible=false;v.attached=false;v.boundWindow=false;
    T(!receive(&v,1));T(!receive(&v,2));T(!begin(&v,1));T(!action(&v,2));
    v=ready();v.directPress=0;T(!receive(&v,1));T(!begin(&v,1));T(!action(&v,1));
    v=ready();v.windowPress=0;T(!receive(&v,2));T(!begin(&v,2));T(!action(&v,2));
    printf("PASS actual receive/begin/action expressions: %u checks, %u valid routes; modeled UIKit inputs only\n",checks,pipelinePasses);
    return 0;
}
