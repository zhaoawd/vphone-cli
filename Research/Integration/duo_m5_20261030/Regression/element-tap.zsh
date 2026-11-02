#!/bin/zsh
# Requires a disposable, running Duo VM with this candidate and TapProbe.
set -euo pipefail
source "${0:a:h}/rpc-request.zsh"
source "${0:a:h}/host-request.zsh"

socket_path="${1:?usage: element-tap.zsh <vphone.sock> <new-output-directory>}"
output_root="${2:?new output directory required}"
[[ -S "$socket_path" && ! -e "$output_root" ]] || exit 2
mkdir -p "$output_root"
socket_path="${socket_path:a}"
output_root="${output_root:a}"
cp "${0:a}" "$output_root/driver.zsh"
git -C "${0:a:h}/../../../.." rev-parse HEAD > "$output_root/source-sha.txt"
rpc() { vphone_host_request "$socket_path" "$(vphone_rpc_request "$@")"; }
id=com.autophone.tap-probe
rpc screen.unlock '{"timeout":30}' > "$output_root/unlock.json"
rpc device.info > "$output_root/device-before.json"
rpc display.modes > "$output_root/displays-before.json"
rpc apps.launch "$(jq -nc --arg id "$id" '{bundle_id:$id}')" > "$output_root/launch.json"
data_path=$(rpc apps.list '{"filter":"user"}' | jq -er --arg id "$id" '.result.apps[]|select(.bundle_id==$id)|.data_path')
probe() {
    rpc files.read "$(jq -nc --arg p "$data_path/Documents/tap-probe.json" '{path:$p}')" | jq -er '.result.content' | jq -ce .
}
print -r -- $'posture\trotation\tresult' > "$output_root/rotations.tsv"
print -r -- $'posture\trotation\tidentifier\tcount' > "$output_root/taps.tsv"
/bin/sleep 2
initial_pid=$(probe | jq -er '.pid')
case_index=0
for posture in closed open-flat closed open-flat partially-open closed; do
    ((case_index += 1))
    case_root="$output_root/$(printf '%02d' "$case_index")-$posture"
    mkdir -p "$case_root"
    rpc display.posture "$(jq -nc --arg h "$posture" '{hinge:$h}')" > "$case_root/posture.json"
    for rotation in portrait landscape-left upside-down landscape-right; do
        rpc screen.unlock '{"timeout":30}' > "$case_root/$rotation-unlock.json"
        if rpc display.rotation "$(jq -nc --arg o "$rotation" '{orientation:$o}')" > "$case_root/$rotation.json" 2> "$case_root/$rotation-error.txt"; then
            printf '%s\t%s\tapplied\n' "$posture" "$rotation" >> "$output_root/rotations.tsv"
        else
            # Preserve the refusal separately; it is never counted as a pass.
            /usr/bin/grep -q 'the host controls have no upside-down orientation' "$case_root/$rotation-error.txt" || {
                cat "$case_root/$rotation-error.txt" >&2
                exit 1
            }
            printf '%s\t%s\trefused\n' "$posture" "$rotation" >> "$output_root/rotations.tsv"
            continue
        fi
        /bin/sleep 2
        rpc display.modes > "$case_root/$rotation-displays.json"
        rpc ui.tree > "$case_root/$rotation-tree.json"
        for index in {0..8}; do
            identifier="tap-$index"
            before=$(probe)
            rpc ui.tap_element "$(jq -nc --arg i "$identifier" '{identifier:$i}')" > "$case_root/$rotation-$identifier-reply.json"
            for attempt in {1..10}; do
                /bin/sleep 0.2
                after=$(probe)
                jq -en --argjson b "$before" --argjson a "$after" '$a.total != $b.total' >/dev/null && break
            done
            print -r -- "$after" > "$case_root/$rotation-$identifier-probe.json"
            jq -en --argjson b "$before" --argjson a "$after" --arg i "$identifier" --argjson pid "$initial_pid" '
                $a.pid == $pid and $a.last_identifier == $i and
                $a.total == ($b.total + 1) and $a.counts[$i] == ($b.counts[$i] + 1)' >/dev/null
            printf '%s\t%s\t%s\t%s\n' "$posture" "$rotation" "$identifier" "$(jq -r '.total' <<< "$after")" >> "$output_root/taps.tsv"
        done
    done
done
# Both panels must have produced distinct app geometry; successful calls on
# an unchanged cover display do not establish inner-panel acceptance.
jq -s -e '[.[].scene] | unique | length >= 2' "$output_root"/*/*-probe.json > "$output_root/geometry-verdict.json"
rpc display.posture '{"hinge":"closed"}' > "$output_root/closed-final.json"
rpc device.info > "$output_root/device-after.json"
print 'Element taps verified by TapProbe UIControl actions; review rotations.tsv for refused directions.'
