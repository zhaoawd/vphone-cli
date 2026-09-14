#import <Foundation/Foundation.h>
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "camera_consumer_types.h"
static uint8_t buffer[VCC_SHM_HEADER_SIZE + 4];
static const uint8_t *vcc_shm_base = buffer;
static uint64_t vcc_last_seq_seen, vcc_frames_received;
static vcc_latest_frame_t vcc_latest_frame = {.lock = PTHREAD_MUTEX_INITIALIZER};
static int fail_allocation, tear_copy, observations;
static void vcc_log(NSString *format, ...) {}
static void vcc_observe_write(uint64_t index, const char *generation, const uint8_t presentation_id[16]) {
    assert(presentation_id[0] == 7); observations++;
}
static void *test_malloc(size_t size) { return fail_allocation ? NULL : malloc(size); }
static void *test_memcpy(void *dst, const void *src, size_t size) {
    void *result = memcpy(dst, src, size);
    if (tear_copy && src == buffer + VCC_SHM_HEADER_SIZE) {
        ((vcc_shm_header_t *)buffer)->seq += 2;
    }
    return result;
}
#define malloc test_malloc
#define memcpy test_memcpy
#include "camera_consumer_reader.h"
#undef malloc
#undef memcpy
int main(int argc, const char **argv) {
    assert(argc == 2);
    fail_allocation = strcmp(argv[1], "allocation") == 0;
    tear_copy = strcmp(argv[1], "torn") == 0;
    vcc_shm_header_t *hdr = (vcc_shm_header_t *)buffer;
    hdr->presentation_id[0] = 7;
    hdr->seq = 2; hdr->width = 1; hdr->height = 1; hdr->bytes_per_row = 4;
    hdr->pixels_length = 4; hdr->frame_index = 1;
    strlcpy(hdr->generation, "g", sizeof(hdr->generation));
    memset(buffer + VCC_SHM_HEADER_SIZE, 255, 4);
    int result = vcc_shm_read_latest();
    int expected = fail_allocation || tear_copy ? 0 : 1;
    if (result != expected || observations != expected ||
        (tear_copy && vcc_latest_frame.pixels_length != 0)) {
        fprintf(stderr, "case=%s result=%d observations=%d bytes=%zu\n",
                argv[1], result, observations, vcc_latest_frame.pixels_length);
        return 1;
    }
    free(vcc_latest_frame.pixels);
    return 0;
}
