/*
 * omarchy-shell-ipc.c — Zero-fork native C IPC front-end for `omarchy-shell`.
 * Replaces 288 lines of shell `makeWrapper` + `bash` + `md5sum` + `ls` + `timeout` + `socat`
 * (~400–1200ms per hotkey) with an in-process AF_UNIX round-trip (~0.2ms).
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef DEFAULT_OMARCHY_PATH
#define DEFAULT_OMARCHY_PATH "/usr/share/omarchy"
#endif

#ifndef DEFAULT_QS_BIN
#define DEFAULT_QS_BIN "qs"
#endif

/* Compact RFC 1321 MD5 for deriving `omarchy-shell-<md5[:16]>.sock`. */
typedef struct {
    uint32_t h[4];
    uint64_t len;
    uint8_t buf[64];
} md5_ctx;

static void md5_block(md5_ctx *c, const uint8_t b[64]) {
    static const uint32_t k[64] = {
        0xd76aa478u,0xe8c7b756u,0x242070dbu,0xc1bdceeeu,0xf57c0fafu,0x4787c62au,0xa8304613u,0xfd469501u,
        0x698098d8u,0x8b44f7afu,0xffff5bb1u,0x895cd7beu,0x6b901122u,0xfd987193u,0xa679438eu,0x49b40821u,
        0xf61e2562u,0xc040b340u,0x265e5a51u,0xe9b6c7aau,0xd62f105du,0x02441453u,0xd8a1e681u,0xe7d3fbc8u,
        0x21e1cde6u,0xc33707d6u,0xf4d50d87u,0x455a14edu,0xa9e3e905u,0xfcefa3f8u,0x676f02d9u,0x8d2a4c8au,
        0xfffa3942u,0x8771f681u,0x6d9d6122u,0xfde5380cu,0xa4beea44u,0x4bdecfa9u,0xf6bb4b60u,0xbebfbc70u,
        0x289b7ec6u,0xeaa127fau,0xd4ef3085u,0x04881d05u,0xd9d4d039u,0xe6db99e5u,0x1fa27cf8u,0xc4ac5665u,
        0xf4292244u,0x432aff97u,0xab9423a7u,0xfc93a039u,0x655b59c3u,0x8f0ccc92u,0xffeff47du,0x85845dd1u,
        0x6fa87e4fu,0xfe2ce6e0u,0xa3014314u,0x4e0811a1u,0xf7537e82u,0xbd3af235u,0x2ad7d2bbu,0xeb86d391u
    };
    static const uint8_t r[64] = {
        7,12,17,22,7,12,17,22,7,12,17,22,7,12,17,22,
        5, 9,14,20,5, 9,14,20,5, 9,14,20,5, 9,14,20,
        4,11,16,23,4,11,16,23,4,11,16,23,4,11,16,23,
        6,10,15,21,6,10,15,21,6,10,15,21,6,10,15,21
    };
    uint32_t w[16];
    for (int i = 0; i < 16; ++i) {
        w[i] = (uint32_t)b[i * 4] | ((uint32_t)b[i * 4 + 1] << 8) |
               ((uint32_t)b[i * 4 + 2] << 16) | ((uint32_t)b[i * 4 + 3] << 24);
    }
    uint32_t a = c->h[0], d0 = c->h[1], e = c->h[2], f = c->h[3];
    for (int i = 0; i < 64; ++i) {
        uint32_t fn, g;
        if (i < 16) { fn = (d0 & e) | ((~d0) & f); g = (uint32_t)i; }
        else if (i < 32) { fn = (f & d0) | ((~f) & e); g = (uint32_t)((5 * i + 1) & 15); }
        else if (i < 48) { fn = d0 ^ e ^ f; g = (uint32_t)((3 * i + 5) & 15); }
        else { fn = e ^ (d0 | (~f)); g = (uint32_t)((7 * i) & 15); }
        uint32_t tmp = f;
        f = e;
        e = d0;
        uint32_t x = a + fn + k[i] + w[g];
        d0 = d0 + ((x << r[i]) | (x >> (32 - r[i])));
        a = tmp;
    }
    c->h[0] += a; c->h[1] += d0; c->h[2] += e; c->h[3] += f;
}

