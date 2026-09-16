// Read-only acceptance probe. These Darwin notification keys are private;
// correlate their values with screenshots on each tested guest combination.
#include <notify.h>
#include <stdint.h>
#include <stdio.h>

int main(void) {
    const char *names[] = {
        "com.apple.springboard.lockstate",
        "com.apple.springboard.hasBlankedScreen",
        "com.apple.iokit.hid.displayStatus",
    };
    int failed = 0;
    for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        int token = 0;
        uint64_t state = 0;
        uint32_t status = notify_register_check(names[i], &token);
        if (status == NOTIFY_STATUS_OK) {
            status = notify_get_state(token, &state);
            notify_cancel(token);
        }
        printf("%s status=%u state=%llu\n", names[i], status,
               (unsigned long long)state);
        if (status != NOTIFY_STATUS_OK) failed = 1;
    }
    return failed;
}
