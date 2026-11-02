#import "vphoned_element_tap.h"
#import "vphoned_ax_hierarchy.h"
#include "../../VPhoneGuestComponents/FoldDisplay/FoldDisplayGeometry.h"
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>
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
    if (pid <= 1 || !f.createApp || !f.copy || !f.getValue || !f.valueTypeID || !f.elementTypeID)
        return @{@"error": @"AX application frame unavailable"};
    CFTypeRef root = f.createApp(pid);
    if (!root) return @{@"error": @"AX application unavailable"};
    if (f.setTimeout) f.setTimeout(root, 0.5f);
    CFTypeRef value = NULL;
    // UIApplication's frame can stay in fixed orientation while its windows
    // and element points rotate. Immediate AX windows define the actual canvas.
    int error = f.copy(root, (CFStringRef)(uintptr_t)5001, &value);
    CFRelease(root);
    id windows = CFBridgingRelease(value);
    if (error || ![windows isKindOfClass:NSArray.class] || ![windows count] || [windows count] > 64)
        return @{@"error": @"AX window query unavailable", @"ax_error": @(error)};
    CGRect frame = CGRectNull;
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 2;
    for (id window in windows) {
        if (NSProcessInfo.processInfo.systemUptime > deadline)
            return @{@"error": @"AX window query timed out"};
        CFTypeRef ref = (__bridge CFTypeRef)window;
        if (CFGetTypeID(ref) != f.elementTypeID()) continue;
        if (f.setTimeout) f.setTimeout(ref, 0.25f);
        value = NULL;
        error = f.copy(ref, (CFStringRef)(uintptr_t)2003, &value);
        CGRect bounds = CGRectZero;
        BOOL valid = !error && value && CFGetTypeID(value) == f.valueTypeID() && f.getValue(value, 3, &bounds)
            && isfinite(bounds.origin.x) && isfinite(bounds.origin.y)
            && isfinite(bounds.size.width) && isfinite(bounds.size.height)
            && bounds.size.width > 0 && bounds.size.height > 0;
        if (value) CFRelease(value);
        if (valid) frame = CGRectUnion(frame, bounds);
    }
    if (CGRectIsNull(frame) || !isfinite(frame.size.width) || !isfinite(frame.size.height))
        return @{@"error": @"AX window frame unavailable"};
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
        f.elementTypeID = dlsym(ax, "AXUIElementGetTypeID");
    }
    return vp_element_tap_frame_for_functions(f, pid);
}

struct __AXUIElement;
@protocol VPElementTapFactory
+ (instancetype)elementWithAXUIElement:(struct __AXUIElement *)element;
@end

static id vpTapAttribute(VPAxFunctions f, CFTypeRef element, uint32_t attribute) {
    CFTypeRef value = NULL;
    int error = f.copy(element, (CFStringRef)(uintptr_t)attribute, &value);
    if (error) { if (value) CFRelease(value); return nil; }
    return CFBridgingRelease(value);
}

