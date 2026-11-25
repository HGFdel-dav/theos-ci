/* Executes the production first-open eligibility policy from
 * Common/PXWindowMemoryPolicy.h. No UIKit, no device, no side effects. */
#include <stdbool.h>
#include <stdio.h>

#include "../Common/PXWindowMemoryPolicy.h"

static int failures;

#define EXPECT(expected, ...)                                                    \
    do {                                                                         \
        bool actual = PXWMInitialHandoffEligible(__VA_ARGS__);                    \
        if (actual != (expected)) {                                               \
            printf("FAIL line %d: expected %d got %d\n", __LINE__, (int)(expected), \
                   (int)actual);                                                  \
            failures++;                                                          \
        }                                                                        \
    } while (0)

#define EXPECT_CARD(expected, ...)                                               \
    do {                                                                         \
        bool actual = PXWMInitialCardFrameUsable(__VA_ARGS__);                    \
        if (actual != (expected)) {                                               \
            printf("FAIL card line %d: expected %d got %d\n", __LINE__,           \
                   (int)(expected), (int)actual);                                 \
            failures++;                                                          \
        }                                                                        \
    } while (0)

int main(void) {
    int checks = 0;
    /* Baseline: binding confirmed, generation zero, still unresolved. */
    EXPECT(true, 7, true, false, 0, false, false, false, false, true);  checks++;
    EXPECT(true, 7, true, false, 0, false, false, false, true, false);  checks++;
    EXPECT(true, 7, true, false, 0, false, false, false, true, true);   checks++;

    /* No serial, no cleanup or an explicit cancellation cannot own a frame. */
    EXPECT(false, 0, true, false, 0, false, false, false, true, true);  checks++;
    EXPECT(false, 7, false, false, 0, false, false, false, true, true); checks++;
    EXPECT(false, 7, true, true, 0, false, false, false, true, true);    checks++;

    /* Any generation advance ends the first-open window. */
    EXPECT(false, 7, true, false, 1, false, false, false, true, true);  checks++;
    EXPECT(false, 7, true, false, 2, false, false, false, true, true);  checks++;

    /* A user gesture, a pending save or a resolved target all end it. */
    EXPECT(false, 7, true, false, 0, true, false, false, true, true);   checks++;
    EXPECT(false, 7, true, false, 0, false, true, false, true, true);   checks++;
    EXPECT(false, 7, true, false, 0, false, false, true, true, true);   checks++;

    /* Neither entering nor bound means the window is not this open's. */
    EXPECT(false, 7, true, false, 0, false, false, false, false, false); checks++;

    /* Exhaustive small-domain sweep: eligible only for the exact first-open
     * shape, so a later ordinary layout can never be treated as a first frame. */
    for (int serial = 0; serial < 2; serial++)
        for (int cleanup = 0; cleanup < 2; cleanup++)
            for (int cancelled = 0; cancelled < 2; cancelled++)
                for (int generation = 0; generation < 3; generation++)
                    for (int resolved = 0; resolved < 2; resolved++)
                        for (int interacting = 0; interacting < 2; interacting++)
                            for (int savePending = 0; savePending < 2; savePending++)
                                for (int entering = 0; entering < 2; entering++)
                                    for (int bound = 0; bound < 2; bound++) {
                                        bool expected = serial && cleanup && !cancelled &&
                                                        generation == 0 && !resolved &&
                                                        !interacting && !savePending &&
                                                        (entering || bound);
                                        bool actual = PXWMInitialHandoffEligible(
                                            (uint64_t)serial, cleanup, cancelled,
                                            (uint64_t)generation, resolved, interacting,
                                            savePending, entering, bound);
                                        checks++;
                                        if (actual != expected) {
                                            printf("FAIL sweep %d%d%d gen%d %d%d%d %d%d\n",
                                                   serial, cleanup, cancelled, generation,
                                                   resolved, interacting, savePending,
                                                   entering, bound);
                                            failures++;
                                        }
                                    }

    /* Card creation can carry a remembered frame only for the exact screen the
     * record was made on; otherwise the later reconcile path must be used.
     * (expected, exactlyOnePending, hasRecord, savedRefW, savedRefH, curW, curH) */
    EXPECT_CARD(true,  true,  true,  390, 844, 390, 844);     checks++;
    EXPECT_CARD(true,  true,  true,  390, 844, 390.8, 844);   checks++;
    EXPECT_CARD(true,  true,  true,  390, 844, 391.0, 844);   checks++;
    EXPECT_CARD(false, false, true,  390, 844, 390, 844);     checks++;
    EXPECT_CARD(false, true,  false, 390, 844, 390, 844);     checks++;
    EXPECT_CARD(false, true,  true,  390, 844, 392, 844);     checks++;
    EXPECT_CARD(false, true,  true,  390, 844, 390, 846.5);   checks++;
    EXPECT_CARD(false, true,  true,  844, 390, 390, 844);     checks++;
    EXPECT_CARD(false, true,  true,  0, 844, 0, 844);         checks++;
    EXPECT_CARD(false, true,  true,  390, 844, -1, 844);      checks++;

    /* Boundary sweep around the one-point tolerance. */
    for (int i = -30; i <= 30; i++) {
        double delta = i / 10.0;
        bool expected = fabs(delta) <= 1.0;
        bool actual = PXWMInitialCardFrameUsable(true, true, 390, 844, 390 + delta, 844);
        checks++;
        if (actual != expected) { printf("FAIL card sweep delta=%.1f\n", delta); failures++; }
    }

    if (failures) {
        printf("WINDOW_MEMORY_HANDOFF_FAIL failures=%d\n", failures);
        return 1;
    }
    printf("WINDOW_MEMORY_HANDOFF_PASS checks=%d\n", checks);
    return 0;
}