static void md5_hex16(const char *data, size_t len, char out17[17]) {
    md5_ctx c = { { 0x67452301u, 0xefcdab89u, 0x98badcfeu, 0x10325476u }, 0, {0} };
    size_t off = 0;
    while (len - off >= 64) {
        md5_block(&c, (const uint8_t *)(data + off));
        off += 64;
    }
    size_t rem = len - off;
    memcpy(c.buf, data + off, rem);
    c.buf[rem++] = 0x80;
    if (rem > 56) {
        memset(c.buf + rem, 0, 64 - rem);
        md5_block(&c, c.buf);
        rem = 0;
    }
    memset(c.buf + rem, 0, 56 - rem);
    uint64_t bits = (uint64_t)len * 8u;
    for (int i = 0; i < 8; ++i) c.buf[56 + i] = (uint8_t)((bits >> (i * 8)) & 0xffu);
    md5_block(&c, c.buf);
    static const char hex[] = "0123456789abcdef";
    uint8_t raw[8];
    for (int i = 0; i < 2; ++i) {
        raw[i * 4 + 0] = (uint8_t)(c.h[i] & 0xffu);
        raw[i * 4 + 1] = (uint8_t)((c.h[i] >> 8) & 0xffu);
        raw[i * 4 + 2] = (uint8_t)((c.h[i] >> 16) & 0xffu);
        raw[i * 4 + 3] = (uint8_t)((c.h[i] >> 24) & 0xffu);
    }
    for (int i = 0; i < 8; ++i) {
        out17[i * 2] = hex[(raw[i] >> 4) & 0x0f];
        out17[i * 2 + 1] = hex[raw[i] & 0x0f];
    }
    out17[16] = '\0';
}

static int g_quiet = 0;

static void fail_msg(const char *msg) {
    if (g_quiet) _exit(0);
    fprintf(stderr, "%s\n", msg);
    _exit(1);
}

static int parse_timeout_ms(const char *s) {
    if (!s || !*s) return 2000;
    char *end = NULL;
    double val = strtod(s, &end);
    if (end == s || val <= 0.0) return 2000;
    if (end && strcmp(end, "ms") == 0) return (int)(val < 50.0 ? 50.0 : val);
    if (end && (*end == 'm' || *end == 'M')) val *= 60.0;
    else if (end && (*end == 'h' || *end == 'H')) val *= 3600.0;
    double ms = val * 1000.0;
    if (ms < 50.0) ms = 50.0;
    if (ms > 300000.0) ms = 300000.0;
    return (int)ms;
}

typedef struct {
    char path[256];
    struct timespec mtime;
} sock_cand;

static int cmp_sock_newest(const void *a, const void *b) {
    const sock_cand *sa = (const sock_cand *)a, *sb = (const sock_cand *)b;
    if (sa->mtime.tv_sec != sb->mtime.tv_sec)
        return sa->mtime.tv_sec < sb->mtime.tv_sec ? 1 : -1;
    if (sa->mtime.tv_nsec != sb->mtime.tv_nsec)
        return sa->mtime.tv_nsec < sb->mtime.tv_nsec ? 1 : -1;
    return strcmp(sa->path, sb->path);
}

static void resolve_wayland_display(const char *runtime_dir) {
    const char *wd = getenv("WAYLAND_DISPLAY");
    if (wd && *wd) {
        char check[512];
        if (wd[0] == '/') snprintf(check, sizeof(check), "%s", wd);
        else snprintf(check, sizeof(check), "%s/%s", runtime_dir, wd);
        struct stat st;
        if (stat(check, &st) == 0) return;
    }
    DIR *d = opendir(runtime_dir);
    if (!d) return;
    char best[128] = "";
    struct timespec best_ts = { 0, 0 };
    struct dirent *de;
    while ((de = readdir(d)) != NULL) {
        if (strncmp(de->d_name, "wayland-", 8) != 0 || !isdigit((unsigned char)de->d_name[8]))
            continue;
        size_t nlen = strlen(de->d_name);
        if (nlen > 5 && strcmp(de->d_name + nlen - 5, ".lock") == 0)
            continue;
        char full[512];
        snprintf(full, sizeof(full), "%s/%s", runtime_dir, de->d_name);
        struct stat st;
        if (stat(full, &st) == 0 && S_ISSOCK(st.st_mode)) {
            if (best[0] == '\0' || st.st_mtim.tv_sec > best_ts.tv_sec ||
                (st.st_mtim.tv_sec == best_ts.tv_sec && st.st_mtim.tv_nsec > best_ts.tv_nsec)) {
                snprintf(best, sizeof(best), "%s", de->d_name);
                best_ts = st.st_mtim;
            }
        }
    }
    closedir(d);
    if (best[0] != '\0') setenv("WAYLAND_DISPLAY", best, 1);
}

