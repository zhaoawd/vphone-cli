// Host-only lifecycle harness. No UIKit, vsock, guest cache or device operations.
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
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

int main(void) {
    int mode = vp_native_process_mode();
    if (mode < 0) return 64;
    if (mode == 0) return vp_native_run_proxy();
    const char *action = getenv("VPHONE_PROXY_TEST_ACTION");
    if (!action) return 65;
    int stubborn = strcmp(action, "stubborn") == 0;
    if (stubborn) signal(SIGTERM, SIG_IGN);
    else if (vp_native_watch_proxy() != 0) return 66;
    const char *ready = getenv("VPHONE_PROXY_TEST_READY");
    int fd = open(ready, O_WRONLY | O_APPEND | O_CREAT, 0600);
    if (fd < 0) return 67;
    dprintf(fd, "%d\n", getpid());
    close(fd);
    if (strcmp(action, "success") == 0) return 0;
    if (strcmp(action, "crash") == 0) return 23;
    for (;;) pause();
}
