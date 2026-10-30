#!/bin/zsh
# F6 locked-screen idle of an isolated acceptance clone, headless (default
# 120 min). Every 10 min: uptime, launchd and kernel_task CPU, SpringBoard/
# backboardd/vphoned PIDs, memory pressure, lock and screen state, crash
# reports newer than the start. After the window, before a normal stop: open
# while locked, unlock, close, a vphoned tap and a host tap on the cover,
# each checked. Ported from the v1.6 run/fold214/f6-idle.sh.
#   f6-idle.zsh <baseline|candidate> <new-output-directory> [minutes]
set -uo pipefail
source "${0:a:h}/rpc-request.zsh"
source "${0:a:h}/host-request.zsh"

repo_root="$(cd "${0:a:h}/../../../.." && pwd)"
variant="${1:?usage: f6-idle.zsh <baseline|candidate> <new-output-directory> [minutes]}"
output_root="${2:?new evidence directory required}"
minutes="${3:-120}"
[[ "$variant" == baseline || "$variant" == candidate ]] || exit 2
[[ "$minutes" == <-> ]] && (( minutes >= 10 && minutes <= 600 )) || exit 2
case "$variant" in
    baseline) bundle="$repo_root/.build/validation/baseline/artifacts/VPhone.bundle" ;;
    candidate) bundle="$repo_root/.build/XcodeDuo/Build/Products/Debug/VPhone.bundle" ;;
esac
cli="$bundle/Contents/MacOS/vphone-cli"
machine="duo-$variant-20261030"
library="$repo_root/.build/acceptance/machines"
socket_path="$library/$machine/vphone.sock"
[[ "$output_root" == "$repo_root/.build/"* && ! -e "$output_root" ]] || exit 2
zsh "${0:a:h}/vm-run.zsh" "$variant" preflight --check > /dev/null || exit 1
pgrep -f "vphone-vm.*/$machine" > /dev/null && { print -u2 "$machine is running"; exit 2; }
mkdir -p "$output_root"
cp "${0:a}" "$output_root/driver.zsh"
shasum -a 256 "${0:a}" > "$output_root/driver-sha256.txt"
git -C "$repo_root" rev-parse HEAD > "$output_root/source-sha.txt"

rpc() { vphone_host_request "$socket_path" "$(vphone_rpc_request "$@")" 2>/dev/null; }
host() { vphone_host_request "$socket_path" "$1" 2>/dev/null; }
note() { print -r -- "$1" | tee -a "$output_root/summary.txt"; }
shot() { host "$(jq -nc --arg p "$output_root/$1.jpg" '{t:"screenshot",path:$p}')" > /dev/null; }
# A field of the named process in the latest `processes.list` reply ($ps).
field() { jq -r --arg n "$1" --arg f "$2" '[.result.processes[] | select(.name==$n or ($n=="launchd" and .pid==1)) | .[$f]][0] // "none"' <<< "$ps"; }
# Cover Home screen icons, in UI points, from this clone family's layout
# (checked against candidate-debug-1/home.jpg). `ui.tree` and `ui.ocr` do
# not serve the Home screen: no verified foreground app, no text recognition.
settings_point=(231 577)
dock_safari_point=(417 350)

"$cli" vm launch "$machine" -l "$library" --headless -v > "$output_root/boot.log" 2>&1 &
launch_pid=$!
t0=$(date +%s)
while (( $(date +%s) - t0 < 300 )); do
    [[ -S "$socket_path" ]] && rpc device.info | jq -e '.ok == true' > /dev/null 2>&1 && break
    /bin/sleep 2
done
/bin/sleep 60
rpc logs.crashes | jq -r '.result.crashes[]?.name' | sort > "$output_root/crashes-start.txt"
rpc display.posture '{"hinge":"closed"}' > /dev/null
rpc input.button '{"name":"power"}' > /dev/null; /bin/sleep 5
note "variant=$machine idle ${minutes} min from $(date '+%F %T')"
print -r -- $'time\tuptime_s\tlaunchd_cpu\tkernel_task_cpu\tSB\tBB\tvphoned\tmemory\tlocked\tscreen_off\tnew_crashes' > "$output_root/samples.tsv"
for n in $(seq 0 $(( minutes / 10 ))); do
    boot_time=$(rpc device.info | jq -r '.result.boot_time | floor')
    ps=$(rpc processes.list)
    memory=$(rpc memory.pressure | jq -c '.result // .error' | tr -d ' ')
    screen=$(rpc device.screen | jq -r '"\(.result.locked)\t\(.result.screen_off)"')
    rpc logs.crashes | jq -r '.result.crashes[]?.name' | sort > "$output_root/crashes-$n.txt"
    new=$(comm -13 "$output_root/crashes-start.txt" "$output_root/crashes-$n.txt" | sed -E 's/-[0-9]{4}-.*//' | sort | uniq -c | awk '{printf "%s=%s,", $2, $1}')
    print -r -- "$(date +%T)	$(( $(date +%s) - boot_time ))	$(field launchd cpu_seconds)	$(field kernel_task cpu_seconds)	$(field SpringBoard pid)	$(field backboardd pid)	$(field vphoned pid)	$memory	$screen	${new:-none}" \
        >> "$output_root/samples.tsv"
    (( n < minutes / 10 )) && /bin/sleep 600
done

# After the idle the guest must still answer.
rpc display.posture '{"hinge":"open-flat"}' > /dev/null; /bin/sleep 4
note "open while locked: $(rpc device.screen | jq -r '.result | "locked=\(.locked) off=\(.screen_off) \(.width)x\(.height)"')"
shot open-locked
note "unlock: $(rpc screen.unlock '{"timeout":30}' | jq -r 'if .ok then "ok" else "fail \(.error)" end')"
rpc display.posture '{"hinge":"closed"}' > /dev/null; /bin/sleep 3
rpc input.button '{"name":"home"}' > /dev/null; /bin/sleep 3
rpc input.tap "$(jq -nc --argjson x $settings_point[1] --argjson y $settings_point[2] '{x:$x,y:$y}')" > /dev/null; /bin/sleep 4
note "vphoned tap Settings -> $(rpc apps.foreground | jq -r '.result.bundle_id // "?"')"
rpc input.button '{"name":"home"}' > /dev/null; /bin/sleep 3
host "$(jq -nc --argjson x $(( dock_safari_point[1] * 3 )) --argjson y $(( dock_safari_point[2] * 3 )) '{t:"tap",x:$x,y:$y,screen:false}')" > /dev/null; /bin/sleep 4
note "host tap Dock Safari -> $(rpc apps.foreground | jq -r '.result.bundle_id // "?"')"
shot after-idle
"$cli" vm stop "$machine" -l "$library" > "$output_root/stop.log" 2>&1 || note "stop failed"
wait $launch_pid
note "done $(date '+%F %T')"
