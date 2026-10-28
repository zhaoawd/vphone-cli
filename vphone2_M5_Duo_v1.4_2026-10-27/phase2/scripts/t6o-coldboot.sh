#!/bin/zsh
# T6 at the outer size on duo-m5-dd (branch duo-m5-v1.4 bundle): N headless cold
# boots. Per boot: time to vphoned, CPU of launchd and kernel_task at 180 s
# uptime, SpringBoard/backboardd/vphoned pids, new crash reports, a touch check
# (unlock, input.tap on Safari in the side dock, foreground app, back home), a
# screenshot; then a clean stop. Results in run/t6-outer/.
set -uo pipefail
VM=duo-m5-dd
N=${1:-10}
B=/Users/kolar/github/vphone-cli-up/.build/pr728-dd/VPhone.bundle/Contents/MacOS/vphone-cli
S=/Users/kolar/.vphone/machines/$VM/vphone.sock
OUT=/Users/kolar/vphone-duo-m5/run/t6-outer
mkdir -p $OUT/shots $OUT/boot-logs
rpc() { print -r -- "{\"t\":\"rpc\",\"method\":\"$1\",\"params\":${2:-{\}}}" | nc -U -w 30 $S 2>/dev/null || true }
crashes() { rpc logs.crashes | jq -r '.result.crashes[]? | .name' | sort }
pidof() { print -r -- "$1" | jq -r --arg n "$2" '[.result.processes[] | select(.name==$n) | .pid][0] // "none"' }

print -r -- "start $(date +%T) bundle $(codesign -dvvv ${B:h}/vphone-vm 2>&1 | grep -o 'CDHash=[0-9a-f]*')" | tee -a $OUT/results.txt
for i in $(seq 1 $N); do
  t0=$(date +%s)
  nohup $B vm launch $VM --headless -v > $OUT/boot-logs/boot-$i.log 2>&1 &
  lp=$!
  ready=""
  while (( $(date +%s) - t0 < 600 )); do
    if [[ -S $S ]] && rpc device.info | jq -e '.ok == true' > /dev/null 2>&1; then
      ready=$(( $(date +%s) - t0 )); break
    fi
    kill -0 $lp 2>/dev/null || break
    sleep 2
  done
  if [[ -z $ready ]]; then
    print -r -- "boot $i: vphoned not ready (launch alive: $(kill -0 $lp 2>/dev/null && print yes || print no))" | tee -a $OUT/results.txt
  else
    (( i == 1 )) && crashes > $OUT/crashes-before.txt
    while :; do
      up=$(rpc device.info | jq -r '.result.uptime_seconds // 0 | floor')
      (( up >= 180 )) && break
      sleep 5
    done
    ps=$(rpc processes.list)
    ld=$(print -r -- $ps | jq -r '[.result.processes[] | select(.pid==1) | .cpu_seconds | floor][0] // "?"')
    kt=$(print -r -- $ps | jq -r '[.result.processes[] | select(.name=="kernel_task") | .cpu_seconds | floor][0] // "?"')
    pids="SB=$(pidof $ps SpringBoard) BB=$(pidof $ps backboardd) vphoned=$(pidof $ps vphoned)"
    unlock=$(rpc screen.unlock '{"timeout":30}' | jq -r 'if .ok then "ok" else "fail" end')
    sleep 2
    rpc input.button '{"name":"home"}' > /dev/null; sleep 3
    rpc input.tap '{"x":418,"y":352}' > /dev/null; sleep 4
    touch=$(rpc apps.foreground | jq -r '.result.bundle_id // "?"')
    rpc input.button '{"name":"home"}' > /dev/null; sleep 2
    crashes > $OUT/crashes-$i.txt
    new=$(comm -13 $OUT/crashes-before.txt $OUT/crashes-$i.txt | sed -E 's/-[0-9]{4}-.*//' | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}')
    cp $OUT/crashes-$i.txt $OUT/crashes-before.txt
    p=$(print -r -- '{"t":"screenshot"}' | nc -U -w 15 $S | jq -r '.path // empty')
    [[ -n $p && -f $p ]] && mv "$p" $OUT/shots/boot-$i.jpg
    print -r -- "boot $i: vphoned_ready=${ready}s up=${up}s launchd_cpu=${ld}s kernel_task=${kt}s $pids unlock=$unlock touch_safari=$touch new_crashes: ${new:-none}" | tee -a $OUT/results.txt
  fi
  $B vm stop $VM > $OUT/boot-logs/stop-$i.log 2>&1 || print -r -- "boot $i: stop failed" | tee -a $OUT/results.txt
  wait $lp 2>/dev/null
  sleep 5
done
print -r -- "done $(date +%T)" | tee -a $OUT/results.txt
