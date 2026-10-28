// libinnercutoutfix.m — Duo inner-screen UI compatibility (experimental):
// the cutout SpringBoard's status bar selects its provider from, for an iPhone
// Duo guest booted at the inner panel's render size on one display.
//
// SpringBoard classifies the device by the main screen's size. At 2007x2853 it
// becomes screen type 32, whose display shape is an island pill, and
// -[UIScreen _exclusionArea] reports that pill. The status bar's
// AxisAlignableSplit selection then finds no inner-panel provider (it needs a
// 37 pt hole), falls back to DynamicSplitSmallIsland, and that provider's
// screen-sized foreground view takes every touch. The simulator reports the
// device's 37 pt hole for its inner screen.
//
// Installed only while the patch system-springboard-exp-inner_cutout is
// selected (cfw install / update-environment place or remove it), and loaded by
// SystemHook into SpringBoard; its presence is the switch. For the main screen
// only, at a 2007x2853 native size only, and only while the original answer is
// the single-rect pill observed there, -[UIScreen _exclusionArea] returns the
// device's 37 pt hole instead. Every other call gets the original answer, and
// the first such call is logged as not applied. Nothing else changes: not the
// screen type, the provider selection, rotation or hit-testing. The hole is
// the simulator's value, not a calibrated inner camera position. Logged to
// /var/mobile/Library/Caches/vphone-innercutout.log.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <fcntl.h>
#include <math.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <sys/stat.h>
#include <unistd.h>

#define VP_INNERCUTOUT_LOG "/var/mobile/Library/Caches/vphone-innercutout.log"

// The device's hole as the simulator's inner screen reports it, in points.
static const CGRect vpCutout = {{399, 30}, {37, 37}};

static IMP vpOriginalExclusionArea;
static unsigned long vpCalls, vpMatched, vpApplied;
static BOOL vpReportedUnsupported;

static void vpLog(NSString *line) {
    int fd = open(VP_INNERCUTOUT_LOG, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0666);
    if (fd < 0)
        return;
    fchmod(fd, 0666);
    dprintf(fd, "pid=%d %s\n", getpid(), line.UTF8String);
    close(fd);
}

static BOOL vpNear(CGFloat a, CGFloat b) { return fabs(a - b) < 0.01; }

// The pill SpringBoard's screen type 32 maps to, as -[UIScreen _exclusionArea]
// reports it at the inner render size.
static BOOL vpIsInnerSizePill(id shape) {
    if (![NSStringFromClass([shape class]) isEqualToString:@"UISDisplaySingleRectShape"] ||
        ![shape respondsToSelector:@selector(rect)])
        return NO;
    CGRect rect = ((CGRect (*)(id, SEL))objc_msgSend)(shape, @selector(rect));
    return vpNear(rect.origin.x, 250.0 + 1.0 / 3.0) && vpNear(rect.origin.y, 14) &&
           vpNear(rect.size.width, 125.0 + 1.0 / 3.0) && vpNear(rect.size.height, 36.0 + 2.0 / 3.0);
}

static id vpExclusionArea(UIScreen *screen, SEL selector) {
    id original = ((id (*)(id, SEL))vpOriginalExclusionArea)(screen, selector);
    vpCalls++;
    CGSize native = screen.nativeBounds.size;
    BOOL innerSize = vpNear(native.width, 2007) && vpNear(native.height, 2853);
    if (screen != UIScreen.mainScreen || !innerSize || !vpIsInnerSizePill(original)) {
        if (!vpReportedUnsupported) {
            vpReportedUnsupported = YES;
            vpLog([NSString stringWithFormat:@"not applied: unsupported configuration (main screen %d, native %@, cutout %@)",
                   screen == UIScreen.mainScreen, NSStringFromCGSize(native), original]);
        }
        return original;
    }
    vpMatched++;
    id corrected = ((id (*)(id, SEL, CGRect))objc_msgSend)([[original class] alloc], NSSelectorFromString(@"initWithRect:"), vpCutout);
    if (!corrected)
        return original;
    vpApplied++;
    if (vpApplied <= 3 || vpApplied % 100 == 0)
        vpLog([NSString stringWithFormat:@"applied #%lu (calls %lu, matched %lu): %@ -> %@", vpApplied, vpCalls,
               vpMatched, original, corrected]);
    return corrected;
}

__attribute__((constructor)) static void vpInstallInnerCutoutFix(void) {
    @autoreleasepool {
        Method method = class_getInstanceMethod(UIScreen.class, NSSelectorFromString(@"_exclusionArea"));
        if (!method) {
            vpLog(@"loaded, -[UIScreen _exclusionArea] absent: inactive");
            return;
        }
        vpOriginalExclusionArea = method_setImplementation(method, (IMP)vpExclusionArea);
        vpLog([NSString stringWithFormat:@"loaded: -[UIScreen _exclusionArea] wrapped, cutout %@", NSStringFromCGRect(vpCutout)]);
    }
}

int vphone_innercutoutfix_version(void) { return 2; }
