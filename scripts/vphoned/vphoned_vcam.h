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

/* Shared-memory layout. seq increments by 2 per frame; odd values mean
 * a write is in progress. Readers re-check seq after copying to detect
 * mid-write tearing.
 *
 * Protocol v2 (§8.1): the publish header carries the frame's `generation`
 * (the QrArtifact/neutral request it belongs to) and a monotonic
 * `published_at_ns`, so the guest observe half (libvcamcaptured -> observe
 * shm -> vphoned vcam_status) can bind an observed frame to the exact
 * generation the host is polling for. The original v1 fields keep their
 * offsets, so a v1 reader that only wants w/h/bpr/pixels stays compatible;
 * only the header size grew (64 -> 256), which moves the pixel start. */
typedef struct __attribute__((packed)) {
  uint64_t seq;
  uint32_t width;
  uint32_t height;
  uint32_t bytes_per_row;
  uint32_t pixel_format;  /* 4cc */
  uint32_t _reserved;
  uint64_t timestamp_ns;
  uint64_t frame_index;
  uint32_t pixels_length;
  uint32_t _pad;
  /* v2 additions (offset 52+): */
  uint64_t published_at_ns;   /* CLOCK_MONOTONIC ns at publish */
  char     generation[80];    /* NUL-terminated generation of this frame */
  /* pixels start at offset VPHONED_VCAM_SHM_HEADER_SIZE (256). */
} vphoned_vcam_shm_header_t;

#define VPHONED_VCAM_SHM_HEADER_SIZE 256
#define VPHONED_VCAM_SHM_MAX_PIXELS (8 * 1024 * 1024)  /* 8 MiB */
#define VPHONED_VCAM_SHM_TOTAL_SIZE                                            \
  (VPHONED_VCAM_SHM_HEADER_SIZE + VPHONED_VCAM_SHM_MAX_PIXELS)
#define VPHONED_VCAM_GENERATION_MAX 80

/*
 * Observe shm: written by libvcamcaptured (inside cameracaptured, which it
 * owns and maps read-write) each time it copies a fresh frame out of the
 * publish shm; read by vphoned (root) to answer the host `vcam_status`
 * query. Separate file so the publish frame buffer stays read-only from the
 * consumer's side (no risk of a consumer corrupting frame pixels, no perms
 * widening on the root-owned publish shm). seq follows the same even/odd
 * write-in-progress discipline.
 */
#ifndef VPHONED_VCAM_OBSERVE_SHM_PATH
#define VPHONED_VCAM_OBSERVE_SHM_PATH                                          \
  "/var/jb/var/mobile/Library/vphone-vcam-observe.shm"
#endif
#define VPHONED_VCAM_OBSERVE_SHM_SIZE 128

typedef struct __attribute__((packed)) {
  uint64_t seq;
  uint64_t observed_frame_index;   /* publish frame_index last consumed */
  uint64_t observed_at_ns;         /* CLOCK_MONOTONIC ns at observe */
  uint64_t observed_count;         /* total frames observed */
  char     observed_generation[VPHONED_VCAM_GENERATION_MAX];
} vphoned_vcam_observe_header_t;

/* Starts the listener on a background thread. Idempotent. */
void vp_vcam_start(void);

/* Answer a host `vcam_status` query. Fuses the publish header (pub index +
 * generation) with the observe shm (obs index) and returns the two-level
 * receipt fields the host requires. `msg` is the request dict (for the
 * `generation` filter and `id` echo). Fail-closed: obs index is reported
 * only when the observed generation matches the currently-published one. */
NSDictionary *vp_vcam_status(NSDictionary *msg);

#ifdef __cplusplus
}
#endif

#endif /* VPHONED_VCAM_H */
