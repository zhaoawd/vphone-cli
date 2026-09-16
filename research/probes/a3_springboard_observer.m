// Temporary rig2-only observer; never part of production packaging.
// Default: forward every intercepted method unchanged. A3_IGNORE_HID_EDGES=1
// additionally acquires a diagnostic assertion and intentionally changes edge recognition.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <fcntl.h>
#include <unistd.h>
#ifndef A3_IGNORE_HID_EDGES
#define A3_IGNORE_HID_EDGES 0
#endif

static char edgeAssertionKey;

static unsigned entries;
static void record(NSString *message) {
    @synchronized(NSProcessInfo.processInfo) {
        if (entries++ >= 1500) return;
        NSString *line = [NSString stringWithFormat:@"[DEBUG-a3-sb] %.3f %@\n", NSProcessInfo.processInfo.systemUptime, message];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        int fd = open("/tmp/vphone-a3-springboard.log", O_CREAT | O_WRONLY | O_APPEND, 0644);
        if (fd >= 0) { (void)write(fd, data.bytes, data.length); close(fd); }
    }
}

static void install(Class cls, SEL sel, IMP replacement, Method method) {
    // Do not replace an inherited implementation on a superclass.
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(method)))
        method_setImplementation(class_getInstanceMethod(cls, sel), replacement);
}

static void observeScalar(Class cls, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method || method_getNumberOfArguments(method) != 2) return;
    char type[64]; method_getReturnType(method, type, sizeof(type));
    IMP original = method_getImplementation(method);
    __block unsigned calls = 0;
    if (strcmp(type, @encode(BOOL)) == 0) {
        IMP replacement = imp_implementationWithBlock(^BOOL(id obj) {
            BOOL result = ((BOOL (*)(id, SEL))original)(obj, sel);
            if (calls++ < 20) record([NSString stringWithFormat:@"%@ %@ = %d", NSStringFromClass(cls), name, result]);
            return result;
        });
        install(cls, sel, replacement, method);
    } else if (strcmp(type, @encode(NSInteger)) == 0) {
        IMP replacement = imp_implementationWithBlock(^NSInteger(id obj) {
            NSInteger result = ((NSInteger (*)(id, SEL))original)(obj, sel);
            if (calls++ < 20) record([NSString stringWithFormat:@"%@ %@ = %ld", NSStringFromClass(cls), name, (long)result]);
            return result;
        });
        install(cls, sel, replacement, method);
    } else return;
    record([NSString stringWithFormat:@"installed %@ %@ type=%s", NSStringFromClass(cls), name, type]);
}

static void observeTouches(Class cls, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method || method_getNumberOfArguments(method) != 4) return;
    char type[64]; method_getReturnType(method, type, sizeof(type));
    if (strcmp(type, @encode(void)) != 0) return;
    for (unsigned i = 2; i < 4; i++) {
        method_getArgumentType(method, i, type, sizeof(type));
        if (type[0] != '@') return;
    }
    IMP original = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(^(id obj, NSSet *touches, UIEvent *event) {
        @try {
            if ([name isEqualToString:@"touchesBegan:withEvent:"] && [obj isKindOfClass:UIScreenEdgePanGestureRecognizer.class]) {
                record([NSString stringWithFormat:@"edge-before %p edges=%lu %@", obj, (unsigned long)[(UIScreenEdgePanGestureRecognizer *)obj edges], [obj valueForKey:@"debugDictionary"]]);
                if (A3_IGNORE_HID_EDGES && [obj isKindOfClass:NSClassFromString(@"SBFluidSwitcherScreenEdgePanGestureRecognizer")] &&
                    !objc_getAssociatedObject(obj, &edgeAssertionKey)) {
                    SEL assertionSelector = NSSelectorFromString(@"_beginRequiringIgnoresHIDEdgeFlagsForReason:");
                    Method assertionMethod = class_getInstanceMethod([obj class], assertionSelector);
                    if (assertionMethod && strcmp(method_getTypeEncoding(assertionMethod), "@24@0:8@16") == 0) {
                        id token = ((id (*)(id, SEL, id))method_getImplementation(assertionMethod))(obj, assertionSelector, @"a3-rig2-experiment");
                        objc_setAssociatedObject(obj, &edgeAssertionKey, token, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                        record([NSString stringWithFormat:@"EXPERIMENT ignore HID edge flags %p token=%@", obj, token]);
                    }
                }
            }
            if ([touches isKindOfClass:NSSet.class]) {
                for (UITouch *touch in touches) {
                    if (![touch isKindOfClass:UITouch.class]) continue;
                    CGPoint point = [touch locationInView:nil];
                    record([NSString stringWithFormat:@"%@ %p %@ phase=%ld point=%.2f,%.2f edgeType=%@ edgeAim=%@", NSStringFromClass(cls), obj, name, (long)touch.phase, point.x, point.y, [touch valueForKey:@"_edgeType"], [touch valueForKey:@"_edgeAim"]]);
                    if ([name isEqualToString:@"touchesBegan:withEvent:"])
                        record([NSString stringWithFormat:@"recognizer %@", obj]);
                }
            }
        } @catch (NSException *exception) { record(exception.name); }
        ((void (*)(id, SEL, id, id))original)(obj, sel, touches, event);
        if ([name isEqualToString:@"touchesBegan:withEvent:"] && [obj isKindOfClass:UIScreenEdgePanGestureRecognizer.class])
            record([NSString stringWithFormat:@"edge-after %p %@", obj, [obj valueForKey:@"debugDictionary"]]);
        if ([obj isKindOfClass:UIGestureRecognizer.class])
            record([NSString stringWithFormat:@"%@ state=%ld", NSStringFromClass(cls), (long)[(UIGestureRecognizer *)obj state]]);
    });
    install(cls, sel, replacement, method);
    record([NSString stringWithFormat:@"installed %@ %@", NSStringFromClass(cls), name]);
}

