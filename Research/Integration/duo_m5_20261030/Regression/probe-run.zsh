#!/bin/zsh
# Install native probes through installd, then capture app-owned measurements.
set -euo pipefail
source "${0:a:h}/rpc-request.zsh"
source "${0:a:h}/host-request.zsh"
repo_root="$(cd "${0:a:h}/../../../.." && pwd)"
variant="${1:?usage: probe-run.zsh <baseline|candidate> <device-probe-directory> <new-output-directory>}"
probe_root="${2:?device probes required}"
output_root="${3:?new evidence directory required}"
[[ "$variant" == baseline || "$variant" == candidate ]] || exit 2
machine="$repo_root/.build/acceptance/machines/duo-$variant-20261030"
socket_path="$machine/vphone.sock"
[[ -S "$socket_path" && "$output_root" == "$repo_root/.build/"* && ! -e "$output_root" ]] || exit 2
[[ "$probe_root" == "$repo_root/.build/"* && -f "$probe_root/Probe/Probe.ipa" ]] || exit 2
udid=$(sed -n 's/^UDID=//p' "$machine/udid-prediction.txt")
[[ -n "$udid" && "$udid" != *$'\n'* ]]
mkdir -p "$output_root"
idevice_id -l > "$output_root/connected-udids.txt"
rg -Fx -- "$udid" "$output_root/connected-udids.txt" >/dev/null
git -C "$repo_root" rev-parse HEAD > "$output_root/source-sha.txt"
cp "${0:a}" "$output_root/driver.zsh"
shasum -a 256 "${0:a}" > "$output_root/driver-sha256.txt"
print -r -- "$udid" > "$output_root/target-udid.txt"
rpc() { vphone_host_request "$socket_path" "$(vphone_rpc_request "$@")"; }
process_ids() {
    rpc processes.list | jq -ce '[.result.processes[] | select(.name == "SpringBoard" or .name == "backboardd") | {name,pid}] | sort_by(.name) | select(length == 2)'
}
read_document() {
    local id="$1" file="$2" label="$3" data_path
    data_path=$(jq -er --arg id "$id" '.result.apps[]|select(.bundle_id==$id)|.data_path' "$output_root/apps.json")
    rpc files.read "$(jq -nc --arg path "$data_path/Documents/$file" '{path:$path}')" > "$output_root/$label-file.json"
    jq -e '.result.truncated==false and .result.encoding=="utf8"' "$output_root/$label-file.json" >/dev/null
    jq -er '.result.content' "$output_root/$label-file.json" | jq -e . > "$output_root/$label.json"
}
capture() {
    local label="$1"
    rpc device.screen > "$output_root/$label-screen.json"
    rpc ui.tree > "$output_root/$label-ui.json"
    vphone_host_request "$socket_path" "$(jq -nc --arg path "$output_root/$label.jpg" '{t:"screenshot",path:$path}')" > "$output_root/$label-shot.json"
    [[ -s "$output_root/$label.jpg" ]]
}
rpc screen.unlock '{"timeout":30}' > "$output_root/unlock.json"
process_ids > "$output_root/processes-before.json"
rpc logs.crashes > "$output_root/crashes-before.json"
rpc apps.list '{"filter":"user"}' > "$output_root/apps-before-install.json"
for probe in GeoProbe GeoBare KBProbe KBProbeFS Probe; do
    case "$probe" in
        GeoProbe) id=com.autophone.geoprobe ;;
        GeoBare) id=com.autophone.geobare ;;
        KBProbe) id=com.autophone.kbprobe ;;
        KBProbeFS) id=com.autophone.kbprobe.fs ;;
        Probe) id=com.autophone.probe ;;
    esac
    if jq -e --arg id "$id" '.result.apps | any(.bundle_id==$id and .pid>0)' "$output_root/apps-before-install.json" >/dev/null; then
        rpc apps.terminate "$(jq -nc --arg id "$id" '{bundle_id:$id}')" > "$output_root/terminate-$probe.json"
    fi
    shasum -a 256 "$probe_root/$probe/$probe.ipa" >> "$output_root/ipa-sha256.txt"
    ideviceinstaller -u "$udid" install "$probe_root/$probe/$probe.ipa" > "$output_root/install-$probe.log" 2>&1
    print "Installed $probe on $variant"
done
rpc apps.list '{"filter":"user"}' > "$output_root/apps.json"
rpc apps.launch '{"bundle_id":"com.autophone.probe"}' > "$output_root/cssc-launch.json"
sleep 3
read_document com.autophone.probe cssc-probe.json cssc
jq -e '.correct==true and (.checks|length)==6 and (.checks|all(.==true))' "$output_root/cssc.json" >/dev/null
capture cssc

for app in geoprobe geobare; do
    id="com.autophone.$app"
    rpc apps.launch "$(jq -nc --arg id "$id" '{bundle_id:$id}')" > "$output_root/$app-launch.json"
    for hinge in closed open-flat; do
        rpc display.posture "$(jq -nc --arg hinge "$hinge" '{hinge:$hinge}')" > "$output_root/$app-$hinge-posture.json"
        sleep 3
        for orientation in portrait landscape-left; do
            label="$app-$hinge-$orientation"
            rpc display.rotation "$(jq -nc --arg orientation "$orientation" '{orientation:$orientation}')" > "$output_root/$label-rotation.json"
            sleep 3
            read_document "$id" geometry.json "$label"
            jq -e '.window.bounds.w>0 and .window.bounds.h>0 and .sceneCoordinateSpace.w>0 and .sceneCoordinateSpace.h>0' "$output_root/$label.json" >/dev/null
            capture "$label"
        done
    done
done

for app in kbprobe kbprobe.fs; do
    id="com.autophone.$app"
    rpc display.posture '{"hinge":"closed"}' > "$output_root/$app-start-posture.json"
    rpc display.rotation '{"orientation":"portrait"}' > "$output_root/$app-start-rotation.json"
    rpc apps.launch "$(jq -nc --arg id "$id" '{bundle_id:$id}')" > "$output_root/$app-launch.json"
    sleep 3
    rpc ui.tap_element '{"identifier":"kb-field"}' > "$output_root/$app-focus.json"
    rpc input.type '{"text":"duo-focus-20261030"}' > "$output_root/$app-type.json"
    for hinge in open-flat closed; do
        rpc display.posture "$(jq -nc --arg hinge "$hinge" '{hinge:$hinge}')" > "$output_root/$app-$hinge-posture.json"
        sleep 3
        read_document "$id" kbprobe.json "$app-$hinge"
        jq -e '.first_responder==true and .text=="duo-focus-20261030" and .window_hidden==false' "$output_root/$app-$hinge.json" >/dev/null
        capture "$app-$hinge"
    done
done
process_ids > "$output_root/processes-after.json"
cmp "$output_root/processes-before.json" "$output_root/processes-after.json"
rpc logs.crashes > "$output_root/crashes-after.json"
print 'Probe checks passed: installd, CSSC correctness, nonzero app geometry, focused text retained across open/close, stable SpringBoard/backboardd.'
print 'Keyboard visibility, layout correctness and transition frames need separate assessment.'
print "Evidence: $output_root"
