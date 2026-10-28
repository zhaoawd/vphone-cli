#!/bin/zsh
# On a running duo-m5-dd whose environment holds libtouchdiag: turn the
# SpringBoard touch diagnostic on, respring, tap the Home screen four times
# through the host view and four through vphoned, pull the diagnostic log, then
# turn it off and respring again. Records whether the library was installed,
# loaded and active, so a run where it was not is reported as such.
#   sb-trace.sh <tag> <fb-width> <fb-height>
set -uo pipefail
TAG=${1:?tag}; W=${2:?fb width}; H=${3:?fb height}
S=/Users/kolar/.vphone/machines/duo-m5-dd/vphone.sock
O=/Users/kolar/vphone-duo-m5/run/phase2/sb-trace/$TAG
FLAG=/private/var/tmp/vphone-touchdiag
LOG=/var/mobile/Library/Caches/vphone-touchdiag.log
mkdir -p $O
send() { print -r -- "$1" | nc -U -w 60 $S 2>/dev/null }
rpc() { send "{\"t\":\"rpc\",\"method\":\"$1\",\"params\":${2:-{\}}}" }
note() { print -r -- "$1" | tee -a $O/results.txt }

note "installed: $(rpc environment.status | jq -c '[.result.libraries[] | select(.name=="libtouchdiag.dylib" or .name=="SystemHook-vphone.dylib") | {name, sha: (.sha256 // "absent" | .[0:12])}]')"
rpc files.remove "{\"path\":\"$LOG\"}" > /dev/null
rpc files.write "{\"path\":\"$FLAG\",\"content\":\"\"}" | jq -c '{flag_on: .ok}'
note "respring: $(rpc system.respring '{"force":true}' | jq -c '{ok, error}')"
sleep 15
rpc screen.unlock '{"timeout":30}' > /dev/null
rpc input.button '{"name":"home"}' > /dev/null; sleep 3
for f in 0.3 0.7; do for g in 0.45 0.65; do
  x=$(( W * f )); y=$(( H * g ))
  send "{\"t\":\"tap\",\"x\":${x%.*},\"y\":${y%.*},\"screen\":false}" > /dev/null; sleep 2
  rpc input.button '{"name":"home"}' > /dev/null; sleep 2
done; done
for f in 0.3 0.7; do for g in 0.45 0.65; do
  x=$(( W / 3.0 * f )); y=$(( H / 3.0 * g ))
  rpc input.tap "{\"x\":${x%.*},\"y\":${y%.*}}" > /dev/null; sleep 2
  rpc input.button '{"name":"home"}' > /dev/null; sleep 2
done; done
send "{\"t\":\"pull\",\"path\":\"$LOG\",\"local\":\"$O/touchdiag.log\"}" > /dev/null
if [[ -f $O/touchdiag.log ]]; then
  note "log: $(grep -cE '^t=' $O/touchdiag.log) touch event lines; $(grep -E 'loaded|active' $O/touchdiag.log | tail -1)"
else
  note "log: absent (library not loaded or not writing)"
fi
rpc files.remove "{\"path\":\"$FLAG\"}" | jq -c '{flag_off: .ok}'
rpc system.respring '{"force":true}' > /dev/null
sleep 12
note "cleanup: flag removed, resprung"
