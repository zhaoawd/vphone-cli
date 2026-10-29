#!/bin/zsh
# Does duo-m5-dd's saved window frame shrink across launches with no deliberate
# resize? Starts from no saved frame; three plain launch/stop cycles at E1, then
# two with a landscape and back rotation. After every stop: the saved frame.
# While running: the live window frame and content size from the host's
# display command when available. Expects the VM stopped; ends stopped.
set -uo pipefail
R=/Users/kolar/vphone-duo-m5/run/phase2
S=/Users/kolar/.vphone/machines/duo-m5-dd/vphone.sock
O=$R/window-frame
KEY="NSWindow Frame vphone-scene-/Users/kolar/.vphone/machines/duo-m5-dd"
mkdir -p $O; : > $O/results.txt
send() { print -r -- "$1" | nc -U -w 60 $S 2>/dev/null }
rpc() { send "{\"t\":\"rpc\",\"method\":\"$1\",\"params\":${2:-{\}}}" }
note() { print -r -- "$1" | tee -a $O/results.txt }
saved() { defaults read com.vphone.bundle "$KEY" 2> /dev/null || print none }
stopvm() {
  rpc system.shutdown > /dev/null; sleep 8
  kill -INT $(cat $R/window-$1/pid) 2>/dev/null; sleep 3
  pkill -INT -f 'machines/duo-m5-dd/' 2>/dev/null; sleep 4
  pkill -f 'machines/duo-m5-dd/' 2>/dev/null; sleep 2
}
defaults delete com.vphone.bundle "$KEY" 2> /dev/null
note "start: saved $(saved)"
note "screens: $(system_profiler SPDisplaysDataType 2>/dev/null | grep -E 'Resolution|Main Display' | tr -s ' ' | tr '\n' ';')"
for i in 1 2 3 4 5; do
  zsh $R/window-launch.sh 0 frame$i > /dev/null 2>&1
  note "cycle $i running: saved $(saved); display $(send '{"t":"display"}' | jq -c 'del(.image) | .result // .' | cut -c1-300)"
  if (( i >= 4 )); then
    rpc display.rotation '{"orientation":"landscape-left"}' > /dev/null; sleep 5
    note "cycle $i landscape: saved $(saved)"
    rpc display.rotation '{"orientation":"portrait"}' > /dev/null; sleep 5
    note "cycle $i portrait again: saved $(saved)"
  fi
  stopvm frame$i
  note "cycle $i stopped: saved $(saved)"
done
