#ifndef VPHONE_VCAM_FRAME_PROTOCOL_H
#define VPHONE_VCAM_FRAME_PROTOCOL_H

#include <stdint.h>
#include <stddef.h>
#include "../Shared/VPhoneCameraFrame.h"

// All guest camera runtime data lives in the mobile media area, regardless
// of how the VM was installed.
#define VPHONE_VCAM_DIRECTORY VPHONE_VCAM_V2_DIRECTORY
#define VPHONE_VCAM_SHM_PATH VPHONE_VCAM_V2_SHM_PATH
#define VPHONE_VCAM_DAEMON_LOG_PATH VPHONE_VCAM_DIRECTORY "/vphone-vcam.log"
#define VPHONE_VCAM_CAPTURE_LOG_PATH VPHONE_VCAM_DIRECTORY "/vcamcaptured.log"
#define VPHONE_VCAM_APP_LOG_PATH VPHONE_VCAM_DIRECTORY "/camfix.log"
#define VPHONE_VCAM_SYNTH_PHOTO_PATH VPHONE_VCAM_DIRECTORY "/vphone-synth-photo.bgra"
#define VPHONE_VCAM_NOTIFY_NAME "com.vphone.vcam.frame"
#ifndef VPHONE_VCAM_OBSERVE_SHM_PATH
#define VPHONE_VCAM_OBSERVE_SHM_PATH VPHONE_VCAM_V2_OBSERVE_SHM_PATH
#endif

#endif
