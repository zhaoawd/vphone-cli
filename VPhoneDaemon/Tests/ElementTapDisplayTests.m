#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <assert.h>
#import "../Native/vphoned_element_tap.h"

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
static TapTestDisplay *primary;
@interface TapTestCatalog : NSObject
+ (NSArray *)displays;
+ (id)mainDisplay;
@end
@implementation TapTestCatalog
+ (NSArray *)displays { return inventory; }
+ (id)mainDisplay { return primary; }
@end

extern NSDictionary *vp_element_tap_display_for_class(Class cls);
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
    inventory = @[primary, inner];
    for (NSNumber *state in @[@1, @0, @1, @0]) {
        inner.stateControl.displayState = state;
        NSDictionary *r = report();
        assert([r[@"dual_display"] boolValue]);
        assert([r[@"name"] isEqual:[state boolValue] ? @"inner" : @"cover"]);
        assert([r[@"width"] doubleValue] == ([state boolValue] ? 669 : 466));
        assert([r[@"height"] doubleValue] == ([state boolValue] ? 951 : 678));
    }
    inner.stateControl.displayState = @2;
    assert(report()[@"error"]);
    inner.stateControl.displayState = @1;
    inner.pointScale = @0;
    assert(report()[@"error"]);
    inner.pointScale = @3;
    inner.stateControl = nil;
    assert(report()[@"error"]);
    inventory = @[primary, inner, panel(@"VPhone Duo Inner", 2007, 2853, 1)];
    assert(report()[@"error"]);
    puts("element tap native display: single panel, fold round trip and invalid-state checks passed");
} }