static void observeFailure(Class cls) {
    SEL sel = @selector(setState:);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method || method_getNumberOfArguments(method) != 3) return;
    char type[64]; method_getArgumentType(method, 2, type, sizeof(type));
    if (strcmp(type, @encode(NSInteger)) != 0) return;
    IMP original = method_getImplementation(method);
    __block unsigned failures = 0;
    IMP replacement = imp_implementationWithBlock(^(id obj, NSInteger state) {
        if (state == UIGestureRecognizerStateFailed && failures++ < 20)
            record([NSString stringWithFormat:@"failure %p %@ stack=%@", obj, obj, NSThread.callStackSymbols]);
        ((void (*)(id, SEL, NSInteger))original)(obj, sel, state);
    });
    install(cls, sel, replacement, method);
}

static void observeDecision(Class cls, Method method) {
    unsigned count = method_getNumberOfArguments(method);
    if (count != 3 && count != 4) return;
    char type[64]; method_getReturnType(method, type, sizeof(type));
    if (strcmp(type, @encode(BOOL)) != 0) return;
    for (unsigned i = 2; i < count; i++) {
        method_getArgumentType(method, i, type, sizeof(type));
        if (type[0] != '@') return;
    }
    SEL sel = method_getName(method);
    NSString *name = NSStringFromSelector(sel);
    IMP original = method_getImplementation(method);
    __block unsigned calls = 0;
    IMP replacement;
    if (count == 3) replacement = imp_implementationWithBlock(^BOOL(id obj, id arg) {
        BOOL value = ((BOOL (*)(id, SEL, id))original)(obj, sel, arg);
        if (calls++ < 30) record([NSString stringWithFormat:@"decision %@ %@ arg=%p result=%d", NSStringFromClass(cls), name, arg, value]);
        return value;
    });
    else replacement = imp_implementationWithBlock(^BOOL(id obj, id first, id second) {
        BOOL value = ((BOOL (*)(id, SEL, id, id))original)(obj, sel, first, second);
        if (calls++ < 30) record([NSString stringWithFormat:@"decision %@ %@ arg=%p,%p result=%d", NSStringFromClass(cls), name, first, second, value]);
        return value;
    });
    install(cls, sel, replacement, method);
}

__attribute__((constructor)) static void start(void) {
    if (![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        record([NSString stringWithFormat:@"loaded pid=%d ignoreHIDEdges=%d", getpid(), A3_IGNORE_HID_EDGES]);
        NSArray *names = @[@"BSPlatform", @"SBHomeGestureSettings", @"SBHomeGesturePanGestureRecognizer", @"SBFluidSwitcherGestureManager", @"SBFluidSwitcherScreenEdgePanGestureRecognizer", @"UIScreenEdgePanGestureRecognizer", @"SBHomeGestureCoordinator", @"UITouch", @"BKSHIDEventDigitizerAttributes"];
        for (NSString *name in names) {
            Class cls = NSClassFromString(name);
            record([NSString stringWithFormat:@"class %@ present=%d", name, cls != Nil]);
            unsigned count = 0;
            Method *methods = class_copyMethodList(cls, &count);
            for (unsigned i = 0; i < count; i++) {
                NSString *selector = NSStringFromSelector(method_getName(methods[i]));
                if ([name isEqualToString:@"SBFluidSwitcherScreenEdgePanGestureRecognizer"] || [name isEqualToString:@"UIScreenEdgePanGestureRecognizer"])
                    record([NSString stringWithFormat:@"implementation %@ %@ %p %s", name, selector, method_getImplementation(methods[i]), method_getTypeEncoding(methods[i])]);
                if ([selector rangeOfString:@"gesture" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [selector rangeOfString:@"home" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [selector rangeOfString:@"edge" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [selector hasPrefix:@"touches"])
                    record([NSString stringWithFormat:@"method %@ %@ %s", name, selector, method_getTypeEncoding(methods[i])]);
                if ([selector rangeOfString:@"should" options:NSCaseInsensitiveSearch].location != NSNotFound)
                    observeDecision(cls, methods[i]);
            }
            free(methods);
            if (!cls) continue;
            observeScalar(cls, @"homeButtonType");
            observeScalar(cls, @"isHomeGestureEnabled");
            if ([name isEqualToString:@"SBHomeGesturePanGestureRecognizer"]) {
                observeFailure(cls);
                for (NSString *selector in @[@"touchesBegan:withEvent:", @"touchesMoved:withEvent:", @"touchesEnded:withEvent:", @"touchesCancelled:withEvent:"])
                    observeTouches(cls, selector);
            }
        }
    });
}
