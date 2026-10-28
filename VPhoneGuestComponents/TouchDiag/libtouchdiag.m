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
// location, window, window level, view; for a touch beginning in the status
// bar window, also the view chain it hit; at the first touch, the status bar
// windows and their providers) and calls the original unchanged. It
// never alters an event, a return value or any state. Each event is a line in
// /var/mobile/Library/Caches/vphone-touchdiag.log, capped at 5000 lines.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <sys/stat.h>
#include <unistd.h>

#define VP_TOUCHDIAG_FLAG "/private/var/tmp/vphone-touchdiag"
#define VP_TOUCHDIAG_LOG "/var/mobile/Library/Caches/vphone-touchdiag.log"
#define VP_TOUCHDIAG_MAX_LINES 5000

static IMP vpOriginalSendEvent;
static void vpDumpProviderClasses(void);
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

static NSString *vpTransform(CGAffineTransform t) {
    return CGAffineTransformIsIdentity(t) ? @"identity"
        : [NSString stringWithFormat:@"[%.3f %.3f %.3f %.3f %.1f %.1f]", t.a, t.b, t.c, t.d, t.tx, t.ty];
}

// For a touch that began in the status bar window: the hit view and each
// ancestor up to the window, with geometry, interaction state, the touch point
// in that view's coordinates and the view's own pointInside answer. Then the
// window's direct subviews that contain the point. pointInside:withEvent: is
// the containment test UIKit itself makes during hit-testing.
static void vpRecordStatusBarChain(UITouch *touch, UIEvent *event) {
    UIWindow *window = touch.window;
    NSMutableArray *chain = [NSMutableArray array];
    for (UIView *view = touch.view; view; view = view.superview) {
        CGPoint p = [touch locationInView:view];
        [chain addObject:[NSString stringWithFormat:@"%@<%p> bounds=%@ center=%@ transform=%@ hidden=%d alpha=%.2f interaction=%d clips=%d point=%@ inside=%d subviews=%lu",
                          vpClassName(view), view, NSStringFromCGRect(view.bounds), NSStringFromCGPoint(view.center),
                          vpTransform(view.transform), view.hidden, view.alpha, view.userInteractionEnabled,
                          view.clipsToBounds, NSStringFromCGPoint(p), [view pointInside:p withEvent:event],
                          (unsigned long)view.subviews.count]];
        if (view == window)
            break;
    }
    NSMutableArray *containing = [NSMutableArray array];
    for (UIView *sub in window.subviews) {
        CGPoint p = [touch locationInView:sub];
        if ([sub pointInside:p withEvent:event])
            [containing addObject:[NSString stringWithFormat:@"%@<%p> bounds=%@", vpClassName(sub), sub, NSStringFromCGRect(sub.bounds)]];
    }
    vpWriteLine([NSString stringWithFormat:@"chain touch=%p window=%@<%p> scene=%@ root=%@\n  %@\n  window subviews containing point: %@",
                 touch, vpClassName(window), window, vpClassName(window.windowScene), vpClassName(window.rootViewController.view),
                 [chain componentsJoinedByString:@"\n  "], [containing componentsJoinedByString:@"; "]]);
}

static id vpValue(id object, NSString *key) {
    return [object respondsToSelector:NSSelectorFromString(key)] ? [object valueForKey:key] : nil;
}

// Once per SpringBoard, at its first touch: every status bar window with its
// frame and its STUIStatusBar views' bounds, intrinsic size, visual provider
// class and that class's own height, if it answers one. Tells an oversized
// status bar at every size from one only at the inner render size, and which
// provider sized it.
static void vpDumpStatusBarWindows(void) {
    static BOOL done;
    if (done)
        return;
    done = YES;
    vpDumpProviderClasses();
    NSMutableArray *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass:UIWindowScene.class])
            [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
    for (UIWindow *window in windows) {
        if (![vpClassName(window) containsString:@"StatusBar"])
            continue;
        NSMutableArray *bars = [NSMutableArray array];
        NSMutableArray *queue = [NSMutableArray arrayWithObject:window];
        while (queue.count) {
            UIView *view = queue.firstObject;
            [queue removeObjectAtIndex:0];
            [queue addObjectsFromArray:view.subviews];
            if (![vpClassName(view) isEqualToString:@"STUIStatusBar"])
                continue;
            id provider = vpValue(view, @"visualProvider");
            Class providerClass = [provider class];
            NSString *height = [providerClass respondsToSelector:NSSelectorFromString(@"height")]
                ? [NSString stringWithFormat:@"%@", [(id)providerClass valueForKey:@"height"]] : @"-";
            [bars addObject:[NSString stringWithFormat:@"STUIStatusBar<%p> bounds=%@ intrinsic=%@ provider=%@ providerHeight=%@ orientation=%@",
                             view, NSStringFromCGRect(view.bounds), NSStringFromCGSize(view.intrinsicContentSize),
                             vpClassName(provider), height, vpValue(view, @"orientation") ?: @"-"]];
        }
        vpWriteLine([NSString stringWithFormat:@"statusbar-window %@<%p> frame=%@ level=%.0f hidden=%d screen=%@\n  %@",
                     vpClassName(window), window, NSStringFromCGRect(window.frame), window.windowLevel, window.hidden,
                     NSStringFromCGRect(window.screen.bounds), [bars componentsJoinedByString:@"\n  "]]);
    }
}

