/* Host-only geometry regression:
 * cc -std=c11 -Wall -Wextra -Werror -pedantic tests/chat/chat_layout_test.c -lm -o /tmp/chat_layout_test
 */
#include "../../MiniSightChatLayout.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static unsigned checks, sample;
static const char *scope = "named";
#define CHECK(test) do { ++checks; if (!(test)) { \
    fprintf(stderr, "FAIL %s sample=%u line=%d: %s\n", scope, sample, __LINE__, #test); \
    exit(1); } } while (0)

static int near(double a, double b) { return fabs(a - b) < 1e-7; }
static double bounded(double x, double lo, double hi) { return fmin(hi, fmax(lo, x)); }
static int overlaps(MSRect a, MSRect b) {
    return a.w > 0. && a.h > 0. && b.w > 0. && b.h > 0. &&
           fmin(a.x + a.w, b.x + b.w) > fmax(a.x, b.x) &&
           fmin(a.y + a.h, b.y + b.h) > fmax(a.y, b.y);
}
static void finite_rect(MSRect r) {
    CHECK(isfinite(r.x) && isfinite(r.y) && isfinite(r.w) && isfinite(r.h));
    CHECK(isfinite(r.x + r.w) && isfinite(r.y + r.h));
    CHECK(r.w >= 0. && r.h >= 0.);
}
static void contained(MSRect r, MSRect safe) {
    finite_rect(r);
    CHECK(r.x >= safe.x - 1e-7 && r.y >= safe.y - 1e-7);
    CHECK(r.x + r.w <= safe.x + safe.w + 1e-7);
    CHECK(r.y + r.h <= safe.y + safe.h + 1e-7);
}
// Independent public-contract checks, including nonzero WORLD safe origins.
static void contract(MSRect safe, MSRect pet, MSSize wanted, double width,
                     double keyboard, MSChatFloatingFrames f) {
    if (isfinite(keyboard) && keyboard > 0.)
        safe.h = fmax(0., fmin(safe.h, keyboard - 8. - safe.y));
    contained(f.messages, safe);
    contained(f.composer, safe);
    CHECK(!overlaps(f.messages, f.composer));
    CHECK(near(f.composer.h, fmin(40., safe.h)));
    CHECK(near(f.composer.w, fmin(safe.w, isfinite(width) && width > 0. ? width : 230.)));
    CHECK(near(f.messages.w, fmin(safe.w, isfinite(wanted.w) && wanted.w > 0. ? wanted.w : 230.)));
    CHECK(f.messages.h <= 200. && f.messages.h <= safe.h * .35 + 1e-7);
    CHECK(f.messages.h <= fmax(0., MSFinite(wanted.h, 0.)) + 1e-7);
    CHECK(near(f.composer.y - f.messages.y - f.messages.h, f.messages.h > 0. ? 6. : 0.));
    CHECK(f.placedBelow == 0 || f.placedBelow == 1);
    CHECK(f.petAvoidance == (overlaps(f.messages, pet) || overlaps(f.composer, pet)));
    MSRect nearest = f.placedBelow && f.messages.h > 0. ? f.messages : f.composer;
    double inset = fmin(12., nearest.w * .5);
    CHECK(isfinite(f.tailX) && f.tailX >= 0. && f.tailX <= nearest.w);
    CHECK(near(f.tailX, bounded(pet.x + pet.w * .5 - nearest.x, inset, nearest.w - inset)));
    CHECK(near(f.messages.x, bounded(pet.x + pet.w * .5 - f.messages.w * .5,
                                    safe.x, safe.x + safe.w - f.messages.w)));
    CHECK(near(f.composer.x, bounded(pet.x + pet.w * .5 - f.composer.w * .5,
                                    safe.x, safe.x + safe.w - f.composer.w)));
}
static void show(const char *name, MSChatFloatingFrames f) {
    printf("%s: messages=(%.2f,%.2f,%.2f,%.2f) composer=(%.2f,%.2f,%.2f,%.2f) "
           "tailX=%.2f below=%d avoidance=%d\n", name,
           f.messages.x, f.messages.y, f.messages.w, f.messages.h,
           f.composer.x, f.composer.y, f.composer.w, f.composer.h,
           f.tailX, f.placedBelow, f.petAvoidance);
}
static void named_cases(void) {
    const MSRect phone = {0., 59., 390., 751.}; // 390x844 minus 59/34 insets
    MSRect pet = {163., 620., 64., 64.};
    MSSize wanted = {220., 96.};
    MSChatFloatingFrames f = MSChatFloatingLayout(phone, pet, wanted, 0., 0.);
    contract(phone, pet, wanted, 0., 0., f);
    CHECK(!f.placedBelow && !f.petAvoidance);
    CHECK(near(f.messages.x, 85.) && near(f.messages.y, 468.) && near(f.messages.h, 96.));
    CHECK(near(f.composer.x, 80.) && near(f.composer.y, 570.) && near(f.tailX, 115.));
    CHECK(near(pet.y - f.composer.y - f.composer.h, 10.));
    show("iphone390x844", f);

    pet.y = 65.;
    f = MSChatFloatingLayout(phone, pet, wanted, 0., 0.);
    contract(phone, pet, wanted, 0., 0., f);
    CHECK(f.placedBelow && !f.petAvoidance);
    CHECK(near(f.messages.y, 139.) && near(f.composer.y, 241.) && near(f.tailX, 110.));
    CHECK(near(f.messages.y - pet.y - pet.h, 10.));
    show("top_pet_below", f);

    // Left/right clamping and a tail kept away from rounded corners.
    pet.y = 620.;
    const double xs[] = {0., 326., -100., 490.};
    for (unsigned i = 0; i < sizeof xs / sizeof xs[0]; ++i) {
        pet.x = xs[i];
        f = MSChatFloatingLayout(phone, pet, wanted, 0., 0.);
        contract(phone, pet, wanted, 0., 0., f);
        CHECK(near(f.composer.x, i == 0 || i == 2 ? 0. : 160.));
        if (i == 2) CHECK(near(f.tailX, 12.));
        if (i == 3) CHECK(near(f.tailX, 218.));
    }
    pet = (MSRect){163., 620., 64., 64.};
    wanted.h = 9000.; // full scroll content must not become a 9000pt outer frame
    f = MSChatFloatingLayout(phone, pet, wanted, 230., 0.);
    contract(phone, pet, wanted, 230., 0., f);
    CHECK(near(f.messages.h, 200.) && near(f.composer.y, 570.));
    wanted.h = 24.;
    f = MSChatFloatingLayout(phone, pet, wanted, 300., 0.);
    contract(phone, pet, wanted, 300., 0., f);
    CHECK(near(f.messages.h, 24.) && near(f.composer.w, 300.));

    const MSRect landscape = {47., 0., 750., 369.}; // 844x390, 47/47/21 insets
    pet = (MSRect){660., 260., 56., 56.};
    wanted = (MSSize){260., 9000.};
    f = MSChatFloatingLayout(landscape, pet, wanted, 0., 0.);
    contract(landscape, pet, wanted, 0., 0., f);
    CHECK(!f.placedBelow && !f.petAvoidance);
    CHECK(near(f.messages.h, 129.15) && near(f.composer.x, 567.));
    CHECK(near(pet.y - f.composer.y - f.composer.h, 10.));
    show("landscape_ratio_cap", f);

    pet = (MSRect){163., 620., 64., 64.};
    wanted = (MSSize){220., 96.};
    f = MSChatFloatingLayout(phone, pet, wanted, 0., 544.);
    contract(phone, pet, wanted, 0., 544., f);
    CHECK(near(f.composer.y + f.composer.h, 536.) && !f.placedBelow);
    show("keyboard_top544", f);
    pet.y = 65.;
    f = MSChatFloatingLayout(phone, pet, wanted, 0., 250.);
    contract(phone, pet, wanted, 0., 250., f);
    CHECK(f.placedBelow && !f.petAvoidance && near(f.messages.h, 57.));
    CHECK(near(f.messages.y, 139.) && near(f.composer.y + f.composer.h, 242.));
    show("keyboard_compress_below", f);
    pet.y = 620.;
    f = MSChatFloatingLayout(phone, pet, wanted, 0., 0.); // keyboard hide/recompute
    CHECK(near(f.composer.y, 570.) && near(f.messages.h, 96.));
    f = MSChatFloatingLayout(landscape, (MSRect){660., 260., 56., 56.}, wanted, 0., 200.);
    contract(landscape, (MSRect){660., 260., 56., 56.}, wanted, 0., 200., f);
    CHECK(near(f.composer.y + f.composer.h, 192.)); // rotation + new world keyboard Y

    const MSRect shortSafe = {0., 59., 390., 151.};
    pet = (MSRect){163., 130., 64., 64.};
    f = MSChatFloatingLayout(shortSafe, pet, wanted, 0., 0.);
    contract(shortSafe, pet, wanted, 0., 0., f);
    CHECK(!f.placedBelow && !f.petAvoidance && near(f.messages.h, 15.));
    CHECK(near(f.messages.y, 59.) && near(f.composer.y, 80.));
    show("compress_above", f);

    const MSRect blocked = {0., 0., 100., 100.};
    pet = (MSRect){10., 20., 80., 60.};
    f = MSChatFloatingLayout(blocked, pet, wanted, 0., 0.);
    contract(blocked, pet, wanted, 0., 0., f);
    CHECK(f.petAvoidance && near(f.composer.h, 40.));
    show("pet_avoidance", f);

    const MSRect tiny = {12., 18., 8., 10.};
    pet = (MSRect){15., 20., 2., 2.};
    f = MSChatFloatingLayout(tiny, pet, wanted, 0., 0.);
    contract(tiny, pet, wanted, 0., 0., f);
    CHECK(near(f.composer.w, 8.) && near(f.composer.h, 10.) && near(f.messages.h, 0.));
    CHECK(near(f.tailX, 4.) && f.petAvoidance);
    show("tiny_safe", f);

    const double heights[] = {0., 39., 40., 45., 46., 47.};
    for (unsigned i = 0; i < sizeof heights / sizeof heights[0]; ++i) {
        MSRect safe = {12., 18., 100., heights[i]};
        pet = (MSRect){40., 200., 20., 20.};
        f = MSChatFloatingLayout(safe, pet, wanted, 999., 0.);
        contract(safe, pet, wanted, 999., 0., f);
        CHECK(near(f.messages.h, heights[i] == 47. ? 1. : 0.));
    }
    wanted.h = 0.;
    f = MSChatFloatingLayout(phone, pet, wanted, 0., 0.);
    contract(phone, pet, wanted, 0., 0., f);
    CHECK(near(f.messages.h, 0.) && near(f.composer.y + f.composer.h, 190.));
    f = MSChatFloatingLayout(phone, pet, wanted, 0., 30.); // keyboard covers all safe
    contract(phone, pet, wanted, 0., 30., f);
    CHECK(near(f.composer.h, 0.) && near(f.composer.y, 59.));
}

