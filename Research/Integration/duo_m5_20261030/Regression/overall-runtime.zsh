#!/bin/zsh
set -euo pipefail
unsetopt BG_NICE
root=${0:a:h:h:h:h:h}
reg=${0:a:h}
cd "$root"
source "$reg/host-request.zsh"
machine="$root/.build/duo-runtime-84e3ce54/machines/duo-overall-20261116"
bundle="$root/.build/overall-port-20261116/REVIEWED/VPhone.bundle"
agent_args=()
first_pose=0
first_pose_args=()
if [[ ${1:-baseline} == ax-candidate ]]; then
    agent="$root/.build/overall-port-20261116/cold-run.qYvDOWMq/vphoned-ax-candidate"
    [[ $(shasum -a 256 "$agent") == 'a4860c0c5b0b630155228d2d53183831b73c69099a8cd4b3e0909c92711a0a6f '* ]]
    agent_args=("$agent")
else
    [[ ${1:-baseline} == baseline || ${1:-baseline} == baseline-stability || ${1:-baseline} == baseline-stability-transition ]]
    if [[ ${1:-baseline} == baseline-stability* ]]; then first_pose=1; fi
    if [[ ${1:-baseline} == baseline-stability-transition ]]; then first_pose_args=(--transition); fi
fi
out=$(mktemp -d "$root/.build/overall-port-20261116/cold-run.XXXXXXXX")
print -r -- "$out"
cp "${0:a}" "$out/driver.zsh"
node "$reg/overall-candidate.mjs" > "$out/candidate.json"
"$bundle/Contents/MacOS/vphone-cli" host preflight > "$out/preflight.log" 2>&1
if lsof "$machine/Disk.img" "$machine/nvram.bin" "$machine/SEPStorage" > "$out/handles-before.txt"; then exit 1; fi
mkdir -p "$out/host-home"
CFFIXED_USER_HOME="$out/host-home" NSUnbufferedIO=YES "$bundle/Contents/MacOS/vphone-vm" --config "$machine/config.plist" --api-listen 127.0.0.1:0 --vphoned-bin "$out/host-update-disabled" > "$out/boot.log" 2>&1 &
vm_pid=$!
print -r -- "$vm_pid" > "$out/vm.pid"
print -r -- "$out" > "$root/.build/overall-port-20261116/active-session.txt"
ready=0
first_pose_done=0
boot_deadline=$(( $(date +%s) + 180 ))
for attempt in {1..180}; do
    (( $(date +%s) <= boot_deadline )) || break
    if ! kill -0 "$vm_pid" 2>/dev/null; then
        print -u2 'VM exited before readiness'
        if wait "$vm_pid"; then print 0 > "$out/vm-exit-code.txt"; else print $? > "$out/vm-exit-code.txt"; fi
        exit 1
    fi
    if [[ -S "$machine/vphone.sock" ]] && vphone_host_request "$machine/vphone.sock" '{"t":"rpc","method":"device.info","params":{},"screen":false}' > "$out/device-ready.json" 2> "$out/device-error.log"; then
        if (( first_pose && !first_pose_done )); then
            first_pose_done=1
            expected_agent=$(shasum -a 256 "$bundle/Contents/Resources/guest-resources/vphoned")
            expected_agent=${expected_agent%% *}
            node "$reg/boot-first-pose.mjs" "$machine/vphone.sock" "$out/first-pose" "$expected_agent" "${first_pose_args[@]}" > "$out/first-pose.log" 2>&1 || touch "$out/first-pose-failed"
        fi
        if jq -e '.result.uptime_seconds >= 20' "$out/device-ready.json" >/dev/null; then ready=1; break; fi
    fi
    sleep 1
done
if (( ready )); then
    node "$reg/patch-port-runtime-check.mjs" "$machine/vphone.sock" "$out" "$bundle" "${agent_args[@]}" > "$out/check.log" 2>&1 || touch "$out/check-failed"
else
    touch "$out/not-ready"
fi
touch "$out/observations-complete"
# The operator runs saved regressions and restores the baseline before requesting stop.
while [[ ! -e "$out/stop" ]]; do sleep 1; done
vphone_host_request "$machine/vphone.sock" '{"t":"rpc","method":"system.shutdown","params":{"force":true},"screen":false}' > "$out/shutdown.json" 2> "$out/shutdown-error.log"
for attempt in {1..60}; do
    if ! lsof "$machine/Disk.img" "$machine/nvram.bin" "$machine/SEPStorage" > "$out/final-handles.txt"; then break; fi
    sleep 1
done
if lsof "$machine/Disk.img" "$machine/nvram.bin" "$machine/SEPStorage" > "$out/final-handles.txt"; then print -u2 'Shutdown incomplete'; exit 1; fi
if wait "$vm_pid"; then print 0 > "$out/vm-exit-code.txt"; else
    vm_status=$?
    print -r -- "$vm_status" > "$out/vm-exit-code.txt"
    exit "$vm_status"
fi
[[ ! -e "$out/not-ready" && ! -e "$out/check-failed" && ! -e "$out/first-pose-failed" ]]