static void vpRecordTouches(UIEvent *event) {
    vpDumpStatusBarWindows();
    NSMutableArray *parts = [NSMutableArray array];
    for (UITouch *touch in event.allTouches) {
        UIWindow *window = touch.window;
        CGPoint inWindow = window ? [touch locationInView:window] : [touch locationInView:nil];
        [parts addObject:[NSString stringWithFormat:@"{touch=%p phase=%ld x=%.1f y=%.1f window=%@ level=%.0f windowFrame=%@ view=%@}",
                          touch, (long)touch.phase, inWindow.x, inWindow.y, vpClassName(window),
                          window ? window.windowLevel : -1.0,
                          window ? NSStringFromCGRect(window.frame) : @"-", vpClassName(touch.view)]];
    }
    vpWriteLine([NSString stringWithFormat:@"t=%.4f touches=%lu other_events_since_start=%lu %@",
                 event.timestamp, (unsigned long)event.allTouches.count, vpOtherEvents,
                 [parts componentsJoinedByString:@" "]]);
    for (UITouch *touch in event.allTouches)
        if (touch.phase == UITouchPhaseBegan && [vpClassName(touch.window) isEqualToString:@"SBStatusBarWindow"])
            vpRecordStatusBarChain(touch, event);
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

// What provider selection sees: the main screen's native size and scale, each
// sized subclass's own nativeDisplayWidth / referenceScreenScale / notchSize,
// and what each family's visualProviderSubclassForScreen: answers for the main
// screen with no provider info. Class getters and factory methods only.
static NSString *vpClassGetter(Class cls, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (!class_getClassMethod(cls, selector))
        return @"-";
    @try {
        return [NSString stringWithFormat:@"%@", [(id)cls valueForKey:name]];
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"threw %@", exception.name];
    }
}

// The exclusion area's class: its ivars, and its methods that take a CGRect,
// which is what a substitute in the selection probe below is built with.
static void vpDescribeExclusionArea(id area) {
    Class cls = [area class];
    NSMutableArray *parts = [NSMutableArray array];
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    for (unsigned int index = 0; index < count; index++)
        [parts addObject:[NSString stringWithFormat:@"ivar %s %s", ivar_getName(ivars[index]), ivar_getTypeEncoding(ivars[index])]];
    free(ivars);
    for (Class target in @[ object_getClass(cls), cls ]) {
        Method *methods = class_copyMethodList(target, &count);
        for (unsigned int index = 0; index < count; index++)
            [parts addObject:[NSString stringWithFormat:@"%c%s %s", class_isMetaClass(target) ? '+' : '-',
                              sel_getName(method_getName(methods[index])), method_getTypeEncoding(methods[index])]];
        free(methods);
    }
    vpWriteLine([NSString stringWithFormat:@"exclusion-class %@ super=%@\n  %@", NSStringFromClass(cls),
                 NSStringFromClass(class_getSuperclass(cls)), [parts componentsJoinedByString:@"\n  "]]);
}

// A substitute exclusion area holding one rect, built through whichever
// one-rect constructor the class has; nil when it has none.
static id vpExclusionAreaWithRect(Class cls, CGRect rect) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(object_getClass(cls), &count);
    id made = nil;
    for (unsigned int index = 0; index < count && !made; index++) {
        const char *types = method_getTypeEncoding(methods[index]);
        if (method_getNumberOfArguments(methods[index]) == 3 && types[0] == '@' && strstr(types, "{CGRect="))
            made = ((id (*)(id, SEL, CGRect))objc_msgSend)(cls, method_getName(methods[index]), rect);
    }
    free(methods);
    if (made)
        return made;
    methods = class_copyMethodList(cls, &count);
    for (unsigned int index = 0; index < count && !made; index++) {
        const char *name = sel_getName(method_getName(methods[index]));
        const char *types = method_getTypeEncoding(methods[index]);
        if (strncmp(name, "init", 4) == 0 && method_getNumberOfArguments(methods[index]) == 3 && strstr(types, "{CGRect="))
            made = ((id (*)(id, SEL, CGRect))objc_msgSend)([cls alloc], method_getName(methods[index]), rect);
    }
    free(methods);
    return made;
}

