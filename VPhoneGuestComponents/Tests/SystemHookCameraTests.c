// Exercises the production constructor. No guest libraries are loaded on the host.
#include "../Shared/InjectionEnvironment.h"
#include "../Shared/AttitudeProcess.h"
#include "../Shared/JetsamLimits.h"
#include "../Shared/RootHideLoaderLinks.h"
#include "../Shared/VPhoneX1Spawn.h"
#include <assert.h>
#include <crt_externs.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *test_path;
static char *test_enabled_env[] = {NULL};
static char *test_disabled_env[] = {"DISABLE_TWEAKS=1", NULL};
static char **test_environment = test_enabled_env;
static const char *test_loaded[32];
static size_t test_load_count;
static int test_avfoundation_loaded;
static int test_executable(char *path, uint32_t *size) {
    size_t length = strlen(test_path) + 1;
    if (*size < length) { *size = (uint32_t)length; return -1; }
    memcpy(path, test_path, length); return 0;
}
static char ***test_environ(void) { return &test_environment; }
static int test_open(const char *path, int flags, ...) { (void)path; (void)flags; errno = EACCES; return -1; }
static int test_access(const char *path, int mode) { (void)mode; return strstr(path, ".dylib") ? 0 : -1; }
static void *test_dlopen(const char *path, int flags) {
    if (flags & RTLD_NOLOAD) return test_avfoundation_loaded ? (void *)1 : NULL;
    assert(test_load_count < 32); test_loaded[test_load_count++] = path; return (void *)1;
}
void vpInstallSurfaceAdapter(void) {}
int vpEnsureRootHideLoaderLink(const char *path, const char *root) { (void)path; (void)root; return 0; }

#define _NSGetExecutablePath test_executable
#define _NSGetEnviron test_environ
#define open test_open
#define access test_access
#define dlopen test_dlopen
// Disable automatic constructor execution and dyld interposition in this test process.
#define __attribute__(attributes)
#include VPHONE_SYSTEMHOOK_SOURCE
#undef __attribute__

static size_t loaded(const char *path) {
    size_t count = 0;
    for (size_t i = 0; i < test_load_count; i++) count += strcmp(test_loaded[i], path) == 0;
    return count;
}
static void run(const char *path, int avfoundation, int disabled) {
    test_path = path; test_avfoundation_loaded = avfoundation; test_load_count = 0;
    test_environment = disabled ? test_disabled_env : test_enabled_env;
    vpLogProcess();
}
int main(void) {
    const char *gpu = "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.GPU.xpc/com.apple.WebKit.GPU";
    run(gpu, 0, 0); assert(loaded(VP_CAMERA_APP_HOOK) == 1 && test_load_count == 1);
    run(gpu, 1, 0); assert(loaded(VP_CAMERA_APP_HOOK) == 1 && test_load_count == 1);
    run(gpu, 0, 1); assert(test_load_count == 0);
    run("/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.WebContent.xpc/com.apple.WebKit.WebContent", 0, 0); assert(test_load_count == 0);
    run("/tmp/com.apple.WebKit.GPU.helper", 0, 0); assert(test_load_count == 0);
    run("/Applications/Camera.app/Camera", 1, 0); assert(loaded(VP_CAMERA_APP_HOOK) == 1);
    run("/Applications/Camera.app/Camera", 0, 0); assert(loaded(VP_CAMERA_APP_HOOK) == 0);
    run("/usr/libexec/cameracaptured", 0, 0); assert(loaded(VP_CAMERA_DAEMON_HOOK) == 1 && loaded(VP_CAMERA_APP_HOOK) == 0);
    run("/usr/libexec/backboardd", 0, 0); assert(loaded(VP_GYROSCOPE_HOOK) == 1 && loaded(VP_FOLD_DISPLAY) == 1 && loaded(VP_CAMERA_APP_HOOK) == 0);
    run("/System/Library/CoreServices/SpringBoard.app/SpringBoard", 0, 0); assert(loaded(VP_FOLD_DISPLAY) == 1 && loaded(VP_CAMERA_APP_HOOK) == 0);
    puts("SystemHook camera constructor: GPU late framework load, safe mode, other services, apps and Duo targets passed");
}
