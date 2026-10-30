#!/bin/zsh
# F2 keyboard modes on a windowed acceptance VM, with KBProbe and KBProbeFS.
# Hardware mode: keys typed through the window's host key path (`hostkey`,
# the same events a Mac keyboard gives the VM view). Software mode: bit 0 of
# `GSEventHardwareKeyboardAttached` cleared, as Device > Toggle Software
# Keyboard does; keys are tapped on the guest's own keyboard. For each mode,
# app and starting display it records focus, text and keyboard visibility,
# then opens/closes with the field focused and records them again.
#   kb-modes.zsh <baseline|candidate> <new-output-directory>
set -euo pipefail
source "${0:a:h}/rpc-request.zsh"
source "${0:a:h}/host-request.zsh"

repo_root="$(cd "${0:a:h}/../../../.." && pwd)"
variant="${1:?usage: kb-modes.zsh <baseline|candidate> <new-output-directory>}"
output_root="${2:?new evidence directory required}"
[[ "$variant" == baseline || "$variant" == candidate ]] || exit 2
socket_path="$repo_root/.build/acceptance/machines/duo-$variant-20261030/vphone.sock"
[[ -S "$socket_path" && "$output_root" == "$repo_root/.build/"* && ! -e "$output_root" ]] || exit 2
mkdir -p "$output_root"
cp "${0:a}" "$output_root/driver.zsh"
shasum -a 256 "${0:a}" > "$output_root/driver-sha256.txt"
git -C "$repo_root" rev-parse HEAD > "$output_root/source-sha.txt"

rpc() { vphone_host_request "$socket_path" "$(vphone_rpc_request "$@")"; }
host() { vphone_host_request "$socket_path" "$1"; }
notify_name=GSEventHardwareKeyboardAttached
keyboard_state() { rpc notify.state "$(jq -nc --arg n $notify_name '{name:$n}')" | jq -r '.result.state'; }
set_keyboard_state() { rpc notify.post "$(jq -nc --arg n $notify_name --arg s "$1" '{name:$n,state:$s}')" > /dev/null; }
# Keys of the guest's keyboard in the app's accessibility tree. This also
# counts hidden keys in hardware mode; screenshots decide visibility.
keyboard_keys() {
    rpc ui.tree '{"nested":true}' | jq '[.. | objects | select(has("frame")) | (.label // "") | select(. == "delete" or . == "space" or . == "q")] | length'
}
probe_state() { # probe_state <bundle-id> <label>
    local data_path
    data_path=$(rpc apps.list '{"filter":"user"}' | jq -er --arg id "$1" '.result.apps[]|select(.bundle_id==$id)|.data_path')
    rpc files.read "$(jq -nc --arg path "$data_path/Documents/kbprobe.json" '{path:$path}')" \
        | jq -er '.result.content' | jq -c . > "$output_root/$2.json"
}
# vphoned's `ui.tap_element` reports inner-display points but injects them
# as primary-panel points, so it misses on the inner display. Taps go through
# the window instead: the element's centre as a fraction of the app's scene,
# scaled to screenshot pixels.
host_tap_element() { # host_tap_element <jq-selector-arg> <value> <scene-json>
    local frame sw sh pw ph
    frame=$(rpc ui.tree '{"nested":true}' | jq -ce --arg v "$2" \
        "first(.. | objects | select(has(\"frame\")) | select((.$1 // \"\" | ascii_downcase) == (\$v | ascii_downcase)) | .frame)") || return 1
    read sw sh <<< "$(jq -r '.scene|"\(.[0]) \(.[1])"' "$3")"
    read pw ph <<< "$(host '{"t":"display.geometry","screen":false}' | jq -r '.result.screenshot_pixels|"\(.[0]) \(.[1])"')"
    host "$(jq -nc --argjson f "$frame" --argjson sw $sw --argjson sh $sh --argjson pw $pw --argjson ph $ph \
        '{t:"tap",x:((($f.x+$f.width/2)/$sw*$pw)|floor),y:((($f.y+$f.height/2)/$sh*$ph)|floor),screen:false}')" > /dev/null
}
record() { # record <bundle-id> <label> <mode> <app> <start> <step>
    /bin/sleep 3
    probe_state "$1" "$2"
    host "$(jq -nc --arg p "$output_root/$2.jpg" '{t:"screenshot",path:$p}')" > /dev/null
    jq -r --arg m "$3" --arg a "$4" --arg s "$5" --arg st "$6" --argjson k "$(keyboard_keys)" \
        '[$m,$a,$s,$st,.first_responder,.text,$k,.window_hidden,(.scene|map(tostring)|join("x"))]|@tsv' \
        "$output_root/$2.json" | tee -a "$result"
}

result="$output_root/result.tsv"
print -r -- $'mode\tapp\tstart\tstep\tfirst_responder\ttext\tkeyboard_keys\twindow_hidden\tscene' > "$result"
rpc screen.unlock '{"timeout":30}' > "$output_root/unlock.json"
host '{"t":"display.geometry","screen":false}' | jq -e '.result.windowed == true' >/dev/null \
    || { print -u2 'Host keys need a windowed launch'; exit 1; }
original=$(keyboard_state)
print -r -- "$original" > "$output_root/keyboard-state-original.txt"
(( original & 1 )) || { print -u2 "Hardware keyboard not attached at start (state $original)"; exit 1; }
trap 'set_keyboard_state "$original"' EXIT

for mode in hardware software; do
    if [[ "$mode" == software ]]; then
        set_keyboard_state $(( original & ~1 ))
    else
        set_keyboard_state "$original"
    fi
    /bin/sleep 1
    keyboard_state > "$output_root/keyboard-state-$mode.txt"
    for app in kbprobe kbprobe.fs; do
        id="com.autophone.$app"
        for start in closed open; do
            other=$([[ "$start" == closed ]] && print open || print closed)
            label="$mode-$app-$start"
            rpc display.posture "$(jq -nc --arg h "$start" '{hinge:$h}')" > /dev/null
            rpc display.rotation '{"orientation":"portrait"}' > /dev/null 2>&1 || true
            rpc apps.terminate "$(jq -nc --arg id "$id" '{bundle_id:$id}')" > /dev/null 2>&1 || true
            rpc apps.launch "$(jq -nc --arg id "$id" '{bundle_id:$id}')" > /dev/null
            /bin/sleep 3
            probe_state "$id" "$label-launched"
            host_tap_element identifier kb-field "$output_root/$label-launched.json" || print -u2 "$label: no kb-field"
            /bin/sleep 1.5
            if [[ "$mode" == hardware ]]; then
                for key in h w; do host "$(jq -nc --arg k $key '{t:"hostkey",keys:$k,screen:false}')" > /dev/null; done
            else
                for key in s w; do
                    host_tap_element label $key "$output_root/$label-launched.json" || print -u2 "$label: no key $key"
                    /bin/sleep 0.4
                done
            fi
            record "$id" "$label-typed" "$mode" "$app" "$start" typed
            rpc display.posture "$(jq -nc --arg h "$other" '{hinge:$h}')" > /dev/null
            record "$id" "$label-$other" "$mode" "$app" "$start" "$other"
            rpc display.posture "$(jq -nc --arg h "$start" '{hinge:$h}')" > /dev/null
            record "$id" "$label-back" "$mode" "$app" "$start" back
        done
    done
done
set_keyboard_state "$original"
trap - EXIT
keyboard_state > "$output_root/keyboard-state-final.txt"
rpc display.posture '{"hinge":"closed"}' > /dev/null
