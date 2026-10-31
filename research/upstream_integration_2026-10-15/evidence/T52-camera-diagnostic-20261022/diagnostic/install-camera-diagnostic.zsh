#!/bin/zsh
set -euo pipefail
[[ $EUID -eq 0 ]] || exit 2
ACTUAL=$(/usr/bin/shasum -a 256 '/Library/Application Support/vphone-launchpad/Bundles/2.6.2-local.93805a71796d/VPhone.bundle/Contents/MacOS/vphone-cli')
[[ "${ACTUAL%% *}" == e4b8a787690dffb82251c44edd0979b094d88e44ba06a8fbb8db254e7c150a71 ]] || exit 3
ACTUAL=$(/usr/bin/shasum -a 256 /Users/kolar/github/vphone-cli/.build/t52-camera-diagnostics-20261022/2.6.2-local.56be1ce20ded.tar)
[[ "${ACTUAL%% *}" == 59822dd34e15f7c9734fa69e5f4ceca9dcf1efa442c7d64bf5bac549f8ad05f4 ]] || exit 3
'/Library/Application Support/vphone-launchpad/Bundles/2.6.2-local.93805a71796d/VPhone.bundle/Contents/MacOS/vphone-cli' core-bundle install --version 2.6.2-local.56be1ce20ded --archive /Users/kolar/github/vphone-cli/.build/t52-camera-diagnostics-20261022/2.6.2-local.56be1ce20ded.tar --sha256 59822dd34e15f7c9734fa69e5f4ceca9dcf1efa442c7d64bf5bac549f8ad05f4 > /Users/kolar/github/vphone-cli/.build/t52-camera-diagnostics-20261022/root-install-receipt.json
'/Library/Application Support/vphone-launchpad/Bundles/2.6.2-local.93805a71796d/VPhone.bundle/Contents/MacOS/vphone-cli' core-bundle verify --version 2.6.2-local.56be1ce20ded > /Users/kolar/github/vphone-cli/.build/t52-camera-diagnostics-20261022/root-verified-receipt.json
