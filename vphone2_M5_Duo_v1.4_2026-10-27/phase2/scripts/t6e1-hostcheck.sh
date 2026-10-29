#!/bin/zsh
# Headless E1: where does a host-view tap on the Maps icon land? Screenshot
# before and after, foreground after, then the same point by vphoned.
# Expects the VM stopped; ends stopped.
set -uo pipefail
B=/Users/kolar/github/vphone-cli-up/.build/pr728-dd/VPhone.bundle/Contents/MacOS/vphone-cli
S=/Users/kolar/.vphone/machines/duo-m5-dd/vphone.sock
O=/Users/kolar/vphone-duo-m5/run/t6-e1/hostcheck
mkdir -p $O
send() { print -r -- "$1" | nc -U -w 30 $S 2>/dev/null }
rpc() { send "{\"t\":\"rpc\",\"method\":\"$1\",\"params\":${2:-{\}}}" }
home() { rpc input.button '{"name":"home"}' > /dev/null; sleep 3 }
VPHONE_SCREEN=2007x2853@430 nohup $B vm launch duo-m5-dd --headless -v > $O/boot.log 2>&1 &
lp=$!
t0=$(date +%s)
while (( $(date +%s) - t0 < 300 )); do
  [[ -S $S ]] && rpc device.info | jq -e '.ok == true' > /dev/null 2>&1 && break
  sleep 2
done
sleep 60
rpc screen.unlock '{"timeout":30}' > /dev/null; home; home
# The cold-boot sequence: Notes by vphoned, one Home, then the host tap.
rpc input.tap '{"x":281,"y":465}' > /dev/null; sleep 5
print -r -- "after vphoned Notes tap: $(rpc apps.foreground | jq -r .result.bundle_id)"
home
print -r -- "after one Home: $(rpc apps.foreground | jq -r .result.bundle_id)"
send "{\"t\":\"screenshot\",\"path\":\"$O/before.png\"}" > /dev/null
print -r -- "host tap reply: $(send '{"t":"tap","x":1479,"y":1396,"screen":false}' | jq -c 'del(.image)')"
sleep 5
print -r -- "after host tap: $(rpc apps.foreground | jq -r .result.bundle_id)"
send "{\"t\":\"screenshot\",\"path\":\"$O/after-host.png\"}" > /dev/null
home; home
rpc input.tap '{"x":493,"y":465}' > /dev/null; sleep 5
print -r -- "after vphoned tap at the same point: $(rpc apps.foreground | jq -r .result.bundle_id)"
home
$B vm stop duo-m5-dd > /dev/null 2>&1
wait $lp 2>/dev/null
print stopped
