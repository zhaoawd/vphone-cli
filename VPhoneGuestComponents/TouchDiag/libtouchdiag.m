// libtouchdiag.m — read-only touch routing diagnostic for SpringBoard.
//
// On an iPhone Duo guest booted at the inner panel's render size, touches
// reach backboardd but no app's UIApplication. This library answers one
// question: does SpringBoard's own UIApplication receive them, and which of its
// windows and views would they hit?
//
// SystemHook loads it into SpringBoard. It does nothing unless
// /private/var/tmp/vphone-touchdiag exists when SpringBoard starts; then it
// wraps -[UIApplication sendEvent:] to record each touch event (phase,
// location, window, window level, view) and calls the original unchanged. It
// never alters an event, a return value or any state. Each event is a line in
// /var/mobile/Library/Caches/vphone-touchdiag.log, capped at 5000 lines.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <objc/runtime.h>
#include <sys/stat.h>
#include <unistd.h>

#define VP_TOUCHDIAG_FLAG "/private/var/tmp/vphone-touchdiag"
#define VP_TOUCHDIAG_LOG "/var/mobile/Library/Caches/vphone-touchdiag.log"
#define VP_TOUCHDIAG_MAX_LINES 5000

static IMP vpOriginalSendEvent;
static unsigned vpLines;
static unsigned long vpOtherEvents;

static void vpWriteLine(NSString *line) {
    if (vpLines >= VP_TOUCHDIAG_MAX_LINES)
        return;
    int fd = open(VP_TOUCHDIAG_LOG, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0666);
    if (fd < 0)
        return;
    fchmod(fd, 0666);
    dprintf(fd, "%s\n", line.UTF8String);
    close(fd);
    vpLines++;
}

static NSString *vpClassName(id object) {
    return object ? NSStringFromClass([object class]) : @"nil";
}

static void vpRecordTouches(UIEvent *event) {
    NSMutableArray *parts = [NSMutableArray array];
    for (UITouch *touch in event.allTouches) {
        UIWindow *window = touch.window;
        CGPoint inWindow = window ? [touch locationInView:window] : [touch locationInView:nil];
        [parts addObject:[NSString stringWithFormat:@"{phase=%ld x=%.1f y=%.1f window=%@ level=%.0f windowFrame=%@ view=%@}",
                          (long)touch.phase, inWindow.x, inWindow.y, vpClassName(window),
                          window ? window.windowLevel : -1.0,
                          window ? NSStringFromCGRect(window.frame) : @"-", vpClassName(touch.view)]];
    }
    vpWriteLine([NSString stringWithFormat:@"t=%.4f touches=%lu other_events_since_start=%lu %@",
                 event.timestamp, (unsigned long)event.allTouches.count, vpOtherEvents,
                 [parts componentsJoinedByString:@" "]]);
}

static void vpSendEvent(id application, SEL selector, UIEvent *event) {
    @autoreleasepool {
        if (event.type == UIEventTypeTouches)
            vpRecordTouches(event);
        else
            vpOtherEvents++;
    }
    ((void (*)(id, SEL, UIEvent *))vpOriginalSendEvent)(application, selector, event);
}

__attribute__((constructor)) static void vpInstallTouchDiag(void) {
    @autoreleasepool {
        if (access(VP_TOUCHDIAG_FLAG, F_OK) != 0) {
            vpWriteLine([NSString stringWithFormat:@"pid=%d loaded, %s absent: inactive", getpid(), VP_TOUCHDIAG_FLAG]);
            return;
        }
        dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_LAZY | RTLD_LOCAL);
        // SpringBoard's application class, or UIApplication if it is not
        // registered yet; class_getInstanceMethod resolves to whichever class
        // defines sendEvent:, so a subclass override is the one wrapped.
        Class application = objc_getClass("SpringBoard") ?: objc_getClass("UIApplication");
        Method method = application ? class_getInstanceMethod(application, @selector(sendEvent:)) : NULL;
        if (!method) {
            vpWriteLine([NSString stringWithFormat:@"pid=%d active, no sendEvent: to wrap", getpid()]);
            return;
        }
        vpOriginalSendEvent = method_setImplementation(method, (IMP)vpSendEvent);
        vpWriteLine([NSString stringWithFormat:@"pid=%d active: wrapped -[%@ sendEvent:] (class %@)", getpid(),
                     NSStringFromClass(application), vpClassName(application)]);
    }
}

int vphone_touchdiag_version(void) { return 1; }
