// Host-only validation. Not included by either dylib's explicit source list.
#include "LCSATypeEncoding.h"
#include "LCSAGenieEngine.h"
#include "LCSASpringMath.h"
#include <assert.h>
#include <stdio.h>
#include <math.h>

static void encoding_tests(void) {
    assert(LCSAEncodingMatches("{UIRectCornerRadii=dddd}", "{?=dddd}"));
    assert(LCSAEncodingMatches("{CGRect={CGPoint=dd}{CGSize=dd}}", "{Box={Origin=dd}{Size=dd}}"));
    assert(LCSAEncodingMatches("{CGPoint=\"x\"d\"y\"d}", "{Point=dd}"));
    assert(LCSAEncodingMatches("{CAMeshVertex={CGPoint=dd}{CAPoint3D=ddd}}", "{Vertex={P=dd}{P3=ddd}}"));
    assert(LCSAEncodingMatches("{CAMeshFace=[4I][4f]}", "{Face=[4I][4f]}"));
    assert(LCSAEncodingMatches("{CAFrameRateRange=fff}", "{Range=fff}"));
    assert(LCSAEncodingMatches("@\"SBAppLayout\"", "@"));
    assert(LCSAEncodingMatches("B", "c"));
    assert(LCSAEncodingMatches("@?", "@?"));
    assert(!LCSAEncodingMatches("@", "@?"));
    assert(!LCSAEncodingMatches("@?", "@"));
    assert(!LCSAEncodingMatches("q", "i"));
    assert(!LCSAEncodingMatches("{R=ffff}", "{R=dddd}"));
    assert(!LCSAEncodingMatches("{R=dddd}", "{R={P=dd}{S=dd}}"));
    assert(!LCSAEncodingMatches("{F=[4I][4f]}", "{F=[4Q][4f]}"));
    assert(!LCSAEncodingMatches("{F=[3I][4f]}", "{F=[4I][4f]}"));
    assert(!LCSAEncodingMatches("{Point}", "{Point=dd}"));
    assert(!LCSAEncodingMatches("{R=dd", "{R=dd}"));
    assert(!LCSAEncodingMatches("{R=dd}}", "{R=dd}"));
    assert(!LCSAEncodingMatches(NULL, "@"));
    assert(!LCSAEncodingMatches("", ""));
    char huge[1600];
    for (int i = 0; i < 1500; ++i) huge[i] = '^';
    huge[1500] = 'd'; huge[1501] = 0;
    assert(!LCSAEncodingMatches(huge, huge));
}
static void engine_tests(void) {
    // Cover slow, critically damped, underdamped and overdamped paths and both targets.
    for (int row = 0; row < 3; ++row) for (int side = 0; side < 2; ++side) {
        double zeta = row == 0 ? 0.74 : row == 1 ? 1.0 : 1.1;
        LCSAG27Genie g = {0};
        LCSAG27GenieStart(&g, side, 200, 700, 60, 390, 844, 0.24, zeta);
        for (int frame = 0; frame < 1800; ++frame) {
            if (frame == 40) LCSAG27GenieRetarget(&g, !side, 65, 200, 60, 390, 844, 0.336, zeta);
            LCSAG27GenieStep(&g, 1.0 / 120);
            double xy[LCSAG27_V][2]; LCSAG27GenieMesh(&g, g.b, xy);
            for (int k = 0; k < LCSAG27_V; ++k) { assert(isfinite(xy[k][0])); assert(isfinite(xy[k][1])); }
            assert(isfinite(g.b));
        }
        assert(LCSAG27GenieSettled(&g));
    }
}
int main(void) { encoding_tests(); engine_tests(); puts("PASS: ABI shape positive/negative checks and finite genie retarget/settle"); }
