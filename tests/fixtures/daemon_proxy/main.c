// Host-only lifecycle harness. No UIKit, vsock, guest cache or device operations.
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int fixture_access(const char *path, int mode);
#define access fixture_access
#include "../../../sources/VPhoneDaemon/Native/vphoned_proxy.c"
#undef access

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

int main(void) {
    int mode = vp_native_process_mode();
    if (mode < 0) return 64;
    if (mode == 0) {
        const char *ignore = getenv("VPHONE_PROXY_TEST_IGNORE_CHLD");
        // Ignored SIGCHLD lets the kernel reap workers, so waitpid fails.
        if (ignore && strcmp(ignore, "1") == 0) signal(SIGCHLD, SIG_IGN);
        return vp_native_run_proxy();
    }
    const char *action = getenv("VPHONE_PROXY_TEST_ACTION");
    if (!action) return 65;
    int stubborn = strcmp(action, "stubborn") == 0;
    if (stubborn) signal(SIGTERM, SIG_IGN);
    else if (vp_native_watch_proxy() != 0) return 66;
    if (strcmp(action, "bind") == 0) {
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
