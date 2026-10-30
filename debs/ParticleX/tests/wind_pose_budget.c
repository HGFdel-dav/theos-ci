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
            assert(m.forward>=previous && fabs(m.lateral)<.92 && m.fade<=previousFade+1e-6);
            assert(m.shrink>=.199 && m.shrink<=1 && m.fade>=0 && m.fade<=1);
            previous=m.forward;previousFade=m.fade;
        }
        PXCWindMotion end=PXCWindEvaluate(1,seed,drift,swirl);close_to(end.fade,0);assert(end.forward>=.3);
        float phase=seed;
        float release=PXCWindReleaseAt(seed,drift,swirl,phase,0.0f);
        assert(release>=.005f && release<=.46f);
        float urgent=PXCWindReleaseAt(seed,drift,swirl,phase,1.0f);
        assert(urgent>=.01f && urgent<=.09f);
        PXCWindWarp idle=PXCWindWarpAt(.5f,.5f,0.0f,phase,0.0f);
        close_to(idle.x,0);close_to(idle.y,0);
        PXCWindWarp bent=PXCWindWarpAt(.5f,.5f,.1f,phase,0.0f);
        PXCWindWarp close=PXCWindWarpAt(.51f,.5f,.1f,phase,0.0f);
        assert(isfinite(bent.x)&&isfinite(bent.y));
        assert(fabs(bent.x-close.x)<.01f&&fabs(bent.y-close.y)<.01f);
        PXCWindStream stream=PXCWindStreamAt(seed,drift,phase,swirl);
        assert(isfinite(stream.angle)&&isfinite(stream.curve));
        assert(fabs(stream.angle)<=2.85f&&fabs(stream.curve)<=1.70f);
        PXCWindWarp ended=PXCWindWarpAt(.5f,.5f,1.0f,phase,0.0f);
        assert(fabs(ended.x)<1e-5f&&fabs(ended.y)<1e-5f);
    }
    float seeds[6];PXCWindSeedPoints(.37f,seeds);
    for (int k=0;k<3;k++) assert(PXCWindReleaseAt(seeds[k*2],seeds[k*2+1],.5f,.37f,0)<.12f);
    assert(PXCWindReleaseAt(.52f,.45f,.5f,.37f,1)<PXCWindReleaseAt(.52f,.45f,.5f,.37f,0));
    unsigned quadrants[4]={0,0,0,0};float neighbour=0;unsigned pairs=0;
    for (unsigned gy=0;gy<40;gy++) for (unsigned gx=0;gx<40;gx++) {
        float x=gx/39.f,y=gy/39.f;
        PXCWindStream f=PXCWindStreamAt(x,y,.43f,.5f);
        float sn=sinf(f.angle),cs=cosf(f.angle);
        if (cs>.35f) quadrants[0]++;
        if (cs<-.35f) quadrants[1]++;
        if (sn>.35f) quadrants[2]++;
        if (sn<-.35f) quadrants[3]++;
        if (gx) { PXCWindStream n=PXCWindStreamAt((gx-1)/39.f,y,.43f,.5f);neighbour+=fabs(f.angle-n.angle);pairs++; }
    }
    for (int q=0;q<4;q++) assert(quadrants[q]>120);
    assert(neighbour/pairs<.22f);
    float worst=0;
    for (unsigned gy=0;gy<30;gy++) for (unsigned gx=1;gx<30;gx++) {
        float a=PXCWindReleaseAt(gx/29.f,gy/29.f,.5f,.31f,1);
        float b=PXCWindReleaseAt((gx-1)/29.f,gy/29.f,.5f,.31f,1);
        if (fabsf(a-b)>worst) worst=fabsf(a-b);
    }
    assert(worst<.05f);
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
