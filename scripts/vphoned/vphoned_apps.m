/*
 * vphoned_apps — App lifecycle management via private APIs.
 *
 * Uses LSApplicationWorkspace (CoreServices) and FBSSystemService
 * (FrontBoardServices).
 */

#import "vphoned_apps.h"
#import "vphoned_protocol.h"
#include <dlfcn.h>
#include <errno.h>
#include <objc/message.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

// MARK: - uiopen bridge
//
// In-process LSApplicationWorkspace launch (openApplicationWithBundleID: /
// openURL:withOptions:) returns NO from the vphoned daemon context: the daemon
// binary is not entitled for the SpringBoard open-application/open-sensitive-url
// service, so the FrontBoard request is rejected. The Procursus `uiopen` CLI is
// a separate, properly entitled platform binary, and launching/opening through
// it from the daemon works (verified on-device). So app launch and URL open
// shell out to uiopen rather than calling the workspace in-process.

static const char *vp_uiopen_path(void) {
  static const char *const candidates[] = {"/var/jb/usr/bin/uiopen",
                                            "/usr/bin/uiopen"};
  for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
    if (access(candidates[i], X_OK) == 0) return candidates[i];
  }
  return NULL;
}

/// Spawn `uiopen` with the given argv tail (NULL-terminated C strings, not
/// counting argv[0]) and wait for it. Returns the process exit code, or -1 if
/// uiopen is missing or could not be spawned.
static int vp_uiopen_run(const char *const argTail[], size_t argTailCount) {
  const char *path = vp_uiopen_path();
  if (!path) return -1;

  size_t argc = argTailCount + 2;  // argv[0] + tail + NULL
  char **argv = (char **)calloc(argc, sizeof(char *));
  if (!argv) return -1;
  argv[0] = (char *)path;
  for (size_t i = 0; i < argTailCount; i++) argv[i + 1] = (char *)argTail[i];
  argv[argc - 1] = NULL;

  pid_t pid = -1;
  int spawnErr = posix_spawn(&pid, path, NULL, NULL, argv, environ);
  free(argv);
  if (spawnErr != 0) return -1;

  int status = 0;
  while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
  }
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return -1;
}

int vp_open_via_uiopen(NSString *url, NSString *bundleID) {
  if (url.length > 0) {
    const char *tail[] = {"--url", url.UTF8String};
    return vp_uiopen_run(tail, 2);
  }
  if (bundleID.length > 0) {
    const char *tail[] = {"--bundleid", bundleID.UTF8String};
    return vp_uiopen_run(tail, 2);
  }
  return -1;
}

// MARK: - Private API Declarations

@interface LSApplicationProxy : NSObject
@property(readonly) NSString *bundleIdentifier;
@property(readonly) NSString *localizedName;
@property(readonly) NSString *shortVersionString;
@property(readonly) NSString *applicationType;
@property(readonly) NSURL *bundleURL;
@property(readonly) NSURL *dataContainerURL;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
@end

// FBSSystemService loaded via dlsym
static Class gFBSSystemServiceClass = Nil;

static BOOL gAppsLoaded = NO;

BOOL vp_apps_load(void) {
  // FrontBoardServices
  void *fbs = dlopen("/System/Library/PrivateFrameworks/"
                     "FrontBoardServices.framework/FrontBoardServices",
                     RTLD_LAZY);
  if (fbs) {
    gFBSSystemServiceClass = NSClassFromString(@"FBSSystemService");
    if (!gFBSSystemServiceClass) {
      NSLog(@"vphoned: FBSSystemService class not found");
    }
  } else {
    NSLog(@"vphoned: dlopen FrontBoardServices failed: %s", dlerror());
  }

  // LSApplicationWorkspace is in CoreServices (already linked)
  Class lsClass = NSClassFromString(@"LSApplicationWorkspace");
  if (!lsClass) {
    NSLog(@"vphoned: LSApplicationWorkspace class not found");
    return NO;
  }

  gAppsLoaded = YES;
  NSLog(@"vphoned: apps loaded (FBS=%s)",
        gFBSSystemServiceClass ? "yes" : "no");
  return YES;
}

// MARK: - Helpers

static pid_t pid_for_app(NSString *bundleID) {
  if (!gFBSSystemServiceClass)
    return 0;
  id service = ((id (*)(Class, SEL))objc_msgSend)(
      gFBSSystemServiceClass, sel_registerName("sharedService"));
  if (!service)
    return 0;
  return ((pid_t (*)(id, SEL, id))objc_msgSend)(
      service, sel_registerName("pidForApplication:"), bundleID);
}

static NSString *state_for_pid(pid_t pid) {
  if (pid > 0)
    return @"running";
  return @"not_running";
}

// MARK: - Command Handler

