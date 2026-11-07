/* Host only: cc -std=c11 -Wall -Wextra -Werror -pedantic tests/physics_fling_20261107.c -lm -o /var/minis/workspace/physics_fling_20261107 */
#include "../MiniSightGravity.h"
#include <stdio.h>
#include <string.h>
static unsigned checks, failures, cases;
#define CHECK(x) do { ++checks; if (!(x)) { ++failures; if (failures < 12) fprintf(stderr,"FAIL case=%u line=%d: %s\n",cases,__LINE__,#x); } } while (0)
static uint32_t seed=20261107;
static double rnd(double lo,double hi) { seed=1664525u*seed+1013904223u; return lo+(hi-lo)*(seed/4294967295.); }
static void inside(MSGravityBody b,MSRect r) {
    r=MSGravityCenterRange(r);
    CHECK(isfinite(b.position.x)&&isfinite(b.position.y)&&isfinite(b.velocity.x)&&isfinite(b.velocity.y)&&isfinite(b.age));
    if (!(b.position.x>=r.x-1e-7&&b.position.x<=r.x+r.w+1e-7&&b.position.y>=r.y-1e-7&&b.position.y<=r.y+r.h+1e-7) && failures<12)
        fprintf(stderr,"OUT pos=(%.17g,%.17g) range=(%.17g,%.17g,%.17g,%.17g) active=%d age=%.9g\n",b.position.x,b.position.y,r.x,r.y,r.w,r.h,b.active,b.age);
    CHECK(b.position.x>=r.x-1e-7&&b.position.x<=r.x+r.w+1e-7&&b.position.y>=r.y-1e-7&&b.position.y<=r.y+r.h+1e-7);
}
int main(void) {
    MSGravityBody b={0}; MSRect r={0,0,1000,1000}; uint64_t t;
    ++cases; t=MSGravityBodyLaunch(&b,r,(MSPoint){500,500},(MSPoint){800,0});
    MSGravityBodyStep(&b,r,0,.05,t); CHECK(b.velocity.x>0&&b.velocity.x<800); inside(b,r);
    for(unsigned side=0;side<4;++side) {
        ++cases; MSPoint p={500,500},v={0,0};
        if(side==0) {p.x=.1;v.x=-1000;} if(side==1) {p.x=999.9;v.x=1000;}
        if(side==2) {p.y=.1;v.y=-1000;} if(side==3) {p.y=999.9;v.y=1000;}
        t=MSGravityBodyLaunch(&b,r,p,v); unsigned hit=MSGravityBodyStep(&b,r,0,.01,t);
        CHECK(hit&(1u<<side)); inside(b,r);
        CHECK(side<2?fabs(b.velocity.x)<1000:fabs(b.velocity.y)<1000);
        CHECK(side==0?b.velocity.x>=0:side==1?b.velocity.x<=0:side==2?b.velocity.y>=0:b.velocity.y<=0);
    }
    ++cases; double last=1000;
    for(unsigned i=0;i<12;++i) { double out=MSGravityImpactVelocity(1000,i,1); CHECK(out<=last&&out<1000); last=out; }
    ++cases; t=MSGravityBodyLaunch(&b,r,(MSPoint){500,1000},(MSPoint){800,0});
    for(unsigned i=0;i<300&&b.active;++i) MSGravityBodyStep(&b,r,0,1./60,t);
    CHECK(!b.active&&b.velocity.x==0&&b.velocity.y==0); inside(b,r);
    ++cases; r=(MSRect){0,0,1e6,1e6}; t=MSGravityBodyLaunch(&b,r,(MSPoint){500000,500000},(MSPoint){800,-500});
    for(unsigned i=0;i<500 && b.active;++i) MSGravityBodyStep(&b,r,1,1./60.,t);
    CHECK(!b.active&&b.age>=8.-1./60.-1e-9&&b.age<=8.+1./60.); CHECK(b.velocity.x==0&&b.velocity.y==0);
    ++cases; t=MSGravityBodyLaunch(&b,r,(MSPoint){500000,500000},(MSPoint){800,-500});
    for(unsigned i=0;i<500 && b.active;++i) MSGravityBodyStep(&b,r,1,1./60.,t);
    CHECK(!b.active); /* At most one 60 Hz tick beyond eight elapsed seconds. */
    ++cases; MSGravityBodyCancel(&b); MSGravityBody snapshot=b;
    for(unsigned i=0;i<100;++i) MSGravityBodyStep(&b,r,1,.016,t);
    CHECK(!memcmp(&b,&snapshot,sizeof b)); CHECK(!b.active&&b.activeGeneration==0);
    ++cases; uint64_t old=t; t=MSGravityBodyLaunch(&b,r,(MSPoint){0,0},(MSPoint){100,-100}); snapshot=b;
    MSGravityBodyStep(&b,r,0,.1,old); CHECK(!memcmp(&b,&snapshot,sizeof b)); CHECK(t!=old);
    ++cases; b.generation=UINT64_MAX; MSGravityBodyCancel(&b); CHECK(b.generation==1);
    for(unsigned mask=0;mask<64;++mask) { ++cases; CHECK(MSGravityMotionAllowed(mask&1,mask&2,mask&4,mask&8,mask&16,mask&32)==((mask&1)&&!(mask&2)&&(mask&4)&&!(mask&8)&&!(mask&16)&&!(mask&32))); }
    for(unsigned k=0;k<180;++k) {
        ++cases; r=(MSRect){rnd(-500,500),rnd(-500,500),rnd(0,1000),rnd(0,1000)};
        if(k%11==0) r.w=0;
        if(k%13==0) r.h=0;
        if(k%17==0) r=(MSRect){NAN,INFINITY,NAN,-1};
        t=MSGravityBodyLaunch(&b,r,(MSPoint){rnd(-3000,3000),k%7?rnd(-3000,3000):NAN},(MSPoint){k%5?rnd(-9000,9000):INFINITY,rnd(-9000,9000)});
        inside(b,r);
        for(unsigned j=0;j<520;++j) {
            if(j==90) {
                /* UIKit's setCenterBounds cancels old generation, then clamps. */
                MSGravityBodyCancel(&b);
                r=(MSRect){15,25,70,30};
                t=MSGravityBodyLaunch(&b,r,b.position,b.velocity);
            }
            MSGravityBodyStep(&b,r,j%37?rnd(-4,4):NAN,j%43?1./60:NAN,t); inside(b,r);
        }
        CHECK(!b.active);
    }
    printf("physics_fling_20261107: cases=%u checks=%u failures=%u\n",cases,checks,failures);
    return failures?1:0;
}
