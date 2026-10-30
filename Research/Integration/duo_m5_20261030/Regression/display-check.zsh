#!/bin/zsh
# One display-configuration check on a disposable acceptance machine: boot
# windowed with the candidate bundle, record the configured display, guest
# libraries and patch receipt, posture replies, GeoBare's safe-area geometry,
# and whether host (VZ) and vphoned taps reach GeoBare at the application,
# window and view levels; then stop normally. It changes no configuration.
#   display-check.zsh <machine> <new-output-directory>
set -uo pipefail
source "${0:a:h}/rpc-request.zsh"
source "${0:a:h}/host-request.zsh"

repo_root="$(cd "${0:a:h}/../../../.." && pwd)"
machine="${1:?usage: display-check.zsh <machine> <new-output-directory>}"
output_root="${2:?new evidence directory required}"
[[ "$machine" == [a-zA-Z0-9]* && "$machine" != *[^a-zA-Z0-9_-]* && "$machine" != duo-*-20261030 && "$machine" != seed ]] \
    || { print -u2 'Use a disposable machine, not the baseline/candidate clones or the seed'; exit 2; }
bundle="$repo_root/.build/XcodeDuo/Build/Products/Debug/VPhone.bundle"
cli="$bundle/Contents/MacOS/vphone-cli"
library="$repo_root/.build/acceptance/machines"
socket_path="$library/$machine/vphone.sock"
[[ -d "$library/$machine" && "$output_root" == "$repo_root/.build/"* && ! -e "$output_root" ]] || exit 2
pgrep -f "vphone-vm.*/$machine" > /dev/null && { print -u2 "$machine is running"; exit 2; }
mkdir -p "$output_root"
cp "${0:a}" "$output_root/driver.zsh"
git -C "$repo_root" rev-parse HEAD > "$output_root/source-sha.txt"
cp "$library/$machine/config.plist" "$library/$machine/PatchReceipt.plist" "$output_root/" 2>/dev/null
cp "$library/$machine/PatchSelection.plist" "$output_root/" 2>/dev/null

rpc() { vphone_host_request "$socket_path" "$(vphone_rpc_request "$@")" 2>&1; }
host() { vphone_host_request "$socket_path" "$1" 2>&1; }
note() { print -r -- "$1" | tee -a "$output_root/results.txt"; }
geobare_file() {
    local data_path
    data_path=$(rpc apps.list '{"filter":"user"}' | jq -er '.result.apps[]|select(.bundle_id=="com.autophone.geobare")|.data_path') || return 1
    rpc files.read "$(jq -nc --arg p "$data_path/Documents/$1" '{path:$p}')" | jq -r '.result.content // ""'
}
lines() { geobare_file "$1" | grep -c . ; }

"$cli" vm launch "$machine" -l "$library" -v > "$output_root/boot.log" 2>&1 &
launch_pid=$!
t0=$(date +%s); ready=""
while (( $(date +%s) - t0 < 300 )); do
    rpc device.info | jq -e '.ok == true' > /dev/null 2>&1 && { ready=$(( $(date +%s) - t0 )); break; }
    kill -0 $launch_pid 2>/dev/null || break
    /bin/sleep 2
done
[[ -n "$ready" ]] || { note "$machine: vphoned not ready"; "$cli" vm stop "$machine" -l "$library" > "$output_root/stop.log" 2>&1; wait $launch_pid; exit 1; }
/bin/sleep 60
note "machine=$machine vphoned_ready=${ready}s display=$("$cli" vm info "$machine" -l "$library" 2>/dev/null | sed -n 's/^ *display: *//p' | head -1)"
note "unlock: $(rpc screen.unlock '{"timeout":30}' | jq -c '.ok')"
rpc device.screen > "$output_root/screen.json"
host '{"t":"display.geometry","screen":false}' > "$output_root/geometry.json"
note "screen: $(jq -c '.result|{width,height,orientation,scale}' "$output_root/screen.json") geometry: $(jq -c '.result|{configured_pixels,screenshot_pixels,windowed}' "$output_root/geometry.json")"
rpc files.list '{"path":"/usr/lib"}' > "$output_root/usr-lib.json"
note "guest libraries: $(jq -r '[.. | strings | select(test("lib(innercutoutfix|vphonefolddisplay|vphonefoldguard)\\.dylib$")) | sub(".*/"; "")] | unique | join(",")' "$output_root/usr-lib.json")"
note "receipt guest patches: $(/usr/bin/plutil -convert json -o - "$library/$machine/PatchReceipt.plist" 2>/dev/null | jq -r '[.. | strings | select(test("inner_cutout|fold_display|fold_guard"))] | unique | join(",")')"
for hinge in closed open-flat; do
    rpc display.posture "$(jq -nc --arg h "$hinge" '{hinge:$h}')" > "$output_root/posture-$hinge.json"
    /bin/sleep 3
    note "posture $hinge: $(jq -c '{ok,error}' "$output_root/posture-$hinge.json") screen=$(rpc device.screen | jq -c '.result|[.width,.height]')"
done
rpc display.posture '{"hinge":"closed"}' > /dev/null 2>&1; /bin/sleep 3
host "$(jq -nc --arg p "$output_root/home.jpg" '{t:"screenshot",path:$p}')" > /dev/null

rpc apps.terminate '{"bundle_id":"com.autophone.geobare"}' > /dev/null 2>&1
rpc apps.launch '{"bundle_id":"com.autophone.geobare"}' > "$output_root/geobare-launch.json"
/bin/sleep 4
geobare_file geometry.json > "$output_root/geobare-geometry.json"
note "GeoBare geometry: $(jq -c '{window: .window.bounds, safe: (.safeAreaInsets // .window.safeAreaInsets), status: (.statusBarFrame // .statusBar)}' "$output_root/geobare-geometry.json" 2>/dev/null)"
host "$(jq -nc --arg p "$output_root/geobare.jpg" '{t:"screenshot",path:$p}')" > /dev/null
read w h <<< "$(rpc device.screen | jq -r '.result|"\(.width) \(.height)"')"
read pw ph <<< "$(host '{"t":"display.geometry","screen":false}' | jq -r '.result.screenshot_pixels|"\(.[0]) \(.[1])"')"
for route in host vphoned; do
    before=($(lines app-events.log) $(lines events.log) $(lines touches.log))
    for point in "0.3 0.35" "0.7 0.35" "0.3 0.7" "0.7 0.7"; do
        read fx fy <<< "$point"
        if [[ "$route" == host ]]; then
            host "$(jq -nc --argjson x $(( pw * fx )) --argjson y $(( ph * fy )) '{t:"tap",x:($x|floor),y:($y|floor),screen:false}')" > /dev/null
        else
            rpc input.tap "$(jq -nc --argjson x $(( w * fx )) --argjson y $(( h * fy )) '{x:($x|floor),y:($y|floor)}')" > /dev/null
        fi
        /bin/sleep 0.8
    done
    /bin/sleep 1
    after=($(lines app-events.log) $(lines events.log) $(lines touches.log))
    note "GeoBare $route taps 4: app_events +$(( after[1] - before[1] )) window_events +$(( after[2] - before[2] )) touchesBegan +$(( after[3] - before[3] ))"
done
rpc logs.crashes | jq -r '.result.crashes[]?.name' | sort > "$output_root/crashes.txt"
note "SpringBoard: $(rpc processes.list | jq -c '[.result.processes[]|select(.name=="SpringBoard")|.pid]')"
"$cli" vm stop "$machine" -l "$library" > "$output_root/stop.log" 2>&1 || note "stop failed"
wait $launch_pid
note "stopped $(date '+%F %T')"
