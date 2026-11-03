// minis-agentd — privileged worker for Minis.
//
// Path rules are copied from Apelin's apelind (Shared/RoothideRoot.swift,
// Apelind/main.swift): the install root is where this executable was started
// from, and a start from anywhere else is refused. Under RootHide that root is
// the .jbroot-<16 hex> directory, so every state path is written as
// "<root>/var/mobile/..." and lands inside the bootstrap the package was
// installed into. Outside a bootstrap the root is "/" and the same paths are
// the plain system ones.

#include <CommonCrypto/CommonDigest.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

// libproc.h is not in the iPhoneOS SDK; apelind declares this itself too.
extern int proc_pidpath(int pid, void *buffer, unsigned int buffersize);

#define LABEL "com.niubiprass.minisagentd"
#define SUFFIX "/usr/libexec/minis-agentd"

static char g_root[PATH_MAX];
static char g_base[PATH_MAX];
static char g_inbox[PATH_MAX];
static char g_jobs[PATH_MAX];
static char g_log[PATH_MAX];
static FILE *g_logfp;
static volatile sig_atomic_t g_stop;

static void on_signal(int sig) { (void)sig; g_stop = 1; }

static void log_line(const char *fmt, ...) {
    if (!g_logfp) return;
    char ts[32];
    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", &tm);
    fprintf(g_logfp, "%s ", ts);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_logfp, fmt, ap);
    va_end(ap);
    fputc('\n', g_logfp);
    fflush(g_logfp);
}

static int mkdir_p(const char *path, mode_t mode) {
    char buf[PATH_MAX];
    snprintf(buf, sizeof buf, "%s", path);
    for (char *p = buf + 1; *p; p++) {
        if (*p != '/') continue;
        *p = 0;
        if (mkdir(buf, mode) && errno != EEXIST) return -1;
        *p = '/';
    }
    if (mkdir(buf, mode) && errno != EEXIST) return -1;
    return 0;
}

static int is_jbroot_name(const char *name) {
    static const char prefix[] = ".jbroot-";
    if (strncmp(name, prefix, sizeof prefix - 1) != 0) return 0;
    const char *hex = name + sizeof prefix - 1;
    if (strlen(hex) != 16) return 0;
    unsigned long long v = strtoull(hex, NULL, 16);
    for (const char *c = hex; *c; c++)
        if (!((*c >= '0' && *c <= '9') || (*c >= 'a' && *c <= 'f'))) return 0;
    unsigned char check = 0;
    for (int i = 1; i <= 7; i++) check ^= (unsigned char)(v >> (i * 8));
    return check == (unsigned char)v;
}

// "/x/.jbroot-<digits>/y" -> "/x/.jbroot-<digits>"
static int roothide_root_of(const char *path, char *out, size_t cap) {
    char copy[PATH_MAX];
    snprintf(copy, sizeof copy, "%s", path);
    size_t len = strlen(copy);
    for (size_t i = len; i > 0; i--) {
        if (copy[i] != '/' && copy[i] != 0) continue;
        char *seg = copy + i + 1;
        char *slash = strchr(seg, '/');
        if (slash) *slash = 0;
        if (is_jbroot_name(seg)) {
            copy[i] = 0;
            if (strlen(copy) >= cap) return -1;
            strcpy(out, copy);
            return 0;
        }
    }
    return -1;
}

static int derive_paths(void) {
    char own[PATH_MAX], real[PATH_MAX];
    if (proc_pidpath(getpid(), own, sizeof own) <= 0) return -1;
    if (!realpath(own, real)) return -1;
    size_t len = strlen(real), slen = strlen(SUFFIX);
    if (len <= slen || strcmp(real + len - slen, SUFFIX) != 0) return -1;
    real[len - slen] = 0;
    snprintf(g_root, sizeof g_root, "%s", real[0] ? real : "/");
    if (roothide_root_of(real, g_root, sizeof g_root) != 0 && strcmp(g_root, "/") != 0) {
        // Outside RootHide keep the derived root as it is.
    }
    snprintf(g_base, sizeof g_base, "%s/var/mobile/Library/MinisAgent", strcmp(g_root, "/") ? g_root : "");
    snprintf(g_inbox, sizeof g_inbox, "%s/inbox", g_base);
    snprintf(g_jobs, sizeof g_jobs, "%s/jobs", g_base);
    snprintf(g_log, sizeof g_log, "%s/agentd.log", g_base);
    return 0;
}

