#!/bin/zsh
# R9 fresh classic control. Requires approval before execution.
set -euo pipefail
BUILD_ROOT=/private/tmp/vphone-v2-build-20261002
TEST_ROOT=/Users/kolar/vphone-v2-accept-20261002
export VPHONE_ROOT="$TEST_ROOT"
export VPHONE_PYTHON=/Users/kolar/github/vphone-cli/.venv/bin/python3
export VPHONE_GUEST_COMPONENTS="$BUILD_ROOT/.build/guest-components-v2/stage"
export VPHONE_API_DAEMON="$BUILD_ROOT/.build/daemon-api-v2/candidate-v2"
CLI="$BUILD_ROOT/.build/vphone-cli.app/Contents/MacOS/vphone-cli"
VPHONE_CLI_BIN="$BUILD_ROOT/.build/vphone-cli.app/Contents/MacOS/vphone-vm" zsh "$BUILD_ROOT/scripts/boot_host_preflight.sh" --assert-bootable
"$CLI" vm create lp-classic-accept-20261002 \
  --library-root "$TEST_ROOT/VMs" --variant regular \
  --iphone-source '/Users/kolar/.vphone/ipsws/iPhone17,3_26.1_23B85_Restore.ipsw' \
  --cloudos-source '/Users/kolar/.vphone/ipsws/399b664dd623358c3de118ffc114e42dcd51c9309e751d43-727c4f5e2432.ipsw' \
  --project-root "$BUILD_ROOT" --root-popup -v