// Where the shape comes from: SpringBoard's own device shape, the screen type
// SpringBoardHome classifies this device as, and the shape each screen type
// maps to (only the types whose shape differs from the previous one are
// written). Pure class methods and lookup functions.
static void vpDumpScreenTypes(Class shapeClass) {
    SEL thisDevice = NSSelectorFromString(@"sb_thisDeviceDisplayShape");
    SEL forType = NSSelectorFromString(@"sb_displayShapeForScreenType:");
    if (class_getClassMethod(shapeClass, thisDevice))
        vpWriteLine([NSString stringWithFormat:@"screen-type sb_thisDeviceDisplayShape = %@",
                     ((id (*)(id, SEL))objc_msgSend)(shapeClass, thisDevice)]);
    for (NSString *name in @[ @"SBHScreenTypeForCurrentDevice", @"SBHScreenTypeForCurrentDeviceSkippingCache" ]) {
        unsigned long long (*function)(void) = dlsym(RTLD_DEFAULT, name.UTF8String);
        vpWriteLine(function ? [NSString stringWithFormat:@"screen-type %@() = %llu", name, function()]
                             : [NSString stringWithFormat:@"screen-type %@ absent", name]);
    }
    if (!class_getClassMethod(shapeClass, forType))
        return;
    NSString *previous = nil;
    for (unsigned long long type = 0; type < 160; type++) {
        NSString *shape = [((id (*)(id, SEL, unsigned long long))objc_msgSend)(shapeClass, forType, type) description] ?: @"nil";
        if (![shape isEqualToString:previous])
            vpWriteLine([NSString stringWithFormat:@"screen-type %llu -> %@", type, shape]);
        previous = shape;
    }
}

// Forwards every message to the real screen and records the selector and the
// answer, so a provider selection run against it lists the screen properties it
// reads. Used only as an argument to a class method; it changes nothing.
@interface VPTouchDiagLoggingProxy : NSProxy
@property(nonatomic, strong) id target;
@property(nonatomic, strong) NSMutableArray<NSString *> *messages;
@property(nonatomic, strong) id exclusionArea;
@end

