// Host C test of the production helper, not a UIKit/device rendering test.
// cc -std=c11 -Wall -Wextra -Werror -pedantic tests/pet_behavior_test.c -lm -o /tmp/pet_behavior_test
#include "../MiniSightPetBehavior.h"
#include "../MiniSightGravity.h"
#include <stdio.h>
#include <stdlib.h>

static unsigned checks;
#define CHECK(condition) do { ++checks; if (!(condition)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); exit(1); } } while (0)
static MSPetResidentContext idle(void) { return (MSPetResidentContext){.running = true}; }
static void nap(MSPetResident *resident, double start) {
    MSPetResidentReset(resident);
    CHECK(MSPetResidentAdvance(resident, start, idle()) == MSPetResidentUnchanged);
    CHECK(MSPetResidentAdvance(resident, start + 18.0, idle()) == MSPetResidentFellAsleep);
    CHECK(resident->sleeping);
}

static void verified_frame_sequences(void) {
    const int entry[] = {0, 1, 2};
    const int loop[] = {3, 4, 5, 4};
    for (int i = 0; i < 3; ++i) CHECK(MSPetResidentSleepColumn((i + .1) / 3.) == entry[i]);
    for (int i = 0; i < 10000; ++i) {
        int column = MSPetResidentSleepColumn((3 + i + .1) / 3.);
        CHECK(column == loop[i % 4]);
        CHECK(column >= 3 && column <= 5);
    }
    CHECK(MSPetResidentWakeColumn(.01) == 5);
    CHECK(MSPetResidentWakeColumn(.21) == 6);
    CHECK(MSPetResidentWakeColumn(.41) == 7);
    CHECK(MSPetResidentSleepColumn(NAN) == 0);
    CHECK(MSPetResidentSleepColumn(INFINITY) == 0);
    CHECK(MSPetResidentWakeColumn(1e200) == 7);
    CHECK(MSPetResidentSleepColumn(1e200) >= 3 && MSPetResidentSleepColumn(1e200) <= 5);

    MSPetResident resident = {0};
    CHECK(MSPetResidentIdleColumn(&resident, 1., 0.) == 0);
    CHECK(resident.nextBlinkAt == 4.);
    CHECK(MSPetResidentIdleColumn(&resident, 3.99, 1.) == 0);
    const int blink[] = {1, 2, 3, 4, 5, 0};
    for (int i = 0; i < 6; ++i) CHECK(MSPetResidentIdleColumn(&resident, 4. + .25 * i, .5) == blink[i]);
    CHECK(MSPetResidentIdleColumn(&resident, 5.5, 1.) == 0);
    CHECK(resident.nextBlinkAt == 12.5); // supplied random choice changes the gap
    CHECK(!resident.blinking);
    CHECK(MSPetResidentIdleColumn(&resident, 12.5, .5) == 1);
    CHECK(MSPetResidentIdleColumn(&resident, 1e200, .5) == 0); // no integer overflow
}

static void inactivity_is_not_pose_duration(void) {
    MSPetResident resident = {0};
    MSPetResidentContext context = idle();
    CHECK(MSPetResidentAdvance(&resident, 100., context) == MSPetResidentUnchanged);
    for (int i = 1; i <= 17; ++i) {
        // A real old roam at 6s, wave at 12s: no interactive clock reset.
        context.moving = i == 6 || i == 7;
        context.holding = i == 12 || i == 13;
        CHECK(MSPetResidentAdvance(&resident, 100. + i, context) == MSPetResidentUnchanged);
        CHECK(resident.idleBegan == 100.);
    }
    context = idle(); context.moving = true;
    CHECK(MSPetResidentAdvance(&resident, 118., context) == MSPetResidentUnchanged);
    CHECK(!resident.sleeping); // let a walk/jump/fling reach its old end first
    context.moving = false;
    CHECK(MSPetResidentAdvance(&resident, 119., context) == MSPetResidentFellAsleep);
    CHECK(MSPetResidentAdvance(&resident, 120., context) == MSPetResidentUnchanged);
    CHECK(resident.sleeping); // repeated reconciliation must preserve the nap
    CHECK(MSPetResidentAdvance(&resident, 131., context) == MSPetResidentWoke);
    CHECK(!resident.sleeping && resident.waking);
    CHECK(MSPetResidentAdvance(&resident, 131.61, context) == MSPetResidentFinishedWaking);
    CHECK(!resident.waking);
}