static void invalid_inputs(void) {
    scope = "nonfinite/degenerate";
    const MSRect safe = {21., 59., 348., 751.};
    const MSRect pet = {163., 620., 64., 64.};
    const double bad[] = {NAN, INFINITY, -INFINITY, -1., 0.};
    for (unsigned i = 0; i < sizeof bad / sizeof bad[0]; ++i) {
        MSSize wanted = {bad[i], bad[i]};
        MSChatFloatingFrames f = MSChatFloatingLayout(safe, pet, wanted, bad[i], bad[i]);
        contract(safe, pet, wanted, bad[i], bad[i], f);
        CHECK(near(f.composer.w, 230.) && near(f.messages.h, 0.));
        f = MSChatFloatingLayout(safe, (MSRect){bad[i], bad[i], NAN, INFINITY},
                                 (MSSize){NAN, NAN}, NAN, NAN);
        contained(f.messages, safe);
        contained(f.composer, safe);
        CHECK(isfinite(f.tailX));
        // All nonfinite pet geometry has an explicit bottom-center fallback.
        if (i < 3) CHECK(near(f.composer.x, 80.) && near(f.composer.y, 760.));
    }
    // Per-field corruption, plus maximal finite magnitudes: not just all-NaN.
    const double extremes[] = {NAN, INFINITY, -INFINITY, -DBL_MAX, DBL_MAX};
    for (unsigned field = 0; field < 12; ++field) {
        for (unsigned i = 0; i < sizeof extremes / sizeof extremes[0]; ++i) {
            double args[12] = {21., 59., 348., 751., 163., 620., 64., 64., 220., 96., 230., 544.};
            args[field] = extremes[i];
            MSRect s = {args[0], args[1], args[2], args[3]};
            MSRect p = {args[4], args[5], args[6], args[7]};
            MSChatFloatingFrames f = MSChatFloatingLayout(s, p, (MSSize){args[8], args[9]}, args[10], args[11]);
            finite_rect(f.messages);
            finite_rect(f.composer);
            CHECK(isfinite(f.tailX) && f.tailX >= 0. && f.tailX <= f.composer.w + f.messages.w);
            CHECK(!overlaps(f.messages, f.composer));
        }
    }
    MSChatFloatingFrames f = MSChatFloatingLayout((MSRect){NAN, INFINITY, NAN, -INFINITY},
                                                  (MSRect){NAN, NAN, NAN, NAN},
                                                  (MSSize){NAN, NAN}, NAN, NAN);
    contained(f.messages, (MSRect){0., 0., 0., 0.});
    contained(f.composer, (MSRect){0., 0., 0., 0.});
    CHECK(near(f.tailX, 0.) && !f.petAvoidance);
    f = MSChatFloatingLayout((MSRect){10., 20., -30., -40.}, pet, (MSSize){220., 96.}, 230., 0.);
    contained(f.messages, (MSRect){10., 20., 0., 0.});
    contained(f.composer, (MSRect){10., 20., 0., 0.});
    printf("nonfinite/degenerate: PASS (NaN, +/-Inf, +/-DBL_MAX, negative and zero sizes)\n");
}

