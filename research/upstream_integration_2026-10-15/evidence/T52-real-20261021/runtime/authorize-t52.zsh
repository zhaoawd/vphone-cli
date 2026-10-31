#!/bin/zsh
set -euo pipefail
[[ $EUID -eq 0 ]] || exit 2
TASK_ROOT=/Users/kolar/github/vphone-cli/.build/t52-real-20261021
INSTALLER_SHA=$(/usr/bin/shasum -a 256 "$TASK_ROOT/install-core-bundle.zsh")
HELPER_SHA=$(/usr/bin/shasum -a 256 "$TASK_ROOT/scoped-amfidont.py")
[[ "${INSTALLER_SHA%% *}" == "ea21ad8eb2661033d99e0e1972d132a6508e8982e0b9eb5243fd0619d3f4f1b6" ]] || exit 3
[[ "${HELPER_SHA%% *}" == "820ed5aecaf019f3afeb588fa664b0ac607aa5e1861a814d926a251912bf9a12" ]] || exit 4
/bin/zsh "$TASK_ROOT/install-core-bundle.zsh"
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 "$TASK_ROOT/scoped-amfidont.py"
