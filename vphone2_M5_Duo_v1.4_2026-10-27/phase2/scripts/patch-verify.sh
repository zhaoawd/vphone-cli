#!/bin/zsh
# Verifies the packaged inner cutout patch on duo-m5-dd at one size, one cold
# boot: selection and receipt (host), installed library hash, the library's
# log, the live status bar provider, four Home icon taps per input path and
# GeoBare's three layers. Expects the VM stopped; ends stopped.
#   patch-verify.sh <tag> [inner|outer|config]   (config: no VPHONE_SCREEN, inner icons)|outer]
set -uo pipefail
TAG=${1:?tag}; SIZE=${2:-inner}
R=/Users/kolar/vphone-duo-m5/run/phase2
S=/Users/kolar/.vphone/machines/duo-m5-dd/vphone.sock
CLI=/Users/kolar/github/vphone-cli-up/.build/pr728-dd/VPhone.bundle/Contents/MacOS/vphone-cli
BUNDLED=/Users/kolar/github/vphone-cli-up/.build/pr728-dd/VPhone.bundle/Contents/Resources/guest-resources/libinnercutoutfix.dylib
O=$R/patch-verify/$TAG
FIX_LOG=/var/mobile/Library/Caches/vphone-innercutout.log
DIAG_LOG=/var/mobile/Library/Caches/vphone-touchdiag.log
mkdir -p $O
send() { print -r -- "$1" | nc -U -w 60 $S 2>/dev/null }
rpc() { send "{\"t\":\"rpc\",\"method\":\"$1\",\"params\":${2:-{\}}}" }
note() { print -r -- "$1" | tee -a $O/results.txt }
front() { rpc apps.foreground | jq -r '.result.bundle_id // "none"' }
home() { rpc input.button '{"name":"home"}' > /dev/null; sleep 3 }
: > $O/results.txt
# KEEP_FRAME=1 keeps the saved window frame (the delivered behaviour).
if [[ ${KEEP_FRAME:-0} == 1 ]]; then
  note "window frame kept: $(defaults read com.vphone.bundle "NSWindow Frame vphone-scene-/Users/kolar/.vphone/machines/duo-m5-dd" 2>/dev/null)"
else
  defaults delete com.vphone.bundle "NSWindow Frame vphone-scene-/Users/kolar/.vphone/machines/duo-m5-dd" 2> /dev/null
fi

note "selection: $($CLI fw patches duo-m5-dd 2>&1 | grep -E '\] system-springboard-exp-inner_cutout' | tr -s ' ')"
note "receipt guest has it: $(plutil -p ~/.vphone/machines/duo-m5-dd/PatchReceipt.plist | grep -c system-springboard-exp-inner_cutout)"
note "bundled library: $(shasum -a 256 $BUNDLED | cut -c1-12)"

if [[ $SIZE == config ]]; then
  # The display the VM's config.plist names, no VPHONE_SCREEN: an inner config.
  W=2007; H=2853; zsh $R/window-launch-any.sh 0 verify-$TAG > /dev/null 2>&1
  icons=(281.5,465.5=com.apple.mobilenotes 493,465.5=com.apple.Maps 175.5,583.5=com.apple.tv 387.5,701.8=com.apple.Preferences)
elif [[ $SIZE == outer ]]; then
  W=1398; H=2034; zsh $R/window-launch-any.sh 0 verify-$TAG > /dev/null 2>&1
  icons=(145,380=com.apple.mobilenotes 321,380=com.apple.Maps 57,479=com.apple.tv 233,578=com.apple.Preferences)
else
  W=2007; H=2853; zsh $R/window-launch.sh 0 verify-$TAG > /dev/null 2>&1
  icons=(281.5,465.5=com.apple.mobilenotes 493,465.5=com.apple.Maps 175.5,583.5=com.apple.tv 387.5,701.8=com.apple.Preferences)
fi
rpc screen.unlock '{"timeout":30}' > /dev/null; home; home
rpc files.remove '{"path":"/var/mobile/Library/Caches/vphone-innercutout.flag"}' > /dev/null
send "{\"t\":\"screenshot\",\"path\":\"$O/screen.png\"}" > /dev/null
note "framebuffer: $(sips -g pixelWidth -g pixelHeight $O/screen.png 2>/dev/null | awk '/pixel/{printf "%s ", $2}')(config screenConfig $(plutil -extract screenConfig.width raw ~/.vphone/machines/duo-m5-dd/config.plist)x$(plutil -extract screenConfig.height raw ~/.vphone/machines/duo-m5-dd/config.plist))"
note "installed library: $(rpc environment.status | jq -r '.result.libraries[] | select(.name == "libinnercutoutfix.dylib") | (.sha256 // "absent") | .[0:12]')"
sleep 30
send "{\"t\":\"pull\",\"path\":\"$DIAG_LOG\",\"local\":\"$O/touchdiag.log\"}" > /dev/null
note "live provider: $(grep -A1 '^statusbar-window SBStatusBarWindow' $O/touchdiag.log 2>/dev/null | grep -oE 'provider=[^ ]+' | tail -1)"

n=0; opened=0
for src in host guest; do for entry in $icons; do
  n=$(( n + 1 )); p=${entry%%=*}; want=${entry#*=}; ix=${p%,*}; iy=${p#*,}
  home; home; before=$(front)
  if [[ $src == host ]]; then
    x=$(( ix * 3 )); y=$(( iy * 3 ))
    send "{\"t\":\"tap\",\"x\":${x%.*},\"y\":${y%.*},\"screen\":false}" > /dev/null
  else
    rpc input.tap "{\"x\":${ix%.*},\"y\":${iy%.*}}" > /dev/null
  fi
  sleep 5; after=$(front)
  [[ $before == com.apple.springboard && $after == $want ]] && opened=$(( opened + 1 ))
  note "tap$n $src $want before=$before after=$after"
done; done
note "icons opened: $opened/8"
home
zsh $R/touch-trace.sh verify-$TAG $W $H > /dev/null 2>&1
note "geobare: $(sed -n 2p $R/touch-trace/verify-$TAG/results.txt)"
send "{\"t\":\"pull\",\"path\":\"$FIX_LOG\",\"local\":\"$O/innercutout.log\"}" > /dev/null
note "fix log: $(grep -v '^$' $O/innercutout.log 2>/dev/null | tail -2 | tr '\n' ' ')"

rpc system.shutdown > /dev/null; sleep 8
kill -INT $(cat $R/window-verify-$TAG/pid) 2>/dev/null; sleep 3
pkill -INT -f 'machines/duo-m5-dd/' 2>/dev/null; sleep 4
pkill -f 'machines/duo-m5-dd/' 2>/dev/null
note "stopped"
