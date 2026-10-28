#!/bin/zsh
# R0/R1/R2 on a running duo-m5-dd: does attaching a display to vphoned's own
# digitizer events let touches reach an app? GeoBare's touch log is the
# criterion (began received, at the expected point).
#   R0  flag file absent              (vphoned path, no display)
#   R1  flag file present, empty      (display = CADisplay mainDisplay.uniqueId)
#   R2  flag file removed again
# Each group taps four normalized points with input.touch_native down/up.
#   r-experiment.sh <tag>
set -uo pipefail
TAG=${1:?tag}
S=/Users/kolar/.vphone/machines/duo-m5-dd/vphone.sock
O=/Users/kolar/vphone-duo-m5/run/phase2/r-experiment/$TAG
BID=com.autophone.geobare
FLAG=/private/var/tmp/vphoned.touch-display
mkdir -p $O
send() { print -r -- "$1" | nc -U -w 60 $S 2>/dev/null }
rpc() { send "{\"t\":\"rpc\",\"method\":\"$1\",\"params\":${2:-{\}}}" }

dir=$(rpc apps.data_dir "{\"bundle_id\":\"$BID\"}" | jq -r '.result.data_path // empty')
group() {
  local name=$1
  rpc apps.terminate "{\"bundle_id\":\"$BID\"}" > /dev/null
  rpc files.remove "{\"path\":\"$dir/Documents/touches.log\"}" > /dev/null
  rpc apps.launch "{\"bundle_id\":\"$BID\"}" > /dev/null
  sleep 5
  local front=$(rpc apps.foreground | jq -r '.result.bundle_id')
  for p in "0.25 0.25" "0.75 0.25" "0.25 0.75" "0.75 0.75"; do
    set -- ${=p}
    rpc input.touch_native "{\"phase\":\"down\",\"x\":$1,\"y\":$2}" > /dev/null
    sleep 0.15
    rpc input.touch_native "{\"phase\":\"up\",\"x\":$1,\"y\":$2}" > /dev/null
    sleep 1
  done
  send "{\"t\":\"pull\",\"path\":\"$dir/Documents/touches.log\",\"local\":\"$O/$name.log\"}" > /dev/null
  local got=0; [[ -f $O/$name.log ]] && got=$(wc -l < $O/$name.log | tr -d ' ')
  print -r -- "$name: foreground=$front touches_received=$got/4 $([[ -f $O/$name.log ]] && jq -c '[.window.x, .window.y] | map(floor)' $O/$name.log | tr '\n' ' ')" | tee -a $O/results.txt
}

rpc files.remove "{\"path\":\"$FLAG\"}" > /dev/null
group R0
rpc files.write "{\"path\":\"$FLAG\",\"content\":\"\"}" | jq -c '{flag_on: .ok, error}'
( rpc logs.syslog '{"seconds":25,"process":"vphoned","max_lines":2000}' > $O/vphoned-R1.raw.json ) &
lg=$!
sleep 1
group R1
wait $lg
print -r -- "vphoned: $(jq -r '.result.entries[]?.message' $O/vphoned-R1.raw.json | grep 'touch display' | head -3)" | tee -a $O/results.txt
rpc files.remove "{\"path\":\"$FLAG\"}" | jq -c '{flag_off: .ok}'
group R2
