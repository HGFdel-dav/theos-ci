#include "PXCDirectionMath.h"
#include <assert.h>
#include <stdio.h>
#include <math.h>

static void near(double a, double b) { assert(fabs(a-b)<1e-9); }

int main(void) {
    near(PXCDirectionClamp01(NAN),0);
    near(PXCDirectionClamp01(-INFINITY),0);
    near(PXCDirectionClamp01(INFINITY),1);
    near(PXCDirectionClamp01(-3),0);
    near(PXCDirectionClamp01(.25),.25);
    near(PXCDirectionClamp01(4),1);
    near(PXCReleaseProgressAngle(0,.25,.5),.25);
    near(PXCReleaseProgressAngle(1.5707963267948966,.5,.25),.25);
    near(PXCReleaseProgressAngle(1.234,.5,.5),.5);
    near(PXCReleaseProgressAngle(NAN,.2,.8),.5);
    for (unsigned i=0;i<40000;i++) {
        double angle=i*.00015707963267948966;
        double x=(i*37%1000)/999.0,y=(i*91%1000)/999.0;
        double p=PXCReleaseProgressAngle(angle,x,y);
        assert(isfinite(p) && p>=0 && p<=1);
        near(p+PXCReleaseProgressAngle(angle,1-x,1-y),1.0);
    }
    puts("direction_math: PASS (40000 random-axis release samples; bounds, centre, mirror)");
    return 0;
}
