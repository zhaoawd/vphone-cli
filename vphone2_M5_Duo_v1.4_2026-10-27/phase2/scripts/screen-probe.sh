#!/bin/zsh
# Boot duo-m5-dd at a panel size given as VPHONE_SCREEN (<w>x<h>@<ppi>) and
# record what the guest makes of it. Replaces inner-boot.sh, whose syslog step
# sent a wrong parameter and silently wrote an empty file.
#
# Every capture keeps the raw vphoned reply and states one of: request failed,
# field missing, or succeeded (with a count, which may be zero).
#
#   screen-probe.sh 1878x2670@430 E0
#   screen-probe.sh 2007x2853@430 E1
set -uo pipefail
VM=duo-m5-dd
SPEC=${1:?size, e.g. 1878x2670@430}
TAG=${2:?tag}
B=/Users/kolar/github/vphone-cli-up/.build/pr728-dd/VPhone.bundle/Contents/MacOS/vphone-cli
S=/Users/kolar/.vphone/machines/$VM/vphone.sock
OUT=/Users/kolar/vphone-duo-m5/run/phase2/screen-$TAG
rm -rf $OUT; mkdir -p $OUT
send() { print -r -- "$1" | nc -U -w 90 $S 2>/dev/null || true }
rpc() { send "{\"t\":\"rpc\",\"method\":\"$1\",\"params\":${2:-{\}}}" }

# capture <name> <method> <params> <jq path to the list>
capture() {
  local name=$1 method=$2 params=$3 jpath=$4 raw
  raw=$(rpc $method $params); print -r -- "$raw" > $OUT/$name.raw.json
  if [[ -z $raw ]] || ! print -r -- "$raw" | jq -e '.ok == true' > /dev/null 2>&1; then
    print -r -- "$name: REQUEST FAILED ($(print -r -- "$raw" | jq -r '.error // "no reply"' 2>/dev/null | head -c 200))"
  elif ! print -r -- "$raw" | jq -e "${jpath} | type == \"array\"" > /dev/null 2>&1; then
    print -r -- "$name: FIELD MISSING ($jpath); result keys: $(print -r -- "$raw" | jq -c '.result | keys? // type')"
  else
    print -r -- "$raw" | jq -r "${jpath}[] | if type == \"string\" then . else tojson end" > $OUT/$name.txt
    print -r -- "$name: ok, $(wc -l < $OUT/$name.txt | tr -d ' ') entries"
  fi
}
launchd_cpu() { rpc processes.list | jq -r '[.result.processes[]? | select(.pid == 1) | .cpu_seconds][0] // "?"' }
pids() { rpc processes.list | jq -r '[.result.processes[]? | select(.name == "SpringBoard" or .name == "backboardd") | "\(.name)=\(.pid)"] | sort | join(" ")' }

VPHONE_SCREEN=$SPEC nohup $B vm launch $VM -v > $OUT/boot.log 2>&1 &
pid=$!; t0=$(date +%s); ready=""
while (( $(date +%s) - t0 < 240 )); do
  kill -0 $pid 2>/dev/null || { print "launch exited"; grep -E '^\[vphone\]' $OUT/boot.log | tail -8; exit 1; }
  [[ -S $S ]] && rpc device.info | jq -e '.ok == true' > /dev/null 2>&1 && { ready=$(( $(date +%s) - t0 )); break; }
  sleep 2
done
print -r -- "[$TAG $SPEC] vphoned ready=${ready:-TIMEOUT}s"
grep -E 'Screen' $OUT/boot.log | grep vphone | head -2

# Capture syslog over the settle window instead of sleeping through it.
capture syslog-settle logs.syslog '{"seconds":40,"max_lines":5000}' '.result.entries'
rpc screen.unlock '{"timeout":30}' | jq -c '.result'
sleep 3
print -r -- "host display: $(send '{"t":"display"}' | jq -c '.result')"
print -r -- "guest screen: $(rpc device.screen | jq -c '.result')" | tee $OUT/guest-screen.txt
p0=$(pids); c0=$(launchd_cpu); u0=$(( $(date +%s) - t0 ))
print -r -- "t+${u0}s pids: $p0, launchd cpu ${c0}s"
send "{\"t\":\"screenshot\",\"path\":\"$OUT/home.png\"}" | jq -c '{ok, error}'
rpc apps.launch '{"bundle_id":"com.apple.mobilesafari"}' | jq -c '{ok, error}'
sleep 6
send "{\"t\":\"screenshot\",\"path\":\"$OUT/safari.png\"}" | jq -c '{ok, error}'
send '{"t":"key","name":"home","screen":false}' > /dev/null
capture syslog-use logs.syslog '{"seconds":50,"max_lines":5000}' '.result.entries'
p1=$(pids); c1=$(launchd_cpu); u1=$(( $(date +%s) - t0 ))
print -r -- "t+${u1}s pids: $p1 ($([[ $p0 == $p1 ]] && print unchanged || print CHANGED)), launchd cpu ${c1}s"
capture crashes logs.crashes '{}' '.result.crashes'
for f in $OUT/syslog-*.txt(N); do
  print -r -- "$(basename $f): $(grep -ciE 'watchdog|exception|crash|fault' $f) watchdog/exception/crash/fault lines"
done
rpc system.shutdown > /dev/null 2>&1; sleep 6
kill -INT $pid 2>/dev/null; sleep 2
pkill -INT -f "machines/$VM/" 2>/dev/null; sleep 4; pkill -f "machines/$VM/" 2>/dev/null
wait $pid 2>/dev/null
print "stopped"
