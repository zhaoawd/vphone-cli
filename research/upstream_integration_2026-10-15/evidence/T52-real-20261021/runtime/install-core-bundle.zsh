#!/bin/zsh
set -euo pipefail
[[ $EUID -eq 0 ]] || { print -u2 'Administrator authentication required'; exit 2; }
TASK_ROOT=/Users/kolar/github/vphone-cli/.build/t52-real-20261021
EXPECTED_ARCHIVE=f61ce4e0f1c6437fa55b7e488a9c888dd5b5e2bd92b2741fa8a4a2134964660c
ARCHIVE="$TASK_ROOT/2.6.2-local.cd529f26a150.tar"
ACTUAL_ARCHIVE=$(/usr/bin/shasum -a 256 "$ARCHIVE")
[[ "${ACTUAL_ARCHIVE%% *}" == "$EXPECTED_ARCHIVE" ]] || exit 3
ACTUAL_CLI=$(/usr/bin/shasum -a 256 "$TASK_ROOT/package/VPhone.bundle/Contents/MacOS/vphone-cli")
[[ "${ACTUAL_CLI%% *}" == "82f940ed219c41f928e7631989589f550d3c38e20360471a821881b062a42244" ]] || exit 4
/usr/bin/codesign --verify --strict "$TASK_ROOT/package/VPhone.bundle"
"$TASK_ROOT/package/VPhone.bundle/Contents/MacOS/vphone-cli" core-bundle install --version 2.6.2-local.cd529f26a150 --archive "$ARCHIVE" --sha256 "$EXPECTED_ARCHIVE" > "$TASK_ROOT/root-install-receipt.json"
"$TASK_ROOT/package/VPhone.bundle/Contents/MacOS/vphone-cli" core-bundle verify --version 2.6.2-local.cd529f26a150 > "$TASK_ROOT/root-verified-receipt.json"
print 'Installed and verified 2.6.2-local.cd529f26a150; VM and AMFI unchanged.'
