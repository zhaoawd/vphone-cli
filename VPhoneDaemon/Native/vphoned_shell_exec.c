#include "Include/VphonedNative.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;
// The Darwin symbol is present in iOS; use the same native bridging convention
// as vphoned's other posix_spawn file actions.
extern int vp_shell_addchdir(posix_spawn_file_actions_t *, const char *)
    __asm__("_posix_spawn_file_actions_addchdir_np");
extern int vp_shell_setpgroup(posix_spawnattr_t *, pid_t) __asm__("_posix_spawnattr_setpgroup");
#define posix_spawn vp_spawn
#define posix_spawn_file_actions_init vp_spawn_file_actions_init
#define posix_spawn_file_actions_destroy vp_spawn_file_actions_destroy
#define posix_spawn_file_actions_addopen vp_spawn_file_actions_addopen
#define posix_spawn_file_actions_adddup2 vp_spawn_file_actions_adddup2
#define posix_spawn_file_actions_addclose vp_spawn_file_actions_addclose
#define posix_spawnattr_init vp_spawnattr_init
#define posix_spawnattr_destroy vp_spawnattr_destroy
#define posix_spawnattr_setflags vp_spawnattr_setflags
#define posix_spawnattr_setpgroup vp_shell_setpgroup

static double monotonic_seconds(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return value.tv_sec + value.tv_nsec / 1e9;
}

static int make_pipe(int pipefd[2]) {
    if (pipe(pipefd) != 0) return errno;
    for (int i = 0; i < 2; i++) {
        if (pipefd[i] < 3) {
            int replacement = fcntl(pipefd[i], F_DUPFD_CLOEXEC, 3);
            if (replacement < 0) {
                int error = errno; close(pipefd[0]); close(pipefd[1]); return error;
            }
            close(pipefd[i]); pipefd[i] = replacement;
        }
    }
    if (fcntl(pipefd[0], F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(pipefd[1], F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(pipefd[0], F_SETFL, O_NONBLOCK) < 0) {
        int error = errno;
        close(pipefd[0]); close(pipefd[1]);
        return error;
    }
    return 0;
}

// Bound each drain as well as stored output so a continuously writing child
// cannot prevent timeout or cancellation checks.
static void drain(int fd, uint8_t *output, size_t *length, bool *truncated, bool *eof) {
    uint8_t buffer[8192];
    for (int turn = 0; turn < 8 && !*eof; turn++) {
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count == 0) { *eof = true; break; }
        if (count < 0) {
            if (errno == EINTR) continue;
            if (errno != EAGAIN && errno != EWOULDBLOCK) { *eof = true; *truncated = true; }
            break;
        }
        size_t available = VP_SHELL_OUTPUT_LIMIT - *length;
        size_t keep = (size_t)count < available ? (size_t)count : available;
        memcpy(output + *length, buffer, keep);
        *length += keep;
        if (keep != (size_t)count) *truncated = true;
    }
}

void vp_shell_result_free(vp_shell_result *result) {
    free(result->out_bytes); free(result->err_bytes);
    result->out_bytes = NULL; result->err_bytes = NULL;
}

int vp_shell_execute(const char *shell, const char *command, const char *cwd,
                     int timeout_ms, bool (*cancelled)(void *), void *context,
                     vp_shell_result *result) {
    memset(result, 0, sizeof(*result));
    if (!shell || !command || timeout_ms < 1 || timeout_ms > 120000) return EINVAL;
    result->out_bytes = malloc(VP_SHELL_OUTPUT_LIMIT);
    result->err_bytes = malloc(VP_SHELL_OUTPUT_LIMIT);
    if (!result->out_bytes || !result->err_bytes) {
        vp_shell_result_free(result); return ENOMEM;
    }
    if (cancelled && cancelled(context)) {
        result->cancelled = true; result->exit_code = 137; return 0;
    }
    int output[2], errors[2];
    int error = make_pipe(output);
    if (error) { vp_shell_result_free(result); return error; }
    error = make_pipe(errors);
    if (error) { close(output[0]); close(output[1]); vp_shell_result_free(result); return error; }
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    error = posix_spawn_file_actions_init(&actions);
    if (error) goto close_pipes;
    error = posix_spawnattr_init(&attributes);
    if (error) { posix_spawn_file_actions_destroy(&actions); goto close_pipes; }
    #define ACTION(call) do { if (!error) error = (call); } while (0)
    ACTION(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0));
    ACTION(posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO));
    ACTION(posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO));
    ACTION(posix_spawn_file_actions_addclose(&actions, output[0]));
    ACTION(posix_spawn_file_actions_addclose(&actions, output[1]));
    ACTION(posix_spawn_file_actions_addclose(&actions, errors[0]));
    ACTION(posix_spawn_file_actions_addclose(&actions, errors[1]));
    if (cwd) ACTION(vp_shell_addchdir(&actions, cwd));
    ACTION(posix_spawnattr_setpgroup(&attributes, 0));
    ACTION(posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT));
    pid_t pid = -1;
    char *argv[] = {(char *)shell, "-c", (char *)command, NULL};
    if (!error) error = posix_spawn(&pid, shell, &actions, &attributes, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    #undef ACTION
    if (error) goto close_pipes;
    close(output[1]); close(errors[1]);

    double deadline = monotonic_seconds() + timeout_ms / 1000.0;
    bool out_eof = false, err_eof = false, exited = false;
    while (!(out_eof && err_eof && exited)) {
        result->cancelled = cancelled && cancelled(context);
        result->timed_out = !result->cancelled && monotonic_seconds() >= deadline;
        if (result->cancelled || result->timed_out) {
            // Keep the leader unreaped until this signal: its PID cannot be
            // reused while a delayed cancellation is targeting its group.
            kill(-pid, SIGKILL);
            break;
        }
        drain(output[0], result->out_bytes, &result->out_length, &result->stdout_truncated, &out_eof);
        drain(errors[0], result->err_bytes, &result->err_length, &result->stderr_truncated, &err_eof);
        siginfo_t observed = {0};
        if (waitid(P_PID, (id_t)pid, &observed, WEXITED | WNOHANG | WNOWAIT) == 0) {
            exited = observed.si_pid == pid;
        } else if (errno != EINTR) {
            error = errno;
            kill(-pid, SIGKILL);
            break;
        }
        if (!(out_eof && err_eof && exited)) {
            struct pollfd channels[] = {{out_eof ? -1 : output[0], POLLIN, 0},
                                        {err_eof ? -1 : errors[0], POLLIN, 0}};
            poll(channels, 2, 10);
        }
    }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) { if (!error) error = errno; break; }
    }
    // Drain queued bytes after the leader was reaped. This loop is finite
    // even if a command deliberately detached into a different process group.
    for (int turn = 0; turn < 50 && !(out_eof && err_eof); turn++) {
        drain(output[0], result->out_bytes, &result->out_length, &result->stdout_truncated, &out_eof);
        drain(errors[0], result->err_bytes, &result->err_length, &result->stderr_truncated, &err_eof);
        if (!(out_eof && err_eof)) usleep(10000);
    }
    result->stdout_truncated |= !out_eof;
    result->stderr_truncated |= !err_eof;
    result->exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    close(output[0]); close(errors[0]);
    if (error) vp_shell_result_free(result);
    return error;

close_pipes:
    close(output[0]); close(output[1]); close(errors[0]); close(errors[1]);
    vp_shell_result_free(result);
    return error;
}
