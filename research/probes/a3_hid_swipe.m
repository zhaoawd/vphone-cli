// Isolated injection experiment using the production HID implementation.
#import "../../scripts/vphoned/vphoned_hid.m"
#include <string.h>
static __typeof__(pDigitizer) originalDigitizer;
static __typeof__(pFinger) originalFinger;
static BOOL testSwipeUp;
// IOHIDDigitizerEventMask: kIOHIDDigitizerEventSwipeUp (Apple IOHIDEventTypes.h).
static uint32_t swipeUpMask = 1u << 24;
static IOHIDEventRef handDigitizer(CFAllocatorRef allocator, uint64_t timestamp,
    uint32_t type, uint32_t index, uint32_t identity, uint32_t mask, uint32_t buttons,
    IOHIDFloat x, IOHIDFloat y, IOHIDFloat z, IOHIDFloat pressure, IOHIDFloat twist,
    boolean_t range, boolean_t touch, uint32_t options) {
    // kIOHIDDigitizerTransducerTypeHand in Apple's IOHIDEventTypes and WebKit SPI.
    return originalDigitizer(allocator, timestamp, testSwipeUp ? type : 3, index, identity,
                             testSwipeUp ? mask | swipeUpMask : mask, buttons,
                             x, y, z, pressure, twist, range, touch, options);
}
static IOHIDEventRef swipeFinger(CFAllocatorRef allocator, uint64_t timestamp,
    uint32_t index, uint32_t identity, uint32_t mask, IOHIDFloat x, IOHIDFloat y,
    IOHIDFloat z, IOHIDFloat pressure, IOHIDFloat twist, boolean_t range,
    boolean_t touch, uint32_t options) {
    return originalFinger(allocator, timestamp, index, identity, mask | swipeUpMask,
                          x, y, z, pressure, twist, range, touch, options);
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2 || (strcmp(argv[1], "baseline") && strcmp(argv[1], "hand") && strcmp(argv[1], "swipe-up") && strcmp(argv[1], "edge-tip") && strcmp(argv[1], "edge-tip-fast") && strcmp(argv[1], "edge-tip-up") && strcmp(argv[1], "edge-flat") && strcmp(argv[1], "edge-pending"))) return 64;
        if (!vp_hid_load()) return 2;
        if (!strcmp(argv[1], "hand")) { originalDigitizer = pDigitizer; pDigitizer = handDigitizer; }
        if (!strcmp(argv[1], "swipe-up") || !strncmp(argv[1], "edge-", 5)) {
            if (!strncmp(argv[1], "edge-tip", 8)) swipeUpMask = 1u << 11;
            if (!strcmp(argv[1], "edge-tip-up")) swipeUpMask |= 1u << 24;
            if (!strcmp(argv[1], "edge-flat")) swipeUpMask = 1u << 10;
            if (!strcmp(argv[1], "edge-pending")) swipeUpMask = 1u << 13;
            testSwipeUp = YES;
            originalDigitizer = pDigitizer; pDigitizer = handDigitizer;
            originalFinger = pFinger; pFinger = swipeFinger;
        }
        vp_hid_touch(0, .5, 2790.0 / 2796.0);
        for (int i = 1; i <= 18; i++) {
            usleep(!strcmp(argv[1], "edge-tip-fast") ? 3333 : 16667);
            vp_hid_touch(i == 18 ? 3 : 1, .5, (2790.0 - 1190.0 * i / 18.0) / 2796.0);
        }
        dispatch_sync(gHIDQueue, ^{});
        puts("injection complete; verify screenshots independently");
    }
    return 0;
}
