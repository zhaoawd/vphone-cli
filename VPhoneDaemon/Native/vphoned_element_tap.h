#pragma once
#import <Foundation/Foundation.h>

/// Duo's currently applied panel, in fixed display points. A missing inner
/// display returns dual_display=false and leaves the ordinary icli path intact.
NSDictionary<NSString *, id> * _Nonnull vp_element_tap_display(void);
/// Read after icli's AX query has enabled accessibility; no switch mutation.
NSDictionary<NSString *, id> * _Nonnull vp_element_tap_application_frame(int pid);
