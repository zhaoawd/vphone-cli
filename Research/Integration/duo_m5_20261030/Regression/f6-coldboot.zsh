#!/bin/zsh
# F6 cold boots of an isolated acceptance clone, headless, with its pinned
# bundle. Per boot: time to vphoned, launchd and kernel_task CPU at 180 s
# uptime, SpringBoard/backboardd/vphoned PIDs, unlock, a cover tap through
# vphoned (Settings) and through the host path (Safari in the Dock) with the
# foreground app after each, open-flat and closed screenshots, inner display
# events, new crash reports, then a normal stop.
# Ported from the v1.6 run/fold214/f6-coldboot.sh.
#   f6-coldboot.zsh <baseline|candidate> <new-output-directory> [boots] [machine]
# `machine` defaults to the variant's clone; an imported copy in the same
# acceptance library may be named instead.
set -uo pipefail
source "${0:a:h}/rpc-request.zsh"
source "${0:a:h}/host-request.zsh"

repo_root="$(cd "${0:a:h}/../../../.." && pwd)"
variant="${1:?usage: f6-coldboot.zsh <baseline|candidate> <new-output-directory> [boots] [machine]}"
output_root="${2:?new evidence directory required}"
boots="${3:-5}"
machine="${4:-duo-$variant-20261030}"
[[ "$variant" == baseline || "$variant" == candidate ]] || exit 2
[[ "$boots" == <-> ]] && (( boots > 0 && boots <= 20 )) || exit 2
[[ "$machine" == [a-zA-Z0-9]* && "$machine" != *[^a-zA-Z0-9_-]* ]] || exit 2
case "$variant" in
    baseline) bundle="$repo_root/.build/validation/baseline/artifacts/VPhone.bundle" ;;
    candidate) bundle="$repo_root/.build/XcodeDuo/Build/Products/Debug/VPhone.bundle" ;;
esac
cli="$bundle/Contents/MacOS/vphone-cli"
library="$repo_root/.build/acceptance/machines"
socket_path="$library/$machine/vphone.sock"
[[ -d "$library/$machine" && "$output_root" == "$repo_root/.build/"* && ! -e "$output_root" ]] || exit 2
# The pinned binaries and root marker are checked by the same preflight.
zsh "${0:a:h}/vm-run.zsh" "$variant" preflight --check > /dev/null || exit 1
pgrep -f "vphone-vm.*/$machine" > /dev/null && { print -u2 "$machine is running"; exit 2; }
mkdir -p "$output_root/shots" "$output_root/boot-logs"
cp "${0:a}" "$output_root/driver.zsh"
shasum -a 256 "${0:a}" > "$output_root/driver-sha256.txt"
git -C "$repo_root" rev-parse HEAD > "$output_root/source-sha.txt"

rpc() { vphone_host_request "$socket_path" "$(vphone_rpc_request "$@")" 2>/dev/null; }
host() { vphone_host_request "$socket_path" "$1" 2>/dev/null; }
note() { print -r -- "$1" | tee -a "$output_root/results.txt"; }
crashes() { rpc logs.crashes | jq -r '.result.crashes[]? | .name' | sort; }
pid_of() { jq -r --arg n "$2" '[.result.processes[] | select(.name==$n) | .pid][0] // "none"' <<< "$1"; }
fold_lines() { rpc files.read '{"path":"/var/mobile/Library/Caches/vphone-folddisplay.log"}' | jq -r '.result.content // ""'; }
shot() {
    host "$(jq -nc --arg p "$output_root/shots/$1.jpg" '{t:"screenshot",path:$p}')" > /dev/null
    sips -g pixelWidth -g pixelHeight "$output_root/shots/$1.jpg" 2>/dev/null | tail -2 | awk '{print $2}' | paste -sd x -
}
# Cover Home screen icons, in UI points, from this clone family's layout
# (checked against candidate-debug-1/home.jpg). `ui.tree` and `ui.ocr` do
# not serve the Home screen: no verified foreground app, no text recognition.
settings_point=(231 577)
dock_safari_point=(417 350)

