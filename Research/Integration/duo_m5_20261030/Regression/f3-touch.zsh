#!/bin/zsh
# F3: touch mapping on the cover and the inner display in each orientation,
# through both input paths, against the preserved touch page in Safari
# (Historical/fold214/f3/touch-server.mjs, run from a copy in the output).
# For each posture x orientation it taps five points (in UI points) through
# vphoned `input.tap` and the window's host `tap` (screenshot pixels), and
# records what the page received. Ported from the v1.6 run/fold214/f3.sh.
#   f3-touch.zsh <baseline|candidate> <new-output-directory>
set -euo pipefail
source "${0:a:h}/rpc-request.zsh"
source "${0:a:h}/host-request.zsh"

repo_root="$(cd "${0:a:h}/../../../.." && pwd)"
variant="${1:?usage: f3-touch.zsh <baseline|candidate> <new-output-directory>}"
output_root="${2:?new evidence directory required}"
[[ "$variant" == baseline || "$variant" == candidate ]] || exit 2
socket_path="$repo_root/.build/acceptance/machines/duo-$variant-20261030/vphone.sock"
[[ -S "$socket_path" && "$output_root" == "$repo_root/.build/"* && ! -e "$output_root" ]] || exit 2
mkdir -p "$output_root"
cp "${0:a}" "$output_root/driver.zsh"
shasum -a 256 "${0:a}" > "$output_root/driver-sha256.txt"
git -C "$repo_root" rev-parse HEAD > "$output_root/source-sha.txt"
cp "${0:a:h}/../Historical/fold214/f3/touch-server.mjs" "$output_root/touch-server.mjs"
touches="$output_root/touches.log"
: > "$touches"
node "$output_root/touch-server.mjs" &
server_pid=$!
trap 'kill $server_pid 2>/dev/null' EXIT
/bin/sleep 1

rpc() { vphone_host_request "$socket_path" "$(vphone_rpc_request "$@")"; }
host() { vphone_host_request "$socket_path" "$1"; }
result="$output_root/result.tsv"
print -r -- $'posture\torientation\tvia\tx\ty\tclient_x\tclient_y\tviewport_w\tviewport_h\tpage_orientation' > "$result"

rpc screen.unlock '{"timeout":30}' > "$output_root/unlock.json"
host '{"t":"display.geometry","screen":false}' > "$output_root/geometry.json"
jq -e '.result.windowed == true' "$output_root/geometry.json" >/dev/null \
    || { print -u2 'Host taps need a windowed launch'; exit 1; }
for posture in closed open-flat; do
    for orientation in portrait landscape-left landscape-right upside-down; do
        label="$posture-$orientation"
        rpc display.posture "$(jq -nc --arg h "$posture" '{hinge:$h}')" > /dev/null
        /bin/sleep 2
        rpc apps.open_url '{"url":"http://192.168.64.1:18766/"}' > /dev/null
        /bin/sleep 3
        # Unsupported physical poses are refused; the reply is kept.
        rpc display.rotation "$(jq -nc --arg o "$orientation" '{orientation:$o}')" \
            > "$output_root/$label-rotation.json" 2>&1 || true
        /bin/sleep 3
        rpc device.screen > "$output_root/$label-screen.json"
        host '{"t":"display.geometry","screen":false}' > "$output_root/$label-geometry.json"
        host "$(jq -nc --arg p "$output_root/$label.jpg" '{t:"screenshot",path:$p}')" > /dev/null
        read w h <<< "$(jq -r '.result|"\(.width) \(.height)"' "$output_root/$label-screen.json")"
        read pw ph <<< "$(jq -r '.result.screenshot_pixels|"\(.[0]) \(.[1])"' "$output_root/$label-geometry.json")"
        for point in "0.5 0.5" "0.3 0.4" "0.7 0.4" "0.3 0.75" "0.7 0.75"; do
            read fx fy <<< "$point"
            x=$(( w * fx )); y=$(( h * fy )); x=${x%.*}; y=${y%.*}
            for via in vphoned host; do
                before=$(wc -l < "$touches")
                if [[ "$via" == vphoned ]]; then
                    rpc input.tap "$(jq -nc --argjson x $x --argjson y $y '{x:$x,y:$y}')" > /dev/null
                else
                    host "$(jq -nc --argjson x $(( x * pw / w )) --argjson y $(( y * ph / h )) '{t:"tap",x:$x,y:$y,screen:false}')" > /dev/null
                fi
                /bin/sleep 0.8
                if (( $(wc -l < "$touches") > before )); then
                    tail -1 "$touches" | jq -r --arg p "$posture" --arg o "$orientation" --arg v "$via" --argjson x $x --argjson y $y \
                        '[$p,$o,$v,$x,$y,.x,.y,.w,.h,.o]|@tsv' >> "$result"
                else
                    print -r -- "$posture	$orientation	$via	$x	$y	none" >> "$result"
                fi
            done
        done
    done
done
rpc display.rotation '{"orientation":"portrait"}' > /dev/null || true
rpc display.posture '{"hinge":"closed"}' > /dev/null
# Offsets (client - injected) per case; one value per path means a constant mapping.
awk -F'\t' 'NR>1 && $6!="none" {k=$1" "$2" "$3; printf "%s\t%.1f\t%.1f\n", k, $6-$4, $7-$5}
            NR>1 && $6=="none" {print $1" "$2" "$3"\tmissed"}' "$result" | sort | uniq -c > "$output_root/offsets.txt"
cat "$output_root/offsets.txt"
