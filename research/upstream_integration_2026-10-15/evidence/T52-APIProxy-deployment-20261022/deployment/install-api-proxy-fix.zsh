#!/bin/zsh
set -euo pipefail
[[ $EUID -eq 0 ]] || { print -u2 'Administrator authentication required'; exit 2; }
TASK_ROOT=/Users/kolar/github/vphone-cli/.build/t52-api-proxy-deploy-20261022
CHECKER='/Library/Application Support/vphone-launchpad/Bundles/2.6.2-local.af333c78ac3b/VPhone.bundle/Contents/MacOS/vphone-cli'
EXPECTED_CHECKER=e297ce7989dba9bb2f810d398ddbc2c572f58f27d0213f7a75ea96e3de3f5a54
ARCHIVE=/Users/kolar/github/vphone-cli/.build/t52-api-proxy-deploy-20261022/2.6.2-local.266810c8ae29.tar
EXPECTED_ARCHIVE=00a12bba36b45355ca53bb73065315c78959676dd620e008d4efb0e840bbbb76
VERSION=2.6.2-local.266810c8ae29
BUNDLE=/Users/kolar/github/vphone-cli/.build/t52-api-proxy-deploy-20261022/package/VPhone.bundle
ACTUAL=$(/usr/bin/shasum -a 256 "$CHECKER")
[[ "${ACTUAL%% *}" == "$EXPECTED_CHECKER" ]] || exit 3
ACTUAL=$(/usr/bin/shasum -a 256 "$ARCHIVE")
[[ "${ACTUAL%% *}" == "$EXPECTED_ARCHIVE" ]] || exit 4
/usr/bin/codesign --verify --strict "$BUNDLE"
"$CHECKER" core-bundle verify --version 2.6.2-local.af333c78ac3b > "$TASK_ROOT/baseline-verified-root.json"
"$CHECKER" core-bundle install --version "$VERSION" --archive "$ARCHIVE" --sha256 "$EXPECTED_ARCHIVE" > "$TASK_ROOT/root-install-receipt.json"
"$CHECKER" core-bundle verify --version "$VERSION" > "$TASK_ROOT/root-verified-receipt.json"
print "Installed and verified $VERSION. VM and AMFI unchanged."
