#!/bin/zsh
# F3 edge gestures: from Settings in the foreground, swipe up from the bottom
# edge and record whether the app left the foreground. Paths: the window's
# host `swipe` (VZ touchscreen), vphoned `input.swipe` (no edge flags), and
# vphoned `input.touch` with `edge: 2` (vphoned's own digitizer edge event).
#   f3-edge.zsh <baseline|candidate> <new-output-directory> [trials]
set -euo pipefail
source "${0:a:h}/rpc-request.zsh"
source "${0:a:h}/host-request.zsh"

repo_root="$(cd "${0:a:h}/../../../.." && pwd)"
variant="${1:?usage: f3-edge.zsh <baseline|candidate> <new-output-directory> [trials]}"
output_root="${2:?new evidence directory required}"
trials="${3:-3}"
[[ "$variant" == baseline || "$variant" == candidate ]] || exit 2
[[ "$trials" == <-> ]] && (( trials > 0 && trials <= 20 )) || exit 2
socket_path="$repo_root/.build/acceptance/machines/duo-$variant-20261030/vphone.sock"
[[ -S "$socket_path" && "$output_root" == "$repo_root/.build/"* && ! -e "$output_root" ]] || exit 2
mkdir -p "$output_root"
cp "${0:a}" "$output_root/driver.zsh"
shasum -a 256 "${0:a}" > "$output_root/driver-sha256.txt"
git -C "$repo_root" rev-parse HEAD > "$output_root/source-sha.txt"

rpc() { vphone_host_request "$socket_path" "$(vphone_rpc_request "$@")"; }
host() { vphone_host_request "$socket_path" "$1"; }
foreground() { rpc apps.foreground | jq -r '.result.bundle_id // "none"'; }
result="$output_root/result.tsv"
print -r -- $'posture\tpath\ttrial\tbefore\tafter\tleft_app' > "$result"

edge_touch() {
    local y
    rpc input.touch '{"phase":"down","x":0.5,"y":0.995,"edge":2}' > /dev/null
    for y in 0.95 0.9 0.85 0.8 0.75 0.7 0.65 0.6 0.55 0.5; do
        /bin/sleep 0.02
        rpc input.touch "$(jq -nc --argjson y $y '{phase:"move",x:0.5,y:$y,edge:2}')" > /dev/null
    done
    rpc input.touch '{"phase":"up","x":0.5,"y":0.5,"edge":2}' > /dev/null
}

rpc screen.unlock '{"timeout":30}' > "$output_root/unlock.json"
host '{"t":"display.geometry","screen":false}' | jq -e '.result.windowed == true' >/dev/null \
    || { print -u2 'Host swipes need a windowed launch'; exit 1; }
for posture in closed open; do
    rpc display.posture "$(jq -nc --arg h "$posture" '{hinge:$h}')" > /dev/null
    /bin/sleep 2
    rpc display.rotation '{"orientation":"portrait"}' > /dev/null 2>&1 || true
    for route in host vphoned-swipe vphoned-edge; do
        for trial in {1..$trials}; do
            rpc apps.launch '{"bundle_id":"com.apple.Preferences"}' > /dev/null
            /bin/sleep 2.5
            before=$(foreground)
            rpc device.screen > "$output_root/$posture-$route-$trial-screen.json"
            read w h <<< "$(jq -r '.result|"\(.width) \(.height)"' "$output_root/$posture-$route-$trial-screen.json")"
            read pw ph <<< "$(host '{"t":"display.geometry","screen":false}' | jq -r '.result.screenshot_pixels|"\(.[0]) \(.[1])"')"
            case "$route" in
                host) host "$(jq -nc --argjson x $(( pw / 2 )) --argjson y1 $(( ph - 2 )) --argjson y2 $(( ph / 2 )) \
                    '{t:"swipe",x1:$x,y1:$y1,x2:$x,y2:$y2,ms:250,screen:false}')" > /dev/null ;;
                vphoned-swipe) rpc input.swipe "$(jq -nc --argjson x $(( w / 2 )) --argjson y1 $(( h - 1 )) --argjson y2 $(( h / 2 )) \
                    '{x1:$x,y1:$y1,x2:$x,y2:$y2,seconds:0.25}')" > /dev/null ;;
                vphoned-edge) edge_touch ;;
            esac
            /bin/sleep 1.5
            after=$(foreground)
            left=$([[ "$before" == com.apple.Preferences && "$after" != com.apple.Preferences ]] && print yes || print no)
            print -r -- "$posture	$route	$trial	$before	$after	$left" | tee -a "$result"
        done
    done
done
rpc display.posture '{"hinge":"closed"}' > /dev/null
awk -F'\t' 'NR>1 {k=$1" "$2; n[k]++; if($6=="yes") y[k]++} END{for(k in n) printf "%-22s %d/%d\n", k, y[k], n[k]}' "$result" \
    | sort > "$output_root/summary.txt"
cat "$output_root/summary.txt"
