#include "../MiniSightNameWakeProtocol.h"
#include "../MiniSightNameWakeGate.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static unsigned checks;
#define CHECK(expr) do { ++checks; assert(expr); } while (0)
#define B(n) ((mask >> (n)) & 1u)
int main(void) {
    for (unsigned mask = 0; mask < 2048; ++mask) {
        bool expected = B(0) && B(1) && B(2) && B(3) && B(4) && B(5) && B(6) &&
            !B(7) && B(8) && !(B(9) && B(10));
        CHECK(MSNWAllowed(B(0),B(1),B(2),B(3),B(4),B(5),B(6),B(7),B(8),B(9),B(10)) == expected);
    }
    for (unsigned mask = 0; mask < 1024; ++mask)
        CHECK(MSNWBusy(B(0),B(1),B(2),B(3),B(4),B(5),B(6),B(7),B(8),B(9)) == (mask != 0));
    for (unsigned mask = 0; mask < 64; ++mask) {
        bool expected = B(0) && !B(1) && B(2) && B(3) && B(4) && !B(5);
        CHECK(MSNWReadyMayConsume(B(0),B(1),B(2) ? 12 : 0,B(3),B(4),B(5)) == expected);
    }
    bool consumed = false;
    CHECK(MSNWReadyMayConsume(true, consumed, 12, true, true, false)); consumed = true;
    CHECK(!MSNWReadyMayConsume(true, consumed, 12, true, true, false));
    for (unsigned mask = 0; mask < 128; ++mask) {
        bool expected = B(0) && B(1) && !B(2) && !B(3) && !B(4) && !B(5);
        CHECK(MSNameWakeMayStartInput(12, B(6) ? 11 : 12, 12, B(0), B(1), B(2), B(3), B(4), B(5)) == (expected && !B(6)));
    }
    CHECK(!MSNameWakeMayStartInput(12,12,13,true,true,false,false,false,false));
    CHECK(!MSNameWakeMayStartInput(0,0,0,true,true,false,false,false,false));
    for (int i = -500; i <= 500; ++i) {
        double clock = 100 + i / 100.0;
        CHECK(MSNWClockFresh(100,clock,3) == (clock <= 100 && clock >= 97));
        CHECK(MSNWClockFresh(100,clock,4) == (clock <= 100 && clock >= 96));
    }
    CHECK(!MSNWClockFresh(100,NAN,3)); CHECK(!MSNWClockFresh(NAN,100,3));
    CHECK(!MSNWClockFresh(INFINITY,100,3)); CHECK(!MSNWClockFresh(100,INFINITY,3));
    CHECK(!MSNWClockFresh(1,-1,3)); CHECK(!MSNWClockFresh(1,10000,3));
    const char *uuid = "4C995381-A377-4E74-B5B6-8DDF0204B0A5";
    CHECK(MSNWUUID(uuid,36)); CHECK(MSNWUUID("4c995381-a377-4e74-b5b6-8ddf0204b0a5",36));
    CHECK(!MSNWUUID(NULL,36)); CHECK(!MSNWUUID(uuid,35)); CHECK(!MSNWUUID(uuid,37));
    for (unsigned index = 0; index < 36; ++index) for (unsigned byte = 0; byte < 256; ++byte) {
        char copy[37]; memcpy(copy,uuid,37); copy[index] = (char)byte;
        bool dash = index == 8 || index == 13 || index == 18 || index == 23;
        bool hex = (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f') || (byte >= 'A' && byte <= 'F');
        CHECK(MSNWUUID(copy,36) == (dash ? byte == '-' : hex));
    }
    printf("PASS production portable name-wake gates: %u assertions\n", checks);
    return 0;
}
