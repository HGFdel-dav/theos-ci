/*
 * test_policy.c -- host-side (iSH, x86/arm64 linux) test of ISDisplayPolicy.h.
 *
 * This tests ONLY the pure decision logic that the dylib runs. It proves:
 *   - 100 stays 100, 1..99 becomes 100, everything else is untouched
 *   - switch OFF never changes anything
 *   - toggling the switch makes ISDReconcile send exactly once per state
 *   - the two keys are independent
 *   - two controller instances are independent
 * It cannot prove iOS loading, hook installation or real sunlight behaviour.
 */
#include <stdio.h>
#include <limits.h>
#include <string.h>
#include "../src/ISDisplayPolicy.h"

static int checks, failures;

#define CHECK(cond, fmt, ...)                                              \
    do {                                                                   \
        ++checks;                                                          \
        if (cond) {                                                        \
            printf("PASS %02d: " fmt "\n", checks, ##__VA_ARGS__);         \
        } else {                                                           \
            ++failures;                                                    \
            printf("FAIL %02d: " fmt "  [%s:%d]\n", checks, ##__VA_ARGS__, \
                   __FILE__, __LINE__);                                    \
        }                                                                  \
    } while (0)

static ISDState fresh(void) {
    ISDState s;
    memset(&s, 0, sizeof s);
    return s;
}

int main(void) {
    /* ---- 1. 100 is already "no cap": must not be rewritten ------------- */
    CHECK(ISDResolve(100, true) == 100, "resolve(100, on) == 100");
    CHECK(ISDResolve(100, false) == 100, "resolve(100, off) == 100");

    /* ---- 2. every plain percentage 1..99 becomes 100 ------------------- */
    {
        int bad = 0;
        for (int v = 1; v <= 99; ++v)
            if (ISDResolve(v, true) != 100) { bad = v; break; }
        CHECK(bad == 0, "resolve(1..99, on) == 100 for all (first miss=%d)", bad);
    }

    /* ---- 3. 0 / negatives / INT bounds / >100 untouched ---------------- */
    CHECK(ISDResolve(0, true) == 0, "resolve(0, on) == 0 (screen-off stays off)");
    CHECK(ISDResolve(-1, true) == -1, "resolve(-1, on) == -1");
    CHECK(ISDResolve(-600, true) == -600, "resolve(-600, on) == -600");
    CHECK(ISDResolve(INT_MIN, true) == INT_MIN, "resolve(INT_MIN, on) == INT_MIN");
    CHECK(ISDResolve(INT_MAX, true) == INT_MAX, "resolve(INT_MAX, on) == INT_MAX");
    CHECK(ISDResolve(101, true) == 101, "resolve(101, on) == 101");
    CHECK(ISDResolve(255, true) == 255, "resolve(255, on) == 255 (MaxBrightness uses 0..255)");

    /* exhaustive: 100 is produced if and only if the input is 1..99 */
    {
        int wrong = 0;
        for (int v = -2000; v <= 2000; ++v) {
            int want = (v >= 1 && v <= 99) ? 100 : v;
            if (ISDResolve(v, true) != want) { wrong = v; break; }
        }
        CHECK(wrong == 0, "exhaustive -2000..2000: only 1..99 -> 100 (first miss=%d)", wrong);
    }

    /* ---- 4. switch OFF never changes a value --------------------------- */
    {
        int bad = 0;
        const int probe[] = { INT_MIN, -5, 0, 1, 37, 60, 99, 100, 101, 255, INT_MAX };
        for (unsigned i = 0; i < sizeof probe / sizeof probe[0]; ++i)
            if (ISDResolve(probe[i], false) != probe[i]) { bad = probe[i]; break; }
        CHECK(bad == 0, "switch off: every value passes through unchanged (first miss=%d)", bad);
    }

    /* ---- 5. reconcile is idempotent: one send per switch state --------- */
    {
        ISDState s = fresh();
        CHECK(ISDNoteEnabled(&s, true) == false, "first observation of the switch is not a toggle");

        ISDDecision d = ISDRequest(&s, ISDMaximum, 60, true);
        CHECK(d.send && d.requested == 60 && d.delivered == 100,
              "request(60, on): system=60 forwarded=100");

        ISDDecision r1 = ISDReconcile(&s, ISDMaximum, true);
        CHECK(r1.send == false, "reconcile(on) right after request: nothing to send");

        ISDDecision off1 = ISDReconcile(&s, ISDMaximum, false);
        CHECK(off1.send && off1.requested == 60 && off1.delivered == 60,
              "switch off -> reconcile re-sends the saved SYSTEM value 60");

        ISDDecision off2 = ISDReconcile(&s, ISDMaximum, false);
        CHECK(off2.send == false, "second reconcile(off) sends nothing (only once)");

        ISDDecision on2 = ISDReconcile(&s, ISDMaximum, true);
        CHECK(on2.send && on2.delivered == 100, "switch back on -> reconcile re-applies 100");

        ISDDecision on3 = ISDReconcile(&s, ISDMaximum, true);
        CHECK(on3.send == false, "third reconcile(on) sends nothing");

        /* a later system value replaces the remembered one */
        ISDDecision d2 = ISDRequest(&s, ISDMaximum, 30, true);
        CHECK(d2.delivered == 100, "new system request 30 while on -> 100");
        ISDDecision off3 = ISDReconcile(&s, ISDMaximum, false);
        CHECK(off3.send && off3.delivered == 30,
              "switch off -> restores the NEWEST system value 30, not the old 60");
    }

    /* ---- 5b. toggle detector fires exactly once per change ------------- */
    {
        ISDState s = fresh();
        CHECK(ISDNoteEnabled(&s, false) == false, "note(first=false) not a toggle");
        CHECK(ISDNoteEnabled(&s, false) == false, "note(false) again not a toggle");
        CHECK(ISDNoteEnabled(&s, true) == true, "note(true) is one toggle");
        CHECK(ISDNoteEnabled(&s, true) == false, "note(true) again is not");
        CHECK(ISDNoteEnabled(&s, false) == true, "note(false) is one toggle");
    }

    /* ---- 6. the two keys do not influence each other ------------------- */
    {
        ISDState s = fresh();
        ISDDecision m = ISDRequest(&s, ISDMaximum, 50, true);
        CHECK(m.delivered == 100, "MaxBrightness 50 -> 100");
        CHECK(s.slots[ISDWeak].present == false, "MaxBrightness call does not create a WeakCap record");

        ISDDecision w0 = ISDReconcile(&s, ISDWeak, false);
        CHECK(w0.send == false, "reconcile on the untouched key sends nothing");

        ISDDecision w = ISDRequest(&s, ISDWeak, 70, true);
        CHECK(w.delivered == 100, "BrightnessWeakCap 70 -> 100");
        CHECK(s.slots[ISDMaximum].systemRequest == 50,
              "WeakCap call leaves MaxBrightness system value at 50");
        CHECK(s.slots[ISDMaximum].delivered == 100,
              "WeakCap call leaves MaxBrightness delivered at 100");

        ISDDecision mo = ISDReconcile(&s, ISDMaximum, false);
        CHECK(mo.send && mo.delivered == 50, "MaxBrightness restores its own 50");
        CHECK(s.slots[ISDWeak].systemRequest == 70, "restoring MaxBrightness does not touch WeakCap 70");
        CHECK(s.slots[ISDWeak].delivered == 100, "restoring MaxBrightness leaves WeakCap delivered at 100");
    }

    /* ---- 7. two controller instances are independent ------------------ */
    {
        ISDState a = fresh(), b = fresh();
        ISDRequest(&a, ISDMaximum, 40, true);
        CHECK(a.slots[ISDMaximum].delivered == 100, "instance A: 40 -> 100");
        CHECK(b.slots[ISDMaximum].present == false, "instance B has no record from A's call");
        ISDDecision rb = ISDReconcile(&b, ISDMaximum, false);
        CHECK(rb.send == false, "instance B reconcile sends nothing");
        ISDRequest(&b, ISDMaximum, 40, false);
        CHECK(b.slots[ISDMaximum].delivered == 40, "instance B with switch off: 40 stays 40");
        CHECK(a.slots[ISDMaximum].delivered == 100, "instance A still 100 after B's call");
        CHECK(a.slots[ISDMaximum].systemRequest == 40 &&
              b.slots[ISDMaximum].systemRequest == 40,
              "both instances keep their own copy of the system value");
    }

    /* ---- 8. invalidation drops one slot only --------------------------- */
    {
        ISDState s = fresh();
        ISDRequest(&s, ISDMaximum, 55, true);
        ISDRequest(&s, ISDWeak, 65, true);
        ISDInvalidate(&s, ISDMaximum);
        CHECK(s.slots[ISDMaximum].present == false, "invalidate clears the named key");
        CHECK(s.slots[ISDWeak].present == true, "invalidate leaves the other key alone");
        CHECK(ISDReconcile(&s, ISDMaximum, false).send == false,
              "invalidated key has nothing to restore");
    }

    /* ---- 9. unknown key is never acted on ------------------------------ */
    {
        ISDState s = fresh();
        CHECK(ISDValidKey(ISDUnknown) == false, "ISDUnknown is not a valid key");
        CHECK(ISDValidKey((ISDKey)7) == false, "out-of-range key is not valid");
        ISDDecision d = ISDRequest(&s, ISDUnknown, 50, true);
        CHECK(d.send == true && d.delivered == 50 && d.touched == false,
              "unknown key passes through untouched (delivered == requested)");
        CHECK(ISDReconcile(&s, ISDUnknown, true).send == false,
              "unknown key has nothing to reconcile");
    }

    printf("\n%d checks, %d failed\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
