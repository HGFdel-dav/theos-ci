#ifndef HMS_DIAGNOSTIC_LOG_SINK_H
#define HMS_DIAGNOSTIC_LOG_SINK_H
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#define HMS_LOG_LIMIT ((off_t)4 * 1024 * 1024)

static int hms_trusted_dir(int fd, uid_t owner, mode_t forbidden) {
    struct stat st;
    return fd >= 0 && fstat(fd, &st) == 0 && S_ISDIR(st.st_mode) &&
           st.st_uid == owner && (st.st_mode & forbidden) == 0;
}

/* Hold validated directory descriptors throughout traversal. Only the
   system's jailbreak-root aliases may contain intermediate symlinks. */
static int hms_open_log(const char *parent, uid_t owner) {
    int base = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (!hms_trusted_dir(base, owner, 0022)) {
        if (base >= 0) close(base);
        return -1;
    }
    if (mkdirat(base, "HMSDiagnostic", 0700) != 0 && errno != EEXIST) {
        close(base);
        return -1;
    }
    int dir = openat(base, "HMSDiagnostic",
                     O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    close(base);
    if (!hms_trusted_dir(dir, owner, 0077)) {
        if (dir >= 0) close(dir);
        return -1;
    }
    int fd = openat(dir, "HMSdiag.log", O_WRONLY | O_CREAT | O_APPEND |
                    O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0600);
    close(dir);
    struct stat st;
    if (fd < 0) return -1;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != owner ||
        st.st_nlink != 1 || (st.st_mode & 0077) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int hms_append_log(int fd, const char *line, size_t length) {
    if (length == 0 || length > (size_t)HMS_LOG_LIMIT ||
        flock(fd, LOCK_EX | LOCK_NB) != 0) return 0;
    struct stat st;
    int written = 0;
    if (fstat(fd, &st) == 0 && st.st_size >= 0 &&
        st.st_size <= HMS_LOG_LIMIT - (off_t)length) {
        ssize_t n = write(fd, line, length);
        written = n == (ssize_t)length;
    }
    flock(fd, LOCK_UN);
    return written;
}
#endif