static int ensure_layout(void) {
    char debs[PATH_MAX];
    snprintf(debs, sizeof debs, "%s/debs", g_base);
    if (mkdir_p(g_base, 0755) || mkdir_p(g_inbox, 0770) || mkdir_p(g_jobs, 0750) ||
        mkdir_p(debs, 0770))
        return -1;
    return 0;
}

static void json_escape(const char *in, char *out, size_t cap) {
    size_t o = 0;
    for (const char *p = in; *p && o + 2 < cap; p++) {
        if (*p == '"' || *p == '\\') out[o++] = '\\';
        if (*p == '\n') { out[o++] = '\\'; out[o++] = 'n'; continue; }
        out[o++] = *p;
    }
    out[o] = 0;
}

static int write_result(const char *dir, const char *status, int code, const char *msg) {
    char path[PATH_MAX], esc[1024];
    snprintf(path, sizeof path, "%s/result.json", dir);
    json_escape(msg, esc, sizeof esc);
    FILE *f = fopen(path, "w");
    if (!f) return -1;
    fprintf(f, "{\"status\":\"%s\",\"exit\":%d,\"message\":\"%s\",\"finished\":%ld}\n",
            status, code, esc, (long)time(NULL));
    fclose(f);
    return 0;
}

static int read_field(const char *path, const char *key, char *out, size_t cap) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    char line[PATH_MAX + 64];
    size_t klen = strlen(key);
    int found = -1;
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, key, klen) == 0 && line[klen] == '=') {
            char *v = line + klen + 1;
            char *nl = strchr(v, '\n');
            if (nl) *nl = 0;
            snprintf(out, cap, "%s", v);
            found = 0;
            break;
        }
    }
    fclose(f);
    return found;
}

static int sha256_file(const char *path, char out[65]) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    unsigned char buf[65536], digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    ssize_t n;
    while ((n = read(fd, buf, sizeof buf)) > 0) CC_SHA256_Update(&ctx, buf, (CC_LONG)n);
    close(fd);
    if (n < 0) return -1;
    CC_SHA256_Final(digest, &ctx);
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) sprintf(out + i * 2, "%02x", digest[i]);
    out[64] = 0;
    return 0;
}

static int run(char *const argv[], char *const envp[], int *exit_code) {
    pid_t pid;
    if (posix_spawn(&pid, argv[0], NULL, NULL, argv, envp) != 0) return -1;
    int status;
    if (waitpid(pid, &status, 0) < 0) return -1;
    *exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    return 0;
}

static int run_shell(const char *cmd) {
    char *argv[] = {"/bin/sh", "-c", (char *)cmd, NULL};
    int code = -1;
    if (run(argv, environ, &code) != 0) return -1;
    return code;
}