/* Returns: 1 = handled (exit 0), 0 = SKIP or no live socket (fall back to qs ipc), -1 = timeout/error */
static int try_socket_call(const char *sock_path, const char *req, size_t req_len, int timeout_ms) {
    struct sockaddr_un addr;
    if (strlen(sock_path) >= sizeof(addr.sun_path)) return 0;
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return 0;

    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", sock_path);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        int err = errno;
        close(fd);
        if (err == ECONNREFUSED || err == ENOENT) {
            unlink(sock_path);
        }
        return 0;
    }

    struct timespec start_ts, now_ts;
    clock_gettime(CLOCK_MONOTONIC, &start_ts);

    size_t sent = 0;
    while (sent < req_len) {
        clock_gettime(CLOCK_MONOTONIC, &now_ts);
        int elapsed = (int)((now_ts.tv_sec - start_ts.tv_sec) * 1000 +
                            (now_ts.tv_nsec - start_ts.tv_nsec) / 1000000);
        int rem_ms = timeout_ms - elapsed;
        if (rem_ms <= 0) { close(fd); return -1; }
        struct pollfd pfd = { .fd = fd, .events = POLLOUT };
        int pr = poll(&pfd, 1, rem_ms);
        if (pr <= 0) {
            if (pr < 0 && errno == EINTR) continue;
            close(fd);
            return -1;
        }
        ssize_t n = send(fd, req + sent, req_len - sent, MSG_NOSIGNAL);
        if (n < 0) {
            if (errno == EINTR) continue;
            close(fd);
            return sent == 0 ? 0 : -1;
        }
        sent += (size_t)n;
    }

    size_t cap = 4096, len = 0;
    char *buf = malloc(cap);
    if (!buf) { close(fd); return -1; }
    int got_rs = 0;

    while (!got_rs) {
        clock_gettime(CLOCK_MONOTONIC, &now_ts);
        int elapsed = (int)((now_ts.tv_sec - start_ts.tv_sec) * 1000 +
                            (now_ts.tv_nsec - start_ts.tv_nsec) / 1000000);
        int rem_ms = timeout_ms - elapsed;
        if (rem_ms <= 0) { free(buf); close(fd); return -1; }
        struct pollfd pfd = { .fd = fd, .events = POLLIN };
        int pr = poll(&pfd, 1, rem_ms);
        if (pr <= 0) {
            if (pr < 0 && errno == EINTR) continue;
            free(buf);
            close(fd);
            return -1;
        }
        if (len + 2048 > cap) {
            size_t ncap = cap * 2;
            char *nb = realloc(buf, ncap);
            if (!nb) { free(buf); close(fd); return -1; }
            buf = nb;
            cap = ncap;
        }
        ssize_t n = recv(fd, buf + len, cap - len - 1, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            free(buf);
            close(fd);
            return -1;
        }
        if (n == 0) break;
        for (ssize_t i = 0; i < n; ++i) {
            if (buf[len + (size_t)i] == '\x1e') {
                got_rs = 1;
                len += (size_t)i + 1;
                break;
            }
        }
        if (!got_rs) len += (size_t)n;
    }
    close(fd);

    if (!got_rs) {
        free(buf);
        return -1;
    }

    if (len >= 4 && buf[0] == 'O' && buf[1] == 'K' && buf[2] == '\x1f') {
        size_t out_len = len - 4; /* strip leading "OK\x1f" and trailing '\x1e' */
        char *out = buf + 3;
        while (out_len > 0 && out[out_len - 1] == '\n') out_len--;
        if (!g_quiet && out_len > 0) {
            fwrite(out, 1, out_len, stdout);
            fputc('\n', stdout);
            fflush(stdout);
        }
        free(buf);
        return 1;
    }

    if (len >= 5 && memcmp(buf, "SKIP\x1e", 5) == 0) {
        free(buf);
        return 0;
    }

    free(buf);
    return -1;
}

