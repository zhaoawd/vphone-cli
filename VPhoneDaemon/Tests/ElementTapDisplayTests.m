#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <assert.h>
#import "../Native/vphoned_element_tap.h"
#import "../Native/vphoned_ax_hierarchy.h"

// CADisplay boundary double: exercise the actual native reader on macOS.
@interface TapTestState : NSObject
@property NSNumber *displayState;
@end
@implementation TapTestState
@end
@interface TapTestDisplay : NSObject
@property NSString *name;
@property NSString *deviceName;
@property NSValue *bounds;
@property NSNumber *pointScale;
@property TapTestState *stateControl;
@end
@implementation TapTestDisplay
@end
static NSArray *inventory;
static NSArray *pendingInventory;
static int refreshes;
static TapTestDisplay *primary;
@interface TapTestCatalog : NSObject
+ (NSArray *)displays;
+ (id)mainDisplay;
+ (void)updateDisplays;
@end
@implementation TapTestCatalog
+ (NSArray *)displays { return inventory; }
+ (id)mainDisplay { return primary; }
+ (void)updateDisplays { refreshes++; if (pendingInventory) inventory = pendingInventory; }
@end

extern NSDictionary *vp_element_tap_display_for_class(Class cls);
extern NSDictionary *vp_element_tap_frame_for_functions(VPAxFunctions f, int pid);
static CGRect appFrame = {{0, 0}, {375, 667}};
static int axError;
static CFTypeRef createApp(pid_t pid) { return CFRetain(CFSTR("root")); }
static int copyFrame(CFTypeRef root, CFStringRef attribute, CFTypeRef *value) {
    assert((uintptr_t)attribute == 2003);
    *value = CFBridgingRetain([NSValue valueWithBytes:&appFrame objCType:@encode(CGRect)]);
    return axError;
}
static CFTypeID frameType(void) {
    return CFGetTypeID((__bridge CFTypeRef)[NSValue valueWithBytes:&appFrame objCType:@encode(CGRect)]);
}
static Boolean getFrame(CFTypeRef value, int type, void *out) {
    assert(type == 3);
    [(__bridge NSValue *)value getValue:out size:sizeof(CGRect)];
    return true;
}
static NSDictionary *report(void) { return vp_element_tap_display_for_class(TapTestCatalog.class); }

static TapTestDisplay *panel(NSString *name, double w, double h, int state) {
    TapTestDisplay *d = [TapTestDisplay new];
    d.name = d.deviceName = name;
    d.bounds = [NSValue valueWithBytes:&(CGRect){{0, 0}, {w, h}} objCType:@encode(CGRect)];
    d.pointScale = @3;
    d.stateControl = [TapTestState new];
    d.stateControl.displayState = @(state);
    return d;
}
int main(void) { @autoreleasepool {
    primary = panel(@"Main", 1398, 2034, 1);
    inventory = @[primary];
    assert(![report()[@"dual_display"] boolValue]);
    TapTestDisplay *inner = panel(@"VPhone Duo Inner", 2007, 2853, 1);
    // Real daemon clients lack SpringBoard's pointScale override.
    inner.pointScale = @1;
    pendingInventory = @[primary, inner];
    for (NSNumber *state in @[@1, @0, @1, @0]) {
        inner.stateControl.displayState = state;
        NSDictionary *r = report();
        assert([r[@"dual_display"] boolValue]);
        assert([r[@"name"] isEqual:[state boolValue] ? @"inner" : @"cover"]);
        assert([r[@"width"] doubleValue] == ([state boolValue] ? 669 : 466));
        assert([r[@"height"] doubleValue] == ([state boolValue] ? 951 : 678));
    }
    assert(refreshes == 5);
    pendingInventory = nil;
    inner.stateControl.displayState = @2;
    assert(report()[@"error"]);
    inner.stateControl.displayState = @1;
    inner.stateControl.displayState = @0;
    primary.pointScale = @0;
    assert(report()[@"error"]);
    primary.pointScale = @3;
    inner.stateControl = nil;
    assert(report()[@"error"]);
    inventory = @[primary, inner, panel(@"VPhone Duo Inner", 2007, 2853, 1)];
    assert(report()[@"error"]);
    VPAxFunctions f = {.createApp = createApp, .copy = copyFrame, .valueTypeID = frameType, .getValue = getFrame};
    assert([vp_element_tap_frame_for_functions(f, 123)[@"height"] doubleValue] == 667);
    axError = -25212;
    assert(vp_element_tap_frame_for_functions(f, 123)[@"error"]);
    axError = 0;
    appFrame.size.width = NAN;
    assert(vp_element_tap_frame_for_functions(f, 123)[@"error"]);
    appFrame.size.width = 0;
    assert(vp_element_tap_frame_for_functions(f, 123)[@"error"]);
    assert(vp_element_tap_frame_for_functions(f, 0)[@"error"]);
    puts("element tap native display: single panel, fold round trip and invalid-state checks passed");
} }
