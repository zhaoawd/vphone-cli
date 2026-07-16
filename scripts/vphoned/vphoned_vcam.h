/*
 * vphoned_vcam — receive virtual-camera frames over vsock and publish
 * them into a shared-memory file that libvcamcaptured (inside
 * cameracaptured) maps for read access.
 *
 * vphoned runs as root and has AF_VSOCK access; the cameracaptured
 * sandbox does not, so libvcamcaptured can't open its own vsock socket.
 * Putting the listener here is the cleanest workaround.
 */

#ifndef VPHONED_VCAM_H
#define VPHONED_VCAM_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Path of the shared frame file (read by libvcamcaptured).
 * Lives under /var/jb so cameracaptured's sandbox allows reads.
 */
#ifndef VPHONED_VCAM_SHM_PATH
#define VPHONED_VCAM_SHM_PATH                                                  \
  "/var/jb/var/mobile/Library/vphone-vcam-frame.shm"
#endif
#ifndef VPHONED_VCAM_VSOCK_PORT
#define VPHONED_VCAM_VSOCK_PORT 1338
#endif
#ifndef VPHONED_VCAM_NOTIFY_NAME
#define VPHONED_VCAM_NOTIFY_NAME "com.vphone.vcam.frame"
#endif
#ifndef VPHONED_VCAM_OBSERVED_PATH
#define VPHONED_VCAM_OBSERVED_PATH                                           \
  "/var/jb/var/mobile/Library/vphone-vcam-observed.shm"
#endif

#define VPHONED_VCAM_PROTOCOL_VERSION 2
#define VPHONED_VCAM_GENERATION_MAX 80
#define VPHONED_VCAM_ROLE_MAX 16

/* Shared-memory layout. seq increments by 2 per frame; odd values mean
 * a write is in progress. Readers re-check seq after copying to detect
 * mid-write tearing. */
typedef struct {
  uint64_t seq;
  uint64_t timestamp_ns;
  uint64_t frame_index;
  uint64_t published_at_ns;    /* guest CLOCK_MONOTONIC */
  uint32_t width;
  uint32_t height;
  uint32_t bytes_per_row;
  uint32_t pixel_format;       /* 4cc */
  uint32_t protocol_version;   /* host wire pv */
  uint32_t pixels_length;
  char generation[VPHONED_VCAM_GENERATION_MAX];
  char role[VPHONED_VCAM_ROLE_MAX];
  uint8_t _reserved[104];
  /* pixels start at offset 256; capacity = total mmap size - 256. */
} vphoned_vcam_shm_header_t;

#define VPHONED_VCAM_SHM_HEADER_SIZE 256
#define VPHONED_VCAM_SHM_MAX_PIXELS (8 * 1024 * 1024)  /* 8 MiB */
#define VPHONED_VCAM_SHM_TOTAL_SIZE                                            \
  (VPHONED_VCAM_SHM_HEADER_SIZE + VPHONED_VCAM_SHM_MAX_PIXELS)

/* Written by libvcamcaptured after it has copied a stable shm frame. The
 * independent seq counter prevents vphoned's low-frequency status reader from
 * accepting a torn generation/frame tuple. */
typedef struct {
  uint64_t seq;
  uint64_t frame_index;
  uint64_t observed_at_ns;     /* guest CLOCK_MONOTONIC */
  uint32_t protocol_version;
  uint32_t _reserved0;
  char generation[VPHONED_VCAM_GENERATION_MAX];
  char role[VPHONED_VCAM_ROLE_MAX];
} vphoned_vcam_observed_t;

#define VPHONED_VCAM_OBSERVED_SIZE 128

/* Starts the listener on a background thread. Idempotent. */
void vp_vcam_start(void);

/* Snapshot for the guest 1337 `vcam_status` command. Observed fields are
 * included only when protocol/generation/role/frame/time match the current
 * published frame exactly. */
NSDictionary *vp_vcam_status(NSString *requested_generation);

#ifdef __cplusplus
}
#endif

#endif /* VPHONED_VCAM_H */