int main(int argc, char **argv) {
    int argi = 1;
    if (argi < argc && strcmp(argv[argi], "-q") == 0) {
        g_quiet = 1;
        argi++;
    }

    if (argi >= argc || strcmp(argv[argi], "-h") == 0 || strcmp(argv[argi], "--help") == 0) {
        printf(
            "Usage: omarchy-shell [-q] <target> <method> [args...]\n\n"
            "Forwards an IPC call to the running Omarchy shell. The shell is expected\n"
            "to already be running; this command does not start it.\n\n"
            "Options:\n"
            "  -q  Quiet best-effort mode. Suppress output and return success even when\n"
            "      the shell, target, method, or arguments are unavailable.\n"
        );
        return 0;
    }

    int rem_argc = argc - argi;
    if (rem_argc < 2) {
        fail_msg("Usage: omarchy-shell <target> <method> [args...]");
    }

    const char *omarchy_path = getenv("OMARCHY_PATH");
    if (!omarchy_path || !*omarchy_path) {
        omarchy_path = DEFAULT_OMARCHY_PATH;
        setenv("OMARCHY_PATH", omarchy_path, 1);
    }

    char shell_dir[512], shell_qml[560];
    snprintf(shell_dir, sizeof(shell_dir), "%s/shell", omarchy_path);
    snprintf(shell_qml, sizeof(shell_qml), "%s/shell.qml", shell_dir);
    struct stat st;
    if (stat(shell_qml, &st) != 0) {
        char msg[640];
        snprintf(msg, sizeof(msg), "omarchy-shell config not found: %s", shell_qml);
        fail_msg(msg);
    }

    char rt_fallback[64];
    const char *runtime_dir = getenv("XDG_RUNTIME_DIR");
    if (!runtime_dir || !*runtime_dir) {
        snprintf(rt_fallback, sizeof(rt_fallback), "/run/user/%u", (unsigned)getuid());
        runtime_dir = rt_fallback;
        setenv("XDG_RUNTIME_DIR", runtime_dir, 1);
    }

    resolve_wayland_display(runtime_dir);
    const char *wd = getenv("WAYLAND_DISPLAY");
    if (!wd) wd = "";

    /* Normalize `shell summon <id>` -> `shell summon <id> {}` */
    int call_argc = rem_argc;
    int append_empty_json = 0;
    if (rem_argc == 3 && strcmp(argv[argi], "shell") == 0 &&
        (strcmp(argv[argi + 1], "summon") == 0 || strcmp(argv[argi + 1], "toggle") == 0)) {
        append_empty_json = 1;
        call_argc = 4;
    }

    int has_sep = 0;
    size_t total_len = 0;
    for (int i = 0; i < rem_argc; ++i) {
        const char *a = argv[argi + i];
        for (const char *p = a; *p; ++p) {
            if (*p == '\x1e' || *p == '\x1f') has_sep = 1;
        }
        total_len += strlen(a) + 1;
    }
    if (append_empty_json) total_len += 3;

    int timeout_ms = parse_timeout_ms(getenv("OMARCHY_SHELL_IPC_TIMEOUT"));

    if (!has_sep) {
        char *req = malloc(total_len + 2);
        if (req) {
            size_t pos = 0;
            for (int i = 0; i < rem_argc; ++i) {
                if (i > 0) req[pos++] = '\x1f';
                size_t al = strlen(argv[argi + i]);
                memcpy(req + pos, argv[argi + i], al);
                pos += al;
            }
            if (append_empty_json) {
                req[pos++] = '\x1f';
                req[pos++] = '{';
                req[pos++] = '}';
            }
            req[pos++] = '\x1e';

            char key_buf[768], md5_id[17], primary_sock[384];
            int klen = snprintf(key_buf, sizeof(key_buf), "%s\n%s", shell_dir, wd);
            if (klen > 0 && (size_t)klen < sizeof(key_buf)) {
                md5_hex16(key_buf, (size_t)klen, md5_id);
                snprintf(primary_sock, sizeof(primary_sock), "%s/omarchy-shell-%s.sock", runtime_dir, md5_id);

                if (stat(primary_sock, &st) == 0 && S_ISSOCK(st.st_mode)) {
                    int rc = try_socket_call(primary_sock, req, pos, timeout_ms);
                    if (rc == 1) { free(req); return 0; }
                    if (rc == -1) { free(req); fail_msg("omarchy-shell is not responding"); }
                }

                /* Fallback to any other live `omarchy-shell-*.sock` in runtime_dir (newest first). */
                DIR *d = opendir(runtime_dir);
                if (d) {
                    sock_cand cands[16];
                    size_t nc = 0;
                    struct dirent *de;
                    while ((de = readdir(d)) != NULL && nc < 16) {
                        if (strncmp(de->d_name, "omarchy-shell-", 14) != 0) continue;
                        size_t nl = strlen(de->d_name);
                        if (nl <= 19 || strcmp(de->d_name + nl - 5, ".sock") != 0) continue;
                        char full[256];
                        int fl = snprintf(full, sizeof(full), "%s/%s", runtime_dir, de->d_name);
                        if (fl <= 0 || (size_t)fl >= sizeof(full)) continue;
                        if (strcmp(full, primary_sock) == 0) continue;
                        if (stat(full, &st) == 0 && S_ISSOCK(st.st_mode)) {
                            snprintf(cands[nc].path, sizeof(cands[nc].path), "%s", full);
                            cands[nc].mtime = st.st_mtim;
                            nc++;
                        }
                    }
                    closedir(d);
                    if (nc > 1) qsort(cands, nc, sizeof(cands[0]), cmp_sock_newest);
                    for (size_t i = 0; i < nc; ++i) {
                        int rc = try_socket_call(cands[i].path, req, pos, timeout_ms);
                        if (rc == 1) { free(req); return 0; }
                        if (rc == -1) { free(req); fail_msg("omarchy-shell is not responding"); }
                        /* rc == 0 on SKIP: stop trying alternate sockets and fall through to qs ipc */
                        if (stat(cands[i].path, &st) == 0) break;
                    }
                }
            }
            free(req);
        }
    }

    /* Fallback path: `qs ipc -n -p "$OMARCHY_PATH/shell" call -- <args...>` */
    int pipefd[2];
    if (pipe2(pipefd, O_CLOEXEC) != 0) fail_msg("omarchy-shell is not running");

    pid_t pid = fork();
    if (pid < 0) fail_msg("omarchy-shell is not running");
    if (pid == 0) {
        dup2(pipefd[1], STDOUT_FILENO);
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) { dup2(devnull, STDERR_FILENO); close(devnull); }
        close(pipefd[0]);
        close(pipefd[1]);

        char **qargv = calloc((size_t)call_argc + 8, sizeof(char *));
        if (!qargv) _exit(127);
        int k = 0;
        qargv[k++] = (char *)DEFAULT_QS_BIN;
        qargv[k++] = "ipc";
        qargv[k++] = "-n";
        qargv[k++] = "-p";
        qargv[k++] = shell_dir;
        qargv[k++] = "call";
        qargv[k++] = "--";
        for (int i = 0; i < rem_argc; ++i) qargv[k++] = argv[argi + i];
        if (append_empty_json) qargv[k++] = "{}";
        qargv[k] = NULL;

        execvp(DEFAULT_QS_BIN, qargv);
        _exit(127);
    }
    close(pipefd[1]);

    struct timespec start_ts, now_ts;
    clock_gettime(CLOCK_MONOTONIC, &start_ts);
    size_t cap = 4096, len = 0;
    char *out = malloc(cap);
    if (!out) { kill(pid, SIGKILL); waitpid(pid, NULL, 0); fail_msg("omarchy-shell is not responding"); }

    int timed_out = 0;
    for (;;) {
        clock_gettime(CLOCK_MONOTONIC, &now_ts);
        int elapsed = (int)((now_ts.tv_sec - start_ts.tv_sec) * 1000 +
                            (now_ts.tv_nsec - start_ts.tv_nsec) / 1000000);
        int rem_ms = timeout_ms - elapsed;
        if (rem_ms <= 0) { timed_out = 1; break; }
        struct pollfd pfd = { .fd = pipefd[0], .events = POLLIN };
        int pr = poll(&pfd, 1, rem_ms);
        if (pr == 0) { timed_out = 1; break; }
        if (pr < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (len + 1024 > cap) {
            char *nb = realloc(out, cap * 2);
            if (!nb) break;
            out = nb;
            cap *= 2;
        }
        ssize_t n = read(pipefd[0], out + len, cap - len - 1);
        if (n < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (n == 0) break;
        len += (size_t)n;
    }
    close(pipefd[0]);

    int status = 0;
    if (timed_out) {
        kill(pid, SIGTERM);
        usleep(50000);
        if (waitpid(pid, &status, WNOHANG) == 0) {
            kill(pid, SIGKILL);
            waitpid(pid, &status, 0);
        }
        free(out);
        fail_msg("omarchy-shell is not responding");
    }
    waitpid(pid, &status, 0);
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        free(out);
        fail_msg("omarchy-shell is not running");
    }

    while (len > 0 && (out[len - 1] == '\n' || out[len - 1] == '\r')) len--;
    out[len] = '\0';

    if (strcmp(out, "Target not found.") == 0 ||
        strcmp(out, "Function not found.") == 0 ||
        strncmp(out, "Too few arguments provided", 26) == 0 ||
        strncmp(out, "Too many arguments provided", 27) == 0) {
        fail_msg(out);
    }
    if (strncmp(out, "Not ready to accept queries yet", 31) == 0) {
        free(out);
        fail_msg("omarchy-shell is not ready");
    }

    if (!g_quiet && len > 0) {
        printf("%s\n", out);
    }
    free(out);
    return 0;
}
