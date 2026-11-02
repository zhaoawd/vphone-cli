#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <assert.h>
#include <math.h>
#import "../Native/vphoned_ax_hierarchy.h"

struct __AXUIElement;
extern NSDictionary *vp_element_tap_context_for_functions(VPAxFunctions, Class, int, NSDictionary *);
static NSArray *nodes;
static int queryError, sends;
static BOOL accepts = YES;
static CGPoint received;

@interface TapContextTest : NSObject
+ (instancetype)elementWithAXUIElement:(struct __AXUIElement *)element;
- (BOOL)simulateTapWithFingerIndex:(NSUInteger)index withPoint:(CGPoint)point;
@end

@interface TapWrongFactoryTest : NSObject
+ (instancetype)elementWithAXUIElement:(id)element;
- (BOOL)simulateTapWithFingerIndex:(NSUInteger)index withPoint:(CGPoint)point;
@end
@implementation TapWrongFactoryTest
+ (instancetype)elementWithAXUIElement:(id)element { return [self new]; }
- (BOOL)simulateTapWithFingerIndex:(NSUInteger)index withPoint:(CGPoint)point { sends++; return YES; }
@end
@implementation TapContextTest
+ (instancetype)elementWithAXUIElement:(struct __AXUIElement *)element { return [self new]; }
- (BOOL)simulateTapWithFingerIndex:(NSUInteger)index withPoint:(CGPoint)point {
    assert(index == 0); sends++; received = point; return accepts;
}
@end

static CFTypeRef create(pid_t pid) { return CFRetain(CFSTR("root")); }
static int copy(CFTypeRef element, CFStringRef key, CFTypeRef *value) {
    id result = nil;
    switch ((uintptr_t)key) {
        case 3015: result = nodes; break;
        case 2003: result = ((__bridge NSDictionary *)element)[@"frame"]; break;
        case 2001: result = ((__bridge NSDictionary *)element)[@"label"]; break;
        case 5019: result = ((__bridge NSDictionary *)element)[@"identifier"]; break;
        default: assert(false);
    }
    *value = CFBridgingRetain(result);
    return queryError;
}
static CFTypeID valueType(void) {
    return CFGetTypeID((__bridge CFTypeRef)[NSValue valueWithBytes:&(CGRect){{0,0},{1,1}} objCType:@encode(CGRect)]);
}
static Boolean getValue(CFTypeRef value, int type, void *out) {
    assert(type == 3); [(__bridge NSValue *)value getValue:out size:sizeof(CGRect)]; return true;
}
static NSDictionary *node(int identity, CGRect frame) {
    return @{@"uid": @(identity), @"frame": [NSValue valueWithBytes:&frame objCType:@encode(CGRect)],
             @"label": @"Target", @"identifier": @"target"};
}
int main(void) { @autoreleasepool {
    VPAxFunctions f = {.createApp=create, .copy=copy, .elementTypeID=CFDictionaryGetTypeID,
                       .valueTypeID=valueType, .getValue=getValue};
    NSDictionary *selected = @{@"x": @12.0, @"y": @23.0, @"label": @"Target", @"identifier": @"target",
        @"frame": @{@"x": @2.0, @"y": @3.0, @"width": @20.0, @"height": @40.0}};
    CGRect frame = {{2,3},{20,40}};
    NSDictionary *target = node(1, frame);
    nodes = @[node(2, CGRectMake(100,100,20,40)), target];
    assert([vp_element_tap_context_for_functions(f, TapContextTest.class, 123, selected)[@"tapped"] boolValue]);
    assert(sends == 1 && received.x == 12 && received.y == 23);
    sends = 0;
    nodes = @[target, target];
    assert([vp_element_tap_context_for_functions(f, TapContextTest.class, 123, selected)[@"tapped"] boolValue]);
    assert(sends == 1);
    sends = 0;
    nodes = @[target, node(3, frame)];
    assert(vp_element_tap_context_for_functions(f, TapContextTest.class, 123, selected)[@"error"] && sends == 0);
    nodes = @[node(4, CGRectMake(20,3,20,40))];
    assert(vp_element_tap_context_for_functions(f, TapContextTest.class, 123, selected)[@"error"] && sends == 0);
    nodes = @[node(5, CGRectMake(NAN,3,20,40))];
    assert(vp_element_tap_context_for_functions(f, TapContextTest.class, 123, selected)[@"error"] && sends == 0);
    nodes = @[target];
    NSMutableDictionary *other = [target mutableCopy]; other[@"identifier"] = @"other";
    nodes = @[other];
    assert(vp_element_tap_context_for_functions(f, TapContextTest.class, 123, selected)[@"error"] && sends == 0);
    other[@"identifier"] = @"target"; other[@"label"] = @"Other";
    assert(vp_element_tap_context_for_functions(f, TapContextTest.class, 123, selected)[@"error"] && sends == 0);
    nodes = @[target];
    queryError = -25212;
    assert(vp_element_tap_context_for_functions(f, TapContextTest.class, 123, selected)[@"error"] && sends == 0);
    queryError = 0;
    assert(vp_element_tap_context_for_functions(f, NSObject.class, 123, selected)[@"error"] && sends == 0);
    assert(vp_element_tap_context_for_functions(f, TapWrongFactoryTest.class, 123, selected)[@"error"] && sends == 0);
    assert(vp_element_tap_context_for_functions(f, TapContextTest.class, 0, selected)[@"error"] && sends == 0);
    NSMutableDictionary *invalid = [selected mutableCopy]; invalid[@"x"] = @(NAN);
    assert(vp_element_tap_context_for_functions(f, TapContextTest.class, 123, invalid)[@"error"] && sends == 0);
    accepts = NO;
    assert(vp_element_tap_context_for_functions(f, TapContextTest.class, 123, selected)[@"error"] && sends == 1);
    puts("element tap AX context: ABI, identity, duplicate, geometry and send-failure checks passed");
} }
