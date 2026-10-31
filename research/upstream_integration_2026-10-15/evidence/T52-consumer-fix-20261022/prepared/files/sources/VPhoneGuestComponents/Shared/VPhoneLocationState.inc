#import <Foundation/Foundation.h>
#include "VPhoneLocationState.h"
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef VPHONE_LOCATION_STATE_UID
#define VPHONE_LOCATION_STATE_UID 0
#endif

static NSDictionary *vphoneReadLocationState(void) {
    int fd = open(VPHONE_LOCATION_STATE_PATH, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return nil;
    struct stat st;
    if (fstat(fd, &st) < 0 || !S_ISREG(st.st_mode) || st.st_nlink != 1 ||
        st.st_uid != VPHONE_LOCATION_STATE_UID || (st.st_mode & 0022) ||
        st.st_size <= 0 || st.st_size > VPHONE_LOCATION_STATE_MAX_BYTES) { close(fd); return nil; }
    char buffer[VPHONE_LOCATION_STATE_MAX_BYTES];
    size_t length = 0;
    while (length < (size_t)st.st_size) {
        ssize_t count = read(fd, buffer + length, (size_t)st.st_size - length);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { close(fd); return nil; }
        length += (size_t)count;
    }
    close(fd);
    NSDictionary *state = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:buffer length:length] options:0 error:NULL];
    if (![state isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *field in @[@"latitude", @"longitude", @"altitude", @"horizontal_accuracy", @"vertical_accuracy", @"speed", @"course", @"published_at", @"delivery_sequence"]) {
        id value = state[field];
        if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ||
            !isfinite([value doubleValue])) return nil;
    }
    NSString *generation = state[@"generation"];
    if (![generation isKindOfClass:NSString.class] || generation.length == 0 || generation.length > 79 ||
        [state[@"delivery_sequence"] doubleValue] < 0 ||
        [state[@"delivery_sequence"] doubleValue] != [state[@"delivery_sequence"] longLongValue]) return nil;
    double age = [NSDate.date timeIntervalSince1970] - [state[@"published_at"] doubleValue];
    double vertical = [state[@"vertical_accuracy"] doubleValue];
    if (fabs([state[@"latitude"] doubleValue]) > 90 || fabs([state[@"longitude"] doubleValue]) > 180 ||
        [state[@"horizontal_accuracy"] doubleValue] < 0 || (vertical < 0 && vertical != -1) ||
        age < -1 || age > VPHONE_LOCATION_STATE_MAX_AGE_SECONDS) return nil;
    return state;
}
