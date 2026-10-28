#!/bin/zsh
# Map injected touches to where GeoBare receives them on the running duo-m5-dd.
# Four frame-buffer pixel points through the host view (vphone.sock `tap`), then
# the same points through vphoned (`input.tap`, screen points = pixels / 3).
# Pulls GeoBare's Documents/touches.log to run/phase2/touch-map/<tag>.log.
#   touch-map.sh <tag>
set -uo pipefail
TAG=${1:?tag}
S=/Users/kolar/.vphone/machines/duo-m5-dd/vphone.sock
O=/Users/kolar/vphone-duo-m5/run/phase2/touch-map
BID=com.autophone.geobare
mkdir -p $O
send() { print -r -- "$1" | nc -U -w 30 $S 2>/dev/null }
rpc() { send "{\"t\":\"rpc\",\"method\":\"$1\",\"params\":${2:-{\}}}" }

rpc apps.terminate "{\"bundle_id\":\"$BID\"}" > /dev/null
dir=$(rpc apps.data_dir "{\"bundle_id\":\"$BID\"}" | jq -r '.result.data_path // empty')
rpc files.remove "{\"path\":\"$dir/Documents/touches.log\"}" > /dev/null
rpc apps.launch "{\"bundle_id\":\"$BID\"}" | jq -c '{launch: .ok}'
sleep 5
print -r -- "foreground: $(rpc apps.foreground | jq -r .result.bundle_id)"
points=("500 700" "1500 700" "500 2100" "1500 2100")
for p in $points; do
  set -- ${=p}
  send "{\"t\":\"tap\",\"x\":$1,\"y\":$2,\"screen\":false}" | jq -c "{host_tap: [$1, $2], ok}"
  sleep 1.5
done
for p in $points; do
  set -- ${=p}
  x=$(( $1 / 3 )); y=$(( $2 / 3 ))
  rpc input.tap "{\"x\":$x,\"y\":$y}" | jq -c "{guest_tap: [$x, $y], ok, error}"
  sleep 1.5
done
send "{\"t\":\"pull\",\"path\":\"$dir/Documents/touches.log\",\"local\":\"$O/$TAG.log\"}" | jq -c '{pull: .ok, error}'
[[ -f $O/$TAG.log ]] && jq -c '{window, screenFixed, o: .orientation}' $O/$TAG.log
