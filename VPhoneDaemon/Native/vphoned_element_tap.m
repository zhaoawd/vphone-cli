#import "vphoned_element_tap.h"
#import "vphoned_ax_hierarchy.h"
#include "../../VPhoneGuestComponents/FoldDisplay/FoldDisplayGeometry.h"
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <math.h>
#import <objc/message.h>
#import <string.h>

NSDictionary<NSString *, id> *vp_element_tap_display_for_class(Class cls) {
    @try {
        if (![cls respondsToSelector:NSSelectorFromString(@"displays")])
            return @{@"dual_display": @NO};
        // The daemon may have enumerated before the inner panel was added.
        // Match vp_display_modes rather than retaining that first inventory.
        SEL refresh = NSSelectorFromString(@"updateDisplays");
        if ([cls respondsToSelector:refresh]) ((void (*)(id, SEL))objc_msgSend)(cls, refresh);
        NSArray *displays = [cls valueForKey:@"displays"];
        id inner = nil;
        for (id display in displays) {
            // Same identity as FoldDisplaySupport and FoldDisplayAdapter.
            for (NSString *key in @[@"name", @"deviceName"]) {
                if ([display respondsToSelector:NSSelectorFromString(key)] &&
                    [[display valueForKey:key] isEqual:@"VPhone Duo Inner"]) {
                    if (inner && inner != display)
                        return @{@"dual_display": @YES, @"error": @"Ambiguous inner display"};
                    inner = display;
                }
            }
        }
        if (!inner) return @{@"dual_display": @NO};
        // Read the applied CADisplay state, as FoldDisplayPanel does. Hinge
        // intent can precede the actual display handover and is not evidence.
        id state = [[inner valueForKey:@"stateControl"] valueForKey:@"displayState"];
        if (![state isKindOfClass:NSNumber.class] || ([state intValue] != 0 && [state intValue] != 1))
            return @{@"dual_display": @YES, @"error": @"Inner display state unavailable"};
        BOOL innerActive = [state boolValue];
        id display = innerActive ? inner : [cls valueForKey:@"mainDisplay"];
        NSValue *value = [display valueForKey:@"bounds"];
        // The virtual display reports 1 to clients. SpringBoard and the
        // render adapter apply the shared inner-panel point scale instead.
        double scale = innerActive ? VPhoneDuoInnerPointScale : [[display valueForKey:@"pointScale"] doubleValue];
        if (![value isKindOfClass:NSValue.class] || strcmp(value.objCType, @encode(CGRect)) != 0)
            return @{@"dual_display": @YES, @"error": @"Active display bounds unavailable"};
        CGRect bounds = CGRectZero;
        [value getValue:&bounds size:sizeof(bounds)];
        if (!isfinite(scale) || scale <= 0 || !isfinite(bounds.size.width) || !isfinite(bounds.size.height) ||
            bounds.size.width <= 0 || bounds.size.height <= 0)
            return @{@"dual_display": @YES, @"error": @"Active display geometry unavailable"};
        return @{@"dual_display": @YES, @"name": innerActive ? @"inner" : @"cover",
                 @"width": @(bounds.size.width / scale), @"height": @(bounds.size.height / scale)};
    } @catch (NSException *exception) {
        return @{@"dual_display": @YES, @"error": exception.reason ?: exception.name};
    }
}

NSDictionary<NSString *, id> *vp_element_tap_display(void) {
    dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY | RTLD_LOCAL);
    return vp_element_tap_display_for_class(NSClassFromString(@"CADisplay"));
}

NSDictionary *vp_element_tap_frame_for_functions(VPAxFunctions f, int pid) {
    if (pid <= 1 || !f.createApp || !f.copy || !f.getValue || !f.valueTypeID)
        return @{@"error": @"AX application frame unavailable"};
    CFTypeRef root = f.createApp(pid);
    if (!root) return @{@"error": @"AX application unavailable"};
    if (f.setTimeout) f.setTimeout(root, 0.5f);
    CFTypeRef value = NULL;
    int error = f.copy(root, (CFStringRef)(uintptr_t)2003, &value);
    CFRelease(root);
    CGRect frame = CGRectZero;
    BOOL valid = !error && value && CFGetTypeID(value) == f.valueTypeID() && f.getValue(value, 3, &frame)
        && isfinite(frame.origin.x) && isfinite(frame.origin.y)
        && isfinite(frame.size.width) && isfinite(frame.size.height)
        && frame.size.width > 0 && frame.size.height > 0;
    if (value) CFRelease(value);
    if (!valid) return @{@"error": @"AX application frame unavailable", @"ax_error": @(error)};
    return @{@"x": @(frame.origin.x), @"y": @(frame.origin.y),
             @"width": @(frame.size.width), @"height": @(frame.size.height)};
}

NSDictionary *vp_element_tap_application_frame(int pid) {
    void *ax = dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_NOW);
    VPAxFunctions f = {0};
    if (ax) {
        f.createApp = dlsym(ax, "_AXUIElementCreateAppElementWithPid");
        f.copy = dlsym(ax, "AXUIElementCopyAttributeValue");
        f.setTimeout = dlsym(ax, "AXUIElementSetMessagingTimeout");
        f.valueTypeID = dlsym(ax, "AXValueGetTypeID");
        f.getValue = dlsym(ax, "AXValueGetValue");
    }
    return vp_element_tap_frame_for_functions(f, pid);
}
