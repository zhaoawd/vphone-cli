/*
 * vphoned_shell — Run shell commands inside the guest over vsock.
 *
 * Executes `cmd` via `/bin/sh -c` in its own process group, capturing
 * stdout and stderr with a bounded timeout. Used by the host "guest shell"
 * feature. The daemon runs as root, so commands run with root privileges.
 */

#pragma once
#import <Foundation/Foundation.h>

/// Handle a `shell` command. Recognized fields:
///   cmd        — command string passed to `/bin/sh -c` (required)
///   cwd        — working directory (optional; must exist, else a structured
///                error is returned rather than exit code 127)
///   timeout_ms — kill the command after this many ms (optional, default 30000)
/// Returns a response dict with `out`, `err`, `code`, and `timed_out`.
/// Every command and its outcome is NSLog'd for auditing (daemon runs as root).
NSDictionary *vp_handle_shell_command(NSDictionary *msg);

/// Path of the shell binary to use, or NULL when no shell is present.
/// Prefers /bin/sh, falling back to the rootless-jailbreak path — sealed
/// system volumes never have /bin/sh, only /var/jb/bin/sh.
const char *vp_shell_path(void);
