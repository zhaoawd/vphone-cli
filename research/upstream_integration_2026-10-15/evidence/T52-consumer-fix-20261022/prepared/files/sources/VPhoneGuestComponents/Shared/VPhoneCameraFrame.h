#ifndef VPHONE_CAMERA_FRAME_H
#define VPHONE_CAMERA_FRAME_H

#include <stdint.h>
#include <stddef.h>

// Paths for the explicit v2 layout; classic retains its existing /var/jb paths.
#ifndef VPHONE_VCAM_V2_DIRECTORY
#define VPHONE_VCAM_V2_DIRECTORY "/var/mobile/Media/SimulatedCamera"
#endif
#define VPHONE_VCAM_V2_SHM_PATH VPHONE_VCAM_V2_DIRECTORY "/vphone-vcam-frame.shm"
#ifndef VPHONE_VCAM_V2_OBSERVE_SHM_PATH
#define VPHONE_VCAM_V2_OBSERVE_SHM_PATH VPHONE_VCAM_V2_DIRECTORY "/vphone-vcam-observe.shm"
#endif
#define VPHONE_VCAM_V2_LOG_PATH VPHONE_VCAM_V2_DIRECTORY "/vphone-vcam.log"

// Shared by the classic publisher and both camera consumer layouts.
#define VPHONE_VCAM_SHM_HEADER_SIZE 256
#define VPHONE_VCAM_SHM_MAX_PIXELS (8 * 1024 * 1024)
#define VPHONE_VCAM_SHM_TOTAL_SIZE (VPHONE_VCAM_SHM_HEADER_SIZE + VPHONE_VCAM_SHM_MAX_PIXELS)
#define VPHONE_VCAM_GENERATION_MAX 80
#define VPHONE_VCAM_OBSERVE_SHM_SIZE 128

typedef struct __attribute__((packed)) {
  uint64_t seq __attribute__((aligned(8)));
  uint32_t width;
  uint32_t height;
  uint32_t bytes_per_row;
  uint32_t pixel_format;
  uint32_t _reserved;
  uint64_t timestamp_ns;
  uint64_t frame_index;
  uint32_t pixels_length;
  uint32_t _pad;
  uint64_t published_at_ns;
  char generation[VPHONE_VCAM_GENERATION_MAX];
  uint8_t presentation_id[16];
} vphone_vcam_shm_header_t;

typedef struct __attribute__((packed)) {
  uint64_t seq __attribute__((aligned(8)));
  uint64_t observed_frame_index;
  uint64_t observed_at_ns;
  uint64_t observed_count;
  char observed_generation[VPHONE_VCAM_GENERATION_MAX];
  uint8_t presentation_id[16];
} vphone_vcam_observe_header_t;

_Static_assert(offsetof(vphone_vcam_shm_header_t, timestamp_ns) == 28, "camera frame timestamp offset");
_Static_assert(offsetof(vphone_vcam_shm_header_t, pixels_length) == 44, "camera frame length offset");
_Static_assert(offsetof(vphone_vcam_shm_header_t, published_at_ns) == 52, "camera frame publication offset");
_Static_assert(offsetof(vphone_vcam_shm_header_t, generation) == 60, "camera frame generation offset");
_Static_assert(offsetof(vphone_vcam_shm_header_t, presentation_id) == 140, "camera frame presentation offset");
_Static_assert(sizeof(vphone_vcam_shm_header_t) <= VPHONE_VCAM_SHM_HEADER_SIZE, "camera frame header capacity");
_Static_assert(sizeof(vphone_vcam_observe_header_t) == VPHONE_VCAM_OBSERVE_SHM_SIZE, "camera observation layout");

#endif
