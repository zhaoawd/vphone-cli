#import "vphoned_location.h"
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <string.h>

static id gSimManager = nil;
static SEL gSetLocationSel = NULL;
static SEL gClearLocationsSel = NULL;
static SEL gFlushSel = NULL;
static SEL gStartSimSel = NULL;
static BOOL gLocationLoaded = NO;
static NSString *gOwnedGeneration = nil;
static NSString *gLastClearedGeneration = nil;
static NSInteger gLastDeliverySequence = -1;
static BOOL gHasOwnedDelivery = NO;

typedef struct {
    double lat;
    double lon;
    double alt;
    double hacc;
    double vacc;
    double speed;
    double course;
    double timestamp;
} VPLocationFrame;

static VPLocationFrame gLastOwnedFrame;

static NSObject *vp_location_state_lock(void) {
    static NSObject *lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static void vp_location_reset_owner(void) {
    gOwnedGeneration = nil;
    gLastDeliverySequence = -1;
    gHasOwnedDelivery = NO;
    memset(&gLastOwnedFrame, 0, sizeof(gLastOwnedFrame));
}

static BOOL vp_location_frame_equal(VPLocationFrame lhs, VPLocationFrame rhs) {
    return lhs.lat == rhs.lat && lhs.lon == rhs.lon && lhs.alt == rhs.alt &&
           lhs.hacc == rhs.hacc && lhs.vacc == rhs.vacc &&
           lhs.speed == rhs.speed && lhs.course == rhs.course &&
           lhs.timestamp == rhs.timestamp;
}

BOOL vp_location_load(void) {
    void *h = dlopen("/System/Library/Frameworks/CoreLocation.framework/CoreLocation", RTLD_NOW);
    if (!h) { NSLog(@"vphoned: dlopen CoreLocation failed"); return NO; }

    Class cls = NSClassFromString(@"CLSimulationManager");
    if (!cls) { NSLog(@"vphoned: CLSimulationManager not found"); return NO; }

    gSimManager = [[cls alloc] init];
    if (!gSimManager) { NSLog(@"vphoned: CLSimulationManager alloc/init failed"); return NO; }

    // Probe available selectors for setting location
    SEL candidates[] = {
        NSSelectorFromString(@"setSimulatedLocation:"),
        NSSelectorFromString(@"appendSimulatedLocation:"),
        NSSelectorFromString(@"setLocation:"),
    };
    for (int i = 0; i < 3; i++) {
        if ([gSimManager respondsToSelector:candidates[i]]) {
            gSetLocationSel = candidates[i];
            break;
        }
    }
    if (!gSetLocationSel) {
        NSLog(@"vphoned: no set-location selector found, dumping methods:");
        unsigned int count = 0;
        Method *methods = class_copyMethodList([gSimManager class], &count);
        for (unsigned int i = 0; i < count; i++) {
            NSLog(@"  %s", sel_getName(method_getName(methods[i])));
        }
        free(methods);
        return NO;
    }

    // Probe clear selector
    SEL clearCandidates[] = {
        NSSelectorFromString(@"clearSimulatedLocations"),
        NSSelectorFromString(@"stopLocationSimulation"),
    };
    for (int i = 0; i < 2; i++) {
        if ([gSimManager respondsToSelector:clearCandidates[i]]) {
            gClearLocationsSel = clearCandidates[i];
            break;
        }
    }

    // Probe flush selector
    SEL flushCandidates[] = {
        NSSelectorFromString(@"flush"),
        NSSelectorFromString(@"flushSimulatedLocations"),
    };
    for (int i = 0; i < 2; i++) {
        if ([gSimManager respondsToSelector:flushCandidates[i]]) {
            gFlushSel = flushCandidates[i];
            break;
        }
    }

    // Probe startLocationSimulation selector
    SEL startCandidates[] = {
        NSSelectorFromString(@"startLocationSimulation"),
        NSSelectorFromString(@"startSimulation"),
    };
    for (int i = 0; i < 2; i++) {
        if ([gSimManager respondsToSelector:startCandidates[i]]) {
            gStartSimSel = startCandidates[i];
            break;
        }
    }

    // Start simulation session if available
    if (gStartSimSel) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [gSimManager performSelector:gStartSimSel];
#pragma clang diagnostic pop
    }

    NSLog(@"vphoned: CoreLocation simulation loaded (set=%s, clear=%s, flush=%s, start=%s)",
          sel_getName(gSetLocationSel),
          gClearLocationsSel ? sel_getName(gClearLocationsSel) : "(none)",
          gFlushSel ? sel_getName(gFlushSel) : "(none)",
          gStartSimSel ? sel_getName(gStartSimSel) : "(none)");
    gLocationLoaded = YES;
    return YES;
}

BOOL vp_location_available(void) {
    return gLocationLoaded;
}

