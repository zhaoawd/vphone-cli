#!/bin/zsh
set -euo pipefail
[[ $EUID -eq 0 ]] || exit 2
ACTUAL=$(/usr/bin/shasum -a 256 /Users/kolar/github/vphone-cli/.build/t52-camera-diagnostics-20261022/diagnostic-maintenance.py)
[[ "${ACTUAL%% *}" == 71eaa7a4151cc49ed7908e85b48a8df8d5b7135b282403f5ef04a9dbbd3ce250 ]] || exit 3
ACTUAL=$(/usr/bin/shasum -a 256 /Users/kolar/github/vphone-cli/research/upstream_integration_2026-10-15/tools/t52_environment_maintenance.py)
[[ "${ACTUAL%% *}" == 8e5cbc5e7deb6f10a794bbb6afa7f4bd096b8f4778f22dc6d2357620c3ead588 ]] || exit 3
ACTUAL=$(/usr/bin/shasum -a 256 /Users/kolar/github/vphone-cli/scripts/cfw_disk_txn.py)
[[ "${ACTUAL%% *}" == c892ccf6f3c821565d07ca8902393bb9b2f2c44ccf8db3fe0e57bd4044b17334 ]] || exit 3
ACTUAL=$(/usr/bin/shasum -a 256 /Users/kolar/github/vphone-cli/scripts/cfw_env_update.py)
[[ "${ACTUAL%% *}" == e70dde3035550196483153c5a00dd032b34435dde543d5f599feae8128bbad5a ]] || exit 3
ACTUAL=$(/usr/bin/shasum -a 256 /Users/kolar/github/vphone-cli/scripts/guest_environment.json)
[[ "${ACTUAL%% *}" == e63467d474c679a44c32f66076b12a2e2175f2371d91b14eee7450c151bb8fad ]] || exit 3
exec /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin PYTHONDONTWRITEBYTECODE=1 /Users/kolar/github/vphone-cli/.venv/bin/python -I -B /Users/kolar/github/vphone-cli/.build/t52-camera-diagnostics-20261022/diagnostic-maintenance.py apply /Users/kolar/github/vphone-cli/.build/t51rt/lib/t52-v2 --resources '/Library/Application Support/vphone-launchpad/Bundles/2.6.2-local.56be1ce20ded/VPhone.bundle/Contents/Resources' --plan /Users/kolar/github/vphone-cli/.build/t51rt/lib/t52-v2/.environment-maintenance-728bf0d4-fa9d-4c12-b5f9-413c93cccb11.json --plan-sha256 c8ed8c96b991a4c49ebbeb01a2ce2e2f9e3bcee4a92d870cecb52e482c60ba17 --work-parent /private/tmp
