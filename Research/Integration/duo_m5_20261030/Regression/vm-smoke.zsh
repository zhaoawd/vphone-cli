#!/bin/zsh
# Regression against an already-running isolated acceptance VM. Changes its
# posture, foreground app and lock state; captures evidence without deleting it.
set -euo pipefail
source "${0:a:h}/rpc-request.zsh"
source "${0:a:h}/host-request.zsh"

repo_root="$(cd "${0:a:h}/../../../.." && pwd)"
socket_path="${1:?usage: vm-smoke.zsh <acceptance-socket> <new-output-directory> [fold-cycles]}"
output_root="${2:?a new evidence directory is required}"
fold_cycles="${3:-6}"
[[ "$fold_cycles" == <-> ]] && (( fold_cycles > 0 && fold_cycles <= 100 )) || exit 2
# Keep this helper away from existing machine libraries.
[[ "$socket_path" == "$repo_root/.build/"* && -S "$socket_path" ]] || {
    print -u2 'Expected a running acceptance VM socket below this worktree/.build'
    exit 2
}
[[ "$output_root" == "$repo_root/.build/"* && ! -e "$output_root" ]] || { print -u2 'Evidence directory must be new and below this worktree/.build'; exit 2; }
mkdir -p "$output_root"
cp "${0:a}" "$output_root/driver.zsh"
shasum -a 256 "${0:a}" > "$output_root/driver-sha256.txt"

host_request() {
    vphone_host_request "$socket_path" "$1"
}
rpc() {
    local request
    request=$(vphone_rpc_request "$@") || return 1
    host_request "$request"
}
capture() {
    local label="$1"
    rpc device.screen > "$output_root/$label-screen.json"
    if (( $# >= 2 )); then
        jq -e --argjson orientation "$2" '.result.orientation == $orientation' "$output_root/$label-screen.json" >/dev/null
    fi
    host_request '{"t":"display.geometry"}' > "$output_root/$label-geometry.json"
    host_request "$(jq -nc --arg path "$output_root/$label.jpg" '{t:"screenshot",path:$path}')" > "$output_root/$label-shot.json"
    [[ -f "$output_root/$label.jpg" ]]
}
process_ids() {
    rpc processes.list | jq -ce '[.result.processes[] | select(.name == "SpringBoard" or .name == "backboardd") | {name,pid}] | sort_by(.name) | select(length == 2)'
}
posture() {
    rpc display.posture "$(jq -nc --arg hinge "$1" '{hinge:$hinge}')" > "$output_root/$2-posture.json"
}

git -C "$repo_root" rev-parse HEAD > "$output_root/source-sha.txt"
sw_vers > "$output_root/host.txt"
rpc device.info > "$output_root/device-info.json"
rpc logs.crashes > "$output_root/crashes-before.json"
process_ids > "$output_root/processes-before.json"
rpc screen.unlock '{"timeout":30}' > "$output_root/unlock.json"
rpc apps.launch '{"bundle_id":"com.apple.mobilesafari"}' > "$output_root/safari.json"

for hinge in closed open-flat; do
    posture "$hinge" "$hinge"
    sleep 3
    for orientation in portrait landscape-left landscape-right upside-down; do
        # Current relay controls have no UIDevice upside-down pose. The
        # cover maps that to interface 180; the inner panel maps it to 270.
        if [[ "$hinge/$orientation" == closed/upside-down || "$hinge/$orientation" == open-flat/landscape-right ]]; then
            rpc device.screen > "$output_root/$hinge-$orientation-before.json"
            if rpc display.rotation "$(jq -nc --arg orientation "$orientation" '{orientation:$orientation}')" \
                > "$output_root/$hinge-$orientation-reply.json" 2> "$output_root/$hinge-$orientation-error.json"; then
                print -u2 "Unsupported relay pose unexpectedly succeeded: $hinge/$orientation"
                exit 1
            fi
            jq -se 'length == 1 and .[0].ok == false and .[0].guest_error.code == "invalid_operation" and .[0].error == "the host controls have no upside-down orientation"' \
                "$output_root/$hinge-$orientation-error.json" >/dev/null
            rpc device.screen > "$output_root/$hinge-$orientation-after.json"
            jq -se '.[0].result.orientation == .[1].result.orientation' \
                "$output_root/$hinge-$orientation-before.json" "$output_root/$hinge-$orientation-after.json" >/dev/null
            continue
        fi
        case "$orientation" in
            portrait) degrees=0 ;;
            landscape-left) degrees=90 ;;
            landscape-right) degrees=270 ;;
            upside-down) degrees=180 ;;
        esac
        rpc display.rotation "$(jq -nc --arg orientation "$orientation" '{orientation:$orientation}')" \
            > "$output_root/$hinge-$orientation-rotation.json"
        sleep 2
        capture "$hinge-$orientation" "$degrees"
    done
done

for ((cycle = 1; cycle <= fold_cycles; cycle++)); do
    posture closed "cycle-$cycle-closed"
    sleep 1
    posture open-flat "cycle-$cycle-open"
    sleep 1
done
capture after-folds
process_ids > "$output_root/processes-after-folds.json"
cmp "$output_root/processes-before.json" "$output_root/processes-after-folds.json"

# A fold made in the dark must remain locked after it wakes the screen.
posture closed before-dark
sleep 3
rpc input.button '{"name":"power"}' > "$output_root/power.json"
sleep 2
rpc device.screen > "$output_root/dark-screen.json"
jq -e '.result.locked == true and .result.screen_off == true' "$output_root/dark-screen.json" >/dev/null
posture open-flat dark-open
sleep 4
capture dark-open
jq -e '.result.locked == true' "$output_root/dark-open-screen.json" >/dev/null
rpc screen.unlock '{"timeout":30}' > "$output_root/unlock-after-dark.json"
posture closed final-closed
sleep 3
capture final
process_ids > "$output_root/processes-after.json"
cmp "$output_root/processes-before.json" "$output_root/processes-after.json"
rpc logs.crashes > "$output_root/crashes-after.json"
print 'VM smoke passed: RPCs, fold/rotation sequence, dark fold lock state, stable SpringBoard/backboardd'
print 'Screenshots and raw replies still require geometry/visual assessment; black-frame timing and touch accuracy are separate acceptance checks.'
print "Evidence: $output_root"
