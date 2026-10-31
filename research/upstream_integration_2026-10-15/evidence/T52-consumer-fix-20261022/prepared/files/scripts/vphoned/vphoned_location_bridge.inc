// MARK: - generation-owned app-side location state

#include "../../sources/VPhoneGuestComponents/Shared/VPhoneLocationState.h"
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef VPHONED_DEFAULT_LOCATION_LAYOUT
#define VPHONED_DEFAULT_LOCATION_LAYOUT "native"
#endif

static int vp_location_layout(void) {
    const char *layout = getenv("VPHONED_LOCATION_LAYOUT");
    if (!layout) layout = VPHONED_DEFAULT_LOCATION_LAYOUT;
    if (strcmp(layout, "native") == 0) return 0;
    if (strcmp(layout, "v2") == 0) return 1;
    return -1;
}

static int vp_location_bridge_directory(void) {
    if (mkdir(VPHONE_LOCATION_STATE_DIRECTORY, 0755) < 0 && errno != EEXIST) return -1;
    int fd = open(VPHONE_LOCATION_STATE_DIRECTORY, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) < 0 || !S_ISDIR(st.st_mode) || st.st_uid != geteuid() || (st.st_mode & 0022)) {
        close(fd); errno = EPERM; return -1;
    }
    return fd;
}

static BOOL vp_location_bridge_target_valid(int directory) {
    struct stat st;
    if (fstatat(directory, "location.json", &st, AT_SYMLINK_NOFOLLOW) < 0) return errno == ENOENT;
    return S_ISREG(st.st_mode) && st.st_uid == geteuid() && st.st_nlink == 1;
}

static BOOL vp_location_bridge_write(NSString *generation, NSInteger sequence, VPLocationFrame point) {
    NSDictionary *state = @{@"generation": generation, @"delivery_sequence": @(sequence),
        @"published_at": @([NSDate.date timeIntervalSince1970]),
        @"latitude": @(point.lat), @"longitude": @(point.lon), @"altitude": @(point.alt),
        @"horizontal_accuracy": @(point.hacc), @"vertical_accuracy": @(point.vacc),
        @"speed": @(point.speed), @"course": @(point.course)};
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:0 error:NULL];
    if (!data || data.length > VPHONE_LOCATION_STATE_MAX_BYTES) return NO;
    int directory = vp_location_bridge_directory();
    if (directory < 0) return NO;
    NSString *temporary = [@".location-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int fd = -1;
    BOOL success = NO;
    if (!vp_location_bridge_target_valid(directory)) goto done;
    fd = openat(directory, temporary.UTF8String, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (fd < 0) goto done;
    for (size_t written = 0; written < data.length;) {
        ssize_t count = write(fd, (const uint8_t *)data.bytes + written, data.length - written);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) goto done;
        written += (size_t)count;
    }
    if (fchmod(fd, 0644) < 0 || fsync(fd) < 0 || !vp_location_bridge_target_valid(directory)) goto done;
    if (renameat(directory, temporary.UTF8String, directory, "location.json") < 0) goto done;
    success = YES;
done:
    if (fd >= 0) close(fd);
    unlinkat(directory, temporary.UTF8String, 0);
    close(directory);
    return success;
}

static dispatch_source_t gLocationBridgeTimer;
static NSString *gLocationBridgeGeneration;
static NSInteger gLocationBridgeSequence;
static VPLocationFrame gLocationBridgeFrame;

static void vp_location_bridge_stop_refresh(void) {
    if (gLocationBridgeTimer) dispatch_source_cancel(gLocationBridgeTimer);
    gLocationBridgeTimer = nil;
    gLocationBridgeGeneration = nil;
}

static BOOL vp_location_bridge_still_owned(void) {
    int directory = vp_location_bridge_directory();
    if (directory < 0) return NO;
    int fd = openat(directory, "location.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    close(directory);
    if (fd < 0) return NO;
    struct stat st;
    char bytes[VPHONE_LOCATION_STATE_MAX_BYTES];
    BOOL valid = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == geteuid() &&
        st.st_nlink == 1 && st.st_size > 0 && st.st_size <= sizeof(bytes);
    ssize_t count = valid ? read(fd, bytes, sizeof(bytes)) : -1;
    close(fd);
    if (!valid || count != st.st_size) return NO;
    NSDictionary *state = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:(NSUInteger)count] options:0 error:NULL];
    return [state isKindOfClass:NSDictionary.class] &&
        [state[@"generation"] isEqual:gLocationBridgeGeneration] &&
        [state[@"delivery_sequence"] isKindOfClass:NSNumber.class] &&
        [state[@"delivery_sequence"] integerValue] == gLocationBridgeSequence;
}

static BOOL vp_location_bridge_set(NSString *generation, NSInteger sequence, VPLocationFrame point) {
    if (!vp_location_bridge_write(generation, sequence, point)) return NO;
    gLocationBridgeGeneration = [generation copy];
    gLocationBridgeSequence = sequence;
    gLocationBridgeFrame = point;
    if (!gLocationBridgeTimer) {
        gLocationBridgeTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(gLocationBridgeTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                                  NSEC_PER_SEC, NSEC_PER_MSEC * 100);
        dispatch_source_set_event_handler(gLocationBridgeTimer, ^{
            @synchronized(vp_location_state_lock()) {
                if (!gLocationBridgeGeneration) return;
                if (!vp_location_bridge_still_owned()) { vp_location_bridge_stop_refresh(); return; }
                vp_location_bridge_write(gLocationBridgeGeneration, gLocationBridgeSequence, gLocationBridgeFrame);
            }
        });
        dispatch_resume(gLocationBridgeTimer);
    }
    return YES;
}

static BOOL vp_location_bridge_clear(NSString *generation) {
    int directory = vp_location_bridge_directory();
    if (directory < 0) return NO;
    int fd = openat(directory, "location.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        BOOL absent = errno == ENOENT;
        if (absent) vp_location_bridge_stop_refresh();
        close(directory); return absent;
    }
    BOOL success = NO;
    struct stat st;
    if (fstat(fd, &st) < 0 || !S_ISREG(st.st_mode) || st.st_uid != geteuid() || st.st_nlink != 1 ||
        st.st_size <= 0 || st.st_size > VPHONE_LOCATION_STATE_MAX_BYTES) goto done;
    if (generation) {
        char bytes[VPHONE_LOCATION_STATE_MAX_BYTES];
        ssize_t count = read(fd, bytes, sizeof(bytes));
        if (count != st.st_size) goto done;
        NSDictionary *state = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:(NSUInteger)count] options:0 error:NULL];
        if (![state isKindOfClass:NSDictionary.class] || ![state[@"generation"] isEqual:generation]) goto done;
    }
    // Directory writes are restricted to this daemon's uid. Check the inode
    // again so an atomic update by another root producer is preserved.
    struct stat current;
    if (fstatat(directory, "location.json", &current, AT_SYMLINK_NOFOLLOW) < 0 ||
        current.st_dev != st.st_dev || current.st_ino != st.st_ino) goto done;
    success = unlinkat(directory, "location.json", 0) == 0;
    if (success) vp_location_bridge_stop_refresh();
done:
    close(fd); close(directory);
    return success;
}
