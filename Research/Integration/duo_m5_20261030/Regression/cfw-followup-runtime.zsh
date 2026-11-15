#!/bin/zsh
set -euo pipefail
unsetopt BG_NICE
root=${0:a:h:h:h:h:h}
cd "$root"
source Research/Integration/duo_m5_20261030/Regression/host-request.zsh
machine="$root/.build/duo-runtime-84e3ce54/machines/duo-cfw-followup-20261115"
bundle="$root/.build/duo-sync-20261113/XcodeBundle/Build/Products/Debug/VPhone.bundle"
out=$(mktemp -d "$root/.build/followup-3-5-20261115/cfw-cold.XXXXXXXX")
print -r -- "$out"
cp "${0:a}" "$out/driver.zsh"
"$bundle/Contents/MacOS/vphone-cli" host preflight > "$out/preflight.log" 2>&1
if lsof "$machine/Disk.img" "$machine/nvram.bin" "$machine/SEPStorage" > "$out/handles-before.txt"; then exit 1; fi
mkdir -p "$out/host-home"
CFFIXED_USER_HOME="$out/host-home" NSUnbufferedIO=YES "$bundle/Contents/MacOS/vphone-vm" --config "$machine/config.plist" --api-listen 127.0.0.1:0 --vphoned-bin "$out/host-update-disabled" > "$out/boot.log" 2>&1 &
vm_pid=$!
ready=0
for attempt in {1..150}; do
 kill -0 "$vm_pid" 2>/dev/null || { print -u2 'VM process exited before RPC readiness'; exit 1; }
 if [[ -S "$machine/vphone.sock" ]] && vphone_host_request "$machine/vphone.sock" '{"t":"rpc","method":"device.info","params":{},"screen":false}' > "$out/device-ready.json" 2> "$out/device-error.log"; then
  if jq -e '.result.uptime_seconds >= 20' "$out/device-ready.json" >/dev/null; then ready=1; break; fi
 fi
 sleep 1
done
if (( ready )); then
 node "${0:a:h}/cfw-followup-check.mjs" "$machine/vphone.sock" "$out" "$bundle/Contents/Resources/guest-resources" > "$out/check.log" 2>&1 || { touch "$out/check-failed"; }
else
 touch "$out/not-ready"
fi
print -r -- "$out" > "$root/.build/followup-3-5-20261115/active-cfw-session.txt"
# Stay available for inspection if readiness fails. A failed RPC must not silently terminate the guest.
touch "$out/observations-complete"
while [[ ! -e "$out/stop" ]]; do sleep 1; done
vphone_host_request "$machine/vphone.sock" '{"t":"rpc","method":"system.shutdown","params":{"force":true},"screen":false}' > "$out/shutdown.json" 2> "$out/shutdown-error.log"
for attempt in {1..60}; do
 if ! lsof "$machine/Disk.img" "$machine/nvram.bin" "$machine/SEPStorage" > "$out/final-handles.txt"; then break; fi
 sleep 1
done
if lsof "$machine/Disk.img" "$machine/nvram.bin" "$machine/SEPStorage" > "$out/final-handles.txt"; then print -u2 'Shutdown incomplete'; exit 1; fi
wait "$vm_pid" || true
[[ ! -e "$out/not-ready" && ! -e "$out/check-failed" ]]
