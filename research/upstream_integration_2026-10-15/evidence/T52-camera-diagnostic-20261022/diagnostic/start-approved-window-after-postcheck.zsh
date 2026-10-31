#!/bin/zsh
set -euo pipefail
[[ $EUID -eq 0 ]] || exit 2
ACTUAL=$(/usr/bin/shasum -a 256 /Users/kolar/github/vphone-cli/.build/t52-camera-diagnostics-20261022/boot-window/scoped-amfidont.py)
[[ "${ACTUAL%% *}" == 4569e126042d1ef24ab5717b1b4448d06614aeb7756d5ab08e6c8ae0e41d498a ]] || exit 3
ACTUAL=$(/usr/bin/shasum -a 256 /Users/kolar/github/vphone-cli/research/upstream_integration_2026-10-15/tools/t52_helper_supervisor.py)
[[ "${ACTUAL%% *}" == 0c1d94c15b23467dd9c99e1a44585d9d9d8116024567d60e28bac5da4aa7ab20 ]] || exit 3
diagnostic_wait_deadline=$(( $(/bin/date +%s) + 360 ))
while [[ ! -f /Users/kolar/github/vphone-cli/.build/t52-camera-diagnostics-20261022/postcheck.json ]]; do
  (( $(/bin/date +%s) < diagnostic_wait_deadline )) || exit 4
  /bin/sleep 1
done
/usr/bin/python3 - /Users/kolar/github/vphone-cli/.build/t52-camera-diagnostics-20261022/postcheck.json <<'CHECK'
import json,sys
p=json.load(open(sys.argv[1]))
assert p['classification']=='already_current' and p['replace']==[]
assert p['vm']=='/Users/kolar/github/vphone-cli/.build/t51rt/lib/t52-v2'
CHECK
exec /usr/bin/python3 -u /Users/kolar/github/vphone-cli/.build/t52-camera-diagnostics-20261022/boot-window/scoped-amfidont.py
