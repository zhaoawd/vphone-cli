#!/bin/zsh
# On a running duo-m5-dd: install the current GeoBare, launch it, send four taps
# through the host view (vphone.sock tap, frame-buffer pixels) and four through
# vphoned (input.tap, screen points), and pull GeoBare's window event log
# (sendEvent), its view touch log (touchesBegan) and its latest sample with the
# scene screen's display identity.
#   touch-trace.sh <tag> <fb-width> <fb-height>
set -uo pipefail
TAG=${1:?tag}; W=${2:?fb width}; H=${3:?fb height}
S=/Users/kolar/.vphone/machines/duo-m5-dd/vphone.sock
U=0000FE01-EE96AF93EAD0FBC8
O=/Users/kolar/vphone-duo-m5/run/phase2/touch-trace/$TAG
BID=com.autophone.geobare
mkdir -p $O
send() { print -r -- "$1" | nc -U -w 30 $S 2>/dev/null }
rpc() { send "{\"t\":\"rpc\",\"method\":\"$1\",\"params\":${2:-{\}}}" }

ideviceinstaller -u $U install /Users/kolar/vphone-duo-m5/src/geo-probe/build/device/GeoBare.ipa 2>&1 | grep -v WARNING | tail -1
rpc apps.terminate "{\"bundle_id\":\"$BID\"}" > /dev/null
dir=$(rpc apps.data_dir "{\"bundle_id\":\"$BID\"}" | jq -r '.result.data_path // empty')
for f in app-events.log events.log touches.log; do rpc files.remove "{\"path\":\"$dir/Documents/$f\"}" > /dev/null; done
rpc apps.launch "{\"bundle_id\":\"$BID\"}" > /dev/null
sleep 6
print -r -- "foreground: $(rpc apps.foreground | jq -r .result.bundle_id)" | tee $O/results.txt
for f in 0.3 0.7; do for g in 0.3 0.7; do
  x=$(( W * f )); y=$(( H * g ))
  send "{\"t\":\"tap\",\"x\":${x%.*},\"y\":${y%.*},\"screen\":false}" > /dev/null; sleep 1.5
done; done
for f in 0.3 0.7; do for g in 0.3 0.7; do
  x=$(( W / 3.0 * f )); y=$(( H / 3.0 * g ))
  rpc input.tap "{\"x\":${x%.*},\"y\":${y%.*}}" > /dev/null; sleep 1.5
done; done
for f in app-events.log events.log touches.log geometry.json; do
  send "{\"t\":\"pull\",\"path\":\"$dir/Documents/$f\",\"local\":\"$O/$f\"}" > /dev/null
done
ap=0; ev=0; tb=0
[[ -f $O/app-events.log ]] && ap=$(wc -l < $O/app-events.log | tr -d " ")
[[ -f $O/events.log ]] && ev=$(jq -s '[.[] | select(.type == 0)] | length' $O/events.log)
[[ -f $O/touches.log ]] && tb=$(wc -l < $O/touches.log | tr -d ' ')
print -r -- "app touch events: $ap, window touch events: $ev, touchesBegan: $tb (8 taps sent)" | tee -a $O/results.txt
[[ -f $O/geometry.json ]] && jq -c '.sceneScreenIdentity' $O/geometry.json | tee -a $O/results.txt
