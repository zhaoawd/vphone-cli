"""Execute the guest HID implementation with an in-process IOKit boundary double."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class GuestTouchTests(unittest.TestCase):
    def test_disconnect_releases_last_point_and_ignores_orphan_moves(self):
        with tempfile.TemporaryDirectory(prefix='guest-touch-') as temp:
            source = Path(temp) / 'test.m'
            source.write_text('#import "' + str(ROOT / 'scripts/vphoned/vphoned_hid.m') + '"\n' + r'''
#include <assert.h>
static int events = 0;
static bool lastTouch;
static double lastX, lastY;
static IOHIDEventRef digitizer(CFAllocatorRef a, uint64_t t, uint32_t b, uint32_t c,
 uint32_t d, uint32_t mask, uint32_t e, double x, double y, double z,
 double p, double q, boolean_t range, boolean_t touch, uint32_t f) {
 return (__bridge_retained void *)@{@"touch": @(touch), @"x": @(x), @"y": @(y)};
}
static IOHIDEventRef finger(CFAllocatorRef a, uint64_t b, uint32_t c, uint32_t d,
 uint32_t e, double f, double g, double h, double i, double j, boolean_t k,
 boolean_t l, uint32_t m) { return NULL; }
static void append(IOHIDEventRef a, IOHIDEventRef b, uint32_t c) {}
static void setInt(IOHIDEventRef a, uint32_t b, int c) {}
static void sender(IOHIDEventRef a, uint64_t b) {}
static void dispatchEvent(IOHIDEventSystemClientRef a, IOHIDEventRef ev) {
 NSDictionary *d = (__bridge NSDictionary *)ev;
 events++; lastTouch = [d[@"touch"] boolValue];
 lastX = [d[@"x"] doubleValue]; lastY = [d[@"y"] doubleValue];
}
static void drain(void) { dispatch_sync(gHIDQueue, ^{}); }
int main(void) {
 @autoreleasepool {
 gHIDQueue = dispatch_queue_create("test.hid", DISPATCH_QUEUE_SERIAL);
 pDigitizer = digitizer; pFinger = finger; pAppend = append;
 pSetInt = setInt; pSetSender = sender; pDispatch = dispatchEvent;
 vp_hid_touch(1, .1, .2); drain(); assert(events == 0);
 vp_hid_touch(0, .2, .3); vp_hid_touch(1, .4, .5); drain();
 assert(events == 2 && lastTouch);
 vp_hid_touch_reset(); drain();
 assert(events == 3 && !lastTouch && lastX == .4 && lastY == .5);
 vp_hid_touch_reset(); vp_hid_touch(3, .4, .5); drain(); assert(events == 3);
 vp_hid_touch(0, .6, .7); vp_hid_touch(3, .8, .9); drain();
 assert(events == 5 && !lastTouch && lastX == .8);
 }
}
''')
            binary = Path(temp) / 'test'
            build = subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-fobjc-arc',
                                    '-framework', 'Foundation', str(source), '-o', str(binary)],
                                   capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
