#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "../LogSink.h"

int main(void) {
    char parent[] = "/tmp/hmsdiag-test-XXXXXX";
    assert(mkdtemp(parent));
    char dir[512], file[512], target[512];
    snprintf(dir, sizeof(dir), "%s/HMSDiagnostic", parent);
    snprintf(file, sizeof(file), "%s/HMSdiag.log", dir);
    snprintf(target, sizeof(target), "%s/other", parent);
    uid_t owner = getuid();
    int fd = hms_open_log(parent, owner);
    assert(fd >= 0);
    assert(hms_append_log(fd, "abc", 3));
    close(fd);
    struct stat st;
    assert(stat(file, &st) == 0 && st.st_size == 3);

    assert(chmod(file, 0666) == 0);
    assert(hms_open_log(parent, owner) < 0);
    assert(unlink(file) == 0);

    int other = open(target, O_CREAT | O_WRONLY, 0600);
    assert(other >= 0);
    close(other);
    assert(symlink(target, file) == 0);
    assert(hms_open_log(parent, owner) < 0);
    assert(stat(target, &st) == 0 && st.st_size == 0);
    assert(unlink(file) == 0);

    assert(mkfifo(file, 0600) == 0);
    assert(hms_open_log(parent, owner) < 0);
    assert(unlink(file) == 0);

    assert(link(target, file) == 0);
    assert(hms_open_log(parent, owner) < 0);
    assert(unlink(file) == 0);

    assert(chmod(dir, 0777) == 0);
    assert(hms_open_log(parent, owner) < 0);
    assert(chmod(dir, 0700) == 0);
    assert(rmdir(dir) == 0);
    assert(symlink(parent, dir) == 0);
    assert(hms_open_log(parent, owner) < 0);
    assert(unlink(dir) == 0);

    fd = hms_open_log(parent, owner);
    assert(fd >= 0);
    assert(ftruncate(fd, HMS_LOG_LIMIT - 2) == 0);
    assert(!hms_append_log(fd, "abc", 3));
    assert(hms_append_log(fd, "ab", 2));
    assert(!hms_append_log(fd, "a", 1));
    assert(fstat(fd, &st) == 0 && st.st_size == HMS_LOG_LIMIT);
    close(fd);
    assert(unlink(file) == 0);
    assert(rmdir(dir) == 0);
    assert(chmod(parent, 0777) == 0);
    assert(hms_open_log(parent, owner) < 0);
    assert(chmod(parent, 0700) == 0);
    assert(unlink(target) == 0);
    assert(rmdir(parent) == 0);
    puts("HMS diagnostic log-sink regression tests passed");
    return 0;
}
