#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
#include <errno.h>
#include <assert.h>
#include <stdatomic.h>

// Exercise the production framing implementation through short syscalls and
// deterministic EINTR; the data still crosses real stream sockets.
static atomic_int readCalls;
static atomic_int writeCalls;
static ssize_t interruptedRead(int fd, void *buf, size_t count) {
    if (atomic_fetch_add(&readCalls, 1) % 19 == 0) { errno = EINTR; return -1; }
    return read(fd, buf, MIN(count, 997));
}
static ssize_t interruptedWrite(int fd, const void *buf, size_t count) {
    if (atomic_fetch_add(&writeCalls, 1) % 19 == 0) { errno = EINTR; return -1; }
    return write(fd, buf, MIN(count, 991));
}
#define read interruptedRead
#define write interruptedWrite
#import "../../scripts/vphoned/vphoned_protocol.m"
#undef read
#undef write

int main(int argc, char **argv) {
    @autoreleasepool {
        alarm(15);
        int fds[2]; assert(socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0);
        for (int i = 0; i < 2; i++) { int one = 1; setsockopt(fds[i], SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)); }
        if (argc > 1 && strcmp(argv[1], "oversize") == 0) {
            NSString *large = [@"x" stringByPaddingToLength:4 * 1024 * 1024 withString:@"x" startingAtIndex:0];
            int reader = fds[1];
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                char buffer[8192]; while (read(reader, buffer, sizeof(buffer)) > 0) {}
            });
            assert(!vp_write_message(fds[0], @{@"v": @1, @"t": @"version", @"hash": large}));
            shutdown(fds[0], SHUT_RDWR); shutdown(fds[1], SHUT_RDWR);
            return 0;
        }
        if (argc > 1 && strcmp(argv[1], "boundary") == 0) {
            NSMutableDictionary *message = [@{@"v": @1, @"t": @"version", @"hash": @""} mutableCopy];
            NSUInteger overhead = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil].length;
            message[@"hash"] = [@"x" stringByPaddingToLength:4 * 1024 * 1024 - overhead withString:@"x" startingAtIndex:0];
            assert([NSJSONSerialization dataWithJSONObject:message options:0 error:nil].length == 4 * 1024 * 1024);
            int writer = fds[0];
            dispatch_group_t group = dispatch_group_create();
            dispatch_group_async(group, dispatch_get_global_queue(0, 0), ^{ assert(vp_write_message(writer, message)); });
            assert([vp_read_message(fds[1]) isEqual:message]);
            dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
            uint32_t bad[] = {0, htonl(4 * 1024 * 1024 + 1), htonl(UINT32_MAX)};
            for (int i = 0; i < 3; i++) {
                assert(vp_write_fully(fds[0], &bad[i], 4));
                assert(vp_read_message(fds[1]) == nil);
            }
            close(fds[0]); close(fds[1]);
            return 0;
        }
        if (argc > 1 && strcmp(argv[1], "concurrent") == 0) {
            int writer = fds[0];
            dispatch_group_t group = dispatch_group_create();
            for (int i = 0; i < 12; i++) {
                dispatch_group_async(group, dispatch_get_global_queue(0, 0), ^{
                    @autoreleasepool {
                        NSMutableData *payload = [NSMutableData dataWithLength:8192];
                        memset(payload.mutableBytes, i, payload.length);
                        NSMutableDictionary *header = vp_make_response(@"file_data", @(i));
                        header[@"size"] = @(payload.length);
                        assert(vp_write_with_payload(writer, header, payload.bytes, payload.length));
                    }
                });
            }
            NSMutableSet *ids = [NSMutableSet set];
            for (int i = 0; i < 12; i++) {
                NSDictionary *header = vp_read_message(fds[1]);
                assert([header[@"v"] intValue] == 1 && [header[@"t"] isEqual:@"file_data"]);
                assert(![ids containsObject:header[@"id"]]); [ids addObject:header[@"id"]];
                unsigned char payload[8192];
                assert([header[@"size"] intValue] == sizeof(payload));
                assert(vp_read_fully(fds[1], payload, sizeof(payload)));
                for (int j = 0; j < sizeof(payload); j++) assert(payload[j] == [header[@"id"] intValue]);
            }
            dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
            close(fds[0]); close(fds[1]);
            return 0;
        }
        NSString *text = [@"x" stringByPaddingToLength:16384 withString:@"x" startingAtIndex:0];
        NSDictionary *message = @{@"v": @1, @"t": @"version", @"id": @"abcd", @"hash": text};
        int writer = fds[0];
        dispatch_group_t group = dispatch_group_create();
        dispatch_group_async(group, dispatch_get_global_queue(0, 0), ^{
            assert(vp_write_message(writer, message));
        });
        NSDictionary *received = vp_read_message(fds[1]);
        assert([received isEqual:message]);
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        close(fds[0]); close(fds[1]);
    }
    return 0;
}