NSDictionary *vp_handle_apps_command(NSDictionary *msg) {
  NSString *type = msg[@"t"];
  id reqId = msg[@"id"];

  if (!gAppsLoaded) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = @"apps not available";
    return r;
  }

  // -- app_list --
  if ([type isEqualToString:@"app_list"]) {
    LSApplicationWorkspace *ws = [LSApplicationWorkspace defaultWorkspace];
    NSArray *allApps = [ws allInstalledApplications];
    NSString *filter = msg[@"filter"] ?: @"all";

    NSMutableArray *result = [NSMutableArray array];
    for (LSApplicationProxy *proxy in allApps) {
      NSString *appType = proxy.applicationType;
      BOOL isSystem = [appType isEqualToString:@"System"];

      if ([filter isEqualToString:@"user"] && isSystem)
        continue;
      if ([filter isEqualToString:@"system"] && !isSystem)
        continue;

      pid_t pid = pid_for_app(proxy.bundleIdentifier);

      if ([filter isEqualToString:@"running"] && pid <= 0)
        continue;

      [result addObject:@{
        @"bundle_id" : proxy.bundleIdentifier ?: @"",
        @"name" : proxy.localizedName ?: @"",
        @"version" : proxy.shortVersionString ?: @"",
        @"type" : isSystem ? @"system" : @"user",
        @"state" : state_for_pid(pid),
        @"pid" : @(pid > 0 ? pid : 0),
        @"path" : proxy.bundleURL.path ?: @"",
        @"data_container" : proxy.dataContainerURL.path ?: @"",
      }];
    }

    NSMutableDictionary *r = vp_make_response(@"app_list", reqId);
    r[@"apps"] = result;
    return r;
  }

  // -- app_launch --
  if ([type isEqualToString:@"app_launch"]) {
    NSString *bundleID = msg[@"bundle_id"];
    if (!bundleID) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"missing bundle_id";
      return r;
    }

    NSString *url = msg[@"url"];

    // Launch via the entitled uiopen CLI; the in-process LSApplicationWorkspace
    // path is rejected from the daemon context (see uiopen bridge note above).
    int rc = vp_open_via_uiopen(url, bundleID);
    if (rc != 0) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = rc < 0
                      ? [NSString stringWithFormat:@"uiopen unavailable to launch %@", bundleID]
                      : [NSString stringWithFormat:@"uiopen exit %d launching %@", rc, bundleID];
      return r;
    }

    // uiopen exit 0 only means the open request was accepted, not that the app
    // materialized. Poll for the pid (up to ~3s, covering a cold start) and
    // fail-closed if it never appears — otherwise a bad bundle id or a launch
    // that never came up would be reported as success. When FBSSystemService is
    // unavailable we cannot read pids at all, so fall back to trusting uiopen's
    // exit code rather than reporting a false failure.
    pid_t pid = 0;
    if (gFBSSystemServiceClass) {
      for (int i = 0; i < 15; i++) {
        usleep(200000);  // 200ms × 15 = ~3s
        pid = pid_for_app(bundleID);
        if (pid > 0) break;
      }
      if (pid <= 0) {
        NSMutableDictionary *r = vp_make_response(@"err", reqId);
        r[@"msg"] = [NSString stringWithFormat:
                                  @"%@ did not start (uiopen ok but no pid)", bundleID];
        return r;
      }
    } else {
      usleep(500000);  // best-effort settle; cannot verify without FBS
    }

    NSMutableDictionary *r = vp_make_response(@"app_launch", reqId);
    r[@"ok"] = @YES;
    r[@"pid"] = @(pid > 0 ? pid : 0);
    return r;
  }

  // -- app_terminate --
  if ([type isEqualToString:@"app_terminate"]) {
    NSString *bundleID = msg[@"bundle_id"];
    if (!bundleID) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"missing bundle_id";
      return r;
    }

    // Both the terminate path and the verify-by-pid below depend on
    // FBSSystemService (pid_for_app uses it). Without it we can neither
    // terminate nor confirm the outcome, so fail closed instead of reporting a
    // phantom success — a blind ok=true here is exactly the trap the pid check
    // is meant to avoid.
    id service = nil;
    if (gFBSSystemServiceClass) {
      service = ((id (*)(Class, SEL))objc_msgSend)(
          gFBSSystemServiceClass, sel_registerName("sharedService"));
    }
    if (!service) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"cannot terminate: FBSSystemService unavailable (no way to "
                  @"terminate or verify)";
      return r;
    }

    pid_t before = pid_for_app(bundleID);

    // terminateApplication:forReason:andReport:withDescription:
    // reason 5 = user requested, report NO
    ((void (*)(id, SEL, id, int, BOOL, id))objc_msgSend)(
        service,
        sel_registerName(
            "terminateApplication:forReason:andReport:withDescription:"),
        bundleID, 5, NO, @"vphoned terminate request");

    // Verify the app is actually gone rather than reporting ok blindly. Give
    // the termination a brief window to take effect, then re-check the pid; if
    // it's still up, fall back to a SIGKILL on the original pid.
    pid_t after = 0;
    for (int i = 0; i < 10; i++) {
      usleep(100000);  // 100ms, up to ~1s total
      after = pid_for_app(bundleID);
      if (after <= 0) break;
    }
    if (after > 0 && before > 0) {
      kill(before, SIGKILL);
      usleep(200000);
      after = pid_for_app(bundleID);
    }

    NSMutableDictionary *r = vp_make_response(@"app_terminate", reqId);
    r[@"ok"] = @(after <= 0);
    if (after > 0) {
      r[@"msg"] = [NSString stringWithFormat:@"%@ still running (pid %d)",
                                             bundleID, after];
    }
    return r;
  }

  NSMutableDictionary *r = vp_make_response(@"err", reqId);
  r[@"msg"] = [NSString stringWithFormat:@"unknown apps command: %@", type];
  return r;
}
