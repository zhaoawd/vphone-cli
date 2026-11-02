#!/bin/zsh
# Requires a disposable, running Duo VM with this candidate and TapProbe.
set -euo pipefail
source "${0:a:h}/rpc-request.zsh"
source "${0:a:h}/host-request.zsh"

socket_path="${1:?usage: element-tap.zsh <vphone.sock> <new-output-directory> [native|compatibility]}"
output_root="${2:?new output directory required}"
layout="${3:-native}"
[[ "$layout" == native || "$layout" == compatibility ]] || exit 2
[[ -S "$socket_path" && ! -e "$output_root" ]] || exit 2
mkdir -p "$output_root"
socket_path="${socket_path:a}"
output_root="${output_root:a}"
cp "${0:a}" "$output_root/driver.zsh"
print -r -- "$layout" > "$output_root/layout.txt"
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
        expected_inner=1
        [[ "$posture" == closed ]] && expected_inner=0
        jq -e --argjson expected "$expected_inner" '
            [.result.displays[] | select(.name == "VPhone Duo Inner" or .deviceName == "VPhone Duo Inner")]
            | length == 1 and .[0].state.displayState == $expected' \
            "$case_root/$rotation-displays.json" >/dev/null
        rpc ui.tree > "$case_root/$rotation-tree.json"
        case "$rotation" in
            portrait) expected_orientation=1; expected_degrees=0 ;;
            landscape-left) expected_orientation=4; expected_degrees=90 ;;
            upside-down) expected_orientation=2; expected_degrees=180 ;;
            landscape-right) expected_orientation=3; expected_degrees=270 ;;
        esac
        # rotationInfo also reads screenshot metrics, which can retain the
        # previous turn in the command reply. Verify SpringBoard directly.
        for attempt in {1..20}; do
            rpc display.orientation > "$case_root/$rotation-orientation.json"
            if jq -e --argjson expected "$expected_degrees" \
                '.result.source == "springboard" and .result.degrees == $expected' \
                "$case_root/$rotation-orientation.json" >/dev/null; then break; fi
            /bin/sleep 0.5
        done
        jq -e --argjson expected "$expected_degrees" \
            '.result.source == "springboard" and .result.degrees == $expected' \
            "$case_root/$rotation-orientation.json" >/dev/null
        for attempt in {1..20}; do
            probe > "$case_root/$rotation-layout.json"
            # A compatibility canvas can stay portrait on the turned inner
            # panel. Record its actual geometry; parent rotation is read above.
            if [[ "$layout" == compatibility && "$posture" != closed ]]; then break; fi
            if jq -e --argjson expected "$expected_orientation" '.orientation == $expected' \
                "$case_root/$rotation-layout.json" >/dev/null; then break; fi
            /bin/sleep 0.5
        done
        if [[ "$layout" == native || "$posture" == closed ]]; then
            jq -e --argjson expected "$expected_orientation" '.orientation == $expected' \
                "$case_root/$rotation-layout.json" >/dev/null
        fi
        for index in {0..8}; do
            identifier="tap-$index"
            before=$(probe)
            print -r -- "$before" > "$case_root/$rotation-$identifier-before.json"
            rpc ui.tap_element "$(jq -nc --arg i "$identifier" '{identifier:$i}')" > "$case_root/$rotation-$identifier-reply.json"
            for attempt in {1..10}; do
                /bin/sleep 0.2
                after=$(probe)
                if jq -en --argjson b "$before" --argjson a "$after" '$a.total != $b.total' >/dev/null; then break; fi
            done
            print -r -- "$after" > "$case_root/$rotation-$identifier-probe.json"
            jq -en --argjson b "$before" --argjson a "$after" --arg i "$identifier" --argjson pid "$initial_pid" '
                $a.pid == $pid and $a.last_identifier == $i and
                $a.total == ($b.total + 1) and $a.counts[$i] == ($b.counts[$i] + 1)' >/dev/null
            rpc files.read "$(jq -nc --arg p "$data_path/Documents/tap-touch.json" '{path:$p}')" \
                | jq -er '.result.content' > "$case_root/$rotation-$identifier-touch.json"
            jq -e --arg id "$identifier" --slurpfile reply "$case_root/$rotation-$identifier-reply.json" '
                .[0] as $touch | $reply[0].result.element as $element |
                $touch.phase == 3 and $touch.identifier == $id and
                (($touch.x - $element.x)|fabs) <= 1 and (($touch.y - $element.y)|fabs) <= 1' \
                "$case_root/$rotation-$identifier-touch.json" >/dev/null
            printf '%s\t%s\t%s\t%s\n' "$posture" "$rotation" "$identifier" "$(jq -r '.total' <<< "$after")" >> "$output_root/taps.tsv"
        done
    done
done
# Check the expected native/compatibility canvas behavior. Actual panel
# handover is established separately by each CADisplay state read above.
jq -s -e --arg layout "$layout" '
    if $layout == "native" then (.[0].scene | sort) != (.[1].scene | sort)
    else (.[0].scene | sort) == (.[1].scene | sort) end' \
    "$output_root/01-closed/portrait-tap-0-probe.json" \
    "$output_root/02-open-flat/portrait-tap-0-probe.json" > "$output_root/geometry-verdict.json"
rpc display.posture '{"hinge":"closed"}' > "$output_root/closed-final.json"
rpc device.info > "$output_root/device-after.json"
print 'Element taps verified by TapProbe UIControl actions; review rotations.tsv for refused directions.'
