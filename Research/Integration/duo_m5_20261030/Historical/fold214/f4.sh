#!/bin/zsh
# F4: lock, screen-off and power scenarios across the fold on duo-m5-fold214.
#   f4.sh <tag> [scenario...]   (default: all of s1..s7)
# Each step records locked/screen_off, the fold display log lines since the
# step began and a screenshot, under f4/<tag>/.
set -uo pipefail
TAG=${1:?tag}; shift
T=/Users/kolar/vphone-duo-m5/run/fold214/tools
S=/Users/kolar/.vphone/machines/duo-m5-fold214/vphone.sock
O=/Users/kolar/vphone-duo-m5/run/fold214/f4/$TAG
mkdir -p $O
LOG=$O/steps.txt

now() { perl -MTime::HiRes=time -e 'printf "%.3f", time' }
rpc() { $T/rpc.sh "$@" }
posture() { rpc display.posture "{\"hinge\":\"$1\"}" > /dev/null }
power() { rpc input.button '{"name":"power"}' > /dev/null }
state() { rpc device.screen | jq -r '.result | "locked=\(.locked) off=\(.screen_off) \(.width)x\(.height)"' }
foldlog() { # lines of the guest fold display log at or after $1
  $T/js.sh - <<EOF
String(fs.read('/var/mobile/Library/Caches/vphone-folddisplay.log')).split('\n').forEach(function (l) { if (parseFloat(l) >= $1) print(l); });
EOF
}
shot() {
  local p=$(print -r -- '{"t":"screenshot"}' | nc -U -w 15 $S | jq -r '.path // empty')
  [[ -n $p && -f $p ]] && mv "$p" $O/$1.jpg && sips -Z 400 $O/$1.jpg --out $O/s-$1.jpg > /dev/null
}
step() { # step <name> : record state, log since the scenario began, screenshot
  print -r -- "  [$1] $(state)" | tee -a $LOG
  shot $SC-$1
}
begin() { # begin <scenario> <description>
  SC=$1; print -r -- "== $1: $2" | tee -a $LOG
  rpc screen.unlock '{"timeout":30}' > /dev/null
  rpc input.button '{"name":"home"}' > /dev/null; /bin/sleep 1
  posture ${3:-closed}; /bin/sleep 3
  T1=$(now)
}
finish() {
  foldlog $T1 | grep -E 'hold|panel owned|shown=|wants state|exception' | sed 's/^/    /' | tee -a $LOG
  local on=$(foldlog $T1 | grep -c 'hold on'); local off=$(foldlog $T1 | grep -c 'hold off')
  print -r -- "  holds on=$on off=$off" | tee -a $LOG
}

run_s1() {
  begin s1 "closed, power off, open while dark" closed
  power; /bin/sleep 2; step dark
  posture open; /bin/sleep 3; step opened
  finish
}
run_s2() {
  begin s2 "open, power off, close while dark" open
  power; /bin/sleep 2; step dark
  posture closed; /bin/sleep 3; step closed
  finish
}
run_s3() {
  begin s3 "open, power off, tap to wake on the inner display" open
  power; /bin/sleep 2; step dark
  rpc input.tap '{"x":300,"y":300}' > /dev/null; /bin/sleep 3; step tapped
  finish
}
run_s4() {
  begin s4 "closed, power off, tap to wake on the cover" closed
  power; /bin/sleep 2; step dark
  rpc input.tap '{"x":233,"y":300}' > /dev/null; /bin/sleep 3; step tapped
  finish
}
run_s5() {
  begin s5 "Safari on the cover, open and power off inside the hold" closed
  rpc apps.launch '{"bundle_id":"com.apple.mobilesafari"}' > /dev/null; /bin/sleep 4
  posture open; /bin/sleep 0.15; power; /bin/sleep 3; step after
  power; /bin/sleep 2; step woken
  finish
}
run_s6() {
  begin s6 "Safari on the inner display, close and power off inside the hold" open
  rpc apps.launch '{"bundle_id":"com.apple.mobilesafari"}' > /dev/null; /bin/sleep 4
  posture closed; /bin/sleep 0.1; power; /bin/sleep 3; step after
  power; /bin/sleep 2; step woken
  finish
}
run_s7() {
  begin s7 "power off, fold 8 times at 0.5 s while dark, end open, wake" closed
  power; /bin/sleep 2
  for i in 1 2 3 4; do posture open; /bin/sleep 0.5; posture closed; /bin/sleep 0.5; done
  posture open; /bin/sleep 3; step dark-open
  power; /bin/sleep 2; step woken
  rpc screen.unlock '{"timeout":30}' > /dev/null; /bin/sleep 2; step unlocked
  finish
}
run_s8() {
  begin s8 "Safari on the inner display, idle past auto-lock, close while auto-locked" open
  rpc apps.launch '{"bundle_id":"com.apple.mobilesafari"}' > /dev/null
  /bin/sleep 330; step idle
  posture closed; /bin/sleep 3; step closed
  finish
}
run_s9() {
  begin s9 "Home on the cover, idle past auto-lock, open while auto-locked" closed
  /bin/sleep 330; step idle
  posture open; /bin/sleep 3; step opened
  rpc screen.unlock '{"timeout":30}' > /dev/null; /bin/sleep 2; step unlocked
  finish
}

: >> $LOG
for s in ${@:-s1 s2 s3 s4 s5 s6 s7}; do run_$s; done
rpc screen.unlock '{"timeout":30}' > /dev/null
posture closed
