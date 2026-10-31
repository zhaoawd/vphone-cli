#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define VP_SHELL_OUTPUT_LIMIT (64 * 1024)
typedef struct {
    uint8_t *out_bytes;
    size_t out_length;
    uint8_t *err_bytes;
    size_t err_length;
    int exit_code;
    bool timed_out;
    bool cancelled;
    bool stdout_truncated;
    bool stderr_truncated;
} vp_shell_result;

int vp_shell_execute(const char *shell, const char *command, const char *cwd,
                     int timeout_ms, bool (*cancelled)(void *), void *context,
                     vp_shell_result *result);
void vp_shell_result_free(vp_shell_result *result);
