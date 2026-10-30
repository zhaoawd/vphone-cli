#!/bin/zsh
# Regression against an already-running isolated acceptance VM. Changes its
# posture, foreground app and lock state; captures evidence without deleting it.
set -euo pipefail
source "${0:a:h}/rpc-request.zsh"

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
[[ ! -e "$output_root" ]] || { print -u2 'Evidence directory must be new'; exit 2; }
mkdir -p "$output_root"

host_request() {
    local response
    response=$(print -r -- "$1" | nc -U -w 40 "$socket_path")
    print -r -- "$response" | jq -e '.ok == true' >/dev/null || {
        print -u2 -- "$response"
        return 1
    }
    print -r -- "$response"
}
rpc() {
    local request
    request=$(vphone_rpc_request "$@") || return 1
    host_request "$request"
}
capture() {
    local label="$1" image_path
    rpc device.screen > "$output_root/$label-screen.json"
    host_request '{"t":"display.geometry"}' > "$output_root/$label-geometry.json"
    host_request '{"t":"screenshot"}' > "$output_root/$label-shot.json"
    image_path=$(jq -er '.path' "$output_root/$label-shot.json")
    [[ -f "$image_path" ]]
    cp "$image_path" "$output_root/$label.jpg"
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
        rpc display.rotation "$(jq -nc --arg orientation "$orientation" '{orientation:$orientation}')" \
            > "$output_root/$hinge-$orientation-rotation.json"
        sleep 2
        capture "$hinge-$orientation"
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
