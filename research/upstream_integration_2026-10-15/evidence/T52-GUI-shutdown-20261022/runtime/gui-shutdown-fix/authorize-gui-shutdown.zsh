#!/bin/zsh
set -euo pipefail
[[ $EUID -eq 0 ]] || { print -u2 'Administrator authentication required'; exit 2; }
TASK_ROOT=/Users/kolar/github/vphone-cli/.build/t52-real-20261021/gui-shutdown-fix
CHECKER='/Library/Application Support/vphone-launchpad/Bundles/2.6.2-local.cd529f26a150/VPhone.bundle/Contents/MacOS/vphone-cli'
ARCHIVE=/Users/kolar/github/vphone-cli/.build/t52-real-20261021/gui-shutdown-fix/2.6.2-local.af333c78ac3b.tar
EXPECTED_ARCHIVE=fae9fc55a7342b80279f878f3df0e379dc6e9e787010e8b5c1d97570dc2fa912
VERSION=2.6.2-local.af333c78ac3b
BUNDLE=/Users/kolar/github/vphone-cli/.build/t52-real-20261021/gui-shutdown-fix/package-2/VPhone.bundle
HELPER=/Users/kolar/github/vphone-cli/.build/t52-real-20261021/gui-shutdown-fix/boot-window/scoped-amfidont.py
EXPECTED_HELPER=23eec5c8dfd7f4e057d284524d839a031ab911668c73f930e1a77e4621538182
ACTUAL=$(/usr/bin/shasum -a 256 "$ARCHIVE")
[[ "${ACTUAL%% *}" == "$EXPECTED_ARCHIVE" ]] || exit 3
ACTUAL=$(/usr/bin/shasum -a 256 "$CHECKER")
[[ "${ACTUAL%% *}" == 82f940ed219c41f928e7631989589f550d3c38e20360471a821881b062a42244 ]] || exit 4
ACTUAL=$(/usr/bin/shasum -a 256 "$HELPER")
[[ "${ACTUAL%% *}" == "$EXPECTED_HELPER" ]] || exit 5
/usr/bin/codesign --verify --strict "$BUNDLE"
"$CHECKER" core-bundle verify --version 2.6.2-local.cd529f26a150 > "$TASK_ROOT/old-bundle-verified-root.json"
"$CHECKER" core-bundle install --version "$VERSION" --archive "$ARCHIVE" --sha256 "$EXPECTED_ARCHIVE" > "$TASK_ROOT/root-install-receipt.json"
"$CHECKER" core-bundle verify --version "$VERSION" > "$TASK_ROOT/root-verified-receipt.json"
/usr/bin/python3 "$HELPER"
