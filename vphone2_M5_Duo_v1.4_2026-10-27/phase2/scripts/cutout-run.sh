#!/bin/zsh
# One cold-boot run of the inner cutout experiment on duo-m5-dd at E1
# (2007x2853@430, rotation 0). Expects the VM stopped.
#   cutout-run.sh C0|C1|C2
#   C0, C2: cutout fix flag absent.  C1: flag holds the rect below.
# Boot 1 lets the host sync the guest libraries and sets both flag files; boot 2
# is the measured cold boot. Records library hashes, the fix's log (loaded,
# enabled, matched, applied), the live status bar provider and screen values
# (touch diagnostic), the window and view each Home screen tap hit with the
# foreground app after it, and GeoBare's three event layers. Ends stopped.
set -uo pipefail
RUN=${1:?C0|C1|C2}
CUTOUT="399 30 37 37"
R=/Users/kolar/vphone-duo-m5/run/phase2
S=/Users/kolar/.vphone/machines/duo-m5-dd/vphone.sock
O=$R/cutout/$RUN
FIX_FLAG=/private/var/tmp/vphone-innercutout
FIX_LOG=/var/mobile/Library/Caches/vphone-innercutout.log
DIAG_FLAG=/private/var/tmp/vphone-touchdiag
DIAG_LOG=/var/mobile/Library/Caches/vphone-touchdiag.log
W=2007; H=2853
mkdir -p $O
send() { print -r -- "$1" | nc -U -w 60 $S 2>/dev/null }
rpc() { send "{\"t\":\"rpc\",\"method\":\"$1\",\"params\":${2:-{\}}}" }
note() { print -r -- "$1" | tee -a $O/results.txt }
stopvm() {
  rpc system.shutdown > /dev/null; sleep 8
  kill -INT $(cat $R/window-$1/pid) 2>/dev/null; sleep 3
  pkill -INT -f 'machines/duo-m5-dd/' 2>/dev/null; sleep 4
  pkill -f 'machines/duo-m5-dd/' 2>/dev/null; sleep 1
}
: > $O/results.txt

# Boot 1: library sync and experiment state.
zsh $R/window-launch.sh 0 cutout-$RUN-prep > /dev/null 2>&1; sleep 20
for f in $FIX_LOG $DIAG_LOG; do rpc files.remove "{\"path\":\"$f\"}" > /dev/null; done
rpc files.write "{\"path\":\"$DIAG_FLAG\",\"content\":\"\"}" > /dev/null
if [[ $RUN == C1 ]]; then
  rpc files.write "{\"path\":\"$FIX_FLAG\",\"content\":\"$CUTOUT\"}" > /dev/null
else
  rpc files.remove "{\"path\":\"$FIX_FLAG\"}" > /dev/null
fi
note "run $RUN: fix flag $([[ $RUN == C1 ]] && print "\"$CUTOUT\"" || print absent), diagnostic flag present"
note "libraries: $(rpc environment.status | jq -c '[.result.libraries[] | select(.name | test("SystemHook|touchdiag|innercutout")) | {name, sha: (.sha256 // "absent" | .[0:12])}]')"
note "bundle vphone-vm: $(shasum -a 256 /Users/kolar/github/vphone-cli-up/.build/pr728-dd/VPhone.bundle/Contents/MacOS/vphone-vm | cut -c1-12)"
stopvm cutout-$RUN-prep

# Boot 2: the measured cold boot.
zsh $R/window-launch.sh 0 cutout-$RUN > /dev/null 2>&1; sleep 25
note "guest boot: $(rpc system.info | jq -c '{uptime: .result.uptime}' 2>/dev/null)"
rpc screen.unlock '{"timeout":30}' > /dev/null
rpc input.button '{"name":"home"}' > /dev/null; sleep 3

# Home screen: tap, record the foreground app, return home.
for src in host guest; do for f in 0.3 0.7; do for g in 0.45 0.65; do
  if [[ $src == host ]]; then
    x=$(( W * f )); y=$(( H * g ))
    send "{\"t\":\"tap\",\"x\":${x%.*},\"y\":${y%.*},\"screen\":false}" > /dev/null
  else
    x=$(( W / 3.0 * f )); y=$(( H / 3.0 * g ))
    rpc input.tap "{\"x\":${x%.*},\"y\":${y%.*}}" > /dev/null
  fi
  sleep 3
  note "home tap $src ${f}x${g}: foreground $(rpc apps.foreground | jq -r '.result.bundle_id // "springboard"')"
  rpc input.button '{"name":"home"}' > /dev/null; sleep 2
done; done; done

# GeoBare: application, window and view layers.
zsh $R/touch-trace.sh cutout-$RUN $W $H > /dev/null 2>&1
note "geobare: $(tail -2 $R/touch-trace/cutout-$RUN/results.txt | head -1)"
cp $R/touch-trace/cutout-$RUN/*(N) $O/ 2>/dev/null

send "{\"t\":\"pull\",\"path\":\"$FIX_LOG\",\"local\":\"$O/innercutout.log\"}" > /dev/null
send "{\"t\":\"pull\",\"path\":\"$DIAG_LOG\",\"local\":\"$O/touchdiag.log\"}" > /dev/null
note "fix log: $([[ -f $O/innercutout.log ]] && grep -v '^$' $O/innercutout.log | tail -2 | tr '\n' ' ' || print absent)"
if [[ -f $O/touchdiag.log ]]; then
  note "live status bar: $(grep -A1 '^statusbar-window SBStatusBarWindow' $O/touchdiag.log | grep -oE 'bounds=[^ ]+ [^ ]+|provider=[^ ]+' | head -2 | tr '\n' ' ')"
  note "screen exclusion: $(grep -m1 -E '^  _exclusionArea' $O/touchdiag.log)"
  note "selection: $(grep -E '^provider-trace \+\[STUIStatusBarVisualProvider_(AxisAlignableSplit|Split) visualProviderSubclassForScreen:proxy info' $O/touchdiag.log | sed 's/.*= //' | tr '\n' ' ')"
  note "home hits: $(grep -E '^t=' $O/touchdiag.log | grep 'phase=0' | grep -oE 'window=[A-Za-z_]+ level=[-0-9]+' | grep -v _UISystemGestureWindow | sort | uniq -c | tr -s ' ' | tr '\n' ';')"
else
  note "touch diagnostic log: absent"
fi
stopvm cutout-$RUN
note "stopped"
