/*
 * vphoned_shell — Run shell commands inside the guest.
 *
 * Spawns `/bin/sh -c <cmd>` in its own process group via posix_spawn, with
 * stdout/stderr redirected to pipes. The parent drains both pipes through
 * poll(2) until EOF or the deadline, then reaps the child. On timeout the
 * whole process group is killed so child subprocesses don't outlive us.
 *
 * Output is capped per stream; the frame limit on both ends is 4 MiB, so an
 * unbounded `cat /dev/zero` must not be able to wedge the link.
 */

#import "vphoned_shell.h"
#import "vphoned_protocol.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

const char *vp_shell_path(void) {
  static const char *const candidates[] = {"/bin/sh", "/var/jb/bin/sh"};
  for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
    if (access(candidates[i], X_OK) == 0) return candidates[i];
  }
  return NULL;
}

#define VP_SHELL_MAX_OUTPUT (1 * 1024 * 1024)  // per stream
#define VP_SHELL_DEFAULT_TIMEOUT_MS 30000
#define VP_SHELL_MAX_TIMEOUT_MS 120000

/// Append up to VP_SHELL_MAX_OUTPUT bytes from `src` to `dst`, flagging if the
/// cap was hit so the caller can report truncation.
static void vp_shell_append_capped(NSMutableData *dst, const void *src, size_t len,
                                   BOOL *truncated) {
  if (dst.length >= VP_SHELL_MAX_OUTPUT) {
    *truncated = YES;
    return;
  }
  size_t room = VP_SHELL_MAX_OUTPUT - dst.length;
  if (len > room) {
    len = room;
    *truncated = YES;
  }
  [dst appendBytes:src length:len];
}

/// Single-quote a path for safe interpolation into a /bin/sh command line.
static NSString *vp_shell_squote(NSString *s) {
  NSString *escaped = [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
  return [NSString stringWithFormat:@"'%@'", escaped];
}

static NSString *vp_shell_string(NSMutableData *data) {
  NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (s) return s;
  // Fall back to a lossy decode so non-UTF-8 output still surfaces.
  return [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] ?: @"";
}

/// Shrink `out`/`err` in the response until the *encoded* JSON frame fits well
/// under the protocol limit. The raw byte caps aren't enough: JSON escaping of
/// control/NUL bytes inflates up to 6x (`\u00XX`), so 1 MiB of NULs would blow
/// past the host's 4 MiB frame ceiling and tear down the link. Halving the
/// larger string converges in a handful of iterations regardless of content.
static void vp_shell_fit_frame(NSMutableDictionary *r) {
  const NSUInteger budget = 3 * 1024 * 1024;  // headroom below the 4 MiB ceiling
  for (int iter = 0; iter < 32; iter++) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:r options:0 error:nil];
    if (json && json.length <= budget) return;

    NSString *out = r[@"out"] ?: @"";
    NSString *err = r[@"err"] ?: @"";
    if (out.length == 0 && err.length == 0) return;  // cannot shrink further
    r[@"truncated"] = @YES;
    if (out.length >= err.length) {
      r[@"out"] = [out substringToIndex:out.length / 2];
    } else {
      r[@"err"] = [err substringToIndex:err.length / 2];
    }
  }
}