static void handle_job(const char *id) {
    char dir[PATH_MAX], job[PATH_MAX], deb[PATH_MAX], want[80], pkg[128], resp[8], digest[65];
    char copied[PATH_MAX], result[PATH_MAX], line[512];
    snprintf(dir, sizeof dir, "%s/%s", g_jobs, id);
    mkdir(dir, 0750);
    snprintf(job, sizeof job, "%s/job", dir);
    snprintf(result, sizeof result, "%s/result.json", dir);
    log_line("job %s start", id);

    if (read_field(job, "deb", deb, sizeof deb) || read_field(job, "sha256", want, sizeof want)) {
        write_result(dir, "fail", 0, "job missing deb or sha256");
        return;
    }
    if (read_field(job, "package", pkg, sizeof pkg)) pkg[0] = 0;
    if (read_field(job, "respring", resp, sizeof resp)) snprintf(resp, sizeof resp, "0");

    if (sha256_file(deb, digest) || strcasecmp(digest, want) != 0) {
        write_result(dir, "fail", 0, "sha256 mismatch");
        log_line("job %s sha256 mismatch", id);
        return;
    }

    char debs[PATH_MAX];
    snprintf(debs, sizeof debs, "%s/debs", g_base);
    snprintf(copied, sizeof copied, "%s/%s-%s", debs, id,
             strrchr(deb, '/') ? strrchr(deb, '/') + 1 : deb);
    char *cp[] = {"/bin/cp", (char *)deb, copied, NULL};
    int code = 0;
    if (run(cp, environ, &code) != 0 || code != 0) {
        snprintf(line, sizeof line, "copy failed (%d)", code);
        write_result(dir, "fail", code, line);
        return;
    }

    char *dpkg[] = {"/usr/bin/dpkg", "-i", copied, NULL};
    if (run(dpkg, environ, &code) != 0 || code != 0) {
        snprintf(line, sizeof line, "dpkg -i failed (%d)", code);
        write_result(dir, "fail", code, line);
        log_line("job %s dpkg failed %d", id, code);
        return;
    }

    if (resp[0] == '1') {
        code = run_shell("/usr/bin/killall SpringBoard");
        log_line("job %s respring %d", id, code);
        sleep(6);
    }

    // Confirm the package is in the dpkg database rather than trusting dpkg's exit code.
    if (pkg[0]) {
        char probe[256];
        snprintf(probe, sizeof probe,
                 "/usr/bin/dpkg -s '%s' >/dev/null 2>&1 && echo yes || echo no", pkg);
        FILE *f = popen(probe, "r");
        char answer[8] = "";
        if (f) { if (fgets(answer, sizeof answer, f)) {} pclose(f); }
        if (strncmp(answer, "yes", 3) != 0) {
            write_result(dir, "fail", 0, "dpkg reports the package not installed");
            log_line("job %s not in dpkg database", id);
            return;
        }
    }

    write_result(dir, "ok", 0, "installed");
    log_line("job %s ok", id);
}

static void scan_jobs(void) {
    DIR *d = opendir(g_inbox);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        size_t len = strlen(e->d_name);
        if (len < 5 || strcmp(e->d_name + len - 4, ".job") != 0) continue;
        char id[128], from[PATH_MAX], to[PATH_MAX];
        snprintf(id, sizeof id, "%.*s", (int)(len - 4), e->d_name);
        snprintf(from, sizeof from, "%s/%s", g_inbox, e->d_name);
        char dir[PATH_MAX], job[PATH_MAX];
        snprintf(dir, sizeof dir, "%s/%s", g_jobs, id);
        snprintf(job, sizeof job, "%s/job", dir);
        if (mkdir(dir, 0750) && errno != EEXIST) continue;
        if (rename(from, job) != 0) continue;
        handle_job(id);
    }
    closedir(d);
}

int main(void) {
    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    signal(SIGPIPE, SIG_IGN);
    umask(022);
    if (derive_paths() != 0) {
        fprintf(stderr, "minis-agentd: refusing to start from an unrecognised path\n");
        return 78;
    }
    if (ensure_layout() != 0) return 1;
    g_logfp = fopen(g_log, "a");
    log_line("start uid=%d root=%s", (int)getuid(), g_root);

    int idle = 0;
    while (!g_stop) {
        DIR *d = opendir(g_inbox);
        int pending = 0;
        if (d) {
            struct dirent *e;
            while ((e = readdir(d)))
                if (strlen(e->d_name) > 4 && strstr(e->d_name, ".job")) pending = 1;
            closedir(d);
        }
        if (pending) { idle = 0; scan_jobs(); continue; }
        if (++idle > 300) {
            log_line("idle exit");
            break;
        }
        sleep(1);
    }
    log_line("stop");
    if (g_logfp) fclose(g_logfp);
    return 0;
}
