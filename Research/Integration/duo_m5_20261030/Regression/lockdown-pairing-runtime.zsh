#!/bin/zsh
set -euo pipefail

udid=0000FE01-C5A51D613717F61A
mode=${1:-discover}
if (( $# > 1 )) || [[ $mode != discover && $mode != validate ]]; then
    print -u2 -- 'Usage: zsh lockdown-pairing-runtime.zsh [discover|validate]'
    exit 2
fi

devices=$(idevice_id -l)
if ! /usr/bin/grep -Fxiq -- "$udid" <<< "$devices"; then
    print -u2 -- "Target $udid is absent from the USB device list."
    exit 1
fi
print -r -- "USB target: $udid"

if [[ $mode == validate ]]; then
    # The handshake can request pairing. The operator confirms Trust on the guest.
    result=$(idevicepair -u "$udid" validate 2>&1) || {
        status_code=$?
        print -u2 -r -- "$result"
        exit "$status_code"
    }
    print -r -- "$result"
    if [[ $result != "SUCCESS: Validated pairing with device $udid" ]]; then
        print -u2 -- 'The target pairing success message was absent.'
        exit 1
    fi
fi