@implementation VPTouchDiagLoggingProxy
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [self.target methodSignatureForSelector:selector];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    if (self.exclusionArea && invocation.selector == NSSelectorFromString(@"_exclusionArea")) {
        __unsafe_unretained id value = self.exclusionArea;
        [invocation setReturnValue:&value];
        [self.messages addObject:[NSString stringWithFormat:@"_exclusionArea -> substituted %@", value]];
        return;
    }
    [invocation invokeWithTarget:self.target];
    NSMethodSignature *signature = invocation.methodSignature;
    const char *type = signature.methodReturnType;
    NSString *answer = @"void";
    if (signature.methodReturnLength && type[0] == '@') {
        __unsafe_unretained id value;
        [invocation getReturnValue:&value];
        answer = [[value description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        if (answer.length > 160)
            answer = [answer substringToIndex:160];
    } else if (signature.methodReturnLength && strchr("cCsSiIlLqQB", type[0])) {
        long long value = 0;
        [invocation getReturnValue:&value];
        answer = [NSString stringWithFormat:@"%lld", value];
    } else if (signature.methodReturnLength && type[0] == 'd') {
        double value;
        [invocation getReturnValue:&value];
        answer = [NSString stringWithFormat:@"%g", value];
    } else if (signature.methodReturnLength && type[0] == '{' && signature.methodReturnLength == sizeof(CGRect)) {
        CGRect value;
        [invocation getReturnValue:&value];
        answer = NSStringFromCGRect(value);
    } else if (signature.methodReturnLength && type[0] == '{' && signature.methodReturnLength == sizeof(CGSize)) {
        CGSize value;
        [invocation getReturnValue:&value];
        answer = NSStringFromCGSize(value);
    } else if (signature.methodReturnLength) {
        answer = [NSString stringWithFormat:@"(%s)", type];
    }
    [self.messages addObject:[NSString stringWithFormat:@"%@ -> %@", NSStringFromSelector(invocation.selector), answer]];
}
@end

static void vpTraceProviderSelection(NSString *className, id exclusionArea) {
    Class cls = NSClassFromString(className);
    SEL choose = NSSelectorFromString(@"visualProviderSubclassForScreen:visualProviderInfo:");
    if (!class_getClassMethod(cls, choose))
        return;
    VPTouchDiagLoggingProxy *proxy = [VPTouchDiagLoggingProxy alloc];
    proxy.target = UIScreen.mainScreen;
    proxy.messages = [NSMutableArray array];
    proxy.exclusionArea = exclusionArea;
    NSString *chosen;
    @try {
        Class result = ((Class (*)(id, SEL, id, id))objc_msgSend)(cls, choose, proxy, nil);
        chosen = result ? NSStringFromClass(result) : @"nil";
    } @catch (NSException *exception) {
        chosen = [NSString stringWithFormat:@"threw %@ %@", exception.name, exception.reason];
    }
    vpWriteLine([NSString stringWithFormat:@"provider-trace +[%@ visualProviderSubclassForScreen:proxy%@ info:nil] = %@\n  %@", className,
                 exclusionArea ? @" (substituted exclusion)" : @"", chosen, [proxy.messages componentsJoinedByString:@"\n  "]]);
}

static void vpDumpProviderSelection(NSArray<NSString *> *classNames) {
    UIScreen *screen = UIScreen.mainScreen;
    vpWriteLine([NSString stringWithFormat:@"provider-screen bounds=%@ nativeBounds=%@ scale=%.2f nativeScale=%.2f",
                 NSStringFromCGRect(screen.bounds), NSStringFromCGRect(screen.nativeBounds), screen.scale, screen.nativeScale]);
    for (NSString *name in classNames) {
        Class cls = NSClassFromString(name);
        NSString *width = vpClassGetter(cls, @"nativeDisplayWidth");
        if (![width isEqualToString:@"-"])
            vpWriteLine([NSString stringWithFormat:@"provider-size %@ nativeDisplayWidth=%@ referenceScreenScale=%@ notchSize=%@",
                         name, width, vpClassGetter(cls, @"referenceScreenScale"), vpClassGetter(cls, @"notchSize")]);
        SEL choose = NSSelectorFromString(@"visualProviderSubclassForScreen:visualProviderInfo:");
        Method own = class_getClassMethod(cls, choose);
        Method inherited = class_getClassMethod(class_getSuperclass(cls), choose);
        if (!own || own == inherited)
            continue;
        NSString *chosen;
        @try {
            Class result = ((Class (*)(id, SEL, id, id))objc_msgSend)(cls, choose, screen, nil);
            chosen = result ? NSStringFromClass(result) : @"nil";
        } @catch (NSException *exception) {
            chosen = [NSString stringWithFormat:@"threw %@", exception.name];
        }
        vpWriteLine([NSString stringWithFormat:@"provider-choose +[%@ visualProviderSubclassForScreen:main info:nil] = %@", name, chosen]);
    }
}

// Once, when active: the status bar visual provider classes in the runtime and
// the class methods each declares itself, the metadata from which the provider
// for a screen is chosen. Read from the runtime, nothing is called.
static void vpDumpProviderClasses(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSMutableArray *lines = [NSMutableArray array];
    for (unsigned int index = 0; index < count; index++) {
        NSString *name = NSStringFromClass(classes[index]);
        if (![name hasPrefix:@"STUIStatusBarVisualProvider"] && ![name containsString:@"VisualProviderFactory"])
            continue;
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(object_getClass(classes[index]), &methodCount);
        NSMutableArray *names = [NSMutableArray array];
        for (unsigned int m = 0; m < methodCount; m++)
            [names addObject:NSStringFromSelector(method_getName(methods[m]))];
        free(methods);
        [names sortUsingSelector:@selector(compare:)];
        [lines addObject:[NSString stringWithFormat:@"provider-class %@ super=%@ +[%@]", name,
                          NSStringFromClass(class_getSuperclass(classes[index])), [names componentsJoinedByString:@" "]]];
    }
    free(classes);
    [lines sortUsingSelector:@selector(compare:)];
    for (NSString *line in lines)
        vpWriteLine(line);
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *line in lines)
        [names addObject:[line componentsSeparatedByString:@" "][1]];
    vpDumpProviderSelection(names);
    vpTraceProviderSelection(@"STUIStatusBarVisualProvider_AxisAlignableSplit", nil);
    vpTraceProviderSelection(@"STUIStatusBarVisualProvider_Split", nil);
    id area = [UIScreen.mainScreen respondsToSelector:NSSelectorFromString(@"_exclusionArea")]
        ? [UIScreen.mainScreen valueForKey:@"_exclusionArea"] : nil;
    if (area) {
        vpDescribeExclusionArea(area);
        vpDumpScreenTypes([area class]);
        // The outer panel's 37 pt hole (what the simulator reports for both
        // panels) and the same hole at the top right of the inner screen.
        CGFloat width = UIScreen.mainScreen.bounds.size.width;
        for (NSValue *rect in @[ [NSValue valueWithCGRect:CGRectMake(399, 30, 37, 37)],
                                  [NSValue valueWithCGRect:CGRectMake(width - 67, 30, 37, 37)] ]) {
            id substitute = vpExclusionAreaWithRect([area class], rect.CGRectValue);
            if (!substitute) {
                vpWriteLine(@"provider-trace substitute: no one-rect constructor");
                break;
            }
            vpTraceProviderSelection(@"STUIStatusBarVisualProvider_AxisAlignableSplit", substitute);
        }
    }
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

int vphone_touchdiag_version(void) { return 8; }
