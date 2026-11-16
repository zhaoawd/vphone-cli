#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <mach-o/dyld.h>
int main(int argc, char **argv) {
    // The measured direct job did not retain its DYLD_* input. Set it in
    // this generated launcher, then exec the independently signed target.
    if (argc == 5 && strcmp(argv[1], "--inject") == 0) {
        if (setenv("DYLD_INSERT_LIBRARIES", argv[2], 1) != 0) return 5;
        char *child[] = {argv[3], argv[4], NULL};
        execv(argv[3], child);
        FILE *file = fopen(argv[4], "w");
        if (file) { fprintf(file, "{\"execError\":%d}\n", errno); fclose(file); }
        return 6;
    }
    if (argc != 2) return 2;
    int (*ready)(void) = dlsym(RTLD_DEFAULT, "remap_injection_ready");
    int (*answer)(void) = dlsym(RTLD_DEFAULT, "remap_injection_answer");
    int r = ready ? ready() : -1, a = answer ? answer() : -1;
    FILE *file = fopen(argv[1], "w");
    if (!file) return 3;
    char executable[4096] = {0}; uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0) executable[0] = 0;
    fprintf(file, "{\"pid\":%d,\"constructor\":%d,\"answer\":%d,\"injectionEnvironment\":%s,\"executablePath\":\"%s\"}\n",
            getpid(), r, a, getenv("DYLD_INSERT_LIBRARIES") ? "true" : "false", executable);
    fclose(file);
    return r == 1 && a == 73 ? 0 : 4;
}
