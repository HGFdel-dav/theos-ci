#include <substrate.h>
#include <Security/SecKey.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <syslog.h>
#include <mach-o/dyld.h>
#include <time.h>
#include <unistd.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

/* Observation only: no licence values, decrypted buffers or CF objects are read. */
static __thread int in_log;
static volatile unsigned int line_count;

static uintptr_t relative_caller(void *address) {
#if __has_feature(ptrauth_calls)
    address = ptrauth_strip(address, ptrauth_key_return_address);
#endif
    uintptr_t base = (uintptr_t)_dyld_get_image_header(0);
    uintptr_t caller = (uintptr_t)address;
    return caller >= base ? caller - base : 0;
}
static void diag(const char *fmt, ...) {
    int saved = errno;
    if (in_log) return;
    if (__atomic_fetch_add(&line_count, 1, __ATOMIC_RELAXED) >= 10000) return;
    in_log = 1;
    char body[240], line[300];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(body, sizeof(body), fmt, ap);
    va_end(ap);
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    snprintf(line, sizeof(line), "HMSdiag %lld.%03ld pid=%d %s\n",
             (long long)ts.tv_sec, ts.tv_nsec / 1000000, getpid(), body);
    const char *path = "/.jbroot/var/mobile/zqbb/HMSdiag.log";
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (fd < 0) fd = open("/var/jb/var/mobile/zqbb/HMSdiag.log",
                          O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (fd >= 0) {
        struct stat st;
        if (fstat(fd, &st) == 0 && st.st_size < 4 * 1024 * 1024)
            write(fd, line, strlen(line));
        close(fd);
    }
    syslog(LOG_NOTICE, "%s", line);
    in_log = 0;
    errno = saved;
}

static int (*real_setpriority)(int, id_t, int);
static int observed_setpriority(int which, id_t who, int prio) {
    int result = real_setpriority(which, who, prio);
    int saved = errno;
    uintptr_t caller = relative_caller(__builtin_return_address(0));
    diag("setpriority caller=0x%lx which=%d who=%d prio=%d result=%d error=%d",
         (unsigned long)caller, which, (int)who, prio, result,
         result < 0 ? saved : 0);
    errno = saved;
    return result;
}

/* Darwin private C API; log only scalar arguments, never the data buffer. */
typedef int (*MemControl)(uint32_t, int32_t, uint32_t, void *, size_t);
static MemControl real_memcontrol;
static int observed_memcontrol(uint32_t command, int32_t pid, uint32_t flags,
                               void *buffer, size_t length) {
    int result = real_memcontrol(command, pid, flags, buffer, length);
    int saved = errno;
    uintptr_t caller = relative_caller(__builtin_return_address(0));
    diag("memorystatus_control caller=0x%lx command=%u pid=%d flags=%u size=%zu result=%d error=%d",
         (unsigned long)caller, command, pid, flags, length, result,
         result < 0 ? saved : 0);
    errno = saved;
    return result;
}

typedef CFDataRef (*DecryptFn)(SecKeyRef, SecKeyAlgorithm, CFDataRef, CFErrorRef *);
static DecryptFn real_decrypt;
static CFDataRef observed_decrypt(SecKeyRef key, SecKeyAlgorithm algorithm,
                                  CFDataRef ciphertext, CFErrorRef *error) {
    CFDataRef result = real_decrypt(key, algorithm, ciphertext, error);
    int saved = errno;
    uintptr_t caller = relative_caller(__builtin_return_address(0));
    /* Never log data lengths, key material, errors or plaintext. */
    diag("decrypt caller=0x%lx input-present=%d result-present=%d",
         (unsigned long)caller, ciphertext != NULL, result != NULL);
    errno = saved;
    return result;
}

/* Only interpose known C ABI functions. The daemon's private log function
   has an unknown signature, and is deliberately left untouched. */
__attribute__((constructor)) static void start_diag(void) {
    const char *name = getprogname();
    if (!name || !strstr(name, "hellomemorystatusd")) return;
    diag("started; observation only; no authorization patch");
    void *setp = dlsym(RTLD_DEFAULT, "setpriority");
    if (setp) MSHookFunction(setp, (void *)observed_setpriority,
                            (void **)&real_setpriority);
    void *mem = dlsym(RTLD_DEFAULT, "memorystatus_control");
    if (mem) MSHookFunction(mem, (void *)observed_memcontrol,
                           (void **)&real_memcontrol);
    void *decrypt = dlsym(RTLD_DEFAULT, "SecKeyCreateDecryptedData");
    if (decrypt) MSHookFunction(decrypt, (void *)observed_decrypt,
                               (void **)&real_decrypt);
    diag("hooks-requested setpriority=%d memorystatus=%d decrypt=%d",
         !!setp, !!mem, !!decrypt);
}
