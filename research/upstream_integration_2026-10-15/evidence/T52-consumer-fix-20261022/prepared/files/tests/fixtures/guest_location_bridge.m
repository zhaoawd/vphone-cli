#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct { double latitude; double longitude; } TestCoordinate;
@interface CLLocation : NSObject
- (instancetype)initWithCoordinate:(TestCoordinate)c altitude:(double)a horizontalAccuracy:(double)h verticalAccuracy:(double)v course:(double)course speed:(double)s timestamp:(NSDate *)date;
@end
@implementation CLLocation
- (instancetype)initWithCoordinate:(TestCoordinate)c altitude:(double)a horizontalAccuracy:(double)h verticalAccuracy:(double)v course:(double)course speed:(double)s timestamp:(NSDate *)date {
    (void)c; (void)a; (void)h; (void)v; (void)course; (void)s; (void)date;
    return [super init];
}
@end

@interface TestSimulation : NSObject
- (void)setSimulatedLocation:(id)location;
- (void)clearSimulatedLocations;
- (void)startLocationSimulation;
@end
@implementation TestSimulation
- (void)setSimulatedLocation:(id)location { (void)location; }
- (void)clearSimulatedLocations {}
- (void)startLocationSimulation {}
@end

static char test_directory[4096], test_path[4096];
#define VPHONE_LOCATION_STATE_DIRECTORY test_directory
#define VPHONE_LOCATION_STATE_PATH test_path
#include "../../scripts/vphoned/vphoned_location.m"
#define VPHONE_LOCATION_STATE_UID geteuid()
#include "../../sources/VPhoneGuestComponents/Shared/VPhoneLocationState.inc"

#define CHECK(value) do { if (!(value)) { fprintf(stderr, "check failed at %d: %s\n", __LINE__, #value); return 1; } } while (0)

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) return 64;
        snprintf(test_directory, sizeof(test_directory), "%s/SimulatedLocation", argv[1]);
        snprintf(test_path, sizeof(test_path), "%s/location.json", test_directory);
        setenv("VPHONED_LOCATION_LAYOUT", strcmp(argv[2], "native") == 0 ? "native" : "v2", 1);
        gSimManager = [TestSimulation new]; gLocationLoaded = YES;
        gSetLocationSel = @selector(setSimulatedLocation:);
        gClearLocationsSel = @selector(clearSimulatedLocations);
        gStartSimSel = @selector(startLocationSimulation);
        CHECK(vp_location_begin(@"owner") == VPLocationProtocolOK);
        BOOL idempotent = NO;
        CHECK(vp_location_simulate_owned(@"owner", 0, 31.2, 121.5, 20, 5, 6, 2, 90, 100, &idempotent) == VPLocationProtocolOK);
        if (strcmp(argv[2], "native") == 0) { CHECK(access(test_path, F_OK) != 0); return 0; }
        NSData *first = [NSData dataWithContentsOfFile:@(test_path)];
        CHECK(first.length > 0);
        NSDictionary *point = [NSJSONSerialization JSONObjectWithData:first options:0 error:NULL];
        CHECK([point[@"generation"] isEqual:@"owner"] && [point[@"delivery_sequence"] integerValue] == 0);
        CHECK([point[@"latitude"] doubleValue] == 31.2 && [point[@"longitude"] doubleValue] == 121.5);
        CHECK([point[@"altitude"] doubleValue] == 20 && [point[@"horizontal_accuracy"] doubleValue] == 5);
        CHECK([point[@"vertical_accuracy"] doubleValue] == 6 && [point[@"speed"] doubleValue] == 2 && [point[@"course"] doubleValue] == 90);
        CHECK([vphoneReadLocationState()[@"generation"] isEqual:@"owner"]);
        if (strcmp(argv[2], "refresh") == 0) {
            [NSThread sleepForTimeInterval:VPHONE_LOCATION_STATE_MAX_AGE_SECONDS + 1.2];
            NSDictionary *current = vphoneReadLocationState();
            CHECK([current[@"generation"] isEqual:@"owner"]);
            CHECK([current[@"delivery_sequence"] integerValue] == 0);
            CHECK([current[@"latitude"] doubleValue] == 31.2);
            CHECK(vp_location_clear_owned(@"owner", NULL) == VPLocationProtocolOK);
            [NSThread sleepForTimeInterval:1.2];
            CHECK(access(test_path, F_OK) != 0);
            return 0;
        }
        CHECK(vp_location_simulate_owned(@"other", 1, 0, 0, 0, 5, 6, 2, 90, 101, NULL) == VPLocationProtocolGenerationConflict);
        CHECK(vp_location_simulate_owned(@"owner", 2, 0, 0, 0, 5, 6, 2, 90, 101, NULL) == VPLocationProtocolSequenceConflict);
        CHECK(vp_location_simulate_owned(@"owner", 0, 31.2, 121.5, 20, 5, 6, 2, 90, 100, &idempotent) == VPLocationProtocolOK && idempotent);
        CHECK([[NSData dataWithContentsOfFile:@(test_path)] isEqual:first]);
        CHECK(vp_location_clear_owned(@"other", NULL) == VPLocationProtocolGenerationConflict);
        CHECK([[NSData dataWithContentsOfFile:@(test_path)] isEqual:first]);
        CHECK(vp_location_simulate_owned(@"owner", 1, 30.25, 120.15, 35, 5, 6, 2, 90, 101, NULL) == VPLocationProtocolOK);
        point = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(test_path)] options:0 error:NULL];
        CHECK([point[@"delivery_sequence"] integerValue] == 1 && [point[@"latitude"] doubleValue] == 30.25);
        CHECK([vphoneReadLocationState()[@"latitude"] doubleValue] == 30.25);
        if (strcmp(argv[2], "reader") == 0) {
            NSData *valid = [NSData dataWithContentsOfFile:@(test_path)];
            for (NSDictionary *change in @[@{@"published_at": @0}, @{@"latitude": @91}, @{@"longitude": @181},
                                          @{@"generation": @""}, @{@"delivery_sequence": @(-1)}, @{@"latitude": @YES}]) {
                NSMutableDictionary *invalid = [point mutableCopy]; [invalid addEntriesFromDictionary:change];
                CHECK([[NSJSONSerialization dataWithJSONObject:invalid options:0 error:NULL] writeToFile:@(test_path) atomically:YES]);
                CHECK(vphoneReadLocationState() == nil);
            }
            CHECK([valid writeToFile:@(test_path) atomically:YES]);
            CHECK(vphoneReadLocationState() != nil);
        }
        CHECK(vp_location_clear_owned(@"owner", &idempotent) == VPLocationProtocolOK && !idempotent);
        CHECK(access(test_path, F_OK) != 0);
        CHECK(vphoneReadLocationState() == nil);
        CHECK(vp_location_clear_owned(@"owner", &idempotent) == VPLocationProtocolOK && idempotent);
        return 0;
    }
}
