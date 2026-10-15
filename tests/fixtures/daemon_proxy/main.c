// Host-only lifecycle harness. No UIKit, vsock, guest cache or device operations.
#include <arpa/inet.h>
#include <spawn.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int fixture_access(const char *path, int mode);
static int fixture_spawn(pid_t *, const char *, const posix_spawn_file_actions_t *, const posix_spawnattr_t *, char *const[], char *const[]);
#define posix_spawn fixture_spawn
#define access fixture_access
#include "../../../sources/VPhoneDaemon/Native/vphoned_proxy.c"
#undef access
#undef posix_spawn

static int fixture_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions, const posix_spawnattr_t *attributes, char *const argv[], char *const envp[]) {
    const char *action = getenv("VPHONE_PROXY_TEST_ACTION");
    if (action && strcmp(action, "spawn-failure") == 0) {
        int fd = open(getenv("VPHONE_PROXY_TEST_READY"), O_WRONLY | O_APPEND | O_CREAT, 0600);
        if (fd >= 0) { dprintf(fd, "%d\n", getpid()); close(fd); }
        return ENOEXEC;
    }
    return posix_spawn(pid, path, actions, attributes, argv, envp);
}

static int fixture_access(const char *path, int mode) {
    (void)path; (void)mode;
    const char *pending = getenv("VPHONE_PROXY_TEST_PENDING");
    if (pending && strcmp(pending, "1") == 0) return 0;
    errno = ENOENT;
    return -1;
}

// Stands in for the worker's VSOCK listeners: a loopback TCP port that stays
// bound for as long as the worker process exists.
static int bind_loopback(const char *path) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in address = {.sin_len = sizeof(address), .sin_family = AF_INET};
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t size = sizeof(address);
    if (bind(fd, (struct sockaddr *)&address, size) != 0 || listen(fd, 1) != 0 ||
        getsockname(fd, (struct sockaddr *)&address, &size) != 0) return -1;
    int out = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (out < 0) return -1;
    dprintf(out, "%d\n", ntohs(address.sin_port));
    close(out);
    return fd;
}

// Deliver the stop on a non-waiting thread, as a Swift runtime can do.
static void *stop_from_other_thread(void *unused) {
    (void)unused;
    for (;;) {
        int fd = open(getenv("VPHONE_PROXY_TEST_READY"), O_RDONLY);
        if (fd >= 0) { close(fd); break; }
        usleep(10000);
    }
    usleep(100000);
    pthread_kill(pthread_self(), SIGTERM);
    return NULL;
}

int main(void) {
    if (getenv("VPHONE_PROXY_TEST_VCAM")) {
        printf("%d\n", vp_native_vcam_enabled());
        return 0;
    }
    int mode = vp_native_process_mode();
    if (mode < 0) return 64;
    if (mode == 0) {
        const char *ignore = getenv("VPHONE_PROXY_TEST_IGNORE_CHLD");
        // Ignored SIGCHLD lets the kernel reap workers, so waitpid fails.
        if (ignore && strcmp(ignore, "1") == 0) signal(SIGCHLD, SIG_IGN);
        const char *action = getenv("VPHONE_PROXY_TEST_ACTION");
        if (action && strcmp(action, "blocked-stop") == 0) {
            sigset_t blocked;
            sigemptyset(&blocked);
            sigaddset(&blocked, SIGTERM);
            sigaddset(&blocked, SIGINT);
            if (pthread_sigmask(SIG_BLOCK, &blocked, NULL)) return 70;
        }
        if (action && strcmp(action, "threaded-stop") == 0) {
            pthread_t stopper;
            if (pthread_create(&stopper, NULL, stop_from_other_thread, NULL)) return 69;
            int result = vp_native_run_proxy();
            pthread_join(stopper, NULL);
            return result;
        }
        return vp_native_run_proxy();
    }
    const char *action = getenv("VPHONE_PROXY_TEST_ACTION");
    if (!action) return 65;
    int stubborn = strcmp(action, "stubborn") == 0;
    if (stubborn) signal(SIGTERM, SIG_IGN);
    else if (vp_native_watch_proxy() != 0) return 66;
    if (strcmp(action, "bind") == 0 || strcmp(action, "threaded-stop") == 0 || strcmp(action, "blocked-stop") == 0) {
        const char *port = getenv("VPHONE_PROXY_TEST_PORT");
        if (!port || bind_loopback(port) < 0) return 68;
    }
    const char *ready = getenv("VPHONE_PROXY_TEST_READY");
    int fd = open(ready, O_WRONLY | O_APPEND | O_CREAT, 0600);
    if (fd < 0) return 67;
    dprintf(fd, "%d\n", getpid());
    close(fd);
    if (strcmp(action, "success") == 0) return 0;
    if (strcmp(action, "crash") == 0) return 23;
    if (strcmp(action, "signal") == 0) raise(SIGKILL);
    for (;;) pause();
}
