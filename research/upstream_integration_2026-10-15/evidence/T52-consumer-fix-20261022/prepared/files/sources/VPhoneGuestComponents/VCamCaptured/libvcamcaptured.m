/*
 * libvcamcaptured — synthetic camera source injection in cameracaptured.
 *
 * Optional hook for `/usr/libexec/cameracaptured`. Building the guest
 * component does not install or inject it; a process loader is required.
 *
 * Strategy (iOS 26.x):
 *   1. AVF clients query `+[AVCaptureDevice devicesWithMediaType:]`.
 *   2. That bottoms out at `FigCaptureSourceRemoteCopyCaptureSources(1)`
 *      which XPC-calls cameracaptured's
 *      `_captureSourceServer_handleCopySourcesMessage`.
 *   3. Native enumeration asks FigCaptureSourceBackingsProvider for its
 *      sourceBackings, then creates sources for the requesting audit token.
 *   4. Add our FigCaptureSourceBacking at that provider boundary. The native
 *      server retains ownership, source creation, locking and serialization.
 *      No source-list mutation or per-client filter patch is needed.
 *   5. Post the Darwin notification subscribed-to by AVF clients so they
 *      drop their cached device list and re-query.
 *
 * Version portability:
 *   No hardcoded image VMAs. All CMCapture addresses are recovered at
 *   runtime via:
 *     - dlsym for exported functions (FigCaptureSourceServerStart,
 *       FigCaptureSourceCreateFromBacking, CMBaseObjectGetVTable).
 *     - getsectiondata to map CMCapture's __text bounds.
 *     - Objective-C runtime lookup of the provider's sourceBackings getter.
 */

#import <CoreFoundation/CoreFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <os/log.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <libkern/OSCacheControl.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <notify.h>
#include <ptrauth.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <time.h>
#include "VCamFrameProtocol.h"

// MARK: - shared frame layout (matches vphoned_vcam.h)
//
// cameracaptured's sandbox blocks AF_VSOCK socket creation, so the frame
// receiver lives in vphoned (root, has vsock perms). vphoned writes
// frames into a shared mmap and posts a Darwin notification; we map the
// file read-only, subscribe to the notification, and copy out the latest
// frame on each fire.

// MARK: - sentinel logging

static void vcc_log(NSString *fmt, ...) {
  va_list args;
  va_start(args, fmt);
  NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
  va_end(args);
  NSString *line = [NSString
      stringWithFormat:@"%@ [vcamcaptured:%d:%@] %@\n",
                       [NSDate.date description],
                       getpid(),
                       NSProcessInfo.processInfo.processName ?: @"?",
                       msg];
  NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
  if (!data.length) return;
  int fd = open(VPHONE_VCAM_CAPTURE_LOG_PATH, O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (fd >= 0) {
    (void)write(fd, data.bytes, data.length);
    close(fd);
  }
  // Initialization can fail before the shared directory exists or when the
  // daemon sandbox denies that directory. Keep the reason visible in the
  // scoped unified-log capture used by the acceptance harness.
  os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "vcamcaptured: %{public}s", msg.UTF8String ?: "?");
}


// The implementation remains one translation unit because these hooks share
// private runtime state and order-sensitive symbol declarations. Each include
// owns one capture subsystem; none becomes a public dylib interface.
#include "VCamImageResolution.inc"
#include "VCamSourceProvider.inc"
#include "VCamSourceInstallation.inc"
#include "VCamCaptureObservation.inc"
#include "VCamSyntheticDevice.inc"
#include "VCamSyntheticStreams.inc"
#include "VCamViewfinderHooks.inc"
#include "VCamSessionHooks.inc"
#include "VCamStillSink.inc"
#include "VCamFrameReceiver.inc"

// MARK: - constructor

__attribute__((constructor)) static void vcc_init(void) {
  @autoreleasepool {
    vcc_log(@"loaded (argv0=%@)",
            NSProcessInfo.processInfo.arguments.firstObject ?: @"?");

    // Let daemon initialization load the provider class. Native enumeration
    // will create client-owned sources from our backing on its own queue.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                     @autoreleasepool {
                       vcc_install_synthetic();
                       vcc_start_frame_receiver();
                       vcc_install_endpoint_hook();
                       vcc_install_sink_observation();
                       vcc_install_still_sink_observation();
                       vcc_install_session_graph_observation();
                       vcc_install_still_coordinator_observation();
                       vcc_install_still_coord_node_observation();
                       vcc_install_still_pipeline_observation();
                       vcc_install_pipelines_addStill_observation();
                       vcc_install_parsed_cfg_observation();
                       vcc_install_csp_requires_master_clock_hook();
                       vcc_install_session_init_capture();
                       vcc_construct_still_sink();
                       // Probe: drive our manually-installed handler 15s
                       // after install. Gives time for vphoned to produce
                       // shm frames our reader can wrap into a CMSampleBuffer.
                       dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                     (int64_t)(15 * NSEC_PER_SEC)),
                                      dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
                                      ^{ @autoreleasepool { vcc_drive_still_sink_once(); }});
                       vcc_install_viewfinder_hooks();
                       vcc_dump_sink_node_methods();
                       // Signature corrected against the observed type
                       // encoding @40@0:8@16i24B28^i32 (clientPID is int,
                       // err is int*). Hook is currently observe-only —
                       // calls orig and logs return + err, which lets us
                       // see what client/PID is asking for our device and
                       // confirm the -12780 nil-return path before we add
                       // synthesis logic.
                       vcc_install_device_vendor_hook();
                       vcc_install_copy_streams_hook();
                       vcc_install_copy_streams_from_hook();
                     }
                   });
  }
}
