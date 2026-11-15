#!/bin/zsh
set -euo pipefail
unsetopt BG_NICE
root="${0:a:h:h:h:h:h}"
cd "$root"
mode="${1:?install|cold|rollback|restored}"
[[ "$mode" == install || "$mode" == cold || "$mode" == rollback || "$mode" == restored ]]
source Research/Integration/duo_m5_20261030/Regression/host-request.zsh
machine="$root/.build/duo-runtime-84e3ce54/machines/duo-rpc-foundation-identity-20261115"
socket="$machine/vphone.sock"
bundle="$root/.build/duo-fixes-20261114/baseline/VPhone.bundle"
candidate="$root/.build/rpc-foundation-20261115/candidate-final/vphoned"
out=$(mktemp -d "$root/.build/rpc-foundation-20261115/identity-worker-$mode.XXXXXXXX")
print -r -- "$out"
cp "${0:a}" "$out/driver.zsh"
cp "${0:a:h}/rpc-foundation-identity-worker-check.mjs" "$out/rpc-foundation-identity-worker-check.mjs"
if lsof "$machine/Disk.img" "$machine/nvram.bin" "$machine/SEPStorage" > "$out/handles-before.txt"; then exit 1; fi
active=0
cleanup() {
    if (( active )); then
        vphone_host_request "$socket" '{"t":"rpc","method":"system.shutdown","params":{"force":true},"screen":false}' > "$out/shutdown.json" 2> "$out/shutdown-error.log" || true
        for i in {1..60}; do
            if ! lsof "$machine/Disk.img" "$machine/nvram.bin" "$machine/SEPStorage" > "$out/open-handles.txt"; then break; fi
            sleep 1
        done
        if lsof "$machine/Disk.img" "$machine/nvram.bin" "$machine/SEPStorage" > "$out/open-handles.txt"; then print -u2 'Normal shutdown incomplete'; return 1; fi
        wait "$vm_pid" || true
        active=0
    fi
}
trap cleanup EXIT
mkdir -p "$out/host-home"
[[ ! -e "$out/host-update-disabled" ]]
CFFIXED_USER_HOME="$out/host-home" NSUnbufferedIO=YES "$bundle/Contents/MacOS/vphone-vm" \
    --config "$machine/config.plist" --headless --api-listen 127.0.0.1:0 \
    --vphoned-bin "$out/host-update-disabled" > "$out/boot.log" 2>&1 &
vm_pid=$!
active=1
ready=0
for i in {1..150}; do
    kill -0 "$vm_pid" 2>/dev/null || { print -u2 'VM exited before ready'; exit 1; }
    if [[ -S "$socket" ]] && vphone_host_request "$socket" '{"t":"rpc","method":"device.info","params":{},"screen":false}' > "$out/ready-device.json" 2> "$out/ready-error.log"; then
        if jq -e '.result.uptime_seconds >= 20' "$out/ready-device.json" >/dev/null; then ready=1; break; fi
    fi
    sleep 1
done
(( ready )) || exit 1
sleep 3
node "${0:a:h}/rpc-foundation-identity-worker-check.mjs" "$socket" "$out/boot.log" "$candidate" "$bundle/Contents/Resources/guest-resources/vphoned" "$out" "$mode" > "$out/check.log" 2>&1
cleanup
trap - EXIT
cat "$out/check.log"
