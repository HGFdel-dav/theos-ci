#include "../MiniSightGravity.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    unsigned checks=0;
#define CHECK(x) do { ++checks; assert(x); } while(0)
    CHECK(!MSGravityShakeShouldTrigger(0.74,0));
    CHECK(MSGravityShakeShouldTrigger(0.75,0));
    CHECK(!MSGravityShakeShouldTrigger(2.0,1));
    CHECK(MSGravityShakeShouldReset(0.35,1));
    CHECK(!MSGravityShakeShouldReset(0.36,1));
    CHECK(!MSGravityShakeShouldTrigger(NAN,0));
    CHECK(!MSGravityShakeShouldTrigger(INFINITY,0));
    for (unsigned i=0;i<10000;++i) {
        double m=(double)i/1000.0;
        double strength=MSGravityShakeStrength(m);
        CHECK(isfinite(strength) && strength>=0.2 && strength<=1.0);
        double roll=(double)(i%201)/100.0-1.0;
        double angle=MSGravityAngle(roll,strength,(double)(i%101)/100.0);
        CHECK(isfinite(angle) && fabs(angle)<=MS_GRAVITY_MAX_ANGLE+1e-9);
        MSSize body={36+(i%105),40+(i%145)};
        MSSize envelope=MSGravityEnvelope(body);
        double a=(double)(i%101)/100.0*MS_GRAVITY_MAX_ANGLE;
        CHECK(body.w*cos(a)+body.h*sin(a)<=envelope.w+1e-9);
        CHECK(body.w*sin(a)+body.h*cos(a)<=envelope.h+1e-9);
    }
    printf("PASS: %u shared gravity threshold/envelope checks (not device sensor validation)\n",checks);
    return 0;
}
