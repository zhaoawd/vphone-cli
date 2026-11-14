#!/bin/zsh
# Compare the old fixed-panel bottom gesture with the bottom of the rotated UI.
set -euo pipefail
source "${0:a:h}/rpc-request.zsh"
source "${0:a:h}/host-request.zsh"
root="$(cd "${0:a:h}/../../../.." && pwd)"
socket=$(vphone_acceptance_socket "$root" "${1:?acceptance socket required}")
out="${2:?new output directory required}"
out="${out:A}"
expected="${3:?expected vphoned SHA-256 required}"
[[ "$out" == "$root/.build/"* && ! -e "$out" && ${#expected} == 64 && "$expected" != *[^0-9a-f]* ]]
mkdir "$out"
host() { vphone_host_request "$socket" "$1"; }
rpc() { host "$(vphone_rpc_request "$@")"; }
rpc device.info > "$out/device.json"
jq -e --arg sha "$expected" '.result.agent.binary_hash == $sha' "$out/device.json" > /dev/null
host '{"t":"display.geometry","screen":false}' | jq -e '.result.windowed' > /dev/null
rpc screen.unlock '{"timeout":30}' > "$out/unlock.json"
rpc display.posture '{"hinge":"open-flat"}' > "$out/open.json"
sleep 2
print -r -- $'orientation\tpath\ttrial\tbefore\tafter\thome' > "$out/result.tsv"

edge_point() {
    local phase="$1" offset="$2" edge="$3" x=0.5 y="$2"
    if [[ "$edge" == 4 ]]; then x="$offset"; y=0.5; fi
    rpc input.touch "$(jq -nc --arg phase "$phase" --argjson x "$x" --argjson y "$y" --argjson edge "$edge" \
        '{$phase,$x,$y,$edge}')"
}

for orientation in portrait landscape-left; do
    degrees=0
    [[ "$orientation" != landscape-left ]] || degrees=90
    for route in host fixed-bottom interface-bottom; do
        for trial in {1..3}; do
            case_out="$out/$orientation-$route-$trial"
            mkdir "$case_out"
            rpc apps.launch '{"bundle_id":"com.apple.Preferences"}' > "$case_out/launch.json"
            rpc display.rotation "$(jq -nc --arg orientation "$orientation" '{$orientation}')" > "$case_out/rotation.json"
            sleep 1.5
            rpc apps.foreground > "$case_out/foreground-before.json"
            jq -e '.result.verified and .result.bundle_id == "com.apple.Preferences"' "$case_out/foreground-before.json" > /dev/null
            rpc display.orientation > "$case_out/orientation-before.json"
            jq -e --argjson degrees "$degrees" '.result | .degrees == $degrees and .fold_angle >= 175' "$case_out/orientation-before.json" > /dev/null
            if [[ "$route" == host ]]; then
                host '{"t":"display.geometry","screen":false}' > "$case_out/geometry.json"
                payload=$(jq -ec --argjson degrees "$degrees" '.result | select(.input_orientation == $degrees) | .screenshot_pixels as [$w,$h] |
                    {t:"swipe",x1:($w/2),y1:($h-2),x2:($w/2),y2:($h/2),ms:250,screen:false}' "$case_out/geometry.json")
                host "$payload" > "$case_out/gesture.json"
            else
                edge=2
                # 90 degrees maps the interface bottom to the fixed panel's right edge.
                if [[ "$route" == interface-bottom && "$degrees" == 90 ]]; then edge=4; fi
                {
                    edge_point down 0.995 "$edge"
                    for position in 0.95 0.9 0.85 0.8 0.75 0.7 0.65 0.6 0.55 0.5; do
                        sleep 0.02
                        edge_point move "$position" "$edge"
                    done
                    edge_point up 0.5 "$edge"
                } > "$case_out/gesture.jsonl"
            fi
            sleep 1.2
            rpc apps.foreground > "$case_out/foreground-after.json"
            after=$(jq -er '.result | select(.verified == true) | .bundle_id' "$case_out/foreground-after.json")
            home=no
            [[ "$after" != com.apple.springboard ]] || home=yes
            print -r -- "$orientation	$route	$trial	com.apple.Preferences	$after	$home" >> "$out/result.tsv"
        done
    done
done
awk -F '\t' 'NR>1 { key=$1 "\t" $2; total[key]++; if ($6=="yes") home[key]++ }
    END { for (key in total) printf "%s\t%d/%d\n", key, home[key], total[key] }' "$out/result.tsv" | sort | tee "$out/summary.tsv"
awk -F '\t' '$2 != "fixed-bottom" || $1 == "portrait" { checked++; if ($3 != "3/3") failed=1 }
    END { exit (checked != 5 || failed) }' "$out/summary.tsv"
