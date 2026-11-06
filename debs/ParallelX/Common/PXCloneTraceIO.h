#pragma once
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

typedef enum {
    PXCloneTraceIOVerified = 0,
    PXCloneTraceIOWriteFailed,
    PXCloneTraceIOReadbackFailed,
} PXCloneTraceIOResult;

// Only operates relative to a pinned, verified directory fd. A later parent
// symlink cannot redirect I/O. Production code and host I/O tests share this.
static inline PXCloneTraceIOResult PXCloneWriteTraceAt(int directory, const char *name,
                                                       const void *data, size_t length,
                                                       int *errorNumber) {
    if (errorNumber) *errorNumber = 0;
    if (directory < 0 || !name || !name[0] || strchr(name, '/') ||
        strcmp(name, ".") == 0 || strcmp(name, "..") == 0 || !data) {
        if (errorNumber) *errorNumber = EINVAL;
        return PXCloneTraceIOWriteFailed;
    }
    struct stat old;
    if (fstatat(directory, name, &old, AT_SYMLINK_NOFOLLOW) == 0) {
        if (!S_ISREG(old.st_mode)) {
            if (errorNumber) *errorNumber = ELOOP;
            return PXCloneTraceIOWriteFailed;
        }
    } else if (errno != ENOENT) {
        if (errorNumber) *errorNumber = errno;
        return PXCloneTraceIOWriteFailed;
    }
    static unsigned long sequence;
    char temporary[96];
    int file = -1;
    for (unsigned int attempt = 0; attempt < 8; attempt++) {
        snprintf(temporary, sizeof(temporary), ".px-trace-%ld-%lu.tmp", (long)getpid(), ++sequence);
        file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (file >= 0 || errno != EEXIST) break;
    }
    if (file < 0) {
        if (errorNumber) *errorNumber = errno;
        return PXCloneTraceIOWriteFailed;
    }
    const unsigned char *bytes = (const unsigned char *)data;
    size_t written = 0;
    while (written < length) {
        ssize_t count = write(file, bytes + written, length - written);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) goto write_failed;
        written += (size_t)count;
    }
    if (fchmod(file, 0600) != 0 || fsync(file) != 0) goto write_failed;
    if (close(file) != 0) { file = -1; goto write_failed; }
    file = -1;
    if (renameat(directory, temporary, directory, name) != 0) goto write_failed;
    file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (file < 0) goto readback_failed;
    struct stat actual;
    if (fstat(file, &actual) != 0 || !S_ISREG(actual.st_mode) || actual.st_size < 0 ||
        (unsigned long long)actual.st_size != (unsigned long long)length) {
        errno = EIO;
        goto readback_failed;
    }
    size_t consumed = 0;
    unsigned char buffer[4096];
    while (consumed < length) {
        size_t chunk = length - consumed;
        if (chunk > sizeof(buffer)) chunk = sizeof(buffer);
        ssize_t count = read(file, buffer, chunk);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0 || memcmp(buffer, bytes + consumed, (size_t)count) != 0) {
            errno = EIO;
            goto readback_failed;
        }
        consumed += (size_t)count;
    }
    if (close(file) != 0) { file = -1; goto readback_failed; }
    return PXCloneTraceIOVerified;

write_failed: {
        int saved = errno ? errno : EIO;
        if (file >= 0) close(file);
        unlinkat(directory, temporary, 0);
        if (errorNumber) *errorNumber = saved;
        return PXCloneTraceIOWriteFailed;
    }
readback_failed: {
        int saved = errno ? errno : EIO;
        if (file >= 0) close(file);
        if (errorNumber) *errorNumber = saved;
        return PXCloneTraceIOReadbackFailed;
    }
}
