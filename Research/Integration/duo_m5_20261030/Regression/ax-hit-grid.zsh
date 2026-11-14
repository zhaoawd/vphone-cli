#!/bin/zsh
# Compare AX point queries on the cover and inner Home Screen.
set -euo pipefail
source "${0:a:h}/host-request.zsh"
source "${0:a:h}/rpc-request.zsh"
root="$(cd "${0:a:h}/../../../.." && pwd)"
socket=$(vphone_acceptance_socket "$root" "${1:?acceptance socket required}")
out="${2:?new output required}"
out="${out:A}"
expected="${3:?expected daemon SHA-256 required}"
[[ "$out" == "$root/.build/"* && ! -e "$out" ]]
mkdir "$out"
rpc() { vphone_host_request "$socket" "$(vphone_rpc_request "$@")"; }
rpc device.info > "$out/device.json"
jq -e --arg sha "$expected" '.result.agent.binary_hash == $sha' "$out/device.json" >/dev/null
rpc screen.unlock '{"timeout":30}' > "$out/unlock.json"
for hinge in closed open-flat; do
    dest="$out/$hinge"
    mkdir "$dest"
    rpc display.posture "{\"hinge\":\"$hinge\"}" > "$dest/posture.json"
    rpc display.rotation '{"orientation":"portrait"}' > "$dest/rotation.json"
    rpc input.button '{"name":"home"}' > "$dest/home.json"
    sleep 2
    rpc apps.foreground > "$dest/foreground.json"
    jq -e '.result.verified and .result.bundle_id == "com.apple.springboard"' "$dest/foreground.json" >/dev/null
    rpc display.orientation > "$dest/orientation.json"
    jq -e --arg hinge "$hinge" '.result | .degrees == 0 and (if $hinge == "closed" then .fold_angle <= 5 else .fold_angle >= 175 end)' "$dest/orientation.json" >/dev/null
    rpc device.screen > "$dest/screen.json"
    rpc ui.tree > "$dest/tree.json"
    jq -nc --slurpfile screen "$dest/screen.json" --slurpfile tree "$dest/tree.json" '
        ($screen[0].result | [.width,.height]) as [$w,$h] |
        [([0.1,0.3,0.5,0.7,0.9][] as $x | [0.15,0.4,0.65,0.85][] as $y |
            {kind:"grid",x:($x*$w),y:($y*$h)}),
         ($tree[0].result.elements[] | select(.identifier=="Settings" and .visible and .clickable) |
            {kind:"settings",x,y})] | .[]' > "$dest/points.jsonl"
    while IFS= read -r point; do
        args=$(print -r -- "$point" | jq -c '{x,y}')
        reply=$(rpc ui.element_at "$args" 2>&1) || true
        jq -nc --argjson point "$point" --argjson reply "$reply" '{$point,$reply}' >> "$dest/results.jsonl"
    done < "$dest/points.jsonl"
    jq -s '{count:length, success:map(select(.reply.ok))|length, errors:(map(select(.reply.ok|not)|.reply.error)|group_by(.)|map({message:.[0],count:length}))}' \
        "$dest/results.jsonl" | tee "$dest/summary.json"
done