note "variant=$variant machine=$machine started $(date '+%F %T')"
note "  vphone-vm cdhash: $(codesign -dvvv "$bundle/Contents/MacOS/vphone-vm" 2>&1 | sed -n 's/^CDHash=//p')"
crashes_seen="$output_root/crashes-seen.txt"
for i in $(seq 1 "$boots"); do
    t0=$(date +%s)
    "$cli" vm launch "$machine" -l "$library" --headless -v > "$output_root/boot-logs/boot-$i.log" 2>&1 &
    launch_pid=$!
    ready=""
    while (( $(date +%s) - t0 < 600 )); do
        if [[ -S "$socket_path" ]] && rpc device.info | jq -e '.ok == true' > /dev/null 2>&1; then
            ready=$(( $(date +%s) - t0 )); break
        fi
        kill -0 $launch_pid 2>/dev/null || break
        /bin/sleep 2
    done
    if [[ -z "$ready" ]]; then
        note "boot $i: vphoned not ready (launch alive: $(kill -0 $launch_pid 2>/dev/null && print yes || print no))"
        "$cli" vm stop "$machine" -l "$library" > "$output_root/boot-logs/stop-$i.log" 2>&1
        wait $launch_pid; continue
    fi
    [[ -s "$crashes_seen" ]] || crashes > "$crashes_seen"
    boot_time=$(rpc device.info | jq -r '.result.boot_time | floor')
    while (( $(date +%s) - boot_time < 180 )); do /bin/sleep 5; done
    up=$(( $(date +%s) - boot_time ))
    ps=$(rpc processes.list)
    launchd_cpu=$(jq -r '[.result.processes[] | select(.pid==1) | .cpu_seconds | floor][0] // "?"' <<< "$ps")
    kernel_cpu=$(jq -r '[.result.processes[] | select(.name=="kernel_task") | .cpu_seconds | floor][0] // "?"' <<< "$ps")
    pids="SB=$(pid_of "$ps" SpringBoard) BB=$(pid_of "$ps" backboardd) vphoned=$(pid_of "$ps" vphoned)"
    unlock=$(rpc screen.unlock '{"timeout":30}' | jq -r 'if .ok then "ok" else "fail" end')
    rpc display.posture '{"hinge":"closed"}' > /dev/null; /bin/sleep 2
    rpc input.button '{"name":"home"}' > /dev/null; /bin/sleep 3
    rpc input.tap "$(jq -nc --argjson x $settings_point[1] --argjson y $settings_point[2] '{x:$x,y:$y}')" > /dev/null; /bin/sleep 4
    guest=$(rpc apps.foreground | jq -r '.result.bundle_id // "?"')
    rpc input.button '{"name":"home"}' > /dev/null; /bin/sleep 3
    # Host taps take screenshot pixels: three per point on the cover.
    host "$(jq -nc --argjson x $(( dock_safari_point[1] * 3 )) --argjson y $(( dock_safari_point[2] * 3 )) '{t:"tap",x:$x,y:$y,screen:false}')" > /dev/null; /bin/sleep 4
    host_app=$(rpc apps.foreground | jq -r '.result.bundle_id // "?"')
    lines_before=$(fold_lines | wc -l)
    rpc display.posture '{"hinge":"open-flat"}' > /dev/null; /bin/sleep 4
    open=$(shot "boot-$i-open")
    rpc display.posture '{"hinge":"closed"}' > /dev/null; /bin/sleep 4
    closed=$(shot "boot-$i-closed")
    shown=$(fold_lines | tail -n +$(( lines_before + 1 )) | grep -c 'shown=1')
    sb_after=$(pid_of "$(rpc processes.list)" SpringBoard)
    rpc input.button '{"name":"home"}' > /dev/null; /bin/sleep 2
    crashes > "$output_root/crashes-$i.txt"
    new=$(comm -13 "$crashes_seen" "$output_root/crashes-$i.txt" | sed -E 's/-[0-9]{4}-.*//' | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}')
    cp "$output_root/crashes-$i.txt" "$crashes_seen"
    note "boot $i: vphoned_ready=${ready}s up=${up}s launchd_cpu=${launchd_cpu}s kernel_task=${kernel_cpu}s $pids unlock=$unlock guest_settings=$guest host_dock=$host_app open=$open inner_shown=$shown closed=$closed SB_after_fold=$sb_after new_crashes: ${new:-none}"
    "$cli" vm stop "$machine" -l "$library" > "$output_root/boot-logs/stop-$i.log" 2>&1 || note "  stop $i failed"
    wait $launch_pid
    /bin/sleep 5
done
note "done $(date '+%F %T')"
