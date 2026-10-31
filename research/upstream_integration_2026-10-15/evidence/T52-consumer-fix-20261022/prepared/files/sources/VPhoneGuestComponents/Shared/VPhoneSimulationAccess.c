#include "VPhoneSimulationAccess.h"
#include "VPhoneCameraFrame.h"
#include "VPhoneLocationState.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

unsigned vpSimulationProgramAccess(const char *path, const char *proxyLabel) {
    if (!path) return 0;
    if (strcmp(path, "/usr/libexec/cameracaptured") == 0) return VP_SIM_CAMERA_ACCESS;
    if (strcmp(path, "/usr/libexec/xpcproxy") == 0) {
        if (proxyLabel && strcmp(proxyLabel, "com.apple.cameracaptured") == 0) return VP_SIM_CAMERA_ACCESS;
        if (proxyLabel && strncmp(proxyLabel, "UIKitApplication:", 17) == 0) return VP_SIM_APP_ACCESS;
        return 0;
    }
    const char *roots[] = {"/Applications/", "/var/containers/Bundle/Application/", "/private/var/containers/Bundle/Application/"};
    for (unsigned i = 0; i < 3; i++)
        if (strncmp(path, roots[i], strlen(roots[i])) == 0 && strstr(path, ".app/")) return VP_SIM_APP_ACCESS;
    return 0;
}

static int vpSimulationDirectory(const char *path, uid_t uid, gid_t gid) {
    int created = mkdir(path, 0755) == 0;
    if (!created && errno != EEXIST) return -1;
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    if (created && fchown(fd, uid, gid) < 0) { close(fd); return -1; }
    struct stat st;
    if (fstat(fd, &st) < 0 || !S_ISDIR(st.st_mode) || st.st_uid != uid || (st.st_mode & 0022)) {
        close(fd); errno = EPERM; return -1;
    }
    return fd;
}

int vpSimulationPrepare(uid_t mobileUID, gid_t mobileGID) {
    int camera = vpSimulationDirectory(VPHONE_VCAM_V2_DIRECTORY, mobileUID, mobileGID);
    if (camera < 0) return -1;
    int location = vpSimulationDirectory(VPHONE_LOCATION_STATE_DIRECTORY, geteuid(), getegid());
    if (location < 0) { close(camera); return -1; }
    close(location);
    int created = 1;
    int fd = openat(camera, "vphone-vcam-observe.shm", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (fd < 0 && errno == EEXIST) {
        created = 0;
        fd = openat(camera, "vphone-vcam-observe.shm", O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    }
    close(camera);
    if (fd < 0) return -1;
    int result = -1;
    if (created && (fchown(fd, mobileUID, mobileGID) < 0 || fchmod(fd, 0644) < 0 ||
                    ftruncate(fd, VPHONE_VCAM_OBSERVE_SHM_SIZE) < 0)) goto done;
    struct stat st;
    if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == mobileUID && st.st_nlink == 1 &&
        !(st.st_mode & 0022) && st.st_size == VPHONE_VCAM_OBSERVE_SHM_SIZE) result = 0;
done:
    close(fd);
    return result;
}

static int vpSimulationKeyIndex(const char *value) {
    for (int i = 0; i < 3; i++) {
        size_t length = strlen(vpSimulationTokenKeys[i]);
        if (strncmp(value, vpSimulationTokenKeys[i], length) == 0 && value[length] == '=') return i;
    }
    return -1;
}

static const char *vpSimulationInherited(char *const environment[], unsigned index) {
    if (!environment) return NULL;
    size_t length = strlen(vpSimulationTokenKeys[index]);
    for (size_t i = 0; i < 4096 && environment[i]; i++)
        if (strncmp(environment[i], vpSimulationTokenKeys[index], length) == 0 && environment[i][length] == '=')
            return environment[i] + length + 1;
    return NULL;
}

VPSimulationEnvironment vpSimulationEnvironment(char *const environment[], char *const inherited[],
                                               unsigned access, VPSimulationIssue issue) {
    VPSimulationEnvironment result = {0};
    size_t count = 0;
    while (environment && count < 4096 && environment[count]) count++;
    if (count == 4096) return result;
    result.values = calloc(count + 4, sizeof(char *));
    if (!result.values) return result;
    size_t output = 0;
    for (size_t i = 0; i < count; i++)
        if (vpSimulationKeyIndex(environment[i]) < 0) result.values[output++] = environment[i];
    const char *paths[] = { VPHONE_VCAM_V2_DIRECTORY, VPHONE_LOCATION_STATE_DIRECTORY, VPHONE_VCAM_V2_OBSERVE_SHM_PATH };
    for (unsigned i = 0; i < 3; i++) {
        unsigned bit = 1u << i;
        if (!(access & bit)) continue;
        char *issued = issue ? issue(i == 2 ? "com.apple.app-sandbox.read-write" : "com.apple.app-sandbox.read", paths[i], 0) : NULL;
        const char *token = issue ? issued : vpSimulationInherited(inherited, i);
        size_t length = token ? strnlen(token, VP_SIM_TOKEN_MAX) : 0;
        if (length > 0 && length < VP_SIM_TOKEN_MAX) {
            size_t bytes = strlen(vpSimulationTokenKeys[i]) + length + 2;
            result.owned[i] = malloc(bytes);
            if (result.owned[i]) {
                snprintf(result.owned[i], bytes, "%s=%s", vpSimulationTokenKeys[i], token);
                result.values[output++] = result.owned[i];
                result.granted |= bit;
            }
        }
        free(issued);
    }
    return result;
}

void vpSimulationFreeEnvironment(VPSimulationEnvironment *environment) {
    for (unsigned i = 0; i < 3; i++) free(environment->owned[i]);
    free(environment->values);
    memset(environment, 0, sizeof(*environment));
}
