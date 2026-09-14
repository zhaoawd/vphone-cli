// Exercise the production publisher/status implementation with disposable mmap files.
#import <Foundation/Foundation.h>
#include <assert.h>
static char frame_path[4096], observe_path[4096];
#define VPHONED_VCAM_SHM_PATH frame_path
#define VPHONED_VCAM_OBSERVE_SHM_PATH observe_path
#include "../../scripts/vphoned/vphoned_vcam.m"

NSMutableDictionary *vp_make_response(NSString *type, id reqId) {
    return [@{@"t": type, @"id": reqId ?: @0} mutableCopy];
}

static const uint8_t presentation_id[16] = {1};
static void observe(uint64_t index, uint64_t at, const char *generation) {
    vphoned_vcam_observe_header_t hdr = {0};
    hdr.seq = 2;
    memcpy(hdr.presentation_id, presentation_id, 16);
    hdr.observed_frame_index = index;
    hdr.observed_at_ns = at;
    hdr.observed_count = 1;
    strlcpy(hdr.observed_generation, generation, sizeof(hdr.observed_generation));
    NSMutableData *data = [NSMutableData dataWithLength:VPHONED_VCAM_OBSERVE_SHM_SIZE];
    memcpy(data.mutableBytes, &hdr, sizeof(hdr));
    assert([data writeToFile:@(observe_path) atomically:NO]);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        assert(argc == 3);
        snprintf(frame_path, sizeof(frame_path), "%s/frame", argv[2]);
        snprintf(observe_path, sizeof(observe_path), "%s/observe", argv[2]);
        NSString *scenario = @(argv[1]);
        if ([scenario isEqual:@"restart"]) observe(1, 1, "g");
        assert(open_shm() == 0);
        uint8_t pixels[4] = {0, 0, 0, 255};
        publish_frame(1, 1, 4, 0x42475241, 1, "g", presentation_id, pixels, 4);
        if ([scenario isEqual:@"valid"]) {
            observe(1, vvc_monotonic_ns(), "g");
            // Publisher may advance beyond the last consumed frame.
            publish_frame(1, 1, 4, 0x42475241, 2, "g", presentation_id, pixels, 4);
        } else if ([scenario isEqual:@"reused-generation"]) {
            observe(1, vvc_monotonic_ns(), "g");
            uint8_t replacement_id[16] = {2};
            publish_frame(1, 1, 4, 0x42475241, 2, "g", replacement_id, pixels, 4);
        } else if ([scenario isEqual:@"legacy-observer"]) {
            observe(1, vvc_monotonic_ns(), "g");
            int fd = open(observe_path, O_WRONLY);
            uint8_t empty[16] = {0};
            assert(pwrite(fd, empty, 16, offsetof(vphoned_vcam_observe_header_t, presentation_id)) == 16);
            close(fd);
        } else if ([scenario isEqual:@"future-index"]) {
            observe(9, vvc_monotonic_ns(), "g");
        } else if ([scenario isEqual:@"old-generation"]) {
            observe(1, vvc_monotonic_ns(), "old");
        } else if ([scenario isEqual:@"truncated"]) {
            assert([[NSData dataWithBytes:"x" length:1] writeToFile:@(observe_path) atomically:NO]);
        }
        NSDictionary *result = vp_vcam_status(@{@"generation": @"g", @"id": @1});
        uint64_t observed = [result[@"libvcam_observed_frame_index"] unsignedLongLongValue];
        uint64_t expected = [scenario isEqual:@"valid"] ? 1 : 0;
        if (observed != expected) {
            fprintf(stderr, "scenario=%s expected=%llu observed=%llu\n", argv[1], expected, observed);
            return 1;
        }
        munmap(s_shm_base, VPHONED_VCAM_SHM_TOTAL_SIZE);
    }
}
