#import "vphoned_element_tap.h"
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
