#!/bin/zsh
# Single-display fold emulation probe on duo-m5-dd: boot at the Duo's outer
# panel size, resize the running display to the inner panel (1878x2670 @ 430)
# and back through vphone.sock's `display` command, and record at each step the
# host display size, the guest's screen report, a guest screenshot and whether
# the VM is still up. Stops the VM at the end.
set -uo pipefail
VM=duo-m5-dd
B=/Users/kolar/github/vphone-cli-up/.build/pr728-dd/VPhone.bundle/Contents/MacOS/vphone-cli
S=/Users/kolar/.vphone/machines/$VM/vphone.sock
OUT=${OUT:-/Users/kolar/vphone-duo-m5/run/phase2/fold-resize}
mkdir -p $OUT
send() { print -r -- "$1" | nc -U -w 60 $S 2>/dev/null || true }
rpc() { send "{\"t\":\"rpc\",\"method\":\"$1\",\"params\":${2:-{\}}}" }
alive() { pgrep -f "machines/$VM/" > /dev/null && print up || print DOWN }

step() {  # tag
  local tag=$1
  print "--- $tag (vm $(alive)) ---"
  send '{"t":"display"}' | jq -c '.result' | tee $OUT/$tag-host-display.json
  rpc device.screen | jq -c '.result' | tee $OUT/$tag-guest-screen.json
  send "{\"t\":\"screenshot\",\"path\":\"$OUT/$tag.png\"}" | jq -c '{ok, path, error}'
}

nohup $B vm launch $VM -v > $OUT/boot.log 2>&1 &
pid=$!; t0=$(date +%s)
while (( $(date +%s) - t0 < 240 )); do
  kill -0 $pid 2>/dev/null || { print "launch exited"; tail -20 $OUT/boot.log; exit 1; }
  [[ -S $S ]] && rpc device.info | jq -e '.ok == true' > /dev/null 2>&1 && break
  sleep 2
done
print "vphoned ready after $(( $(date +%s) - t0 ))s"
sleep 40
rpc screen.unlock '{"timeout":30}' | jq -c '.result'
sleep 3
step outer-boot

print "=== resize to inner 1878x2670 @ 430 ==="
send '{"t":"display","width":1878,"height":2670,"ppi":430}' | jq -c '{ok, result, error}'
sleep 8
step inner

print "=== resize back to outer 1398x2034 @ 460 ==="
send '{"t":"display","width":1398,"height":2034,"ppi":460}' | jq -c '{ok, result, error}'
sleep 8
step outer-again

rpc logs.syslog '{"lines":6000}' > $OUT/syslog.json
print "vm $(alive) at end"
rpc system.shutdown > /dev/null 2>&1; sleep 6
kill -INT $pid 2>/dev/null; sleep 2
pkill -INT -f "machines/$VM/" 2>/dev/null; sleep 4; pkill -f "machines/$VM/" 2>/dev/null
wait $pid 2>/dev/null
print "stopped"
