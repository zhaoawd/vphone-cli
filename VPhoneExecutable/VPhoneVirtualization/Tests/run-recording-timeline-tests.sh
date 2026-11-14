#!/bin/zsh
# vphone-tier: build
set -euo pipefail
command -v ffprobe >/dev/null
out="$(mktemp -d "${TMPDIR:-/tmp}/vphone-recording-timeline.XXXXXXXX")"
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library -module-cache-path "$out/module-cache" \
    -target arm64-apple-macos15.0 \
    "${0:a:h:h}/UI/HostDevices/VPhoneRecordingTimeline.swift" \
    "${0:a:h}/RecordingTimelineTests.swift" -o "$out/test"
"$out/test" "$out/variable-interval.mov"
ffprobe -v error -select_streams v -show_entries frame=pts_time -of csv=p=0 "$out/variable-interval.mov" \
    | awk -F , 'BEGIN { split("0 .040 .360 .400", pts, " ") }
        NF && $1 != "" { n++; if (n>4 || ($1-pts[n])^2 > 0.000004) bad=1 }
        END { exit (n != 4 || bad) }'
print 'Recording timeline: movie preserved the 320 ms capture gap'
root="${0:a:h:h:h:h}"
VPHONE_RECORDING_CLOCK_TEST="$out/test" node --test \
    "$root/Research/Integration/duo_m5_20261030/Regression/test-f5-mov-align.mjs" \
    "$root/Research/Integration/duo_m5_20261030/Regression/test-f5-source-report.mjs" \
    "$root/Research/Integration/duo_m5_20261030/Regression/test-f5-hold-report.mjs" \
    "$root/Research/Integration/duo_m5_20261030/Regression/test-f5-trace-state.mjs"
