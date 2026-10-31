#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
static char camera_directory[4096], location_directory[4096], observe_path[4096];
#define VPHONE_VCAM_V2_DIRECTORY camera_directory
#define VPHONE_VCAM_V2_OBSERVE_SHM_PATH observe_path
#define VPHONE_LOCATION_STATE_DIRECTORY location_directory
#include "../../sources/VPhoneGuestComponents/Shared/VPhoneSimulationAccess.c"

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "check failed at %d: %s\n", __LINE__, #x); return 1; } } while (0)
static unsigned issued_count, consumed_count;
static char *issue(const char *kind, const char *path, uint32_t flags) {
    if (flags || (strcmp(path, camera_directory) && strcmp(path, location_directory) && strcmp(path, observe_path))) abort();
    if (strcmp(kind, strcmp(path, observe_path) == 0 ? "com.apple.app-sandbox.read-write" : "com.apple.app-sandbox.read")) abort();
    issued_count++; return strdup(strcmp(path, observe_path) == 0 ? "receipt-write" : "state-read");
}
static int64_t consume(const char *token) { if (strncmp(token, "read-", 5)) abort(); consumed_count++; return 42; }
static unsigned entries(char *const values[], unsigned index) {
    unsigned n = 0;
    for (unsigned i = 0; values && values[i]; i++) if (vpSimulationKeyIndex(values[i]) == (int)index) n++;
    return n;
}

int main(int argc, char **argv) {
    if (argc != 3) return 64;
    snprintf(camera_directory, sizeof(camera_directory), "%s/camera", argv[1]);
    snprintf(location_directory, sizeof(location_directory), "%s/location", argv[1]);
    snprintf(observe_path, sizeof(observe_path), "%s/vphone-vcam-observe.shm", camera_directory);
    if (!strcmp(argv[2], "prepare")) {
        CHECK(vpSimulationPrepare(geteuid(), getegid()) == 0);
        int fd = open(observe_path, O_WRONLY); CHECK(fd >= 0); CHECK(write(fd, "keep", 4) == 4); close(fd);
        CHECK(vpSimulationPrepare(geteuid(), getegid()) == 0);
        char bytes[4]; fd = open(observe_path, O_RDONLY); CHECK(fd >= 0); CHECK(read(fd, bytes, 4) == 4); close(fd);
        CHECK(!memcmp(bytes, "keep", 4));
        struct stat st; CHECK(stat(observe_path, &st) == 0 && st.st_size == 128 && st.st_uid == geteuid());
    } else if (!strcmp(argv[2], "symlink")) {
        CHECK(mkdir(camera_directory, 0755) == 0);
        char outside[4096]; snprintf(outside, sizeof(outside), "%s/outside", argv[1]);
        int fd = open(outside, O_CREAT | O_WRONLY, 0600); CHECK(fd >= 0); CHECK(write(fd, "keep", 4) == 4); close(fd);
        CHECK(symlink(outside, observe_path) == 0); CHECK(vpSimulationPrepare(geteuid(), getegid()) < 0);
        struct stat st; CHECK(stat(outside, &st) == 0 && st.st_size == 4);
    } else if (!strcmp(argv[2], "scopes")) {
        char *environment[] = {"HOME=/test", "VPHONE_CAMERA_READ_TOKEN=stale", "VPHONE_CAMERA_READ_TOKEN=duplicate", "VPHONE_CAMERA_OBSERVE_WRITE_TOKEN=stale-write", NULL};
        VPSimulationEnvironment app = vpSimulationEnvironment(environment, NULL, VP_SIM_APP_ACCESS, issue);
        CHECK(app.granted == VP_SIM_APP_ACCESS && issued_count == 2);
        CHECK(entries(app.values, 0) == 1 && entries(app.values, 1) == 1 && entries(app.values, 2) == 0);
        char *fresh[] = {"DYLD_INSERT_LIBRARIES=/usr/lib/SystemHook-vphone.dylib", NULL};
        VPSimulationEnvironment carried = vpSimulationEnvironment(fresh, app.values, VP_SIM_APP_ACCESS, NULL);
        CHECK(carried.granted == VP_SIM_APP_ACCESS && entries(carried.values, 2) == 0);
        VPSimulationEnvironment daemon = vpSimulationEnvironment(environment, NULL, VP_SIM_CAMERA_ACCESS, issue);
        CHECK(daemon.granted == VP_SIM_CAMERA_ACCESS && issued_count == 4 && entries(daemon.values, 1) == 0);
        VPSimulationEnvironment dropped = vpSimulationEnvironment(daemon.values, daemon.values, 0, NULL);
        CHECK(entries(dropped.values, 0) == 0 && entries(dropped.values, 1) == 0 && entries(dropped.values, 2) == 0);
        CHECK(!strcmp(environment[1], "VPHONE_CAMERA_READ_TOKEN=stale"));
        vpSimulationFreeEnvironment(&dropped); vpSimulationFreeEnvironment(&daemon);
        vpSimulationFreeEnvironment(&carried); vpSimulationFreeEnvironment(&app);
    } else if (!strcmp(argv[2], "consume")) {
        setenv(vpSimulationTokenKeys[0], "read-camera", 1); setenv(vpSimulationTokenKeys[1], "read-location", 1);
        setenv(vpSimulationTokenKeys[2], "write-receipt", 1);
        vpSimulationFilterTokens(VP_SIM_APP_ACCESS); CHECK(getenv(vpSimulationTokenKeys[2]) == NULL);
        CHECK(vpSimulationConsumeWith(VP_SIM_APP_ACCESS, consume) == VP_SIM_APP_ACCESS && consumed_count == 2);
        CHECK(getenv(vpSimulationTokenKeys[0]) == NULL && getenv(vpSimulationTokenKeys[1]) == NULL);
        CHECK(vpSimulationConsumeWith(VP_SIM_APP_ACCESS, consume) == VP_SIM_APP_ACCESS && consumed_count == 2);
    } else if (!strcmp(argv[2], "targets")) {
        CHECK(vpSimulationProgramAccess("/usr/libexec/xpcproxy", "UIKitApplication:org.test[1]") == VP_SIM_APP_ACCESS);
        CHECK(vpSimulationProgramAccess("/usr/libexec/xpcproxy", "com.apple.cameracaptured") == VP_SIM_CAMERA_ACCESS);
        CHECK(vpSimulationProgramAccess("/usr/libexec/cameracaptured", NULL) == VP_SIM_CAMERA_ACCESS);
        CHECK(vpSimulationProgramAccess("/private/var/containers/Bundle/Application/id/Test.app/Test", NULL) == VP_SIM_APP_ACCESS);
        CHECK(vpSimulationProgramAccess("/usr/libexec/xpcproxy", "com.apple.other") == 0);
        CHECK(vpSimulationProgramAccess("/tmp/Fake.app/Tool", NULL) == 0);
    } else return 65;
    return 0;
}
