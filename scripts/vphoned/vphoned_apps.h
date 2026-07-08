/*
 * vphoned_apps — App lifecycle management over vsock.
 *
 * Handles app_list, app_launch, app_terminate, app_foreground using
 * private APIs: LSApplicationWorkspace, FBSSystemService, SpringBoardServices.
 *
 * app_foreground: iOS 26.4+ broke SBS frontmost APIs (both
 * SBSCopyFrontmostApplicationDisplayIdentifier and
 * SBSCopyApplicationDisplayIdentifiers return NULL). TODO: implement via
 * RunningBoardServices RBSProcessMonitor to restore precise foreground
 * detection. Current stub returns empty (degraded mode in autophone).
 */

#pragma once
#import <Foundation/Foundation.h>

/// Load private framework symbols for app management. Returns NO on failure.
BOOL vp_apps_load(void);

/// Handle an app command. Returns a response dict.
NSDictionary *vp_handle_apps_command(NSDictionary *msg);

/// Launch an app / open a URL through the entitled `uiopen` CLI. Pass a non-nil
/// `url` to open a URL, otherwise `bundleID` to launch by bundle identifier.
/// Returns uiopen's exit code (0 = success), or -1 if uiopen is unavailable.
/// The in-process LSApplicationWorkspace open path is rejected from the daemon
/// context, so URL/app open is delegated to uiopen.
int vp_open_via_uiopen(NSString *url, NSString *bundleID);