NSDictionary *vp_element_tap_context_for_functions(VPAxFunctions f, Class cls, int pid, NSDictionary *selected) {
    @try {
        SEL factory = @selector(elementWithAXUIElement:);
        SEL tap = NSSelectorFromString(@"simulateTapWithFingerIndex:withPoint:");
        Method make = class_getClassMethod(cls, factory), send = class_getInstanceMethod(cls, tap);
        if (!make || !send || strcmp(method_getTypeEncoding(make), "@24@0:8^{__AXUIElement=}16") != 0 ||
            strcmp(method_getTypeEncoding(send), "B40@0:8Q16{CGPoint=dd}24") != 0)
            return @{@"error": @"AX context tap ABI unavailable"};
        NSDictionary *frame = selected[@"frame"];
        NSArray *numbers = @[frame[@"x"] ?: NSNull.null, frame[@"y"] ?: NSNull.null,
            frame[@"width"] ?: NSNull.null, frame[@"height"] ?: NSNull.null,
            selected[@"x"] ?: NSNull.null, selected[@"y"] ?: NSNull.null];
        for (id value in numbers)
            if (![value isKindOfClass:NSNumber.class] || !isfinite([value doubleValue]))
                return @{@"error": @"Selected AX geometry unavailable"};
        CGRect expected = CGRectMake([numbers[0] doubleValue], [numbers[1] doubleValue],
                                     [numbers[2] doubleValue], [numbers[3] doubleValue]);
        if (expected.size.width <= 0 || expected.size.height <= 0 || pid <= 1 ||
            !f.createApp || !f.copy || !f.getValue || !f.valueTypeID || !f.elementTypeID)
            return @{@"error": @"Selected AX element unavailable"};
        CFTypeRef root = f.createApp(pid);
        if (!root) return @{@"error": @"AX application unavailable"};
        if (f.setTimeout) f.setTimeout(root, 0.5f);
        CFTypeRef value = NULL;
        int error = f.copy(root, (CFStringRef)(uintptr_t)3015, &value);
        CFRelease(root);
        id collection = CFBridgingRelease(value);
        if (error || ![collection isKindOfClass:NSArray.class])
            return @{@"error": @"AX context element query failed"};
        id match = nil;
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 2;
        for (id element in collection) {
            if (NSProcessInfo.processInfo.systemUptime > deadline)
                return @{@"error": @"AX context element query timed out"};
            CFTypeRef ref = (__bridge CFTypeRef)element;
            if (CFGetTypeID(ref) != f.elementTypeID()) continue;
            if (f.setTimeout) f.setTimeout(ref, 0.25f);
            id box = vpTapAttribute(f, ref, 2003);
            CGRect actual = CGRectZero;
            if (!box || CFGetTypeID((__bridge CFTypeRef)box) != f.valueTypeID() ||
                !f.getValue((__bridge CFTypeRef)box, 3, &actual)) continue;
            if (!isfinite(actual.origin.x) || !isfinite(actual.origin.y) || !isfinite(actual.size.width) ||
                !isfinite(actual.size.height) || actual.size.width <= 0 || actual.size.height <= 0) continue;
            if (fabs(actual.origin.x - expected.origin.x) > 1e-6 || fabs(actual.origin.y - expected.origin.y) > 1e-6 ||
                fabs(actual.size.width - expected.size.width) > 1e-6 || fabs(actual.size.height - expected.size.height) > 1e-6)
                continue;
            id identifier = vpTapAttribute(f, ref, 5019), label = vpTapAttribute(f, ref, 2001);
            if (![identifier isKindOfClass:NSString.class]) identifier = @"";
            if (![label isKindOfClass:NSString.class]) label = @"";
            if (![identifier isEqual:selected[@"identifier"] ?: @""] || ![label isEqual:selected[@"label"] ?: @""]) continue;
            if (match && !CFEqual((__bridge CFTypeRef)match, ref))
                return @{@"error": @"Selected AX context element is ambiguous"};
            match = element;
        }
        if (!match) return @{@"error": @"Selected AX context element changed; retry"};
        id wrapped = [(Class<VPElementTapFactory>)cls elementWithAXUIElement:(struct __AXUIElement *)(__bridge void *)match];
        if (!wrapped) return @{@"error": @"AX context element unavailable"};
        CGPoint point = CGPointMake([numbers[4] doubleValue], [numbers[5] doubleValue]);
        BOOL sent = ((BOOL (*)(id, SEL, NSUInteger, CGPoint))objc_msgSend)(wrapped, tap, 0, point);
        return sent ? @{@"tapped": @YES} : @{@"error": @"AX context tap failed"};
    } @catch (NSException *exception) {
        return @{@"error": exception.reason ?: exception.name};
    }
}

NSDictionary *vp_element_tap_in_context(int pid, NSDictionary *element) {
    dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_NOW);
    void *ax = dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_NOW);
    VPAxFunctions f = {0};
    if (ax) {
        f.createApp = dlsym(ax, "_AXUIElementCreateAppElementWithPid");
        f.copy = dlsym(ax, "AXUIElementCopyAttributeValue");
        f.setTimeout = dlsym(ax, "AXUIElementSetMessagingTimeout");
        f.elementTypeID = dlsym(ax, "AXUIElementGetTypeID");
        f.valueTypeID = dlsym(ax, "AXValueGetTypeID");
        f.getValue = dlsym(ax, "AXValueGetValue");
    }
    return vp_element_tap_context_for_functions(f, NSClassFromString(@"AXElement"), pid, element);
}

#include <sys/sysctl.h>
#if __has_include(<libproc.h>)
#include <libproc.h>
#else
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
#endif

int vp_springboard_pid(void) {
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL};
    size_t length = 0;
    if (sysctl(mib, 3, NULL, &length, NULL, 0) != 0 || length == 0) return 0;
    length += 64 * sizeof(struct kinfo_proc);
    struct kinfo_proc *processes = calloc(1, length);
    if (!processes) return 0;
    if (sysctl(mib, 3, processes, &length, NULL, 0) != 0) {
        free(processes);
        return 0;
    }
    int found = 0;
    size_t count = length / sizeof(struct kinfo_proc);
    for (size_t i = 0; i < count; i++) {
        pid_t pid = processes[i].kp_proc.p_pid;
        if (pid <= 1) continue;
        const char *comm = processes[i].kp_proc.p_comm;
        if (strncmp(comm, "SpringBoard", sizeof(processes[i].kp_proc.p_comm)) == 0 ||
            strncmp(comm, "PineBoard", sizeof(processes[i].kp_proc.p_comm)) == 0) {
            char path[4096] = {0};
            proc_pidpath(pid, path, sizeof(path));
            if (strstr(path, "/SpringBoard") != NULL || strstr(path, "/PineBoard") != NULL) {
                found = (int)pid;
                break;
            }
        }
    }
    free(processes);
    return found;
}

char *vp_ax_elements_json(int pid, int maxElements) {
    static char *(*fn)(int, int);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (char *(*)(int, int))dlsym(RTLD_DEFAULT, "icli_ax_elements_json");
    });
    if (!fn) return NULL;
    return fn(pid, maxElements);
}

char *vp_ax_element_at_json(int pid, double x, double y) {
    static char *(*fn)(int, double, double);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (char *(*)(int, double, double))dlsym(RTLD_DEFAULT, "icli_ax_element_at_json");
    });
    if (!fn) return NULL;
    return fn(pid, x, y);
}
