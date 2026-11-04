#!/bin/zsh
# Requires a disposable, running Duo with Always On Display enabled after
# the MobileGestalt cache update and reboot. Changes its pose and lock state.
set -euo pipefail
source "${0:a:h}/host-request.zsh"
source "${0:a:h}/rpc-request.zsh"

repo_root="${0:a:h:h:h:h:h}"
socket_path="${1:?usage: always-on.zsh <acceptance-socket> <new-output-directory>}"
output_root="${2:?a new evidence directory is required}"
[[ "$socket_path" == "$repo_root/.build/"* && -S "$socket_path" ]] || exit 2
[[ "$output_root" == "$repo_root/.build/"* && ! -e "$output_root" ]] || exit 2
mkdir "$output_root"
cp "${0:a}" "$output_root/driver.zsh"
git -C "$repo_root" rev-parse HEAD > "$output_root/source-sha.txt"

host_request() { vphone_host_request "$socket_path" "$1"; }
rpc() { host_request "$(vphone_rpc_request "$@")"; }
snapshot() {
    rpc device.screen > "$output_root/$1-screen.json"
    rpc display.orientation > "$output_root/$1-orientation.json"
    rpc notify.state '{"name":"com.vphone.folddisplay.panel-dark"}' > "$output_root/$1-panel.json"
}

rpc screen.unlock '{"timeout":30}' > "$output_root/unlock.json"
rpc display.posture '{"hinge":"closed"}' > "$output_root/closed.json"
sleep 2
snapshot awake
rpc input.button '{"name":"power"}' > "$output_root/power.json"
for second in {1..10}; do
    sleep 1
    snapshot "lock-$second"
done
host_request "$(jq -nc --arg path "$output_root/always-on.jpg" '{t:"screenshot",path:$path}')" > "$output_root/screenshot.json"
jq -se '.[0].result.locked == true and .[0].result.screen_off == true and
    .[1].result.screen_off == false and .[2].result.state == 1' \
    "$output_root/lock-10-screen.json" "$output_root/lock-10-orientation.json" "$output_root/lock-10-panel.json" > "$output_root/always-on-verdict.json"
rpc screen.unlock '{"timeout":30}' > "$output_root/wake.json"
snapshot wake
jq -e '.result.locked == false and .result.screen_off == false' "$output_root/wake-screen.json" > "$output_root/wake-verdict.json"
print 'Always On panel state and wake passed; inspect always-on.jpg for rendered content.'
