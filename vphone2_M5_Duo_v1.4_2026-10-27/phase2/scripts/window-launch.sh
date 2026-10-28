#!/bin/zsh
# Launch duo-m5-dd windowed at the inner render size with a panel rotation,
# unlock, open GeoProbe and leave the VM running for a visual check.
#   window-launch.sh <panel-rotation-degrees> <tag>
set -uo pipefail
ROT=${1:?degrees}
TAG=${2:?tag}
CLI=/Users/kolar/github/vphone-cli-up/.build/pr728-dd/VPhone.bundle/Contents/MacOS/vphone-cli
S=/Users/kolar/.vphone/machines/duo-m5-dd/vphone.sock
O=/Users/kolar/vphone-duo-m5/run/phase2/window-$TAG
mkdir -p $O
rpc() { print -r -- "{\"t\":\"rpc\",\"method\":\"$1\",\"params\":${2:-{\}}}" | nc -U -w 60 $S 2>/dev/null }

VPHONE_PANEL_ROTATION=$ROT VPHONE_SCREEN=2007x2853@430 nohup $CLI vm launch duo-m5-dd -v > $O/boot.log 2>&1 &
print -r -- $! > $O/pid
t0=$(date +%s)
while true; do
  now=$(date +%s)
  if (( now - t0 > 200 )); then print "timeout"; break; fi
  if [[ -S $S ]] && rpc device.info | jq -e '.ok' > /dev/null 2>&1; then break; fi
  sleep 2
done
print -r -- "ready after $(( $(date +%s) - t0 ))s"
sleep 35
rpc screen.unlock '{"timeout":30}' | jq -c .result
rpc apps.launch '{"bundle_id":"com.autophone.geoprobe"}' | jq -c '{ok}'
sleep 4
print -r -- "springboard orientation: $(rpc display.orientation | jq -c .result)"
