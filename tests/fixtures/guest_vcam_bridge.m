#import <Foundation/Foundation.h>
#include <assert.h>
#include <pthread.h>
static char frame_path[4096], observe_path[4096];
#define VPHONED_VCAM_SHM_PATH frame_path
#define VPHONED_VCAM_OBSERVE_SHM_PATH observe_path
#include "../../scripts/vphoned/vphoned_vcam.m"
#define VPHONE_VCAM_OBSERVE_SHM_PATH observe_path
#include "../../sources/VPhoneGuestComponents/VCamCaptured/VCamFrameProtocol.h"
#include "consumer_types.h"
static void vcc_log(NSString *fmt, ...) {}
static int fail_allocation, tear_copy;
static void *bridge_realloc(void *memory, size_t length) {
    return fail_allocation ? NULL : realloc(memory, length);
}
static void *bridge_memcpy(void *to, const void *from, size_t length) {
    void *result = memcpy(to, from, length);
    if (tear_copy && from == s_shm_base + VPHONE_VCAM_SHM_HEADER_SIZE)
        ((vphoned_vcam_shm_header_t *)s_shm_base)->seq += 2;
    return result;
}
#define realloc bridge_realloc
#define memcpy bridge_memcpy
#include "../../sources/VPhoneGuestComponents/VCamCaptured/VCamFrameReceiver.inc"
#undef realloc
#undef memcpy

NSMutableDictionary *vp_make_response(NSString *type, id reqId) {
    return [@{@"t": type, @"id": reqId ?: @0} mutableCopy];
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        assert(argc == 3);
        if (strcmp(argv[2], "paths") == 0) {
            assert(!vvc_uses_v2_layout());
            setenv("VPHONED_CAMERA_LAYOUT", "v2", 1);
            assert(strcmp(vvc_frame_path(), VPHONE_VCAM_SHM_PATH) == 0);
            assert(strcmp(vvc_observe_path(), VPHONE_VCAM_V2_OBSERVE_SHM_PATH) == 0);
            setenv("VPHONED_CAMERA_LAYOUT", "unsupported", 1);
            assert(open_shm() == -1 && errno == EINVAL);
            return 0;
        }
        snprintf(frame_path, sizeof(frame_path), "%s/frame", argv[1]);
        snprintf(observe_path, sizeof(observe_path), "%s/observe", argv[1]);
        assert(open_shm() == 0);
        const uint8_t pixels[8] = {19, 42, 63, 255, 77, 88, 99, 255};
        const uint8_t presentation[16] = {7};
        publish_frame(2, 1, 8, 0x42475241, 1, "bridge-generation", presentation, pixels, sizeof(pixels));
        vcc_shm_base = s_shm_base;
        fail_allocation = strcmp(argv[2], "allocation") == 0;
        tear_copy = strcmp(argv[2], "torn") == 0;
        if (fail_allocation || tear_copy) {
            assert(vcc_shm_read_latest() == 0);
            assert(vcc_latest_frame.pixels_length == 0);
            NSDictionary *receipt = vp_vcam_status(@{@"generation": @"bridge-generation", @"id": @1});
            assert([receipt[@"libvcam_observed_frame_index"] unsignedLongLongValue] == 0);
            return 0;
        }
        assert(vcc_shm_read_latest() == 1);
        if (vcc_latest_frame.pixels_length != sizeof(pixels) ||
            memcmp(vcc_latest_frame.pixels, pixels, sizeof(pixels)) != 0) {
            fprintf(stderr, "production v2 reader copied different pixels from classic publisher\n");
            return 1;
        }
        NSDictionary *receipt = vp_vcam_status(@{@"generation": @"bridge-generation", @"id": @1});
        assert([receipt[@"libvcam_observed_frame_index"] unsignedLongLongValue] == 1);
        assert(vcc_shm_read_latest() == 0);
        vcc_observe_write(1, "wrong-generation", presentation);
        receipt = vp_vcam_status(@{@"generation": @"bridge-generation", @"id": @2});
        assert([receipt[@"libvcam_observed_frame_index"] unsignedLongLongValue] == 0);
        return 0;
    }
}
