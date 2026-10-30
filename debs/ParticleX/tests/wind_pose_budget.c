#include "PXCDustMotion.h"
#include "PXCPerformance.h"
#include "PXCPoseMath.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <math.h>
static void close_to(double a,double b) { assert(fabs(a-b)<1e-5); }
int main(void) {
    uint32_t s=0x7721;
    for (unsigned i=0;i<10000;i++) {
        s=s*1664525u+1013904223u;float seed=(s%10000)/10000.f;
        s=s*1664525u+1013904223u;float drift=(s%10000)/10000.f;
        s=s*1664525u+1013904223u;float swirl=((int)(s%20000)-10000)/10000.f;
        PXCWindMotion start=PXCWindEvaluate(0,seed,drift,swirl);
        close_to(start.forward,0);close_to(start.lateral,0);close_to(start.rotation,0);close_to(start.shrink,1);close_to(start.fade,1);
        PXCWindMotion epsilon=PXCWindEvaluate(.00001f,seed,drift,swirl);
        assert(fabs(epsilon.forward)<1e-6 && fabs(epsilon.lateral)<1e-6);
        float previous=0,previousFade=1;
        for (unsigned frame=0;frame<=80;frame++) {
            float age=frame/80.f;PXCWindMotion m=PXCWindEvaluate(age,seed,drift,swirl);
            assert(isfinite(m.forward) && isfinite(m.lateral) && isfinite(m.rotation));
            assert(m.forward>=previous && fabs(m.lateral)<.78 && m.fade<=previousFade+1e-6);
            assert(m.shrink>=.199 && m.shrink<=1 && m.fade>=0 && m.fade<=1);
            previous=m.forward;previousFade=m.fade;
        }
        PXCWindMotion end=PXCWindEvaluate(1,seed,drift,swirl);close_to(end.fade,0);assert(end.forward>=.3);
        float release=PXCWindReleaseProgress(seed,drift,swirl);
        assert(release>=0 && release<=.57);
    }
    PXCWindMotion invalid=PXCWindEvaluate(NAN,NAN,NAN,NAN);assert(isfinite(invalid.lateral));
    for (unsigned heat=0;heat<5;heat++) for (unsigned power=0;power<2;power++) {
        PXCPerformanceBudget b=PXCPerformancePolicy(power!=0,heat);
        assert(b.allowed==(heat<2));
        if (b.allowed) {
            assert(b.overlays<=2 && b.perEffectParticles<=16000 && b.totalParticles<=20000);
            assert(b.fps<=30 && b.textureSide<=1280 && b.totalTextureBytes<=6u*1024u*1024u);
            if (power || heat==1) assert(b.maxDensity==0 && b.overlays==1);
        }
    }
    for (unsigned i=0;i<10000;i++) {
        double angle=i*.001,w=80+i%200,h=40+i%100;
        double a=cos(angle),b=sin(angle),c=-b,d=a,ox=-300+i*.08,oy=50+i*.03;
        PXCPoseTransform t;assert(PXCPoseTransformMake(w,h,ox,oy,ox+a*w,oy+b*w,ox+c*h,oy+d*h,17,29,&t));
        close_to(t.a,a);close_to(t.b,b);close_to(t.c,c);close_to(t.d,d);close_to(t.tx,ox-17);close_to(t.ty,oy-29);
        close_to(t.a*w+t.tx,ox+a*w-17);close_to(t.c*h+t.tx,ox+c*h-17);
    }
    PXCPoseTransform t;assert(!PXCPoseTransformMake(80,40,0,0,0,0,0,0,0,0,&t));
    puts("PASS wind/pose/performance: 810000 motion samples, 10000 affine poses, thermal/low-power budgets");
    return 0;
}
