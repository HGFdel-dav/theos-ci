#define _POSIX_C_SOURCE 200809L
#include "../Common/PXCloneTraceIO.h"
#include <assert.h>
#include <stdlib.h>
#include <dirent.h>

static unsigned checks;
#define CHECK(x) do { assert(x); ++checks; } while (0)
int main(void) {
    char base[] = "/tmp/px-trace-io-XXXXXX";
    CHECK(mkdtemp(base) != NULL);
    int directory = open(base, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    CHECK(directory >= 0);
    const char bytes[] = "trace-data-one\n";
    int error = 0;
    CHECK(PXCloneWriteTraceAt(directory, "record.plist", bytes, sizeof(bytes), &error) == PXCloneTraceIOVerified);
    CHECK(error == 0);
    struct stat st;
    CHECK(fstatat(directory, "record.plist", &st, AT_SYMLINK_NOFOLLOW) == 0);
    CHECK((st.st_mode & 0777) == 0600);
    char replacement[8200];
    memset(replacement, 0x5a, sizeof(replacement));
    CHECK(PXCloneWriteTraceAt(directory, "record.plist", replacement, sizeof(replacement), &error) == PXCloneTraceIOVerified);
    CHECK(fstatat(directory, "record.plist", &st, AT_SYMLINK_NOFOLLOW) == 0 && st.st_size == sizeof(replacement));
    CHECK(PXCloneWriteTraceAt(directory, "../outside", bytes, sizeof(bytes), &error) == PXCloneTraceIOWriteFailed);
    CHECK(error == EINVAL);
    CHECK(PXCloneWriteTraceAt(directory, ".", bytes, sizeof(bytes), &error) == PXCloneTraceIOWriteFailed);
    CHECK(PXCloneWriteTraceAt(-1, "record.plist", bytes, sizeof(bytes), &error) == PXCloneTraceIOWriteFailed);
    CHECK(symlinkat("record.plist", directory, "link.plist") == 0);
    CHECK(PXCloneWriteTraceAt(directory, "link.plist", bytes, sizeof(bytes), &error) == PXCloneTraceIOWriteFailed);
    CHECK(error == ELOOP);
    CHECK(fstatat(directory, "record.plist", &st, AT_SYMLINK_NOFOLLOW) == 0 && st.st_size == sizeof(replacement));
    CHECK(mkdirat(directory, "folder", 0700) == 0);
    CHECK(PXCloneWriteTraceAt(directory, "folder", bytes, sizeof(bytes), &error) == PXCloneTraceIOWriteFailed);
    CHECK(unlinkat(directory, "link.plist", 0) == 0);
    CHECK(unlinkat(directory, "record.plist", 0) == 0);
    CHECK(unlinkat(directory, "folder", AT_REMOVEDIR) == 0);
    // A renamed parent and new symlink path cannot redirect the pinned fd.
    char moved[512];
    snprintf(moved, sizeof(moved), "%s-pinned", base);
    CHECK(rename(base, moved) == 0);
    CHECK(symlink("/tmp", base) == 0);
    CHECK(PXCloneWriteTraceAt(directory, "record.plist", bytes, sizeof(bytes), &error) == PXCloneTraceIOVerified);
    CHECK(fstatat(directory, "record.plist", &st, AT_SYMLINK_NOFOLLOW) == 0 && st.st_size == sizeof(bytes));
    CHECK(unlinkat(directory, "record.plist", 0) == 0);
    CHECK(unlink(base) == 0);
    CHECK(close(directory) == 0);
    CHECK(rmdir(moved) == 0);
    printf("trace_io_checks=%u\n", checks);
    return 0;
}
