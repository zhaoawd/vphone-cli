#pragma once
#import <Foundation/Foundation.h>

/// Duo's currently applied panel, in fixed display points. A missing inner
/// display returns dual_display=false and leaves the ordinary icli path intact.
NSDictionary<NSString *, id> * _Nonnull vp_element_tap_display(void);
/// Immediate AX window bounds in application coordinates, after icli enables AX.
NSDictionary<NSString *, id> * _Nonnull vp_element_tap_application_frame(int pid);
/// Re-resolve the selected AX element and send its point through its context.
NSDictionary<NSString *, id> * _Nonnull vp_element_tap_in_context(int pid, NSDictionary<NSString *, id> * _Nonnull element);

/// Locate the SpringBoard / PineBoard process identifier via sysctl KERN_PROC.
int vp_springboard_pid(void);
/// Query AX elements via icli_ax_elements_json if present in the runtime.
char * _Nullable vp_ax_elements_json(int pid, int maxElements);
/// Query AX element at position via icli_ax_element_at_json if present in the runtime.
char * _Nullable vp_ax_element_at_json(int pid, double x, double y);