static BOOL vp_location_simulate_raw(double lat, double lon, double alt,
                                     double hacc, double vacc,
                                     double speed, double course) {
    if (!gLocationLoaded || !gSimManager || !gSetLocationSel) return NO;

    @try {
        typedef struct { double latitude; double longitude; } CLCoord2D;
        CLCoord2D coord = {lat, lon};

        Class locClass = NSClassFromString(@"CLLocation");
        id locInst = [locClass alloc];

        // Try full init including speed and course
        SEL initSel = NSSelectorFromString(
            @"initWithCoordinate:altitude:horizontalAccuracy:verticalAccuracy:course:speed:timestamp:");
        if (![locInst respondsToSelector:initSel]) {
            // Fallback to simpler init
            initSel = NSSelectorFromString(
                @"initWithCoordinate:altitude:horizontalAccuracy:verticalAccuracy:timestamp:");
            typedef id (*InitFunc5)(id, SEL, CLCoord2D, double, double, double, id);
            id location = ((InitFunc5)objc_msgSend)(locInst, initSel, coord, alt, hacc, vacc, [NSDate date]);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [gSimManager performSelector:gSetLocationSel withObject:location];
            if (gFlushSel) [gSimManager performSelector:gFlushSel];
#pragma clang diagnostic pop

            NSLog(@"vphoned: simulate_location lat=%.6f lon=%.6f (fallback init)", lat, lon);
            return YES;
        }

        typedef id (*InitFunc7)(id, SEL, CLCoord2D, double, double, double, double, double, id);
        id location = ((InitFunc7)objc_msgSend)(locInst, initSel, coord, alt, hacc, vacc, course, speed, [NSDate date]);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [gSimManager performSelector:gSetLocationSel withObject:location];
        if (gFlushSel) [gSimManager performSelector:gFlushSel];
#pragma clang diagnostic pop

        NSLog(@"vphoned: simulate_location lat=%.6f lon=%.6f alt=%.1f spd=%.1f crs=%.1f",
              lat, lon, alt, speed, course);
        return YES;
    } @catch (NSException *e) {
        NSLog(@"vphoned: simulate_location exception: %@", e);
        return NO;
    }
}

static BOOL vp_location_clear_raw(void) {
    if (!gLocationLoaded || !gSimManager) return NO;
    // A clear selector is not required for the "location" capability, so its
    // absence is a real failure the caller must see (not a silent no-op).
    if (!gClearLocationsSel) {
        NSLog(@"vphoned: clear_simulated_location: no clear selector available");
        return NO;
    }
    @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [gSimManager performSelector:gClearLocationsSel];
#pragma clang diagnostic pop
        NSLog(@"vphoned: cleared simulated location");
        return YES;
    } @catch (NSException *e) {
        NSLog(@"vphoned: clear_simulated_location exception: %@", e);
        return NO;
    }
}

VPLocationProtocolResult vp_location_begin(NSString *generation) {
    if (!gLocationLoaded) return VPLocationProtocolUnavailable;
    if (![generation isKindOfClass:[NSString class]] || generation.length == 0)
        return VPLocationProtocolInvalid;
    @synchronized(vp_location_state_lock()) {
        gOwnedGeneration = [generation copy];
        gLastClearedGeneration = nil;
        gLastDeliverySequence = -1;
        gHasOwnedDelivery = NO;
        memset(&gLastOwnedFrame, 0, sizeof(gLastOwnedFrame));
    }
    return VPLocationProtocolOK;
}

VPLocationProtocolResult vp_location_simulate_owned(
    NSString *generation, NSInteger deliverySequence,
    double lat, double lon, double alt,
    double hacc, double vacc,
    double speed, double course, double timestamp,
    BOOL *idempotent) {
    if (idempotent) *idempotent = NO;
    if (!gLocationLoaded) return VPLocationProtocolUnavailable;
    if (![generation isKindOfClass:[NSString class]] || generation.length == 0 ||
        deliverySequence < 0)
        return VPLocationProtocolInvalid;

    VPLocationFrame frame = {
        lat, lon, alt, hacc, vacc, speed, course, timestamp,
    };
    @synchronized(vp_location_state_lock()) {
        if (![gOwnedGeneration isEqualToString:generation])
            return VPLocationProtocolGenerationConflict;
        if (gHasOwnedDelivery) {
            if (deliverySequence == gLastDeliverySequence) {
                if (!vp_location_frame_equal(frame, gLastOwnedFrame))
                    return VPLocationProtocolSequenceConflict;
                if (idempotent) *idempotent = YES;
                return VPLocationProtocolOK;
            }
            if (deliverySequence != gLastDeliverySequence + 1)
                return VPLocationProtocolSequenceConflict;
        }
        if (!vp_location_simulate_raw(lat, lon, alt, hacc, vacc, speed, course))
            return VPLocationProtocolUnavailable;
        gLastOwnedFrame = frame;
        gLastDeliverySequence = deliverySequence;
        gHasOwnedDelivery = YES;
        return VPLocationProtocolOK;
    }
}

VPLocationProtocolResult vp_location_clear_owned(
    NSString *generation, BOOL *idempotent) {
    if (idempotent) *idempotent = NO;
    if (!gLocationLoaded) return VPLocationProtocolUnavailable;
    if (![generation isKindOfClass:[NSString class]] || generation.length == 0)
        return VPLocationProtocolInvalid;
    @synchronized(vp_location_state_lock()) {
        if (!gOwnedGeneration) {
            if ([gLastClearedGeneration isEqualToString:generation]) {
                if (idempotent) *idempotent = YES;
                return VPLocationProtocolOK;
            }
            return VPLocationProtocolGenerationConflict;
        }
        if (![gOwnedGeneration isEqualToString:generation])
            return VPLocationProtocolGenerationConflict;
        if (!vp_location_clear_raw()) return VPLocationProtocolUnavailable;
        gLastClearedGeneration = [generation copy];
        vp_location_reset_owner();
        return VPLocationProtocolOK;
    }
}

BOOL vp_location_simulate(double lat, double lon, double alt,
                          double hacc, double vacc,
                          double speed, double course) {
    @synchronized(vp_location_state_lock()) {
        vp_location_reset_owner();
        gLastClearedGeneration = nil;
        return vp_location_simulate_raw(lat, lon, alt, hacc, vacc, speed, course);
    }
}

BOOL vp_location_clear(void) {
    @synchronized(vp_location_state_lock()) {
        vp_location_reset_owner();
        gLastClearedGeneration = nil;
        return vp_location_clear_raw();
    }
}
