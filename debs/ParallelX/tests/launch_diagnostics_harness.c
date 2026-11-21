#if defined(__APPLE__)
#define _DARWIN_C_SOURCE 1
#else
#define _POSIX_C_SOURCE 200809L
#endif
#include "../Common/PXCloneLaunchDiagnostics.h"
#include "../Common/PXCloneTraceHistory.h"
#include "../Common/PXCloneTraceIO.h"
#include <assert.h>
#include <stdio.h>

static unsigned checks;
#define CHECK(x) do { assert(x); ++checks; } while (0)
typedef struct { char id[37]; double time; unsigned code, gate, poll; } Failure;
typedef struct { size_t count; Failure rows[PXCloneFailureLimit]; } Archive;
static Failure fixture(unsigned i) {
    Failure f = {{0}, (double)i + 1, 19, i % 11 + 1, 100};
    snprintf(f.id, sizeof(f.id), "00000000-0000-0000-0000-%012u", i);
    return f;
}
/* Only this fixture encoding is substituted for Foundation's plist. Selection,
 * safe startup reads and atomic writes/byte readback are production C code. */
static void append(Archive *archive, const Failure *incoming) {
    Failure rows[PXCloneFailureLimit + 1] = {0};
    PXCloneFailureKey keys[PXCloneFailureLimit + 1];
    size_t total = archive->count;
    memcpy(rows, archive->rows, total * sizeof(Failure));
    if (incoming) rows[total++] = *incoming;
    for (size_t i = 0; i < total; ++i) keys[i] = (PXCloneFailureKey){rows[i].id, rows[i].time};
    size_t selected[PXCloneFailureLimit];
    archive->count = PXCloneSelectFailures(keys, total, selected);
    for (size_t i = 0; i < archive->count; ++i) archive->rows[i] = rows[selected[i]];
}
static void gates(void) {
    for (unsigned mask = 0; mask <= PXLaunchDiagAll; ++mask) {
        CHECK(PXLaunchDiagnosticFailed(PXLaunchDiagAll, mask) == (PXLaunchDiagAll & ~mask));
        CHECK(PXLaunchDiagnosticUnknown(mask) == (PXLaunchDiagAll & ~mask));
        CHECK(PXLaunchDiagnosticFailed(mask, mask) == 0);
        CHECK(PXLaunchDiagnosticFirstGate(mask, mask) == 0);
    }
    for (unsigned i = 0; i < 11; ++i) {
        CHECK(PXLaunchDiagnosticFirstGate(PXLaunchDiagAll, PXLaunchDiagAll ^ (1u << i)) == i + 1);
        CHECK(PXLaunchDiagnosticFailed(0, 0) == 0); /* unavailable isn't a false gate */
    }
    PXLaunchDiagnosticThrottle state = {0};
    unsigned emitted = 0, last = 0;
    for (unsigned poll = 1; poll <= 100; ++poll) {
        bool write = PXLaunchDiagnosticShouldWrite(&state, 7, poll, false);
        if (write) { if (last) CHECK(poll - last >= 20); last = poll; ++emitted; }
    }
    CHECK(emitted == 5);
    CHECK(PXLaunchDiagnosticShouldWrite(&state, 7, 100, true));
    state = (PXLaunchDiagnosticThrottle){0}; emitted = 0; last = 0;
    for (unsigned poll = 1; poll <= 100; ++poll) {
        bool write = PXLaunchDiagnosticShouldWrite(&state, poll, poll, false);
        if (write) { if (last) CHECK(poll - last >= 5); last = poll; ++emitted; }
    }
    CHECK(emitted == 12);
    CHECK(PXLaunchDiagnosticShouldWrite(&state, 999, 100, true));
    CHECK(state.signature == 999); /* forced latest现场 beats the cap */
    CHECK(!PXLaunchDiagnosticShouldWrite(&state, 1000, 101, false));
    CHECK(!PXLaunchDiagnosticShouldWrite(NULL, 0, 0, true));
    state = (PXLaunchDiagnosticThrottle){0};
    CHECK(PXLaunchDiagnosticShouldWrite(&state, 1, 1, false));
    CHECK(!PXLaunchDiagnosticShouldWrite(&state, 2, 2, false));
    CHECK(PXLaunchDiagnosticShouldWrite(&state, 2, 6, false));
    CHECK(!PXLaunchDiagnosticShouldWrite(&state, 3, 1, false));
}
static void persistence(void) {
    char path[] = "/tmp/px-launch-history-XXXXXX";
    CHECK(mkdtemp(path) != NULL);
    int directory = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    CHECK(directory >= 0);
    int error = 0;
    void *bytes = NULL; size_t length = 0;
    CHECK(PXCloneReadTraceAt(directory, "trace.plist", &bytes, &length, &error) == PXCloneTraceReadMissing);
    CHECK(bytes == NULL && length == 0 && error == 0);
    Archive history = {0}; Failure first = fixture(1);
    append(&history, &first);
    CHECK(history.count == 1);
    for (unsigned success = 0; success < 40; ++success) {
        append(&history, NULL);
        CHECK(PXCloneWriteTraceAt(directory, "trace.plist", &history, sizeof(history), &error) == PXCloneTraceIOVerified);
        memset(&history, 0, sizeof(history)); /* process restart, no memory cache */
        CHECK(PXCloneReadTraceAt(directory, "trace.plist", &bytes, &length, &error) == PXCloneTraceReadOK);
        CHECK(length == sizeof(history)); memcpy(&history, bytes, length); free(bytes); bytes = NULL;
        CHECK(history.count == 1 && history.rows[0].code == 19 && history.rows[0].poll == 100);
        CHECK(!strcmp(history.rows[0].id, first.id));
    }
    append(&history, &first); CHECK(history.count == 1); /* repeated rolling snapshot */
    for (unsigned i = 2; i <= 6; ++i) { Failure f = fixture(i); append(&history, &f); }
    CHECK(history.count == 4);
    CHECK(history.rows[0].time == 4 && history.rows[3].time == 7);
    append(&history, &first); CHECK(history.rows[0].time == 4); /* old ring cannot resurrect evicted failure */
    Failure invalid = fixture(20); invalid.time = NAN; append(&history, &invalid);
    CHECK(history.count == 4 && history.rows[3].time == 7);
    invalid = fixture(21); invalid.id[2] = 0; append(&history, &invalid);
    CHECK(history.count == 4 && history.rows[3].time == 7);
    CHECK(symlinkat("trace.plist", directory, "link") == 0);
    CHECK(PXCloneReadTraceAt(directory, "link", &bytes, &length, &error) == PXCloneTraceReadFailed);
    CHECK(bytes == NULL && length == 0);
    CHECK(PXCloneReadTraceAt(directory, "../trace.plist", &bytes, &length, &error) == PXCloneTraceReadFailed);
    CHECK(mkdirat(directory, "folder", 0700) == 0);
    CHECK(PXCloneReadTraceAt(directory, "folder", &bytes, &length, &error) == PXCloneTraceReadFailed);
    int fd = openat(directory, "oversize", O_CREAT | O_WRONLY | O_CLOEXEC, 0600);
    CHECK(fd >= 0 && ftruncate(fd, PXCloneTraceReadLimit + 1) == 0 && close(fd) == 0);
    CHECK(PXCloneReadTraceAt(directory, "oversize", &bytes, &length, &error) == PXCloneTraceReadFailed);
    CHECK(error == EFBIG && bytes == NULL && length == 0);
    fd = openat(directory, "empty", O_CREAT | O_WRONLY | O_CLOEXEC, 0600); CHECK(fd >= 0 && close(fd) == 0);
    CHECK(PXCloneReadTraceAt(directory, "empty", &bytes, &length, &error) == PXCloneTraceReadFailed);
    CHECK(mkfifoat(directory, "fifo", 0600) == 0);
    CHECK(PXCloneReadTraceAt(directory, "fifo", &bytes, &length, &error) == PXCloneTraceReadFailed);
    CHECK(unlinkat(directory, "fifo", 0) == 0);
    CHECK(unlinkat(directory, "empty", 0) == 0);
    CHECK(unlinkat(directory, "oversize", 0) == 0);
    CHECK(unlinkat(directory, "folder", AT_REMOVEDIR) == 0);
    CHECK(unlinkat(directory, "link", 0) == 0);
    CHECK(unlinkat(directory, "trace.plist", 0) == 0);
    CHECK(close(directory) == 0 && rmdir(path) == 0);
}
int main(void) { gates(); persistence(); printf("launch_diagnostics_checks=%u\n", checks); return 0; }
