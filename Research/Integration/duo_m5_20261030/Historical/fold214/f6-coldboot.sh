#!/bin/zsh
# F6 cold boots of a v1.6 fold VM, headless. Per boot: time to vphoned, launchd
# and kernel_task CPU at 180 s uptime, SpringBoard/backboardd/vphoned pids,
# unlock, the fold (open-flat: the inner display shown and the panel turned;
# closed: the cover back), a cover touch by vphoned (Settings) and by the host
# view (Safari in the Dock) with the foreground app after each, new crash
# reports, screenshots; then a clean stop. Results in run/fold214/f6/<tag>/.
#   f6-coldboot.sh <vm> <tag> [boots]
set -uo pipefail
VM=${1:?vm}; TAG=${2:?tag}; N=${3:-5}
BUNDLE=/Users/kolar/github/vphone-cli-up/.build/fold214/Build/Products/Debug/VPhone.bundle
B=$BUNDLE/Contents/MacOS/vphone-cli
S=/Users/kolar/.vphone/machines/$VM/vphone.sock
OUT=/Users/kolar/vphone-duo-m5/run/fold214/f6/$TAG
mkdir -p $OUT/shots $OUT/boot-logs
send() { print -r -- "$1" | nc -U -w 30 $S 2>/dev/null || true }
rpc() { send "{\"t\":\"rpc\",\"method\":\"$1\",\"params\":${2:-{\}}}" }
note() { print -r -- "$1" | tee -a $OUT/results.txt }
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time' }
crashes() { rpc logs.crashes | jq -r '.result.crashes[]? | .name' | sort }
pidof() { print -r -- "$1" | jq -r --arg n "$2" '[.result.processes[] | select(.name==$n) | .pid][0] // "none"' }
foldlog() { # fold display log lines at or after $1
  local src="String(fs.read('/var/mobile/Library/Caches/vphone-folddisplay.log')).split('\\n').forEach(function (l) { if (parseFloat(l) >= $1) print(l); });"
  jq -nc --arg s "$src" '{t:"rpc",method:"script.eval",params:{source:$s,timeout:30}}' | nc -U -w 40 $S 2>/dev/null | jq -r '.result.output // empty'
}
shot() {
  local p=$(send '{"t":"screenshot"}' | jq -r '.path // empty')
  [[ -n $p && -f $p ]] && mv "$p" $OUT/shots/$1.jpg && sips -g pixelWidth -g pixelHeight $OUT/shots/$1.jpg | tail -2 | awk '{print $2}' | paste -sd x -
}
boot() { # boot <log>; sets lp and ready
  t0=$(date +%s)
  nohup $B vm launch $VM --headless -v > $1 2>&1 &
  lp=$!; ready=""
  while (( $(date +%s) - t0 < 600 )); do
    if [[ -S $S ]] && rpc device.info | jq -e '.ok == true' > /dev/null 2>&1; then
      ready=$(( $(date +%s) - t0 )); break
    fi
    kill -0 $lp 2>/dev/null || break
    sleep 2
  done
}
stopvm() { $B vm stop $VM > $1 2>&1 || note "stop failed ($1)"; wait $lp 2>/dev/null; sleep 5 }

note "candidate $(date '+%F %T') vm=$VM"
note "  source: $(git -C /Users/kolar/vphone-duo-m5/src/fold214 log --oneline -1)"
note "  vphone-vm cdhash: $(codesign -dvvv $BUNDLE/Contents/MacOS/vphone-vm 2>&1 | sed -n 's/^CDHash=//p')"
note "  display-choice: $(cat /Users/kolar/.vphone/machines/$VM/display-choice 2>/dev/null || print 'absent (fold)')"
crashes_before=$OUT/crashes-before.txt # taken once vphoned answers: a stopped VM has no list
for i in $(seq 1 $N); do
  boot $OUT/boot-logs/boot-$i.log
  if [[ -z $ready ]]; then
    note "boot $i: vphoned not ready (launch alive: $(kill -0 $lp 2>/dev/null && print yes || print no))"
    stopvm $OUT/boot-logs/stop-$i.log; continue
  fi
  [[ -s $crashes_before ]] || { crashes > $crashes_before; note "  crash reports before (boot $i, at ready): $(wc -l < $crashes_before | tr -d " ")"; }
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
  rpc display.posture '{"hinge":"closed"}' > /dev/null; sleep 2
  rpc input.button '{"name":"home"}' > /dev/null; sleep 3
  rpc input.tap '{"x":231,"y":577}' > /dev/null; sleep 4
  guest=$(rpc apps.foreground | jq -r '.result.bundle_id // "?"')
  rpc input.button '{"name":"home"}' > /dev/null; sleep 3
  send '{"t":"tap","x":1251,"y":1044}' > /dev/null; sleep 4
  host=$(rpc apps.foreground | jq -r '.result.bundle_id // "?"')
  t1=$(now)
  rpc display.posture '{"hinge":"open-flat"}' > /dev/null; sleep 4
  open=$(shot boot-$i-open)
  rpc display.posture '{"hinge":"closed"}' > /dev/null; sleep 4
  closed=$(shot boot-$i-closed)
  fl=$(foldlog $t1)
  shown=$(print -r -- $fl | grep -c 'shown=1'); held=$(print -r -- $fl | grep -c 'hold on'); released=$(print -r -- $fl | grep -c 'hold off')
  sb2=$(pidof "$(rpc processes.list)" SpringBoard)
  rpc input.button '{"name":"home"}' > /dev/null; sleep 2
  crashes > $OUT/crashes-$i.txt
  new=$(comm -13 $crashes_before $OUT/crashes-$i.txt | sed -E 's/-[0-9]{4}-.*//' | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}')
  cp $OUT/crashes-$i.txt $crashes_before
  note "boot $i: vphoned_ready=${ready}s up=${up}s launchd_cpu=${ld}s kernel_task=${kt}s $pids unlock=$unlock guest_settings=$guest host_dock=$host open=$open inner_shown=$shown closed=$closed holds=$held/$released SB_after_fold=$sb2 new_crashes: ${new:-none}"
  stopvm $OUT/boot-logs/stop-$i.log
done
note "done $(date +%T)"
