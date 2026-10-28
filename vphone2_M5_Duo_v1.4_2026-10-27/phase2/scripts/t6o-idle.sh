#!/bin/zsh
# T6 at the outer size on duo-m5-dd: a long idle run (default 120 min), headless.
# Every 10 min: uptime, launchd and kernel_task CPU, SpringBoard / backboardd /
# vphoned pids, memory pressure, screen state, new crash reports. Ends with
# launchd ΔCPU/Δwall over the whole window and per interval. Auto-Lock is
# 120 s on this guest, so the idle run is a locked-screen idle.
#   t6o-idle.sh [minutes]
set -uo pipefail
VM=duo-m5-dd
MIN=${1:-120}
B=/Users/kolar/github/vphone-cli-up/.build/pr728-dd/VPhone.bundle/Contents/MacOS/vphone-cli
S=/Users/kolar/.vphone/machines/$VM/vphone.sock
OUT=/Users/kolar/vphone-duo-m5/run/t6-outer/idle
mkdir -p $OUT
rpc() { print -r -- "{\"t\":\"rpc\",\"method\":\"$1\",\"params\":${2:-{\}}}" | nc -U -w 60 $S 2>/dev/null || true }

nohup $B vm launch $VM --headless -v > $OUT/boot.log 2>&1 &
lp=$!
t0=$(date +%s)
while (( $(date +%s) - t0 < 300 )); do
  [[ -S $S ]] && rpc device.info | jq -e '.ok == true' > /dev/null 2>&1 && break
  sleep 2
done
sleep 60
rpc screen.unlock '{"timeout":30}' > /dev/null
print -r -- "time uptime_s launchd_cpu kernel_task_cpu SB BB vphoned mem_pressure locked screen_off new_crashes" > $OUT/samples.tsv
first_up=""; first_cpu=""
for n in $(seq 0 $(( MIN / 10 ))); do
  info=$(rpc device.info); ps=$(rpc processes.list)
  up=$(print -r -- $info | jq -r '.result.uptime_seconds // 0')
  ld=$(print -r -- $ps | jq -r '[.result.processes[] | select(.pid==1) | .cpu_seconds][0] // 0')
  kt=$(print -r -- $ps | jq -r '[.result.processes[] | select(.name=="kernel_task") | .cpu_seconds][0] // 0')
  sb=$(print -r -- $ps | jq -r '[.result.processes[] | select(.name=="SpringBoard") | .pid][0] // "none"')
  bb=$(print -r -- $ps | jq -r '[.result.processes[] | select(.name=="backboardd") | .pid][0] // "none"')
  vd=$(print -r -- $ps | jq -r '[.result.processes[] | select(.name=="vphoned") | .pid][0] // "none"')
  mp=$(rpc memory.pressure | jq -c '.result // .error' | tr -d ' ')
  sc=$(rpc device.screen | jq -r '"\(.result.locked) \(.result.screen_off)"')
  cr=$(rpc logs.crashes | jq -r --argjson t $t0 '[.result.crashes[]? | select(.mtime >= $t) | .process] | group_by(.) | map("\(.[0])=\(length)") | join(",")')
  print -r -- "$(date +%T) $up $ld $kt $sb $bb $vd $mp $sc ${cr:-none}" >> $OUT/samples.tsv
  [[ -z $first_up ]] && { first_up=$up; first_cpu=$ld; }
  (( n < MIN / 10 )) && sleep 600
done
print -r -- "launchd ΔCPU/Δwall over the window: $(( (ld - first_cpu) / (up - first_up) ))" | tee $OUT/summary.txt
$B vm stop $VM > $OUT/stop.log 2>&1
wait $lp 2>/dev/null
print -r -- "stopped $(date +%T)" >> $OUT/summary.txt
