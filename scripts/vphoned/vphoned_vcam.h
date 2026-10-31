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

#include "../../sources/VPhoneGuestComponents/Shared/VPhoneCameraFrame.h"

typedef vphone_vcam_shm_header_t vphoned_vcam_shm_header_t;
typedef vphone_vcam_observe_header_t vphoned_vcam_observe_header_t;
#define VPHONED_VCAM_SHM_HEADER_SIZE VPHONE_VCAM_SHM_HEADER_SIZE
#define VPHONED_VCAM_SHM_MAX_PIXELS VPHONE_VCAM_SHM_MAX_PIXELS
#define VPHONED_VCAM_SHM_TOTAL_SIZE VPHONE_VCAM_SHM_TOTAL_SIZE
#define VPHONED_VCAM_GENERATION_MAX VPHONE_VCAM_GENERATION_MAX
#ifndef VPHONED_VCAM_OBSERVE_SHM_PATH
#define VPHONED_VCAM_OBSERVE_SHM_PATH "/var/jb/var/mobile/Library/vphone-vcam-observe.shm"
#endif
#define VPHONED_VCAM_OBSERVE_SHM_SIZE VPHONE_VCAM_OBSERVE_SHM_SIZE

/* Starts the listener on a background thread. Idempotent. */
void vp_vcam_start(void);

/* Answer a host `vcam_status` query. Fuses the publish header (pub index +
 * generation) with the observe shm (obs index) and returns the two-level
 * receipt fields the host requires. `msg` is the request dict (for the
 * `generation` filter and `id` echo). Fail-closed: obs index is reported
 * only for a stable same-generation observation from this publisher run,
 * with 0 < observed index <= published index. This is not an app receipt. */
NSDictionary *vp_vcam_status(NSDictionary *msg);

#ifdef __cplusplus
}
#endif

#endif /* VPHONED_VCAM_H */
