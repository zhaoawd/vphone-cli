// libinnercutoutfix.m — experimental cutout correction for an iPhone Duo guest
// booted at the inner panel's render size.
//
// SpringBoard classifies the device by the main screen's size. At 2007x2853 it
// becomes screen type 32, whose display shape is an island pill, and
// -[UIScreen _exclusionArea] reports that pill. The status bar's
// AxisAlignableSplit selection then finds no inner-panel provider (it needs a
// 37 pt hole), falls back to DynamicSplitSmallIsland, and that provider's
// screen-sized foreground view takes every touch. The simulator reports the
// device's 37 pt hole for its inner screen.
//
// SystemHook loads this into SpringBoard. It does nothing unless
// /private/var/tmp/vphone-innercutout exists when SpringBoard starts and holds
// a rect "x y width height" in points. Then, for the main screen only, at a
// 2007x2853 native size only, and only while the original answer is the
// single-rect pill observed there, -[UIScreen _exclusionArea] returns a
// single-rect shape with that rect instead. Every other call gets the original
// answer. Nothing else is changed: not the screen type, the provider selection,
// rotation or hit-testing. Loaded, enabled, matched and applied are logged to
// /var/mobile/Library/Caches/vphone-innercutout.log.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <fcntl.h>
#include <math.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <sys/stat.h>
#include <unistd.h>

#define VP_INNERCUTOUT_FLAG "/private/var/tmp/vphone-innercutout"
#define VP_INNERCUTOUT_LOG "/var/mobile/Library/Caches/vphone-innercutout.log"

static IMP vpOriginalExclusionArea;
static CGRect vpCutout;
static unsigned long vpCalls, vpMatched, vpApplied;

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
    if (screen != UIScreen.mainScreen || !vpNear(native.width, 2007) || !vpNear(native.height, 2853) ||
        !vpIsInnerSizePill(original))
        return original;
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
        NSString *contents = [NSString stringWithContentsOfFile:@VP_INNERCUTOUT_FLAG encoding:NSUTF8StringEncoding error:nil];
        if (!contents) {
            vpLog(@"loaded, flag absent: inactive");
            return;
        }
        NSArray<NSString *> *fields = [[contents stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
            componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (fields.count != 4 || fields[2].doubleValue <= 0 || fields[3].doubleValue <= 0) {
            vpLog([NSString stringWithFormat:@"flag present but not \"x y width height\": %@; inactive", contents]);
            return;
        }
        vpCutout = CGRectMake(fields[0].doubleValue, fields[1].doubleValue, fields[2].doubleValue, fields[3].doubleValue);
        Method method = class_getInstanceMethod(UIScreen.class, NSSelectorFromString(@"_exclusionArea"));
        if (!method) {
            vpLog(@"enabled, -[UIScreen _exclusionArea] absent: inactive");
            return;
        }
        vpOriginalExclusionArea = method_setImplementation(method, (IMP)vpExclusionArea);
        vpLog([NSString stringWithFormat:@"enabled: -[UIScreen _exclusionArea] wrapped, cutout %@", NSStringFromCGRect(vpCutout)]);
    }
}

int vphone_innercutoutfix_version(void) { return 1; }
