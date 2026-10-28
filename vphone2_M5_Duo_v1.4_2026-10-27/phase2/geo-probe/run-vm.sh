#!/bin/zsh
# Boot duo-m5-dd once and run GeoProbe (mode B) and GeoBare (mode A) on it,
# saving each app's samples (geometry-<n>.json) and a screenshot under
# run/phase2/geo-<tag>/<App>/, plus device.info. An empty size boots at the
# VM's configured outer panel. ROTATE=landscape-left etc. turns the guest once
# each app is in front (Home refuses rotation).
#   run-vm.sh vm-inner-portrait 2007x2853@430
set -uo pipefail
D=${0:a:h}
TAG=${1:?tag}
SPEC=${2:-}
APPS=(${=APPS:-GeoProbe GeoBare})
VM=duo-m5-dd
U=0000FE01-EE96AF93EAD0FBC8
B=/Users/kolar/github/vphone-cli-up/.build/pr728-dd/VPhone.bundle/Contents/MacOS/vphone-cli
S=/Users/kolar/.vphone/machines/$VM/vphone.sock
OUT=/Users/kolar/vphone-duo-m5/run/phase2/geo-$TAG
rm -rf $OUT; mkdir -p $OUT
send() { print -r -- "$1" | nc -U -w 60 $S 2>/dev/null || true }
rpc() { send "{\"t\":\"rpc\",\"method\":\"$1\",\"params\":${2:-{\}}}" }

if [[ -n $SPEC ]]; then
  VPHONE_SCREEN=$SPEC nohup $B vm launch $VM -v > $OUT/boot.log 2>&1 &
else
  nohup $B vm launch $VM -v > $OUT/boot.log 2>&1 &
fi
pid=$!; t0=$(date +%s)
while (( $(date +%s) - t0 < 240 )); do
  kill -0 $pid 2>/dev/null || { print "launch exited"; grep -E '^\[vphone\]' $OUT/boot.log | tail -8; exit 1; }
  [[ -S $S ]] && rpc device.info | jq -e '.ok == true' > /dev/null 2>&1 && break
  sleep 2
done
print -r -- "[$TAG ${SPEC:-configured}] vphoned ready after $(( $(date +%s) - t0 ))s"
rpc device.info > $OUT/device-info.raw.json
sleep 35
rpc screen.unlock '{"timeout":30}' | jq -c '.result'

for APP in $APPS; do
  BID=$([[ $APP == GeoBare ]] && print com.autophone.geobare || print com.autophone.geoprobe)
  mkdir -p $OUT/$APP
  ideviceinstaller -u $U install $D/build/device/$APP.ipa 2>&1 | grep -v WARNING | tail -1
  rpc apps.terminate "{\"bundle_id\":\"$BID\"}" > /dev/null
  dir=$(rpc apps.data_dir "{\"bundle_id\":\"$BID\"}" | jq -r '.result.data_path // empty')
  [[ -z $dir ]] && { print "$APP: no data_path"; continue; }
  for f in $(rpc files.list "{\"path\":\"$dir/Documents\"}" | jq -r '.result.entries[]?.name | select(startswith("geometry"))'); do
    rpc files.remove "{\"path\":\"$dir/Documents/$f\"}" > /dev/null
  done
  # SBLOG=1: capture SpringBoard's own log (process filter, so it stays under
  # the 5000-line cap) for 20 s around the launch, raw reply kept.
  if [[ -n ${SBLOG:-} ]]; then
    rpc logs.syslog '{"seconds":20,"process":"SpringBoard","max_lines":5000}' > $OUT/$APP/springboard.raw.json &
    sblog=$!
    sleep 1
  fi
  rpc apps.launch "{\"bundle_id\":\"$BID\"}" | jq -c "{app: \"$APP\", ok, error}"
  sleep 6
  if [[ -n ${ROTATE:-} ]]; then
    rpc display.rotation "{\"orientation\":\"$ROTATE\"}" | jq -c '{rotation: .result.name, ok, error}'
    sleep 4
  fi
  send "{\"t\":\"screenshot\",\"path\":\"$OUT/$APP/screen.png\"}" > /dev/null
  for f in $(rpc files.list "{\"path\":\"$dir/Documents\"}" | jq -r '.result.entries[]?.name | select(startswith("geometry"))'); do
    send "{\"t\":\"pull\",\"path\":\"$dir/Documents/$f\",\"local\":\"$OUT/$APP/$f\"}" > /dev/null
  done
  print -r -- "$APP: $(ls $OUT/$APP/geometry-*.json 2>/dev/null | wc -l | tr -d ' ') samples"
  if [[ -n ${SBLOG:-} ]]; then
    wait $sblog
    jq -c "{app: \"$APP\", springboard_log: (if .ok then {count: .result.count, truncated: .result.truncated} else {error: .error} end)}" $OUT/$APP/springboard.raw.json
  fi
  rpc apps.terminate "{\"bundle_id\":\"$BID\"}" > /dev/null
  [[ -n ${ROTATE:-} ]] && { rpc display.rotation '{"orientation":"portrait"}' > /dev/null; sleep 2; }
done

rpc system.shutdown > /dev/null 2>&1; sleep 6
kill -INT $pid 2>/dev/null; sleep 2
pkill -INT -f "machines/$VM/" 2>/dev/null; sleep 4; pkill -f "machines/$VM/" 2>/dev/null
wait $pid 2>/dev/null
print "stopped"