static uint32_t state = UINT32_C(0x4d534348);
static uint32_t next_random(void) {
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    return state;
}
static double random_range(double low, double high) {
    return low + (high - low) * ((double)next_random() / UINT32_MAX);
}
static void random_cases(void) {
    scope = "random";
    for (sample = 0; sample < 4096; ++sample) {
        MSRect safe = {random_range(-120., 120.), random_range(-80., 120.),
                       random_range(0., 1200.), random_range(0., 950.)};
        if (sample % 31 == 0) safe.h = sample % 47;
        if (sample % 61 == 0) safe.w = 0.;
        MSRect pet = {random_range(safe.x - 100., safe.x + safe.w + 100.),
                      random_range(safe.y - 100., safe.y + safe.h + 100.),
                      random_range(0., 120.), random_range(0., 130.)};
        MSSize wanted = {random_range(-20., 650.), random_range(-20., 3000.)};
        double width = random_range(-20., 650.);
        double keyboard = sample % 3 == 0 ? random_range(1., safe.y + safe.h + 200.) : 0.;
        MSChatFloatingFrames f = MSChatFloatingLayout(safe, pet, wanted, width, keyboard);
        contract(safe, pet, wanted, width, keyboard, f);
        double bottom = safe.y + safe.h;
        if (keyboard > 0.) bottom = fmax(safe.y, fmin(bottom, keyboard - 8.));
        double usableHeight = bottom - safe.y;
        double capped = fmin(fmax(0., wanted.h), fmin(200., usableHeight * .35));
        double stack = fmin(40., usableHeight) + (capped > 0. ? 6. + capped : 0.);
        if (safe.w > 0. && fmin(bottom, pet.y - 10.) - safe.y >= stack) {
            CHECK(!f.placedBelow && !f.petAvoidance);
            CHECK(near(f.messages.h, capped));
            CHECK(near(f.composer.y + f.composer.h, fmin(bottom, pet.y - 10.)));
        }
        if (sample % 32 == 0) { // world-coordinate covariance; no wrapper offset leak
            MSRect shiftedSafe = safe, shiftedPet = pet;
            shiftedSafe.x += 500.; shiftedSafe.y += 400.;
            shiftedPet.x += 500.; shiftedPet.y += 400.;
            MSChatFloatingFrames shifted = MSChatFloatingLayout(shiftedSafe, shiftedPet, wanted, width,
                                                               keyboard > 0. ? keyboard + 400. : 0.);
            CHECK(near(shifted.messages.x, f.messages.x + 500.) &&
                  near(shifted.messages.y, f.messages.y + 400.));
            CHECK(near(shifted.composer.x, f.composer.x + 500.) &&
                  near(shifted.composer.y, f.composer.y + 400.));
            CHECK(near(shifted.messages.w, f.messages.w) && near(shifted.messages.h, f.messages.h));
            CHECK(near(shifted.composer.w, f.composer.w) && near(shifted.composer.h, f.composer.h));
            CHECK(near(shifted.tailX, f.tailX) && shifted.placedBelow == f.placedBelow &&
                  shifted.petAvoidance == f.petAvoidance);
        }
    }
    printf("random: 4096 cases PASS (seed=0x4d534348; 128 world translations)\n");
}
int main(void) {
    named_cases();
    invalid_inputs();
    random_cases();
    printf("chat floating layout: %u checks passed\n", checks);
    return 0;
}
