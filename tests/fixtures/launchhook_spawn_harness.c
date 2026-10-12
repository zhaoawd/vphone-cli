#include <assert.h>
static const char *expected;
static int calls;
int vpTestPosixSpawn(pid_t *restrict pid, const char *restrict path,
                    const posix_spawn_file_actions_t *restrict actions,
                    const posix_spawnattr_t *restrict attr,
                    char *const argv[restrict], char *const env[restrict]) {
    (void)path; (void)actions; (void)attr; (void)argv;
    const char *hook = vpEnvValue(env, "DYLD_INSERT_LIBRARIES");
    if (expected) {
        if (!hook || strcmp(hook, expected)) {
            fprintf(stderr, "SystemHook missing from forwarded spawn environment\n");
            exit(1);
        }
    } else if (hook) {
        fprintf(stderr, "Unexpected SystemHook in forwarded spawn environment\n");
        exit(1);
    }
    calls++;
    if (pid) *pid = 123;
    return 0;
}
int vpTestPosixSpawnP(pid_t *restrict pid, const char *restrict path,
                     const posix_spawn_file_actions_t *restrict actions,
                     const posix_spawnattr_t *restrict attr,
                     char *const argv[restrict], char *const env[restrict]) {
    return vpTestPosixSpawn(pid, path, actions, attr, argv, env);
}
int main(int argc, char **argv) {
    if (argc < 3 || argc > 5) return 2;
    expected = strcmp(argv[2], "inject") == 0 ? VP_SYSTEM_HOOK : NULL;
    char *env[] = {"PATH=/usr/bin", argc == 5 ? argv[4] : NULL, NULL};
    char *childArgs[] = {argv[1], NULL};
    pid_t pid;
    if (argc >= 4 && strcmp(argv[3], "spawnp") == 0) {
        typedef int (*Spawn)(pid_t *, const char *, const posix_spawn_file_actions_t *,
                             const posix_spawnattr_t *, char *const [], char *const []);
        Spawn replacement = NULL;
        for (size_t i = 0; i < sizeof(vpInterpose) / sizeof(vpInterpose[0]); i++) {
            if (vpInterpose[i].replacee == (const void *)vpTestPosixSpawnP)
                replacement = (Spawn)vpInterpose[i].replacement;
        }
        if (!replacement) {
            fprintf(stderr, "launchdhook does not interpose posix_spawnp\n");
            return 1;
        }
        assert(replacement(&pid, argv[1], NULL, NULL, childArgs, env) == 0);
    } else {
        assert(vpSpawn(&pid, argv[1], NULL, NULL, childArgs, env) == 0);
    }
    assert(calls == 1);
    return 0;
}