static void authoritative_activity_and_owner_gates(void) {
    // Every bit independently wakes and blocks; pose ownership alone delays
    // entry but must not create new activity (covered in the previous case).
    for (unsigned gate = 0; gate < 6; ++gate) {
        MSPetResident resident;
        nap(&resident, 10.);
        MSPetResidentContext context = idle();
        if (gate == 0) context.activity = true;
        if (gate == 1) context.interaction = true;
        if (gate == 2) context.paused = true;
        if (gate >= 3) context.locks = 1u << (gate - 3);
        CHECK(MSPetResidentAdvance(&resident, 29., context) == MSPetResidentWoke);
        double wakeBegan = resident.wakeBegan;
        for (int i = 0; i < 600; ++i) {
            double now = 29. + i / 15.;
            MSPetResidentAdvance(&resident, now, context);
            CHECK(!resident.sleeping);
            CHECK(resident.wakeBegan == wakeBegan); // held gate cannot restart wake
        }
        context = idle();
        CHECK(MSPetResidentAdvance(&resident, 69., context) == MSPetResidentUnchanged);
        CHECK(MSPetResidentAdvance(&resident, 88., context) == MSPetResidentFellAsleep);
    }
    MSPetResident resident = {0};
    MSPetResidentAdvance(&resident, 1., idle());
    MSPetResidentContext context = idle(); context.locks = 1u | 2u;
    MSPetResidentAdvance(&resident, 50., context);
    context.locks &= ~1u; // editor owner releasing cannot release approval
    MSPetResidentAdvance(&resident, 100., context);
    CHECK(!resident.sleeping);
    CHECK(!MSGravityMotionAllowed(true, false, true, false, false, context.locks));
    context.locks = 0;
    CHECK(MSPetResidentAdvance(&resident, 118., context) == MSPetResidentFellAsleep);
}

static void interactions_and_bounded_response(void) {
    MSPetResident resident;
    nap(&resident, 1.);
    CHECK(MSPetResidentTouch(&resident, 20.));
    CHECK(!resident.sleeping && resident.waking);
    MSPetResidentRequestAttention(&resident, 20.);
    CHECK(!MSPetResidentTakeAttention(&resident, 20., true)); // finish wake pose
    MSPetResidentTouch(&resident, 20.1);
    CHECK(resident.wakeBegan == 20.);
    CHECK(MSPetResidentAdvance(&resident, 20.61, idle()) == MSPetResidentFinishedWaking);
    CHECK(MSPetResidentTakeAttention(&resident, 20.61, true));
    CHECK(!MSPetResidentTakeAttention(&resident, 20.62, true));
    MSPetResidentRequestAttention(&resident, 21.);
    CHECK(!MSPetResidentTakeAttention(&resident, 22., false)); // old jump/fling owns pose
    CHECK(MSPetResidentTakeAttention(&resident, 23., true));
    MSPetResidentRequestAttention(&resident, 30.);
    CHECK(!MSPetResidentTakeAttention(&resident, 34., true)); // no surprise response later
    CHECK(resident.attentionUntil == 0.);
    nap(&resident, 40.);
    CHECK(MSPetResidentTouch(&resident, 59.));
    MSPetResidentCancelWakePose(&resident); // drag Began chooses its directional clip
    MSPetResidentContext context = idle(); context.interaction = true;
    for (int i = 0; i < 100; ++i) {
        MSPetResidentAdvance(&resident, 59. + i / 15., context);
        CHECK(!resident.sleeping && !resident.waking);
    }
}

int main(void) {
    verified_frame_sequences();
    inactivity_is_not_pose_duration();
    authoritative_activity_and_owner_gates();
    interactions_and_bounded_response();
    printf("pet behavior: %u checks passed\n", checks);
    return 0;
}
