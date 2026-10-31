#ifndef VPHONE_SIMULATION_ACCESS_H
#define VPHONE_SIMULATION_ACCESS_H

#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

enum {
    VP_SIM_CAMERA_READ = 1,
    VP_SIM_LOCATION_READ = 2,
    VP_SIM_OBSERVE_WRITE = 4,
    VP_SIM_APP_ACCESS = VP_SIM_CAMERA_READ | VP_SIM_LOCATION_READ,
    VP_SIM_CAMERA_ACCESS = VP_SIM_CAMERA_READ | VP_SIM_OBSERVE_WRITE,
    VP_SIM_TOKEN_MAX = 16384,
};

static const char *const vpSimulationTokenKeys[] = {
    "VPHONE_CAMERA_READ_TOKEN", "VPHONE_LOCATION_READ_TOKEN", "VPHONE_CAMERA_OBSERVE_WRITE_TOKEN",
};
typedef char *(*VPSimulationIssue)(const char *, const char *, uint32_t);
typedef int64_t (*VPSimulationConsume)(const char *);
typedef struct {
    char **values;
    char *owned[3];
    unsigned granted;
} VPSimulationEnvironment;

int vpSimulationPrepare(uid_t mobileUID, gid_t mobileGID);
unsigned vpSimulationProgramAccess(const char *path, const char *proxyLabel);
VPSimulationEnvironment vpSimulationEnvironment(char *const environment[], char *const inherited[],
                                               unsigned access, VPSimulationIssue issue);
void vpSimulationFreeEnvironment(VPSimulationEnvironment *environment);

static inline void vpSimulationFilterTokens(unsigned access) {
    for (unsigned i = 0; i < 3; i++)
        if (!(access & (1u << i))) unsetenv(vpSimulationTokenKeys[i]);
}

// Called only after the app-side API has checked its normal authorization.
// A successful extension lasts for this process; credentials leave envp as
// soon as consumed and are never printed or stored in a policy file.
static inline unsigned vpSimulationConsumeWith(unsigned access, VPSimulationConsume consume) {
    static unsigned consumed;
    for (unsigned i = 0; i < 3; i++) {
        unsigned bit = 1u << i;
        if (!(access & bit) || (consumed & bit)) continue;
        const char *token = getenv(vpSimulationTokenKeys[i]);
        if (token && token[0] && strnlen(token, VP_SIM_TOKEN_MAX) < VP_SIM_TOKEN_MAX && consume && consume(token) >= 0)
            consumed |= bit;
        unsetenv(vpSimulationTokenKeys[i]);
    }
    return consumed & access;
}

static inline unsigned vpSimulationConsumeTokens(unsigned access) {
    VPSimulationConsume consume = (VPSimulationConsume)dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    return vpSimulationConsumeWith(access, consume);
}

#endif
