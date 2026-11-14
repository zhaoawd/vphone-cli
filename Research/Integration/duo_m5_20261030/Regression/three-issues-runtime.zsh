#!/bin/zsh
set -euo pipefail
unsetopt BG_NICE
root="${0:a:h:h:h:h:h}"
cd "$root"
reg="${0:a:h}"
mode="${1:-baseline}"
case "$mode" in
    baseline|followup|context|cache|cache-context) ;;
    *) print -u2 'Usage: three-issues-runtime.zsh [baseline|followup|context|cache|cache-context]'; exit 64 ;;
esac
source "$reg/host-request.zsh"
cli="$root/.build/duo-sync-20261113/XcodeBundle/Build/Products/Debug/VPhone.bundle/Contents/MacOS/vphone-cli"
library="$root/.build/duo-runtime-84e3ce54/machines"
machine=duo-rpc-accept-205443
socket="$library/$machine/vphone.sock"
mkdir -p "$root/.build/three-issues"
out=$(mktemp -d "$root/.build/three-issues/run.XXXXXXXX")
print -r -- "$out"
cp "${0:a}" "$out/driver.zsh"
cp "$reg/three-issues-$mode.mjs" "$out/probe.mjs"
node --input-type=module <<'JS'
import fs from 'node:fs';
import {createHash} from 'node:crypto';
import {validateTraceBundle} from './Research/Integration/duo_m5_20261030/Regression/f5-trace-state.mjs';
validateTraceBundle(createHash('sha256').update(fs.readFileSync('.build/duo-sync-20261113/XcodeBundle/Build/Products/Debug/VPhone.bundle/Contents/Resources/guest-resources/libvphonefolddisplay.dylib')).digest('hex'));
JS
"$cli" host preflight > "$out/preflight.log" 2>&1
if lsof "$library/$machine/Disk.img" "$library/$machine/nvram.bin" "$library/$machine/SEPStorage" > "$out/handles-before.txt"; then exit 1; fi
mkdir -p "$out/host-home/Desktop"
active=0
cleanup() {
    if (( active )); then
        vphone_host_request "$socket" '{"t":"rpc","method":"system.shutdown","params":{"force":true},"screen":false}' > "$out/shutdown.json" 2> "$out/shutdown-error.log" || true
        for i in {1..40}; do
            if ! lsof "$library/$machine/Disk.img" "$library/$machine/nvram.bin" "$library/$machine/SEPStorage" > "$out/open-handles.txt"; then break; fi
            sleep 1
        done
        if lsof "$library/$machine/Disk.img" "$library/$machine/nvram.bin" "$library/$machine/SEPStorage" > "$out/open-handles.txt"; then
            print -u2 'Normal shutdown has not completed; VM state files remain open'
            return 1
        fi
        wait "$launch_pid" || true
    fi
    active=0
    if lsof "$library/$machine/Disk.img" "$library/$machine/nvram.bin" "$library/$machine/SEPStorage" > "$out/open-handles.txt"; then return 1; fi
}
trap cleanup EXIT
CFFIXED_USER_HOME="$out/host-home" NSUnbufferedIO=YES "$cli" vm launch "$machine" -l "$library" -v > "$out/boot.log" 2>&1 &
launch_pid=$!
active=1
ready=0
for i in {1..150}; do
    kill -0 "$launch_pid" 2>/dev/null || exit 1
    if [[ -S "$socket" ]] && vphone_host_request "$socket" '{"t":"rpc","method":"device.info","params":{},"screen":false}' > "$out/device.json" 2> "$out/device-error.log"; then
        if jq -e '.result.uptime_seconds >= 35' "$out/device.json" >/dev/null; then ready=1; break; fi
    fi
    sleep 1
done
(( ready )) || exit 1
node "$reg/three-issues-$mode.mjs" "$socket" "$out/samples" > "$out/baseline.log" 2>&1
cleanup
trap - EXIT
print -r -- "Evidence: $out"
