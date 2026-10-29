/* Run from project root:
 * cc -std=c11 -Wall -Wextra -Werror -I Sources tests/direction_math.c -lm
 */
#include <assert.h>
#include <float.h>
#include <limits.h>
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#include "PXCDirectionMath.h"
#include "PXCDirectionMath.h" /* Header is safe to include more than once. */

static void near(double actual, double expected) {
    assert(isfinite(actual));
    assert(fabs(actual - expected) <= 1e-12);
}

static void bounded(double value) {
    assert(isfinite(value));
    assert(value >= 0.0 && value <= 1.0);
}

static void test_resolution(void) {
    unsigned counts[4] = {0u, 0u, 0u, 0u};
    const unsigned invalid[] = {5u, 6u, 255u, UINT_MAX};
    for (uint32_t entropy = 0; entropy < UINT32_C(10000); ++entropy) {
        for (unsigned direction = 0; direction < 4u; ++direction) {
            assert(PXCResolvedDirection(direction, entropy) == direction);
        }
        unsigned resolved = PXCResolvedDirection(4u, entropy);
        assert(resolved < 4u);
        assert(resolved == PXCResolvedDirection(4u, entropy));
        ++counts[resolved];
        for (size_t i = 0; i < sizeof invalid / sizeof invalid[0]; ++i) {
            assert(PXCResolvedDirection(invalid[i], entropy) == 0u);
        }
    }
    for (unsigned direction = 0; direction < 4u; ++direction) {
        assert(counts[direction] == 2500u);
    }
    assert(PXCResolvedDirection(4u, UINT32_MAX) == 3u);
    assert(PXCResolvedDirection(4u, UINT32_C(0x80000000)) == 0u);
    assert(PXCResolvedDirection(UINT_MAX, UINT32_MAX) == 0u);
}

static void test_vectors(void) {
    const unsigned directions[] = {0u, 1u, 2u, 3u, 4u, 5u, UINT_MAX};
    const double expected[][2] = {
        {1.0, 0.0}, {-1.0, 0.0}, {0.0, 1.0}, {0.0, -1.0},
        {1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0}
    };
    for (size_t i = 0; i < sizeof directions / sizeof directions[0]; ++i) {
        double dx = NAN, dy = NAN;
        PXCDirectionVector(directions[i], &dx, &dy);
        near(dx, expected[i][0]);
        near(dy, expected[i][1]);
        near(dx * dx + dy * dy, 1.0);
        /* (-dy, dx) is a unit perpendicular, as used by Metal. */
        near(dx * -dy + dy * dx, 0.0);
        near((-dy) * (-dy) + dx * dx, 1.0);
        dx = dy = NAN;
        PXCDirectionVector(directions[i], &dx, NULL);
        PXCDirectionVector(directions[i], NULL, &dy);
        near(dx, expected[i][0]);
        near(dy, expected[i][1]);
        PXCDirectionVector(directions[i], NULL, NULL);
    }
}

static void test_bounds(void) {
    const double input[] = {
        -INFINITY, -DBL_MAX, -1.0, -DBL_MIN, -0.0, 0.0,
        DBL_MIN, 0.25, 0.5, 0.75, 1.0, 2.0, DBL_MAX, INFINITY, NAN
    };
    const double clamped[] = {
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        DBL_MIN, 0.25, 0.5, 0.75, 1.0, 1.0, 1.0, 1.0, 0.0
    };
    const unsigned directions[] = {0u, 1u, 2u, 3u, 4u, 5u, UINT_MAX};
    for (size_t i = 0; i < sizeof input / sizeof input[0]; ++i) {
        for (size_t j = 0; j < sizeof input / sizeof input[0]; ++j) {
            const double expected[] = {
                clamped[i], 1.0 - clamped[i], clamped[j],
                1.0 - clamped[j], clamped[i], clamped[i], clamped[i]
            };
            for (size_t k = 0; k < sizeof directions / sizeof directions[0]; ++k) {
                double progress = PXCReleaseProgress(directions[k], input[i], input[j]);
                bounded(progress);
                near(progress, expected[k]);
            }
        }
    }
    near(PXCReleaseProgress(0u, nextafter(0.0, -1.0), 0.5), 0.0);
    near(PXCReleaseProgress(0u, nextafter(1.0, 2.0), 0.5), 1.0);
    near(PXCReleaseProgress(1u, 1.0, 0.5), 0.0);
    near(PXCReleaseProgress(3u, 0.5, 1.0), 0.0);
}

static void test_matrix(void) {
    /* Exactly 10,000 center samples, covering both boundary axes. */
    for (unsigned row = 0; row < 100u; ++row) {
        for (unsigned column = 0; column < 100u; ++column) {
            double x = (double)column / 99.0;
            double y = (double)row / 99.0;
            const double expected[] = {x, 1.0 - x, y, 1.0 - y};
            for (unsigned direction = 0; direction < 4u; ++direction) {
                double progress = PXCReleaseProgress(direction, x, y);
                bounded(progress);
                near(progress, expected[direction]);
                double dx, dy;
                PXCDirectionVector(direction, &dx, &dy);
                /* Motion along the vector increases the release progress. */
                near(progress, x * dx + y * dy +
                     ((direction == 1u || direction == 3u) ? 1.0 : 0.0));
                if (direction < 2u) {
                    near(progress, PXCReleaseProgress(direction, x, 1.0 - y));
                } else {
                    near(progress, PXCReleaseProgress(direction, 1.0 - x, y));
                }
                /* Resolving random once gives the same release field. */
                unsigned random = PXCResolvedDirection(4u, row * 100u + column);
                near(PXCReleaseProgress(random, x, y), expected[random]);
            }
            /* Mirrored directions, complementary waves and swapped axes. */
            near(PXCReleaseProgress(0u, x, y), PXCReleaseProgress(1u, 1.0 - x, y));
            near(PXCReleaseProgress(2u, x, y), PXCReleaseProgress(3u, x, 1.0 - y));
            near(PXCReleaseProgress(0u, x, y) + PXCReleaseProgress(1u, x, y), 1.0);
            near(PXCReleaseProgress(2u, x, y) + PXCReleaseProgress(3u, x, y), 1.0);
            near(PXCReleaseProgress(0u, x, y), PXCReleaseProgress(2u, y, x));
            near(PXCReleaseProgress(1u, x, y), PXCReleaseProgress(3u, y, x));
            if (column < 99u) {
                double nextX = (double)(column + 1u) / 99.0;
                assert(PXCReleaseProgress(0u, nextX, y) >= expected[0]);
                assert(PXCReleaseProgress(1u, nextX, y) <= expected[1]);
            }
            if (row < 99u) {
                double nextY = (double)(row + 1u) / 99.0;
                assert(PXCReleaseProgress(2u, x, nextY) >= expected[2]);
                assert(PXCReleaseProgress(3u, x, nextY) <= expected[3]);
            }
        }
    }
}

int main(void) {
    test_resolution();
    test_vectors();
    test_bounds();
    test_matrix();
    puts("direction_math: PASS (10000 centers; mirrors, axes, bounds, vectors, random all4)");
    return 0;
}