NSDictionary *vp_handle_shell_command(NSDictionary *msg) {
  id reqId = msg[@"id"];
  NSString *cmd = msg[@"cmd"];

  if (![cmd isKindOfClass:[NSString class]] || cmd.length == 0) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = @"missing cmd";
    return r;
  }

  const char *shellPath = vp_shell_path();
  if (!shellPath) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = @"no shell binary on guest";
    return r;
  }

  NSString *cwd = [msg[@"cwd"] isKindOfClass:[NSString class]] ? msg[@"cwd"] : nil;

  NSInteger timeoutMs = VP_SHELL_DEFAULT_TIMEOUT_MS;
  if ([msg[@"timeout_ms"] isKindOfClass:[NSNumber class]]) {
    timeoutMs = [msg[@"timeout_ms"] integerValue];
  }
  if (timeoutMs <= 0) timeoutMs = VP_SHELL_DEFAULT_TIMEOUT_MS;
  if (timeoutMs > VP_SHELL_MAX_TIMEOUT_MS) timeoutMs = VP_SHELL_MAX_TIMEOUT_MS;

  int outPipe[2] = {-1, -1};
  int errPipe[2] = {-1, -1};
  if (pipe(outPipe) != 0 || pipe(errPipe) != 0) {
    if (outPipe[0] >= 0) { close(outPipe[0]); close(outPipe[1]); }
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = [NSString stringWithFormat:@"pipe failed: %s", strerror(errno)];
    return r;
  }

  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  // Child only needs the write ends; close the read ends it inherits.
  posix_spawn_file_actions_addclose(&actions, outPipe[0]);
  posix_spawn_file_actions_addclose(&actions, errPipe[0]);
  posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO);
  posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO);
  posix_spawn_file_actions_addclose(&actions, outPipe[1]);
  posix_spawn_file_actions_addclose(&actions, errPipe[1]);

  // posix_spawn cannot chdir on iOS, so fold `cwd` into the shell line.
  NSString *shellCmd = cmd;
  if (cwd.length > 0) {
    shellCmd = [NSString
        stringWithFormat:@"cd %@ || exit 127\n%@", vp_shell_squote(cwd), cmd];
  }

  // Run the command in its own process group so a timeout can signal the
  // whole tree, not just the top-level sh.
  posix_spawnattr_t attr;
  posix_spawnattr_init(&attr);
  posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
  posix_spawnattr_setpgroup(&attr, 0);

  char *argv[] = {(char *)shellPath, "-c", (char *)shellCmd.UTF8String, NULL};
  pid_t pid = -1;
  int spawnErr =
      posix_spawn(&pid, shellPath, &actions, &attr, argv, environ);

  posix_spawn_file_actions_destroy(&actions);
  posix_spawnattr_destroy(&attr);
  // Parent closes the write ends so reads see EOF when the child exits.
  close(outPipe[1]);
  close(errPipe[1]);

  if (spawnErr != 0) {
    close(outPipe[0]);
    close(errPipe[0]);
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = [NSString stringWithFormat:@"spawn %s failed: %s", shellPath,
                                           strerror(spawnErr)];
    return r;
  }

  NSMutableData *outData = [NSMutableData data];
  NSMutableData *errData = [NSMutableData data];
  BOOL outTruncated = NO, errTruncated = NO;

  fcntl(outPipe[0], F_SETFL, O_NONBLOCK);
  fcntl(errPipe[0], F_SETFL, O_NONBLOCK);

  struct pollfd fds[2] = {
      {.fd = outPipe[0], .events = POLLIN},
      {.fd = errPipe[0], .events = POLLIN},
  };
  int openCount = 2;
  BOOL timedOut = NO;

  uint64_t deadlineMs =
      (uint64_t)([NSDate date].timeIntervalSince1970 * 1000.0) + (uint64_t)timeoutMs;
  uint8_t buf[32768];

  while (openCount > 0) {
    int64_t remaining =
        (int64_t)deadlineMs - (int64_t)([NSDate date].timeIntervalSince1970 * 1000.0);
    if (remaining <= 0) {
      timedOut = YES;
      break;
    }

    int pollTimeout = remaining > 1000 ? 1000 : (int)remaining;
    int ready = poll(fds, 2, pollTimeout);
    if (ready < 0) {
      if (errno == EINTR) continue;
      break;
    }
    if (ready == 0) continue;  // re-check deadline

    for (int i = 0; i < 2; i++) {
      if (fds[i].fd < 0) continue;
      if ((fds[i].revents & (POLLIN | POLLHUP | POLLERR)) == 0) continue;

      ssize_t n = read(fds[i].fd, buf, sizeof(buf));
      if (n > 0) {
        if (i == 0) {
          vp_shell_append_capped(outData, buf, (size_t)n, &outTruncated);
        } else {
          vp_shell_append_capped(errData, buf, (size_t)n, &errTruncated);
        }
      } else if (n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR)) {
        close(fds[i].fd);
        fds[i].fd = -1;
        openCount--;
      }
    }
  }

  if (timedOut) {
    // Signal the whole process group, then reap.
    kill(-pid, SIGKILL);
  }

  for (int i = 0; i < 2; i++) {
    if (fds[i].fd >= 0) {
      close(fds[i].fd);
      fds[i].fd = -1;
    }
  }

  int status = 0;
  while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
  }

  int exitCode;
  if (WIFEXITED(status)) {
    exitCode = WEXITSTATUS(status);
  } else if (WIFSIGNALED(status)) {
    exitCode = 128 + WTERMSIG(status);
  } else {
    exitCode = -1;
  }

  NSMutableDictionary *r = vp_make_response(@"shell", reqId);
  r[@"out"] = vp_shell_string(outData);
  r[@"err"] = vp_shell_string(errData);
  r[@"code"] = @(exitCode);
  r[@"timed_out"] = @(timedOut);
  if (outTruncated || errTruncated) {
    r[@"truncated"] = @YES;
  }
  vp_shell_fit_frame(r);
  return r;
}
