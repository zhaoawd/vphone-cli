#!/bin/zsh
# F6 locked-screen idle of a v1.6 fold VM, headless (default 120 min). Every
# 10 min: uptime, launchd and kernel_task CPU, SpringBoard/backboardd/vphoned
# pids, memory pressure, lock and screen state, new crash reports. After the
# window, before stopping: open while locked (inner lock screen), unlock,
# close, a vphoned tap and a host tap on the cover, each checked, so the run
# shows the guest still answers after the idle and not only that it stayed up.
#   f6-idle.sh <vm> [minutes]
set -uo pipefail
VM=${1:?vm}; MIN=${2:-120}
B=/Users/kolar/github/vphone-cli-up/.build/fold214/Build/Products/Debug/VPhone.bundle/Contents/MacOS/vphone-cli
S=/Users/kolar/.vphone/machines/$VM/vphone.sock
OUT=/Users/kolar/vphone-duo-m5/run/fold214/f6/idle
mkdir -p $OUT
send() { print -r -- "$1" | nc -U -w 60 $S 2>/dev/null || true }
rpc() { send "{\"t\":\"rpc\",\"method\":\"$1\",\"params\":${2:-{\}}}" }
note() { print -r -- "$1" | tee -a $OUT/summary.txt }
shot() {
  local p=$(send '{"t":"screenshot"}' | jq -r '.path // empty')
  [[ -n $p && -f $p ]] && mv "$p" $OUT/$1.jpg && sips -Z 400 $OUT/$1.jpg --out $OUT/s-$1.jpg > /dev/null
}

nohup $B vm launch $VM --headless -v > $OUT/boot.log 2>&1 &
lp=$!
t0=$(date +%s)
while (( $(date +%s) - t0 < 300 )); do
  [[ -S $S ]] && rpc device.info | jq -e '.ok == true' > /dev/null 2>&1 && break
  sleep 2
done
sleep 60
rpc display.posture '{"hinge":"closed"}' > /dev/null
rpc input.button '{"name":"power"}' > /dev/null; sleep 5
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
note "window: $MIN min, launchd ΔCPU/Δwall: $(( (ld - first_cpu) / (up - first_up) ))"

# After the idle: the guest must still answer.
rpc display.posture '{"hinge":"open-flat"}' > /dev/null; sleep 4
note "open while locked: $(rpc device.screen | jq -r '.result | "locked=\(.locked) off=\(.screen_off) \(.width)x\(.height)"')"
shot open-locked
note "unlock: $(rpc screen.unlock '{"timeout":30}' | jq -r 'if .ok then "ok" else "fail \(.error)" end')"
rpc display.posture '{"hinge":"closed"}' > /dev/null; sleep 3
rpc input.button '{"name":"home"}' > /dev/null; sleep 3
rpc input.tap '{"x":231,"y":577}' > /dev/null; sleep 4
note "vphoned tap Settings -> $(rpc apps.foreground | jq -r '.result.bundle_id // "?"')"
rpc input.button '{"name":"home"}' > /dev/null; sleep 3
send '{"t":"tap","x":1251,"y":1044}' > /dev/null; sleep 4
note "host tap Dock Safari -> $(rpc apps.foreground | jq -r '.result.bundle_id // "?"')"
shot after
note "SpringBoard pid after: $(rpc processes.list | jq -r '[.result.processes[] | select(.name=="SpringBoard") | .pid][0] // "none"') (during window: $sb)"
$B vm stop $VM > $OUT/stop.log 2>&1
wait $lp 2>/dev/null
note "stopped $(date +%T)"
