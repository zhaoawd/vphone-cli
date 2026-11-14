#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "../Native/vphoned_ax_hierarchy.h"
#include <assert.h>
#include <math.h>

extern NSDictionary *vp_ax_display_hit_for_functions(VPAxFunctions, Class, int, unsigned int,
                                                      double, double, double, double, int);
static unsigned int receivedDisplay;
static CGPoint receivedPoint;
static BOOL emptyHit;
static int returnedPID = 123;
static NSDictionary *node;
struct __AXUIElement;
@interface AXDisplayHitFixture : NSObject
+ (id)uiElementAtCoordinate:(CGPoint)point displayId:(unsigned int)display;
- (struct __AXUIElement *)axElement;
@end
@implementation AXDisplayHitFixture
+ (id)uiElementAtCoordinate:(CGPoint)point displayId:(unsigned int)display {
    receivedDisplay = display; receivedPoint = point;
    return emptyHit ? nil : [self new];
}
- (struct __AXUIElement *)axElement { return (struct __AXUIElement *)(__bridge void *)node; }
@end
@interface AXWrongDisplayHitFixture : NSObject
+ (id)uiElementAtCoordinate:(id)point displayId:(unsigned int)display;
@end
@implementation AXWrongDisplayHitFixture
+ (id)uiElementAtCoordinate:(id)point displayId:(unsigned int)display { abort(); }
@end
static int copyAttribute(CFTypeRef element, CFStringRef key, CFTypeRef *output) {
    id value = ((__bridge NSDictionary *)element)[@((uintptr_t)key)];
    *output = CFBridgingRetain(value);
    return value ? 0 : -25212;
}
static int getPID(CFTypeRef element, pid_t *pid) { (void)element; *pid = returnedPID; return 0; }
static CFTypeID valueType(void) { return CFGetTypeID((__bridge CFTypeRef)[NSValue valueWithPoint:NSZeroPoint]); }
static Boolean getValue(CFTypeRef value, int kind, void *output) {
    [(__bridge NSValue *)value getValue:output size:kind == 3 ? sizeof(CGRect) : sizeof(CGPoint)]; return true;
}
int main(void) { @autoreleasepool {
    CGRect frame = CGRectMake(15, 25, 30, 40); CGPoint invalid = CGPointMake(NAN, 2);
    node = @{@2003:[NSValue valueWithBytes:&frame objCType:@encode(CGRect)],
             @2007:[NSValue valueWithBytes:&invalid objCType:@encode(CGPoint)], @2001:@"Settings", @5019:@"Settings", @2004:@1};
    VPAxFunctions f = {.copy=copyAttribute,.elementTypeID=CFDictionaryGetTypeID,.valueTypeID=valueType,.getValue=getValue,.getPid=getPID};
    for (int degrees = 0; degrees < 360; degrees += 90) {
        NSDictionary *result = vp_ax_display_hit_for_functions(f, AXDisplayHitFixture.class, 123, 7, 60, 80, 669, 951, degrees);
        assert(!result[@"error"] && [result[@"element"][@"identifier"] isEqual:@"Settings"]);
        assert(receivedDisplay == 7);
        CGPoint expected = degrees == 90 ? CGPointMake(80,891) : degrees == 180 ? CGPointMake(609,871)
                         : degrees == 270 ? CGPointMake(589,60) : CGPointMake(60,80);
        assert(CGPointEqualToPoint(receivedPoint,expected));
        assert([result[@"element"][@"x"] doubleValue] == 30 && [result[@"element"][@"y"] doubleValue] == 45);
    }
    returnedPID = 456;
    assert(vp_ax_display_hit_for_functions(f, AXDisplayHitFixture.class,123,7,60,80,669,951,0)[@"error"]);
    returnedPID = 123; emptyHit = YES;
    assert([vp_ax_display_hit_for_functions(f, AXDisplayHitFixture.class,123,7,60,80,669,951,0)[@"element"] count] == 0);
    assert(vp_ax_display_hit_for_functions(f, AXDisplayHitFixture.class,123,7,700,80,669,951,0)[@"error"]);
    assert(vp_ax_display_hit_for_functions(f, AXDisplayHitFixture.class,123,7,NAN,80,669,951,0)[@"error"]);
    assert(vp_ax_display_hit_for_functions(f, AXWrongDisplayHitFixture.class,123,7,60,80,669,951,0)[@"error"]);
    puts("AX display hit: display identity, rotations, PID admission, empty hit, ABI and finite geometry passed");
} }
